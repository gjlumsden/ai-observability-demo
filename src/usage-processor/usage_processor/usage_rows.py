from math import isfinite

from .evidence import archive_prefix
from .errors import ScopeViolation
from .settings import canonical_resource_id


USAGE_COLUMNS = {
    "TimeGenerated",
    "EventId",
    "SchemaVersion",
    "CorrelationId",
    "TraceId",
    "Provider",
    "RequestModel",
    "ResponseModel",
    "DeploymentName",
    "DeploymentType",
    "ModelResourceId",
    "ResourceGroupId",
    "TeamId",
    "SubjectId",
    "ProjectId",
    "AttributionMode",
    "RequestOutcome",
    "HttpStatusCode",
    "LatencyMs",
    "TokenQuality",
    "InputTokens",
    "CachedInputTokens",
    "UncachedInputTokens",
    "CacheWrite5mTokens",
    "CacheWrite1hTokens",
    "OutputTokens",
    "ReasoningTokens",
    "VisibleOutputTokens",
    "TotalTokens",
    "RawUsage",
    "RateCardVersionId",
    "EstimatedCost",
    "PricingCurrency",
    "EventHubPartition",
    "EventHubSequenceNumber",
    "ArchivePath",
}


def enforce_usage_scope(event, workload_resource_group_id):
    expected_group = canonical_resource_id(workload_resource_group_id)
    event_group = canonical_resource_id(event.get("resourceGroupId"))
    model_resource = canonical_resource_id(event.get("modelResourceId"))
    expected_prefix = expected_group + "/providers/microsoft.cognitiveservices/accounts/"
    if event_group != expected_group:
        raise ScopeViolation("usage-resource-group-mismatch")
    if not model_resource.startswith(expected_prefix):
        raise ScopeViolation("usage-model-resource-mismatch")


def build_usage_row(event, usage, estimate, evidence, settings):
    rate_version = estimate.version
    if estimate.status == "no-rate":
        rate_version = "no-rate"
    amount = estimate.amount
    if amount is not None and not isfinite(amount):
        amount = None
        rate_version = "no-rate"

    row = {
        "TimeGenerated": event["eventTimeUtc"],
        "EventId": event["eventId"],
        "SchemaVersion": event["schemaVersion"],
        "CorrelationId": event["correlationId"],
        "TraceId": event["traceId"],
        "Provider": event["provider"],
        "RequestModel": event["requestModel"],
        "ResponseModel": event["responseModel"],
        "DeploymentName": event["deploymentName"],
        "DeploymentType": event["deploymentType"],
        "ModelResourceId": event["modelResourceId"],
        "ResourceGroupId": event["resourceGroupId"],
        "TeamId": event["teamId"],
        "SubjectId": event["subjectId"],
        "ProjectId": event["projectId"],
        "AttributionMode": event["attributionMode"],
        "RequestOutcome": event["requestOutcome"],
        "HttpStatusCode": event["httpStatusCode"],
        "LatencyMs": event["latencyMs"],
        "TokenQuality": event["tokenQuality"],
        "InputTokens": usage.input_tokens,
        "CachedInputTokens": usage.cached_input_tokens,
        "UncachedInputTokens": usage.uncached_input_tokens,
        "CacheWrite5mTokens": usage.cache_write_5m_tokens,
        "CacheWrite1hTokens": usage.cache_write_1h_tokens,
        "OutputTokens": usage.output_tokens,
        "ReasoningTokens": usage.reasoning_tokens,
        "VisibleOutputTokens": usage.visible_output_tokens,
        "TotalTokens": usage.total_tokens,
        "RawUsage": event["rawUsage"],
        "RateCardVersionId": rate_version,
        "EstimatedCost": amount,
        "PricingCurrency": estimate.currency,
        "EventHubPartition": (
            int(evidence.partition_id)
            if evidence.partition_id is not None
            and evidence.partition_id.isdigit()
            else None
        ),
        "EventHubSequenceNumber": evidence.sequence_number,
        "ArchivePath": archive_prefix(
            evidence,
            settings.event_hub_namespace,
            settings.event_hub_name,
            settings.capture_container_name,
        ),
    }
    return {key: value for key, value in row.items() if key in USAGE_COLUMNS}
