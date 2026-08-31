from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal
import hashlib
import json
import uuid

from . import ALLOCATION_VERSION
from .errors import FocusContractError


EXACT_CLAUDE_PUBLISHERS = {"anthropic"}
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
    def __init__(self, subscription_id, credential):
        from azure.mgmt.costmanagement import CostManagementClient

        self._client = CostManagementClient(credential=credential)
        self._scope = f"/subscriptions/{subscription_id}"

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
                    QueryGrouping(type="Dimension", name="PublisherName"),
                    QueryGrouping(type="Dimension", name="PublisherType"),
                    QueryGrouping(type="Dimension", name="Meter"),
                ],
            ),
        )
        result = self._client.query.usage(
            scope=self._scope,
            parameters=definition,
        )
        return select_exact_claude_ccu(result)


def select_exact_claude_ccu(result):
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
        "PublisherName",
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
        publisher = str(row["PublisherName"]).strip()
        publisher_type = str(row["PublisherType"]).strip()
        meter = str(row["Meter"]).strip()
        if (
            publisher.casefold() not in EXACT_CLAUDE_PUBLISHERS
            or publisher_type.casefold() not in EXACT_MARKETPLACE_TYPES
            or meter.casefold() not in EXACT_CLAUDE_METERS
        ):
            continue
        matches.append(
            ExternalCost(
                usage_date=_usage_date(row["UsageDate"]),
                publisher_name=publisher,
                publisher_type=publisher_type,
                meter_name=meter,
                currency=str(row["Currency"]).upper(),
                billed_cost=Decimal(str(row["PreTaxCost"])),
            )
        )
    return matches


def external_result_etag(costs):
    content = [
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
    ]
    encoded = json.dumps(content, separators=(",", ":"), sort_keys=True).encode(
        "utf-8"
    )
    return hashlib.sha256(encoded).hexdigest()


def build_external_rows(costs, source_path, source_etag, generated_at=None):
    generated_at = generated_at or datetime.now(timezone.utc)
    run_id = str(uuid.uuid5(uuid.NAMESPACE_URL, source_path + "|" + source_etag))
    rows = []
    for cost in costs:
        start = datetime.combine(cost.usage_date, time.min, tzinfo=timezone.utc)
        end = start + timedelta(days=1)
        rows.append(
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
