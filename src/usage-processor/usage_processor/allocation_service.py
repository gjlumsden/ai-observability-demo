from datetime import datetime, timedelta, timezone
import logging
import uuid

from .allocation import allocate_cost_bucket, unavailable_claude_row
from .cost_context import build_external_rows, external_result_etag
from .errors import FocusContractError, ScopeViolation
from .focus import (
    group_focus_rows,
    is_claude_ccu_bucket,
    validate_focus_rows,
    validate_manifest_scope,
)


LOGGER = logging.getLogger("usage_processor.allocation")
INGESTION_BATCH_SIZE = 500


def process_focus_manifests(
    *,
    settings,
    source,
    state_store,
    usage_query,
    ingestion_writer,
    validator,
):
    processed = 0
    skipped = 0
    rejected = 0
    for manifest in source.list_completed_manifests():
        claim = state_store.claim_cost(
            manifest.path,
            manifest.etag,
            {"SourcePath": manifest.path, "SourceETag": manifest.etag},
        )
        if claim.outcome == "complete":
            skipped += 1
            continue
        if claim.status == "ingesting":
            skipped += 1
            LOGGER.warning(
                "Skipped an ambiguously ingested cost dataset; the immutable run may already exist."
            )
            continue
        run_id = str(
            uuid.uuid5(
                uuid.NAMESPACE_URL,
                f"finops-focus|{manifest.path}|{manifest.etag}",
            )
        )
        try:
            year, month = validate_manifest_scope(
                manifest.path, settings.workload_resource_group_id
            )
            claim = state_store.transition(claim, "reading", {"RunId": run_id})
            rows = source.read_rows(manifest)
            validate_focus_rows(rows, settings.workload_resource_group_id)
        except (FocusContractError, ScopeViolation) as error:
            state_store.transition(
                claim,
                "rejected",
                {"FailureCode": str(error)[:256]},
            )
            LOGGER.warning(
                "Rejected a FOCUS dataset because its contract or scope was invalid."
            )
            rejected += 1
            continue

        buckets = group_focus_rows(rows, settings.workload_model_resource_ids)
        allocation_rows = []
        has_claude_ccu = False
        for bucket in buckets:
            has_claude_ccu = has_claude_ccu or is_claude_ccu_bucket(bucket)
            if bucket.provider is None:
                weights = []
                no_usage_status = "unallocated-unmatched-meter"
            elif (
                bucket.provider == "OpenAI"
                and bucket.resource_id
                and bucket.resource_id.casefold()
                not in {
                    item.casefold()
                    for item in settings.workload_model_resource_ids
                }
            ):
                weights = []
                no_usage_status = "unallocated-resource-mismatch"
            else:
                weights = usage_query.get_weights(
                    bucket, settings.workload_resource_group_id
                )
                no_usage_status = "unallocated-no-matching-usage"
            allocation_rows.extend(
                allocate_cost_bucket(
                    bucket,
                    weights,
                    run_id=run_id,
                    source_scope=settings.workload_resource_group_id,
                    source_path=manifest.path,
                    source_etag=manifest.etag,
                    no_usage_status=no_usage_status,
                )
            )

        if not has_claude_ccu:
            period_start, period_end = _month_range(year, month)
            allocation_rows.append(
                unavailable_claude_row(
                    run_id=run_id,
                    source_scope=settings.workload_resource_group_id,
                    source_path=manifest.path,
                    source_etag=manifest.etag,
                    charge_period_start=period_start,
                    charge_period_end=period_end,
                )
            )

        for row in allocation_rows:
            validator.validate_allocation(row)
        claim = state_store.transition(
            claim,
            "ingesting",
            {"AllocationRows": len(allocation_rows)},
        )
        _upload_in_batches(
            ingestion_writer,
            settings.dcr_allocation_stream,
            allocation_rows,
        )
        state_store.transition(claim, "allocated")
        processed += 1

    LOGGER.info(
        "FOCUS manifests processed: processed=%d skipped=%d rejected=%d",
        processed,
        skipped,
        rejected,
    )
    return {"processed": processed, "skipped": skipped, "rejected": rejected}


def process_external_claude_context(
    *,
    settings,
    start,
    end,
    cost_query,
    state_store,
    ingestion_writer,
    validator,
):
    costs = cost_query.query_claude_ccu(start, end)
    source_etag = external_result_etag(costs)
    source_path = (
        f"/subscriptions/{settings.subscription_id}"
        "/providers/Microsoft.CostManagement/query"
        f"?api-version=2026-06-01&from={start.date()}&to={end.date()}"
    )
    claim = state_store.claim_cost(
        source_path,
        source_etag,
        {"SourcePath": source_path, "SourceETag": source_etag},
    )
    if claim.outcome == "complete":
        return {"processed": 0, "rows": 0, "duplicate": True}
    if claim.status == "ingesting":
        LOGGER.warning(
            "Skipped ambiguously ingested Claude context; the immutable run may already exist."
        )
        return {"processed": 0, "rows": 0, "duplicate": True}

    rows = build_external_rows(costs, source_path, source_etag)
    for row in rows:
        validator.validate_allocation(row)
    claim = state_store.transition(
        claim,
        "ingesting",
        {"AllocationRows": len(rows)},
    )
    _upload_in_batches(
        ingestion_writer,
        settings.dcr_allocation_stream,
        rows,
    )
    state_store.transition(claim, "allocated")
    LOGGER.info("Claude external context processed: rows=%d", len(rows))
    return {"processed": 1, "rows": len(rows), "duplicate": False}


def default_external_query_range(now=None):
    current = now or datetime.now(timezone.utc)
    end = datetime.combine(
        current.date(), datetime.min.time(), tzinfo=timezone.utc
    )
    return end - timedelta(days=7), end


def _month_range(year, month):
    start = datetime(year, month, 1, tzinfo=timezone.utc)
    if month == 12:
        return start, datetime(year + 1, 1, 1, tzinfo=timezone.utc)
    return start, datetime(year, month + 1, 1, tzinfo=timezone.utc)


def _upload_in_batches(writer, stream_name, rows):
    for start in range(0, len(rows), INGESTION_BATCH_SIZE):
        writer.upload(stream_name, rows[start : start + INGESTION_BATCH_SIZE])
