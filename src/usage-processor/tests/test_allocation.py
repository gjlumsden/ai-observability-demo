from datetime import date, datetime, timezone
from decimal import Decimal
from types import SimpleNamespace
import unittest

import bootstrap  # noqa: F401

from usage_processor.allocation import (
    CostBucket,
    UsageWeight,
    allocate_cost_bucket,
    unavailable_claude_row,
)
from usage_processor.cost_context import (
    ExternalCost,
    build_external_rows,
    external_result_etag,
    select_exact_claude_ccu,
)
from usage_processor.errors import FocusContractError, ScopeViolation
from usage_processor.focus import (
    classify_provider,
    enforce_focus_row_scope,
    group_focus_rows,
    validate_focus_rows,
    validate_manifest_scope,
)
from usage_processor.validation import ContractValidator

from helpers import MODEL_RESOURCE_ID, RESOURCE_GROUP_ID, SUBSCRIPTION_ID


def bucket(billed="100", effective="80"):
    return CostBucket(
        charge_period_start=datetime(2026, 8, 28, tzinfo=timezone.utc),
        charge_period_end=datetime(2026, 8, 29, tzinfo=timezone.utc),
        billing_period_start=datetime(2026, 8, 1, tzinfo=timezone.utc),
        billing_period_end=datetime(2026, 9, 1, tzinfo=timezone.utc),
        provider="OpenAI",
        publisher_name="Microsoft",
        meter_id="meter-1",
        meter_name="gpt-5.4",
        resource_id=MODEL_RESOURCE_ID.lower(),
        billing_currency="USD",
        source_quantity=Decimal("1"),
        source_unit="1M tokens",
        billed_cost=Decimal(billed),
        effective_cost=Decimal(effective),
    )


class AllocationTests(unittest.TestCase):
    def test_allocates_by_estimated_cost_and_preserves_totals(self):
        weights = [
            UsageWeight("Research", "r" * 43, Decimal("1"), "v1"),
            UsageWeight("Engineering", "e" * 43, Decimal("2"), "v1"),
        ]
        rows = allocate_cost_bucket(
            bucket(),
            weights,
            run_id="33333333-3333-3333-3333-333333333333",
            source_scope=RESOURCE_GROUP_ID.lower(),
            source_path="Costs/path/manifest.json",
            source_etag="etag",
        )

        allocated_billed = sum(row["AllocatedBilledCost"] or 0 for row in rows)
        unallocated_billed = sum(row["UnallocatedBilledCost"] or 0 for row in rows)
        self.assertAlmostEqual(allocated_billed + unallocated_billed, 100)
        self.assertAlmostEqual(
            sum(row["AllocationRatio"] or 0 for row in rows), 1
        )

    def test_no_weights_preserves_an_unallocated_row(self):
        rows = allocate_cost_bucket(
            bucket(),
            [],
            run_id="33333333-3333-3333-3333-333333333333",
            source_scope=RESOURCE_GROUP_ID.lower(),
            source_path="Costs/path/manifest.json",
            source_etag="etag",
        )
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["UnallocatedBilledCost"], 100)
        self.assertEqual(rows[0]["AttributionStatus"], "unallocated-no-matching-usage")

    def test_negative_correction_remains_negative(self):
        rows = allocate_cost_bucket(
            bucket("-12.5", "-10"),
            [UsageWeight("Research", "r" * 43, Decimal("1"), "v1")],
            run_id="33333333-3333-3333-3333-333333333333",
            source_scope=RESOURCE_GROUP_ID.lower(),
            source_path="Costs/path/manifest.json",
            source_etag="etag-2",
        )
        self.assertEqual(rows[0]["AllocatedBilledCost"], -12.5)
        self.assertEqual(rows[0]["AllocatedEffectiveCost"], -10)

    def test_unavailable_claude_actual_is_not_a_workload_total(self):
        row = unavailable_claude_row(
            run_id="33333333-3333-3333-3333-333333333333",
            source_scope=RESOURCE_GROUP_ID.lower(),
            source_path="Costs/path/manifest.json",
            source_etag="etag",
            charge_period_start=datetime(2026, 8, 1, tzinfo=timezone.utc),
            charge_period_end=datetime(2026, 9, 1, tzinfo=timezone.utc),
        )
        self.assertEqual(
            row["AttributionStatus"],
            "actual-unavailable-at-resource-group-scope",
        )
        self.assertFalse(row["IncludedInWorkloadTotal"])
        self.assertIsNone(row["AllocatedBilledCost"])


class ScopeTests(unittest.TestCase):
    def test_rejects_cross_resource_group_manifest(self):
        path = (
            "Costs/2026/08/subscriptions/"
            f"{SUBSCRIPTION_ID}/resourcegroups/other/manifest.json"
        )
        with self.assertRaises(ScopeViolation):
            validate_manifest_scope(path, RESOURCE_GROUP_ID)

    def test_rejects_cross_resource_group_row(self):
        row = {
            "ResourceId": (
                f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/other/"
                "providers/Microsoft.CognitiveServices/accounts/model"
            ),
            "x_ResourceGroupName": "other",
        }
        with self.assertRaises(ScopeViolation):
            enforce_focus_row_scope(row, RESOURCE_GROUP_ID)

    def test_groups_exact_model_resource_cost(self):
        row = {
            "BilledCost": Decimal("2"),
            "EffectiveCost": Decimal("1.5"),
            "BillingCurrency": "USD",
            "BillingPeriodStart": datetime(2026, 8, 1, tzinfo=timezone.utc),
            "BillingPeriodEnd": datetime(2026, 9, 1, tzinfo=timezone.utc),
            "ChargePeriodStart": datetime(2026, 8, 28, tzinfo=timezone.utc),
            "ChargePeriodEnd": datetime(2026, 8, 29, tzinfo=timezone.utc),
            "PublisherName": "Microsoft",
            "ServiceName": "Foundry Models",
            "SkuMeter": "5.4 inp Gl",
            "x_SkuMeterId": "meter",
            "ResourceId": MODEL_RESOURCE_ID,
            "x_ResourceGroupName": "ai-observability-demo",
            "SubAccountId": SUBSCRIPTION_ID,
            "ConsumedQuantity": Decimal("1"),
            "ConsumedUnit": "1M Tokens",
        }
        groups = group_focus_rows([row], [MODEL_RESOURCE_ID])
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0].provider, "OpenAI")
        self.assertEqual(groups[0].model, "gpt-5.4")
        self.assertEqual(groups[0].token_category, "uncached_input")

    def test_cognitive_services_name_does_not_classify_an_unknown_meter(self):
        row = {
            "PublisherName": "Microsoft",
            "ServiceName": "Azure Cognitive Services",
            "SkuMeter": "Document Intelligence Pages",
        }
        self.assertIsNone(
            classify_provider(
                row,
                MODEL_RESOURCE_ID.lower(),
                {MODEL_RESOURCE_ID.lower()},
            )
        )

    def test_resource_group_ccu_uses_the_claude_provider(self):
        row = {
            "BilledCost": Decimal("2"),
            "EffectiveCost": Decimal("2"),
            "BillingCurrency": "USD",
            "ChargePeriodStart": datetime(2026, 8, 28, tzinfo=timezone.utc),
            "ChargePeriodEnd": datetime(2026, 8, 29, tzinfo=timezone.utc),
            "PublisherName": "Anthropic",
            "SkuMeter": "Claude Consumption Unit",
            "ResourceId": (
                RESOURCE_GROUP_ID
                + "/providers/Microsoft.CognitiveServices/accounts/other"
            ),
            "x_ResourceGroupName": "ai-observability-demo",
        }
        groups = group_focus_rows([row], [MODEL_RESOURCE_ID])
        self.assertEqual(groups[0].provider, "Anthropic")
        self.assertEqual(groups[0].model, "claude-opus-5")
        self.assertEqual(groups[0].token_category, "estimated_cost")

        allocations = allocate_cost_bucket(
            groups[0],
            [UsageWeight("Research", "r" * 43, Decimal("1"), "v1")],
            run_id="33333333-3333-3333-3333-333333333333",
            source_scope=RESOURCE_GROUP_ID.lower(),
            source_path="Costs/path/manifest.json",
            source_etag="etag",
        )
        self.assertEqual(allocations[0]["Provider"], "Anthropic")
        self.assertEqual(allocations[0]["TeamId"], "Research")
        self.assertEqual(allocations[0]["AllocatedBilledCost"], 2)

    def test_focus_layout_requires_authoritative_columns(self):
        with self.assertRaises(FocusContractError):
            validate_focus_rows(
                [{"BilledCost": Decimal("1")}],
                RESOURCE_GROUP_ID,
            )

    def test_focus_layout_rejects_empty_required_values(self):
        row = {
            "BilledCost": Decimal("1"),
            "EffectiveCost": Decimal("1"),
            "BillingCurrency": "",
            "ChargePeriodStart": datetime(2026, 8, 28, tzinfo=timezone.utc),
            "ChargePeriodEnd": datetime(2026, 8, 29, tzinfo=timezone.utc),
            "ResourceId": MODEL_RESOURCE_ID,
        }
        with self.assertRaisesRegex(FocusContractError, "empty required fields"):
            validate_focus_rows([row], RESOURCE_GROUP_ID)


class ExternalContextTests(unittest.TestCase):
    def test_only_exact_marketplace_claude_ccu_is_selected(self):
        names = [
            "PreTaxCost",
            "UsageDate",
            "Currency",
            "PublisherName",
            "PublisherType",
            "Meter",
        ]
        result = SimpleNamespace(
            columns=[SimpleNamespace(name=name) for name in names],
            rows=[
                [10, 20260828, "USD", "Anthropic", "Marketplace", "Claude Consumption Unit"],
                [99, 20260828, "USD", "Other", "Marketplace", "Claude Consumption Unit"],
                [88, 20260828, "USD", "Anthropic", "Marketplace", "Other"],
            ],
        )
        costs = select_exact_claude_ccu(result)
        self.assertEqual(len(costs), 1)
        self.assertEqual(costs[0].billed_cost, Decimal("10"))

        etag = external_result_etag(costs)
        rows = build_external_rows(costs, "cost-query", etag)
        self.assertEqual(rows[0]["SourceScope"], "subscription")
        self.assertEqual(rows[0]["AttributionStatus"], "external-unallocated")
        self.assertFalse(rows[0]["IncludedInWorkloadTotal"])
        self.assertIsNone(rows[0]["TeamId"])
        self.assertIsNone(rows[0]["SubjectId"])
        self.assertIsNone(rows[0]["AllocatedBilledCost"])
        ContractValidator().validate_allocation(rows[0])

    def test_external_etag_changes_when_query_window_changes(self):
        costs = [
            ExternalCost(
                usage_date=date(2026, 8, 28),
                publisher_name="Anthropic",
                publisher_type="Marketplace",
                meter_name="Claude Consumption Unit",
                currency="USD",
                billed_cost=Decimal("10"),
            )
        ]
        first = external_result_etag(
            costs,
            query_start=datetime(2026, 8, 21, tzinfo=timezone.utc),
            query_end=datetime(2026, 8, 28, tzinfo=timezone.utc),
        )
        second = external_result_etag(
            costs,
            query_start=datetime(2026, 8, 22, tzinfo=timezone.utc),
            query_end=datetime(2026, 8, 29, tzinfo=timezone.utc),
        )
        self.assertNotEqual(first, second)


if __name__ == "__main__":
    unittest.main()
