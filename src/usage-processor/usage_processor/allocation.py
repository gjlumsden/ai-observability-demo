"""Custom workload allocation built on Microsoft FOCUS and Logs Ingestion.

The upstream services normalize cost and append log rows. They do not allocate
cost to application subjects or publish several ingestion batches atomically.
Stable record IDs and a final run marker make those custom operations retryable.
"""

from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_EVEN
import hashlib
import json

from . import ALLOCATION_VERSION


ALLOCATION_QUANTUM = Decimal("0.000000000001")
ALLOCATION_RECORD_TYPE = "allocation"
RUN_COMPLETE_RECORD_TYPE = "run-complete"


def decimal_value(value):
    if value is None or value == "":
        return None
    try:
        result = Decimal(str(value))
    except (InvalidOperation, ValueError, TypeError) as error:
        raise ValueError("Cost value is not numeric.") from error
    if not result.is_finite():
        raise ValueError("Cost value must be finite.")
    return result


@dataclass(frozen=True)
class UsageWeight:
    team_id: str
    subject_id: str
    weight: Decimal
    rate_card_version_id: str | None = None


@dataclass(frozen=True)
class CostBucket:
    charge_period_start: datetime
    charge_period_end: datetime
    billing_period_start: datetime | None
    billing_period_end: datetime | None
    provider: str | None
    publisher_name: str | None
    meter_id: str | None
    meter_name: str | None
    resource_id: str | None
    billing_currency: str | None
    source_quantity: Decimal | None
    source_unit: str | None
    billed_cost: Decimal | None
    effective_cost: Decimal | None
    model: str | None = None
    token_category: str | None = None
    unit_rate: Decimal | None = None
    rate_card_version_id: str | None = None


def usage_snapshot_id(weights):
    normalized = [
        {
            "teamId": weight.team_id,
            "subjectId": weight.subject_id,
            "weight": str(weight.weight),
            "rateCardVersionId": weight.rate_card_version_id,
        }
        for weight in sorted(
            weights,
            key=lambda item: (
                item.team_id,
                item.subject_id,
                item.rate_card_version_id or "",
            ),
        )
    ]
    canonical = json.dumps(
        normalized, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def allocate_cost_bucket(
    bucket,
    weights,
    *,
    run_id,
    source_scope,
    source_path,
    source_etag,
    no_usage_status="unallocated-no-matching-usage",
    generated_at=None,
):
    generated_at = generated_at or datetime.now(timezone.utc)
    positive_weights = [weight for weight in weights if weight.weight > 0]
    total_weight = sum(
        (weight.weight for weight in positive_weights), start=Decimal(0)
    )
    snapshot_id = usage_snapshot_id(positive_weights) if positive_weights else None
    common = _common_row(
        bucket,
        run_id=run_id,
        source_scope=source_scope,
        source_path=source_path,
        source_etag=source_etag,
        generated_at=generated_at,
        usage_snapshot_id_value=snapshot_id,
    )

    if total_weight <= 0:
        return [
            with_record_identity(
                {
                    **common,
                    "TeamId": None,
                    "SubjectId": None,
                    "AllocationBasis": "none",
                    "AllocationWeight": None,
                    "AllocationRatio": None,
                    "AllocatedBilledCost": None,
                    "AllocatedEffectiveCost": None,
                    "UnallocatedBilledCost": _as_float(bucket.billed_cost),
                    "UnallocatedEffectiveCost": _as_float(bucket.effective_cost),
                    "AttributionStatus": no_usage_status,
                    "IncludedInWorkloadTotal": True,
                    "RateCardVersionId": None,
                },
            )
        ]

    rows = []
    allocated_billed = Decimal(0)
    allocated_effective = Decimal(0)
    for weight in sorted(
        positive_weights,
        key=lambda item: (
            item.team_id,
            item.subject_id,
            item.rate_card_version_id or "",
        ),
    ):
        ratio = weight.weight / total_weight
        billed = _allocate_value(bucket.billed_cost, ratio)
        effective = _allocate_value(bucket.effective_cost, ratio)
        if billed is not None:
            allocated_billed += billed
        if effective is not None:
            allocated_effective += effective
        rows.append(
            with_record_identity(
                {
                    **common,
                    "TeamId": weight.team_id,
                    "SubjectId": weight.subject_id,
                    "AllocationBasis": "rate-card-estimated-cost",
                    "AllocationWeight": _as_float(weight.weight),
                    "AllocationRatio": float(ratio),
                    "AllocatedBilledCost": _as_float(billed),
                    "AllocatedEffectiveCost": _as_float(effective),
                    "UnallocatedBilledCost": 0.0 if billed is not None else None,
                    "UnallocatedEffectiveCost": (
                        0.0 if effective is not None else None
                    ),
                    "AttributionStatus": "allocated",
                    "IncludedInWorkloadTotal": True,
                    "RateCardVersionId": weight.rate_card_version_id,
                },
            )
        )

    residual_billed = _residual(bucket.billed_cost, allocated_billed)
    residual_effective = _residual(bucket.effective_cost, allocated_effective)
    if _is_nonzero(residual_billed) or _is_nonzero(residual_effective):
        rows.append(
            with_record_identity(
                {
                    **common,
                    "TeamId": None,
                    "SubjectId": None,
                    "AllocationBasis": "rounding-residual",
                    "AllocationWeight": 0.0,
                    "AllocationRatio": 0.0,
                    "AllocatedBilledCost": None,
                    "AllocatedEffectiveCost": None,
                    "UnallocatedBilledCost": _as_float(residual_billed),
                    "UnallocatedEffectiveCost": _as_float(residual_effective),
                    "AttributionStatus": "residual",
                    "IncludedInWorkloadTotal": True,
                    "RateCardVersionId": None,
                },
            )
        )
    return rows


def unavailable_claude_row(
    *,
    run_id,
    source_scope,
    source_path,
    source_etag,
    charge_period_start,
    charge_period_end,
    generated_at=None,
):
    generated_at = generated_at or datetime.now(timezone.utc)
    return with_record_identity(
        {
            "TimeGenerated": _iso(generated_at),
            "RunId": run_id,
            "AllocationVersion": ALLOCATION_VERSION,
            "SourceType": "finops-hub-focus-v1.2-preview",
            "SourceScope": source_scope,
            "ChargePeriodStart": _iso(charge_period_start),
            "ChargePeriodEnd": _iso(charge_period_end),
            "BillingPeriodStart": None,
            "BillingPeriodEnd": None,
            "Provider": "Anthropic",
            "PublisherName": "Anthropic",
            "MeterId": None,
            "MeterName": "Claude Consumption Unit",
            "ResourceId": None,
            "BillingCurrency": None,
            "SourceQuantity": None,
            "SourceUnit": "CCU",
            "SourceBilledCost": None,
            "SourceEffectiveCost": None,
            "TeamId": None,
            "SubjectId": None,
            "AllocationBasis": "none",
            "AllocationWeight": None,
            "AllocationRatio": None,
            "AllocatedBilledCost": None,
            "AllocatedEffectiveCost": None,
            "UnallocatedBilledCost": None,
            "UnallocatedEffectiveCost": None,
            "AttributionStatus": "actual-unavailable-at-resource-group-scope",
            "IncludedInWorkloadTotal": False,
            "RateCardVersionId": None,
            "UsageSnapshotId": None,
            "SourcePath": source_path,
            "SourceETag": source_etag,
        }
    )


def build_run_complete_row(
    *,
    run_id,
    source_type,
    source_scope,
    source_path,
    source_etag,
    expected_record_count,
    generated_at=None,
):
    generated_at = generated_at or datetime.now(timezone.utc)
    row = {
        "TimeGenerated": _iso(generated_at),
        "RunId": run_id,
        "AllocationVersion": ALLOCATION_VERSION,
        "SourceType": source_type,
        "SourceScope": source_scope,
        "ChargePeriodStart": None,
        "ChargePeriodEnd": None,
        "BillingPeriodStart": None,
        "BillingPeriodEnd": None,
        "Provider": None,
        "PublisherName": None,
        "MeterId": None,
        "MeterName": None,
        "ResourceId": None,
        "BillingCurrency": None,
        "SourceQuantity": None,
        "SourceUnit": None,
        "SourceBilledCost": None,
        "SourceEffectiveCost": None,
        "TeamId": None,
        "SubjectId": None,
        "AllocationBasis": "run-publication",
        "AllocationWeight": None,
        "AllocationRatio": None,
        "AllocatedBilledCost": None,
        "AllocatedEffectiveCost": None,
        "UnallocatedBilledCost": None,
        "UnallocatedEffectiveCost": None,
        "AttributionStatus": "run-complete",
        "IncludedInWorkloadTotal": False,
        "RateCardVersionId": None,
        "UsageSnapshotId": None,
        "SourcePath": source_path,
        "SourceETag": source_etag,
        "RecordType": RUN_COMPLETE_RECORD_TYPE,
        "ExpectedRecordCount": expected_record_count,
    }
    return with_record_identity(row)


def with_record_identity(row):
    result = dict(row)
    result.setdefault("RecordType", ALLOCATION_RECORD_TYPE)
    result.setdefault("ExpectedRecordCount", None)
    identity_fields = {
        key: result.get(key)
        for key in (
            "RunId",
            "SourceType",
            "SourceScope",
            "SourcePath",
            "SourceETag",
            "ChargePeriodStart",
            "ChargePeriodEnd",
            "BillingPeriodStart",
            "BillingPeriodEnd",
            "Provider",
            "PublisherName",
            "MeterId",
            "MeterName",
            "ResourceId",
            "BillingCurrency",
            "SourceUnit",
            "TeamId",
            "SubjectId",
            "AllocationBasis",
            "AttributionStatus",
            "RateCardVersionId",
            "RecordType",
            "ExpectedRecordCount",
        )
    }
    encoded = json.dumps(
        identity_fields,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    result["RecordId"] = hashlib.sha256(encoded).hexdigest()
    return result


def _common_row(
    bucket,
    *,
    run_id,
    source_scope,
    source_path,
    source_etag,
    generated_at,
    usage_snapshot_id_value,
):
    return {
        "TimeGenerated": _iso(generated_at),
        "RunId": run_id,
        "AllocationVersion": ALLOCATION_VERSION,
        "SourceType": "finops-hub-focus-v1.2-preview",
        "SourceScope": source_scope,
        "ChargePeriodStart": _iso(bucket.charge_period_start),
        "ChargePeriodEnd": _iso(bucket.charge_period_end),
        "BillingPeriodStart": _iso(bucket.billing_period_start),
        "BillingPeriodEnd": _iso(bucket.billing_period_end),
        "Provider": bucket.provider,
        "PublisherName": bucket.publisher_name,
        "MeterId": bucket.meter_id,
        "MeterName": bucket.meter_name,
        "ResourceId": bucket.resource_id,
        "BillingCurrency": (
            bucket.billing_currency.upper() if bucket.billing_currency else None
        ),
        "SourceQuantity": _as_float(bucket.source_quantity),
        "SourceUnit": bucket.source_unit,
        "SourceBilledCost": _as_float(bucket.billed_cost),
        "SourceEffectiveCost": _as_float(bucket.effective_cost),
        "UsageSnapshotId": usage_snapshot_id_value,
        "SourcePath": source_path,
        "SourceETag": source_etag,
    }


def _allocate_value(value, ratio):
    if value is None:
        return None
    return (value * ratio).quantize(ALLOCATION_QUANTUM, rounding=ROUND_HALF_EVEN)


def _residual(source, allocated):
    if source is None:
        return None
    return source - allocated


def _is_nonzero(value):
    return value is not None and value != 0


def _as_float(value):
    return None if value is None else float(value)


def _iso(value):
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat()
