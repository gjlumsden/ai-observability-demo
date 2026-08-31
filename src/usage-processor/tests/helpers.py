from datetime import datetime, timezone

from usage_processor.evidence import EventEvidence


SUBSCRIPTION_ID = "11111111-1111-1111-1111-111111111111"
RESOURCE_GROUP_ID = (
    f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/ai-observability-demo"
)
MODEL_RESOURCE_ID = (
    RESOURCE_GROUP_ID
    + "/providers/Microsoft.CognitiveServices/accounts/ai-observability"
)


def valid_event(**overrides):
    event = {
        "schemaVersion": "1.0",
        "eventTimeUtc": "2026-08-28T12:00:00Z",
        "eventId": "e" * 43,
        "correlationId": "22222222-2222-2222-2222-222222222222",
        "traceId": "a" * 32,
        "provider": "OpenAI",
        "requestModel": "gpt-5.4",
        "responseModel": "gpt-5.4",
        "deploymentName": "gpt-5.4",
        "deploymentType": "GlobalStandard",
        "modelResourceId": MODEL_RESOURCE_ID,
        "resourceGroupId": RESOURCE_GROUP_ID,
        "teamId": "Engineering",
        "subjectId": "s" * 43,
        "projectId": "platform-engineering",
        "attributionMode": "synthetic",
        "requestOutcome": "succeeded",
        "httpStatusCode": 200,
        "latencyMs": 125,
        "tokenQuality": "exact",
        "inputTokens": 100,
        "cachedInputTokens": 40,
        "uncachedInputTokens": 60,
        "cacheWrite5mTokens": None,
        "cacheWrite1hTokens": None,
        "outputTokens": 60,
        "reasoningTokens": 20,
        "visibleOutputTokens": 40,
        "totalTokens": 160,
        "rawUsage": {
            "input_tokens": 100,
            "input_tokens_details": {"cached_tokens": 40},
            "output_tokens": 60,
            "output_tokens_details": {"reasoning_tokens": 20},
            "total_tokens": 160,
        },
    }
    event.update(overrides)
    return event


def valid_allocation(**overrides):
    row = {
        "TimeGenerated": "2026-08-28T12:00:00Z",
        "RunId": "33333333-3333-3333-3333-333333333333",
        "AllocationVersion": "1.0",
        "SourceType": "finops-hub-focus-v1.2-preview",
        "SourceScope": RESOURCE_GROUP_ID,
        "ChargePeriodStart": "2026-08-28T00:00:00Z",
        "ChargePeriodEnd": "2026-08-29T00:00:00Z",
        "BillingPeriodStart": "2026-08-01T00:00:00Z",
        "BillingPeriodEnd": "2026-09-01T00:00:00Z",
        "Provider": "OpenAI",
        "PublisherName": "Microsoft",
        "MeterId": "meter-1",
        "MeterName": "gpt-5.4",
        "ResourceId": MODEL_RESOURCE_ID,
        "BillingCurrency": "USD",
        "SourceQuantity": 1,
        "SourceUnit": "1M tokens",
        "SourceBilledCost": 1.25,
        "SourceEffectiveCost": 1.0,
        "TeamId": "Engineering",
        "SubjectId": "s" * 43,
        "AllocationBasis": "rate-card-estimated-cost",
        "AllocationWeight": 1.0,
        "AllocationRatio": 1.0,
        "AllocatedBilledCost": 1.25,
        "AllocatedEffectiveCost": 1.0,
        "UnallocatedBilledCost": 0.0,
        "UnallocatedEffectiveCost": 0.0,
        "AttributionStatus": "allocated",
        "IncludedInWorkloadTotal": True,
        "RateCardVersionId": "list-price-2026-08-27",
        "UsageSnapshotId": "a" * 64,
        "SourcePath": "Costs/2026/08/manifest.json",
        "SourceETag": "etag-1",
    }
    row.update(overrides)
    return row


def evidence():
    return EventEvidence(
        partition_id="0",
        sequence_number=42,
        offset="100",
        enqueued_time=datetime(2026, 8, 28, 12, tzinfo=timezone.utc),
    )
