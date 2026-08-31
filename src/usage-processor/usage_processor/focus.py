from collections import defaultdict
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from pathlib import PurePosixPath

from .allocation import CostBucket, decimal_value
from .errors import FocusContractError, ScopeViolation
from .settings import canonical_resource_id


REQUIRED_FOCUS_COLUMNS = {
    "BilledCost",
    "BillingCurrency",
    "ChargePeriodStart",
    "EffectiveCost",
    "ResourceId",
}
CLAUDE_PUBLISHERS = {"anthropic"}
CLAUDE_METERS = {
    "claude consumption unit",
    "claude consumption unit (ccu)",
}
MICROSOFT_PUBLISHERS = {"microsoft", "microsoft corporation"}
OPENAI_SERVICES = {
    "azure ai foundry models",
    "azure cognitive services",
    "azure openai",
    "azure openai service",
    "microsoft foundry",
}
GPT_METERS = {
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.4-nano",
}


@dataclass(frozen=True)
class FocusManifest:
    path: str
    etag: str
    parquet_paths: tuple[str, ...]


class AzureFocusSource:
    def __init__(self, endpoint, container_name, credential):
        from azure.storage.blob import BlobServiceClient

        service = BlobServiceClient(account_url=endpoint, credential=credential)
        self._container = service.get_container_client(container_name)

    def list_completed_manifests(self):
        blobs = list(self._container.list_blobs(name_starts_with="Costs/"))
        paths = {blob.name: blob for blob in blobs}
        manifests = []
        for path, blob in paths.items():
            if PurePosixPath(path).name.casefold() != "manifest.json":
                continue
            parent = str(PurePosixPath(path).parent)
            parquet = tuple(
                sorted(
                    candidate
                    for candidate in paths
                    if str(PurePosixPath(candidate).parent) == parent
                    and candidate.casefold().endswith(".parquet")
                )
            )
            if parquet:
                manifests.append(
                    FocusManifest(
                        path=path,
                        etag=str(blob.etag),
                        parquet_paths=parquet,
                    )
                )
        return sorted(manifests, key=lambda item: item.path)

    def read_rows(self, manifest):
        import pyarrow as arrow
        import pyarrow.parquet as parquet

        rows = []
        for blob_path in manifest.parquet_paths:
            data = self._container.download_blob(blob_path).readall()
            table = parquet.read_table(arrow.BufferReader(data))
            rows.extend(table.to_pylist())
        return rows


def validate_manifest_scope(path, workload_resource_group_id):
    parts = PurePosixPath(path).parts
    scope_parts = PurePosixPath(
        canonical_resource_id(workload_resource_group_id).lstrip("/")
    ).parts
    if (
        len(parts) != len(scope_parts) + 4
        or parts[0].casefold() != "costs"
        or not parts[1].isdigit()
        or len(parts[1]) != 4
        or not parts[2].isdigit()
        or len(parts[2]) != 2
        or tuple(part.casefold() for part in parts[3:-1])
        != tuple(part.casefold() for part in scope_parts)
        or parts[-1].casefold() != "manifest.json"
    ):
        raise ScopeViolation("focus-manifest-scope-mismatch")
    return int(parts[1]), int(parts[2])


def validate_focus_rows(rows, workload_resource_group_id):
    if not rows:
        raise FocusContractError("The completed FOCUS dataset contains no rows.")
    columns = set().union(*(row.keys() for row in rows))
    missing = sorted(REQUIRED_FOCUS_COLUMNS - columns)
    if missing:
        raise FocusContractError(
            "The FOCUS dataset is missing required columns: " + ", ".join(missing)
        )
    for row in rows:
        enforce_focus_row_scope(row, workload_resource_group_id)


def enforce_focus_row_scope(row, workload_resource_group_id):
    expected = canonical_resource_id(workload_resource_group_id)
    expected_subscription = expected.split("/")[2]
    expected_group = expected.split("/")[4]

    row_group = _first(row, "x_ResourceGroupName", "ResourceGroupName")
    if row_group and str(row_group).casefold() != expected_group.casefold():
        raise ScopeViolation("focus-row-resource-group-mismatch")

    resource_id = canonical_resource_id(_first(row, "ResourceId"))
    if "/resourcegroups/" in resource_id:
        resource_parts = resource_id.split("/")
        try:
            resource_group = resource_parts[
                [part.casefold() for part in resource_parts].index("resourcegroups")
                + 1
            ]
        except (ValueError, IndexError) as error:
            raise ScopeViolation("focus-row-resource-id-invalid") from error
        if resource_group.casefold() != expected_group.casefold():
            raise ScopeViolation("focus-row-resource-id-mismatch")

    sub_account = str(_first(row, "SubAccountId") or "").strip()
    if sub_account:
        candidate = sub_account.strip("/").split("/")[-1]
        if (
            len(candidate) == 36
            and candidate.casefold() != expected_subscription.casefold()
        ):
            raise ScopeViolation("focus-row-subscription-mismatch")


def group_focus_rows(rows, allowed_model_resource_ids):
    allowed = {canonical_resource_id(value) for value in allowed_model_resource_ids}
    grouped = defaultdict(list)
    for row in rows:
        start = _datetime_value(row.get("ChargePeriodStart"))
        end = _datetime_value(row.get("ChargePeriodEnd"))
        day_start = datetime.combine(start.date(), time.min, tzinfo=timezone.utc)
        day_end = day_start + timedelta(days=1)
        resource_id = canonical_resource_id(_first(row, "ResourceId")) or None
        publisher = _string(_first(row, "PublisherName"))
        meter_id = _string(_first(row, "x_SkuMeterId", "MeterId"))
        meter_name = _string(
            _first(row, "SkuMeter", "x_SkuMeterName", "MeterName")
        )
        provider = classify_provider(row, resource_id, allowed)
        currency = _string(_first(row, "BillingCurrency"))
        key = (
            day_start,
            provider,
            publisher,
            meter_id,
            meter_name,
            resource_id,
            currency,
            _string(_first(row, "ConsumedUnit", "PricingUnit")),
        )
        grouped[key].append((row, end))

    buckets = []
    for key, entries in sorted(grouped.items(), key=lambda item: str(item[0])):
        (
            day_start,
            provider,
            publisher,
            meter_id,
            meter_name,
            resource_id,
            currency,
            source_unit,
        ) = key
        billed = _sum_optional(row.get("BilledCost") for row, _ in entries)
        effective = _sum_optional(row.get("EffectiveCost") for row, _ in entries)
        quantity = _sum_optional(
            _first(row, "ConsumedQuantity", "PricingQuantity")
            for row, _ in entries
        )
        billing_starts = [
            _datetime_value(row.get("BillingPeriodStart"))
            for row, _ in entries
            if row.get("BillingPeriodStart") is not None
        ]
        billing_ends = [
            _datetime_value(row.get("BillingPeriodEnd"))
            for row, _ in entries
            if row.get("BillingPeriodEnd") is not None
        ]
        buckets.append(
            CostBucket(
                charge_period_start=day_start,
                charge_period_end=day_start + timedelta(days=1),
                billing_period_start=min(billing_starts) if billing_starts else None,
                billing_period_end=max(billing_ends) if billing_ends else None,
                provider=provider,
                publisher_name=publisher,
                meter_id=meter_id,
                meter_name=meter_name,
                resource_id=resource_id,
                billing_currency=currency,
                source_quantity=quantity,
                source_unit=source_unit,
                billed_cost=billed,
                effective_cost=effective,
            )
        )
    return buckets


def classify_provider(row, resource_id, allowed_model_resource_ids):
    publisher = (_string(_first(row, "PublisherName", "x_PublisherId")) or "").casefold()
    meter = (
        _string(_first(row, "SkuMeter", "x_SkuMeterName", "MeterName")) or ""
    ).casefold()
    if publisher in CLAUDE_PUBLISHERS and meter in CLAUDE_METERS:
        return "Anthropic"

    service = (_string(_first(row, "ServiceName", "x_SkuMeterCategory")) or "").casefold()
    if (
        resource_id in allowed_model_resource_ids
        and publisher in MICROSOFT_PUBLISHERS
        and (service in OPENAI_SERVICES or meter in GPT_METERS)
    ):
        return "OpenAI"
    return None


def is_claude_ccu_bucket(bucket):
    return (
        bucket.provider == "Anthropic"
        and
        (bucket.publisher_name or "").casefold() in CLAUDE_PUBLISHERS
        and (bucket.meter_name or "").casefold() in CLAUDE_METERS
    )


def _sum_optional(values):
    converted = [decimal_value(value) for value in values if value is not None]
    return sum(converted, start=decimal_value(0)) if converted else None


def _datetime_value(value):
    if isinstance(value, datetime):
        result = value
    elif isinstance(value, date):
        result = datetime.combine(value, time.min)
    else:
        result = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if result.tzinfo is None:
        result = result.replace(tzinfo=timezone.utc)
    return result.astimezone(timezone.utc)


def _first(row, *names):
    for name in names:
        if name in row and row[name] not in (None, ""):
            return row[name]
    return None


def _string(value):
    return None if value is None else str(value)
