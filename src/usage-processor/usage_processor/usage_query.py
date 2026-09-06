from datetime import datetime, timezone
from decimal import Decimal

from .allocation import UsageWeight
from .errors import ConfigurationError
from .settings import canonical_resource_id


class MonitorUsageQuery:
    def __init__(self, workspace_id, credential, model_resource_ids):
        if not workspace_id:
            raise ConfigurationError("LOG_ANALYTICS_WORKSPACE_ID is required.")
        if not model_resource_ids:
            raise ConfigurationError("WORKLOAD_MODEL_RESOURCE_IDS is required.")
        from azure.monitor.query import LogsQueryClient

        self._client = LogsQueryClient(credential)
        self._workspace_id = workspace_id
        self._model_resource_ids = tuple(
            canonical_resource_id(value) for value in model_resource_ids
        )

    def get_weights(self, bucket, workload_resource_group_id):
        from azure.monitor.query import LogsQueryStatus

        if canonical_resource_id(bucket.resource_id) not in self._model_resource_ids:
            raise ValueError("The cost bucket resource is not allowlisted.")
        query = build_usage_query(
            bucket,
            workload_resource_group_id,
        )
        response = self._client.query_workspace(
            workspace_id=self._workspace_id,
            query=query,
            timespan=(bucket.charge_period_start, bucket.charge_period_end),
        )
        if response.status != LogsQueryStatus.SUCCESS:
            raise RuntimeError("The Azure Monitor usage query returned a partial result.")
        if not response.tables:
            return []
        table = response.tables[0]
        columns = list(table.columns)
        results = []
        for values in table.rows:
            row = dict(zip(columns, values))
            weight = Decimal(str(row.get("AllocationWeight") or 0))
            results.append(
                UsageWeight(
                    team_id=str(row.get("TeamId") or "Unknown"),
                    subject_id=str(row.get("SubjectId") or ""),
                    weight=weight,
                    rate_card_version_id=row.get("RateCardVersionId"),
                )
            )
        return results


def build_usage_query(bucket, workload_resource_group_id):
    provider = _kql_string(bucket.provider)
    group_id = _kql_string(canonical_resource_id(workload_resource_group_id))
    resource_id = _kql_string(canonical_resource_id(bucket.resource_id))
    start = _kql_datetime(bucket.charge_period_start)
    end = _kql_datetime(bucket.charge_period_end)
    bucket_filter, weight_expression = _bucket_weight_expression(bucket)
    return f"""
AIRequestUsage_CL
| where TimeGenerated >= datetime({start}) and TimeGenerated < datetime({end})
| where tolower(ResourceGroupId) == {group_id}
| where tolower(ModelResourceId) == {resource_id}
| where Provider == {provider}
| summarize arg_max(TimeGenerated, *) by EventId
| where isnotnull(EstimatedCost)
{bucket_filter}
| summarize AllocationWeight=sum({weight_expression})
    by TeamId, SubjectId, RateCardVersionId
""".strip()


def _bucket_weight_expression(bucket):
    if bucket.token_category == "estimated_cost" and bucket.model:
        model = _kql_string(bucket.model.casefold())
        version = _kql_string(bucket.rate_card_version_id)
        return (
            "\n".join(
                (
                    f"| where tolower(RequestModel) == {model}",
                    f"| where RateCardVersionId == {version}",
                )
            ),
            "EstimatedCost",
        )
    columns = {
        "uncached_input": "UncachedInputTokens",
        "cached_input": "CachedInputTokens",
        "output": "OutputTokens",
    }
    column = columns.get(bucket.token_category)
    if (
        not bucket.model
        or column is None
        or bucket.unit_rate is None
        or not bucket.rate_card_version_id
    ):
        raise ValueError(
            "The cost bucket lacks an exact model, meter rate, or token category."
        )
    model = _kql_string(bucket.model.casefold())
    version = _kql_string(bucket.rate_card_version_id)
    rate = str(bucket.unit_rate)
    return (
        "\n".join(
            (
                f"| where tolower(RequestModel) == {model}",
                f"| where RateCardVersionId == {version}",
            )
        ),
        f"todouble({column}) * {rate} / 1000000.0",
    )


def _kql_string(value):
    return "'" + str(value).replace("'", "''") + "'"


def _kql_datetime(value):
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat()
