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

        query = build_usage_query(
            bucket,
            workload_resource_group_id,
            self._model_resource_ids,
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
        columns = [column.name for column in table.columns]
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


def build_usage_query(bucket, workload_resource_group_id, model_resource_ids):
    provider = _kql_string(bucket.provider)
    group_id = _kql_string(canonical_resource_id(workload_resource_group_id))
    models = ", ".join(
        _kql_string(canonical_resource_id(value)) for value in model_resource_ids
    )
    start = _kql_datetime(bucket.charge_period_start)
    end = _kql_datetime(bucket.charge_period_end)
    return f"""
AIRequestUsage_CL
| where TimeGenerated >= datetime({start}) and TimeGenerated < datetime({end})
| where tolower(ResourceGroupId) == {group_id}
| where tolower(ModelResourceId) in ({models})
| where Provider == {provider}
| summarize arg_max(TimeGenerated, *) by EventId
| where isnotnull(EstimatedCost)
| summarize AllocationWeight=sum(EstimatedCost)
    by TeamId, SubjectId, RateCardVersionId
""".strip()


def _kql_string(value):
    return "'" + str(value).replace("'", "''") + "'"


def _kql_datetime(value):
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat()
