from datetime import datetime, timezone
from decimal import Decimal
import unittest

import bootstrap  # noqa: F401

from azure.monitor.query import LogsQueryResult, LogsTable

from usage_processor.allocation import CostBucket
from usage_processor.usage_query import MonitorUsageQuery, build_usage_query

from helpers import MODEL_RESOURCE_ID, RESOURCE_GROUP_ID


def bucket(
    model="gpt-5.4",
    token_category="uncached_input",
    provider="OpenAI",
    resource_id=MODEL_RESOURCE_ID.lower(),
):
    return CostBucket(
        charge_period_start=datetime(2026, 8, 28, tzinfo=timezone.utc),
        charge_period_end=datetime(2026, 8, 29, tzinfo=timezone.utc),
        billing_period_start=None,
        billing_period_end=None,
        provider=provider,
        publisher_name="Microsoft",
        meter_id="meter-1",
        meter_name="5.4 inp Gl 1M Tokens",
        resource_id=resource_id,
        billing_currency="USD",
        source_quantity=Decimal("1"),
        source_unit="1M Tokens",
        billed_cost=Decimal("2.5"),
        effective_cost=Decimal("2.5"),
        model=model,
        token_category=token_category,
        unit_rate=Decimal("2.5") if provider == "OpenAI" else None,
        rate_card_version_id="list-price-2026-08-27",
    )


class FakeLogsClient:
    def __init__(self, response):
        self.response = response
        self.calls = []

    def query_workspace(self, **kwargs):
        self.calls.append(kwargs)
        return self.response


class UsageQueryTests(unittest.TestCase):
    def test_actual_sdk_table_uses_string_columns(self):
        table = LogsTable(
            name="PrimaryResult",
            columns=[
                "TeamId",
                "SubjectId",
                "RateCardVersionId",
                "AllocationWeight",
            ],
            columns_types=["string", "string", "string", "real"],
            rows=[["Engineering", "s" * 43, "rate-v1", 125.0]],
        )
        client = FakeLogsClient(LogsQueryResult(tables=[table]))
        query = object.__new__(MonitorUsageQuery)
        query._client = client
        query._workspace_id = "workspace"
        query._model_resource_ids = (MODEL_RESOURCE_ID.lower(),)

        weights = query.get_weights(bucket(), RESOURCE_GROUP_ID)

        self.assertEqual(len(weights), 1)
        self.assertEqual(weights[0].team_id, "Engineering")
        self.assertEqual(weights[0].weight, Decimal("125.0"))

    def test_monitor_query_rejects_a_non_allowlisted_bucket_resource(self):
        table = LogsTable(
            name="PrimaryResult",
            columns=["AllocationWeight"],
            columns_types=["real"],
            rows=[],
        )
        query = object.__new__(MonitorUsageQuery)
        query._client = FakeLogsClient(LogsQueryResult(tables=[table]))
        query._workspace_id = "workspace"
        query._model_resource_ids = (MODEL_RESOURCE_ID.lower(),)
        other = bucket(
            resource_id=(
                RESOURCE_GROUP_ID.lower()
                + "/providers/microsoft.cognitiveservices/accounts/other"
            )
        )

        with self.assertRaisesRegex(ValueError, "not allowlisted"):
            query.get_weights(other, RESOURCE_GROUP_ID)

    def test_query_matches_exact_resource_model_and_token_category(self):
        text = build_usage_query(
            bucket(),
            RESOURCE_GROUP_ID,
        )

        self.assertIn(
            f"tolower(ModelResourceId) == '{MODEL_RESOURCE_ID.lower()}'",
            text,
        )
        self.assertIn("tolower(RequestModel) == 'gpt-5.4'", text)
        self.assertIn(
            "sum(todouble(UncachedInputTokens) * 2.5 / 1000000.0)",
            text,
        )
        self.assertNotIn("ModelResourceId) in", text)
        self.assertNotIn("sum(EstimatedCost)", text)

    def test_each_model_and_meter_category_has_an_independent_denominator(self):
        mini_output = build_usage_query(
            bucket(model="gpt-5.4-mini", token_category="output"),
            RESOURCE_GROUP_ID,
        )
        nano_cached = build_usage_query(
            bucket(model="gpt-5.4-nano", token_category="cached_input"),
            RESOURCE_GROUP_ID,
        )

        self.assertIn("tolower(RequestModel) == 'gpt-5.4-mini'", mini_output)
        self.assertIn(
            "sum(todouble(OutputTokens) * 2.5 / 1000000.0)",
            mini_output,
        )
        self.assertIn("tolower(RequestModel) == 'gpt-5.4-nano'", nano_cached)
        self.assertIn(
            "sum(todouble(CachedInputTokens) * 2.5 / 1000000.0)",
            nano_cached,
        )

    def test_claude_ccu_is_limited_to_the_configured_model_and_resource(self):
        claude = bucket(
            model="claude-opus-5",
            token_category="estimated_cost",
            provider="Anthropic",
        )
        text = build_usage_query(
            claude,
            RESOURCE_GROUP_ID,
        )

        self.assertIn(
            f"tolower(ModelResourceId) == '{MODEL_RESOURCE_ID.lower()}'",
            text,
        )
        self.assertIn("tolower(RequestModel) == 'claude-opus-5'", text)
        self.assertIn("sum(EstimatedCost)", text)


if __name__ == "__main__":
    unittest.main()
