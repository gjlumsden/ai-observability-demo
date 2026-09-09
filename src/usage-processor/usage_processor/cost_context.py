from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal
import hashlib
import json
import time as time_module
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen
import uuid

from . import ALLOCATION_VERSION
from .allocation import CostBucket, with_record_identity
from .errors import FocusContractError
from .rates import load_provider_model_versions


EXACT_MARKETPLACE_TYPES = {"marketplace"}
EXACT_CLAUDE_METERS = {
    "claude consumption unit",
    "claude consumption unit (ccu)",
}


@dataclass(frozen=True)
class ExternalCost:
    usage_date: date
    publisher_name: str
    publisher_type: str
    meter_name: str
    currency: str
    billed_cost: Decimal


class SubscriptionCostQuery:
    def __init__(
        self,
        subscription_id,
        credential,
        workload_resource_group_id=None,
        max_attempts=3,
        sleep=None,
        usage_details_query=None,
    ):
        from azure.mgmt.costmanagement import CostManagementClient

        self._client = CostManagementClient(credential=credential)
        self._scope = f"/subscriptions/{subscription_id}"
        self._resource_group_name = _resource_group_name(
            workload_resource_group_id
        )
        self._max_attempts = max_attempts
        self._sleep = sleep or time_module.sleep
        self._usage_details_query = usage_details_query or (
            lambda start, end: query_claude_ccu_usage_details(
                subscription_id,
                credential,
                start,
                end,
                self._resource_group_name,
            )
        )

    def query_claude_ccu(self, start, end):
        from azure.mgmt.costmanagement.models import (
            QueryAggregation,
            QueryDataset,
            QueryDefinition,
            QueryGrouping,
            QueryTimePeriod,
        )

        definition = QueryDefinition(
            type="ActualCost",
            timeframe="Custom",
            time_period=QueryTimePeriod(
                from_property=start.astimezone(timezone.utc),
                to=end.astimezone(timezone.utc),
            ),
            dataset=QueryDataset(
                granularity="Daily",
                aggregation={
                    "billedCost": QueryAggregation(
                        name="PreTaxCost",
                        function="Sum",
                    )
                },
                grouping=[
                    QueryGrouping(type="Dimension", name="ResourceGroupName"),
                    QueryGrouping(type="Dimension", name="PublisherType"),
                    QueryGrouping(type="Dimension", name="Meter"),
                ],
            ),
        )
        for attempt in range(self._max_attempts):
            try:
                result = self._client.query.usage(
                    scope=self._scope,
                    parameters=definition,
                )
                costs = select_exact_claude_ccu(
                    result,
                    self._resource_group_name,
                )
                fallback = getattr(self, "_usage_details_query", None)
                if costs or fallback is None:
                    return costs
                return fallback(start, end)
            except Exception as error:
                if _http_status(error) != 429:
                    raise
                if attempt + 1 == self._max_attempts:
                    fallback = getattr(self, "_usage_details_query", None)
                    if fallback is None:
                        raise
                    return fallback(start, end)
                self._sleep(_retry_after_seconds(error))


def _resource_group_name(resource_group_id):
    if not resource_group_id:
        return None
    return str(resource_group_id).rstrip("/").split("/")[-1].casefold()


def query_claude_ccu_usage_details(
    subscription_id,
    credential,
    start,
    end,
    resource_group_name=None,
    open_url=urlopen,
):
    query_filter = (
        f"properties/usageEnd ge '{start.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')}' "
        f"and properties/usageEnd le '{end.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')}'"
    )
    parameters = urlencode(
        {
            "$filter": query_filter,
            "$top": "500",
            "api-version": "2023-05-01",
        }
    )
    url = (
        "https://management.azure.com/subscriptions/"
        f"{subscription_id}/providers/Microsoft.Consumption/usageDetails?{parameters}"
    )
    token = credential.get_token(
        "https://management.azure.com/.default"
    ).token
    items = []
    for _ in range(100):
        parsed = urlparse(url)
        if parsed.scheme != "https" or parsed.hostname != "management.azure.com":
            raise FocusContractError(
                "The Usage Details continuation URL is not an Azure Resource Manager URL."
            )
        request = Request(
            url.replace(" ", "%20").replace("'", "%27"),
            headers={"Authorization": f"Bearer {token}"},
        )
        with open_url(request, timeout=120) as response:
            payload = json.load(response)
        items.extend(payload.get("value") or [])
        url = payload.get("nextLink")
        if not url:
            break
    else:
        raise FocusContractError("The Usage Details response exceeded 100 pages.")
    return select_exact_claude_usage_details(items, resource_group_name)


def select_exact_claude_usage_details(items, resource_group_name=None):
    totals = {}
    for item in items or []:
        properties = item.get("properties") or {}
        publisher = str(properties.get("publisherName") or "").strip()
        publisher_type = str(properties.get("publisherType") or "").strip()
        meter_id = str(properties.get("meterId") or "").strip()
        row_resource_group = str(properties.get("resourceGroup") or "").strip()
        if (
            publisher.casefold() != "anthropic"
            or publisher_type.casefold() not in EXACT_MARKETPLACE_TYPES
            or meter_id.casefold() != "claude-consumption-units"
            or (
                resource_group_name
                and row_resource_group.casefold() != resource_group_name
            )
        ):
            continue
        usage_date = _usage_date(properties.get("date"))
        currency = str(properties.get("billingCurrencyCode") or "").upper()
        key = (usage_date, currency)
        totals[key] = totals.get(key, Decimal(0)) + Decimal(
            str(properties.get("costInBillingCurrency"))
        )
    return [
        ExternalCost(
            usage_date=usage_date,
            publisher_name="Anthropic",
            publisher_type="Marketplace",
            meter_name="Claude Consumption Unit",
            currency=currency,
            billed_cost=billed_cost,
        )
        for (usage_date, currency), billed_cost in sorted(totals.items())
    ]


def _http_status(error):
    status = getattr(error, "status_code", None)
    if status is not None:
        return status
    return getattr(getattr(error, "response", None), "status_code", None)


def _retry_after_seconds(error):
    response = getattr(error, "response", None)
    headers = getattr(response, "headers", {}) or {}
    value = (
        headers.get("Retry-After")
        or headers.get("retry-after")
        or headers.get(
            "x-ms-ratelimit-microsoft.costmanagement-entity-retry-after"
        )
    )
    try:
        return min(60.0, max(0.0, float(value)))
    except (TypeError, ValueError):
        return 60.0


def select_exact_claude_ccu(result, resource_group_name=None):
    columns = getattr(result, "columns", None)
    rows = getattr(result, "rows", None)
    if columns is None or rows is None:
        properties = getattr(result, "properties", None)
        columns = getattr(properties, "columns", None)
        rows = getattr(properties, "rows", None)
    names = [getattr(column, "name", None) for column in (columns or [])]
    required = {
        "PreTaxCost",
        "UsageDate",
        "Currency",
        "ResourceGroupName",
        "PublisherType",
        "Meter",
    }
    if not required.issubset(set(names)):
        raise FocusContractError(
            "The Cost Management result lacks exact Claude CCU identifiers."
        )

    matches = []
    for values in rows or []:
        row = dict(zip(names, values))
        row_resource_group = str(row["ResourceGroupName"]).strip()
        publisher_type = str(row["PublisherType"]).strip()
        meter = str(row["Meter"]).strip()
        if (
            publisher_type.casefold() not in EXACT_MARKETPLACE_TYPES
            or meter.casefold() not in EXACT_CLAUDE_METERS
            or (
                resource_group_name
                and row_resource_group.casefold() != resource_group_name
            )
        ):
            continue
        matches.append(
            ExternalCost(
                usage_date=_usage_date(row["UsageDate"]),
                publisher_name="Anthropic",
                publisher_type=publisher_type,
                meter_name=meter,
                currency=str(row["Currency"]).upper(),
                billed_cost=Decimal(str(row["PreTaxCost"])),
            )
        )
    return matches


def external_result_etag(costs, *, query_start=None, query_end=None):
    content = {
        "queryStart": _etag_boundary(query_start),
        "queryEnd": _etag_boundary(query_end),
        "rows": [
            {
                "date": item.usage_date.isoformat(),
                "publisher": item.publisher_name,
                "publisherType": item.publisher_type,
                "meter": item.meter_name,
                "currency": item.currency,
                "billedCost": str(item.billed_cost),
            }
            for item in sorted(
                costs,
                key=lambda item: (
                    item.usage_date,
                    item.currency,
                    item.publisher_name,
                    item.meter_name,
                ),
            )
        ],
    }
    encoded = json.dumps(content, separators=(",", ":"), sort_keys=True).encode(
        "utf-8"
    )
    return hashlib.sha256(encoded).hexdigest()


def build_external_bucket(cost, model_resource_id):
    model_version = load_provider_model_versions().get("anthropic")
    if model_version is None:
        return None
    start = datetime.combine(cost.usage_date, time.min, tzinfo=timezone.utc)
    return CostBucket(
        charge_period_start=start,
        charge_period_end=start + timedelta(days=1),
        billing_period_start=start.replace(day=1),
        billing_period_end=None,
        provider="Anthropic",
        publisher_name=cost.publisher_name,
        meter_id=None,
        meter_name=cost.meter_name,
        resource_id=model_resource_id,
        billing_currency=cost.currency,
        source_quantity=None,
        source_unit="CCU",
        billed_cost=cost.billed_cost,
        effective_cost=None,
        model=model_version[0],
        token_category="estimated_cost",
        unit_rate=None,
        rate_card_version_id=model_version[1],
    )


def build_external_rows(
    costs,
    source_path,
    source_etag,
    generated_at=None,
    run_id=None,
):
    generated_at = generated_at or datetime.now(timezone.utc)
    run_id = run_id or str(
        uuid.uuid5(uuid.NAMESPACE_URL, source_path + "|" + source_etag)
    )
    rows = []
    for cost in costs:
        start = datetime.combine(cost.usage_date, time.min, tzinfo=timezone.utc)
        end = start + timedelta(days=1)
        rows.append(
            with_record_identity(
                {
                    "TimeGenerated": generated_at.isoformat(),
                    "RunId": run_id,
                    "AllocationVersion": ALLOCATION_VERSION,
                    "SourceType": "cost-management-query",
                    "SourceScope": "subscription",
                    "ChargePeriodStart": start.isoformat(),
                    "ChargePeriodEnd": end.isoformat(),
                    "BillingPeriodStart": start.replace(day=1).isoformat(),
                    "BillingPeriodEnd": None,
                    "Provider": "Anthropic",
                    "PublisherName": cost.publisher_name,
                    "MeterId": None,
                    "MeterName": cost.meter_name,
                    "ResourceId": None,
                    "BillingCurrency": cost.currency,
                    "SourceQuantity": None,
                    "SourceUnit": "CCU",
                    "SourceBilledCost": float(cost.billed_cost),
                    "SourceEffectiveCost": None,
                    "TeamId": None,
                    "SubjectId": None,
                    "AllocationBasis": "none-external-context",
                    "AllocationWeight": None,
                    "AllocationRatio": None,
                    "AllocatedBilledCost": None,
                    "AllocatedEffectiveCost": None,
                    "UnallocatedBilledCost": float(cost.billed_cost),
                    "UnallocatedEffectiveCost": None,
                    "AttributionStatus": "external-unallocated",
                    "IncludedInWorkloadTotal": False,
                    "RateCardVersionId": None,
                    "UsageSnapshotId": None,
                    "SourcePath": source_path,
                    "SourceETag": source_etag,
                }
            )
        )
    return rows


def _usage_date(value):
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    text = str(value)
    if text.isdigit() and len(text) == 8:
        return datetime.strptime(text, "%Y%m%d").date()
    return datetime.fromisoformat(text.replace("Z", "+00:00")).date()


def _etag_boundary(value):
    if value is None:
        return None
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).isoformat()
    if isinstance(value, date):
        return value.isoformat()
    return str(value)
