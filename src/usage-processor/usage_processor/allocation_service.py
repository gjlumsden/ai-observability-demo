from datetime import datetime, timedelta, timezone
import logging
import uuid

from .allocation import (
    allocate_cost_bucket,
    build_run_complete_row,
    unavailable_claude_row,
)
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
EXTERNAL_QUERY_SOURCE_TYPE = "cost-management-query"
EXTERNAL_QUERY_SOURCE_SCOPE = "subscription"


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
        attempt = int(claim.properties.get("Attempt") or 0) + 1
        run_id = _run_id(
            "finops-focus",
            manifest.path,
            manifest.etag,
            attempt,
        )
        try:
            year, month = validate_manifest_scope(
                manifest.path, settings.workload_resource_group_id
            )
            claim = state_store.transition(
                claim,
                "reading",
                {"RunId": run_id, "Attempt": attempt},
            )
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
                not bucket.resource_id
                or bucket.resource_id.casefold()
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
        completion = build_run_complete_row(
            run_id=run_id,
            source_type="finops-hub-focus-v1.2-preview",
            source_scope=settings.workload_resource_group_id,
            source_path=manifest.path,
            source_etag=manifest.etag,
            expected_record_count=len(allocation_rows),
        )
        validator.validate_allocation(completion)
        ingestion_writer.upload(settings.dcr_allocation_stream, [completion])
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
    source_etag = external_result_etag(
        costs,
        query_start=start,
        query_end=end,
    )
    source_path = external_cost_source_path(settings.subscription_id)
    claim = state_store.claim_cost(
        source_path,
        source_etag,
        {"SourcePath": source_path, "SourceETag": source_etag},
    )
    if claim.outcome == "complete":
        return {"processed": 0, "rows": 0, "duplicate": True}
    attempt = int(claim.properties.get("Attempt") or 0) + 1
    run_id = _run_id(
        EXTERNAL_QUERY_SOURCE_TYPE,
        source_path,
        source_etag,
        attempt,
    )
    claim = state_store.transition(
        claim,
        "reading",
        {"RunId": run_id, "Attempt": attempt},
    )
    rows = build_external_rows(
        costs,
        source_path,
        source_etag,
        run_id=run_id,
    )
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
    completion = build_run_complete_row(
        run_id=run_id,
        source_type=EXTERNAL_QUERY_SOURCE_TYPE,
        source_scope=EXTERNAL_QUERY_SOURCE_SCOPE,
        source_path=source_path,
        source_etag=source_etag,
        expected_record_count=len(rows),
    )
    validator.validate_allocation(completion)
    ingestion_writer.upload(settings.dcr_allocation_stream, [completion])
    state_store.transition(claim, "allocated")
    LOGGER.info("Claude external context processed: rows=%d", len(rows))
    return {"processed": 1, "rows": len(rows), "duplicate": False}


def default_external_query_range(now=None):
    current = now or datetime.now(timezone.utc)
    end = datetime.combine(
        current.date(), datetime.min.time(), tzinfo=timezone.utc
    )
    return end - timedelta(days=7), end


def external_cost_source_path(subscription_id):
    return (
        f"/subscriptions/{subscription_id}"
        "/providers/Microsoft.CostManagement/query"
        "?api-version=2026-06-01&view=claude-ccu-daily-snapshot"
    )


def _month_range(year, month):
    start = datetime(year, month, 1, tzinfo=timezone.utc)
    if month == 12:
        return start, datetime(year + 1, 1, 1, tzinfo=timezone.utc)
    return start, datetime(year, month + 1, 1, tzinfo=timezone.utc)


def _upload_in_batches(writer, stream_name, rows):
    for start in range(0, len(rows), INGESTION_BATCH_SIZE):
        writer.upload(stream_name, rows[start : start + INGESTION_BATCH_SIZE])


def _run_id(source_type, source_path, source_etag, attempt):
    return str(
        uuid.uuid5(
            uuid.NAMESPACE_URL,
            f"{source_type}|{source_path}|{source_etag}|attempt={attempt}",
        )
    )
