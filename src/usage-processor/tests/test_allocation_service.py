from datetime import date, datetime, timezone
from decimal import Decimal
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import bootstrap  # noqa: F401

from usage_processor.allocation import UsageWeight
from usage_processor.allocation_service import (
    default_external_query_range,
    process_external_claude_context,
    process_focus_manifests,
)
from usage_processor.cost_context import ExternalCost
from usage_processor.focus import FocusManifest
from usage_processor.state import InMemoryStateStore
from usage_processor.validation import ContractValidator

from helpers import MODEL_RESOURCE_ID, RESOURCE_GROUP_ID, SUBSCRIPTION_ID


MANIFEST_PATH = (
    "Costs/2026/08/subscriptions/"
    f"{SUBSCRIPTION_ID}/resourcegroups/ai-observability-demo/manifest.json"
)


def focus_row():
    return {
        "BilledCost": Decimal("9"),
        "EffectiveCost": Decimal("8"),
        "BillingCurrency": "USD",
        "BillingPeriodStart": datetime(2026, 8, 1, tzinfo=timezone.utc),
        "BillingPeriodEnd": datetime(2026, 9, 1, tzinfo=timezone.utc),
        "ChargePeriodStart": datetime(2026, 8, 28, tzinfo=timezone.utc),
        "ChargePeriodEnd": datetime(2026, 8, 29, tzinfo=timezone.utc),
        "PublisherName": "Microsoft",
        "ServiceName": "Foundry Models",
        "SkuMeter": "5.4 opt Gl",
        "x_SkuMeterId": "meter-output",
        "ResourceId": MODEL_RESOURCE_ID,
        "x_ResourceGroupName": "ai-observability-demo",
        "SubAccountId": SUBSCRIPTION_ID,
        "ConsumedQuantity": Decimal("1"),
        "ConsumedUnit": "1M Tokens",
    }


class FakeSource:
    def __init__(self, row=None):
        self.manifest = FocusManifest(MANIFEST_PATH, "etag-1", ("data.parquet",))
        self.row = row or focus_row()

    def list_completed_manifests(self):
        return [self.manifest]

    def read_rows(self, manifest):
        return [self.row]


class FakeUsageQuery:
    def __init__(self):
        self.calls = 0

    def get_weights(self, bucket, workload_resource_group_id):
        self.calls += 1
        return [
            UsageWeight("TeamA", "a" * 43, Decimal("1"), "rate-v1"),
            UsageWeight("TeamB", "b" * 43, Decimal("2"), "rate-v1"),
            UsageWeight("TeamC", "c" * 43, Decimal("3"), "rate-v1"),
        ]


class FakeCostQuery:
    def __init__(self, snapshots):
        self.snapshots = list(snapshots)
        self.calls = []

    def query_claude_ccu(self, start, end):
        self.calls.append((start, end))
        if not self.snapshots:
            raise AssertionError("Unexpected external cost query call.")
        return list(self.snapshots.pop(0))


class FailureWriter:
    def __init__(self, fail_calls=()):
        self.fail_calls = set(fail_calls)
        self.attempts = 0
        self.successful = []

    def upload(self, stream, rows):
        self.attempts += 1
        if self.attempts in self.fail_calls:
            raise RuntimeError("simulated upload failure")
        self.successful.append((stream, [dict(row) for row in rows]))


class FailAllocatedTransitionOnce(InMemoryStateStore):
    def __init__(self):
        super().__init__()
        self.failed = False

    def transition(self, claim, status, properties=None):
        if status == "allocated" and not self.failed:
            self.failed = True
            raise RuntimeError("simulated crash after upload")
        return super().transition(claim, status, properties)


def settings():
    return SimpleNamespace(
        subscription_id=SUBSCRIPTION_ID,
        workload_resource_group_id=RESOURCE_GROUP_ID.lower(),
        workload_model_resource_ids=(MODEL_RESOURCE_ID.lower(),),
        dcr_allocation_stream="Custom-AICostAllocation_CL",
    )


def external_cost(usage_day, billed_cost):
    return ExternalCost(
        usage_date=date.fromisoformat(usage_day),
        publisher_name="Anthropic",
        publisher_type="Marketplace",
        meter_name="Claude Consumption Unit",
        currency="USD",
        billed_cost=Decimal(str(billed_cost)),
    )


class AllocationServiceTests(unittest.TestCase):
    def _run(self, state, writer, source=None, usage_query=None):
        return process_focus_manifests(
            settings=settings(),
            source=source or FakeSource(),
            state_store=state,
            usage_query=usage_query or FakeUsageQuery(),
            ingestion_writer=writer,
            validator=ContractValidator(),
        )

    def test_partial_multi_batch_upload_replays_with_stable_record_ids(self):
        state = InMemoryStateStore()
        writer = FailureWriter(fail_calls={2})

        with patch(
            "usage_processor.allocation_service.INGESTION_BATCH_SIZE",
            2,
        ):
            with self.assertRaisesRegex(RuntimeError, "simulated upload failure"):
                self._run(state, writer)
            result = self._run(state, writer)

        self.assertEqual(result["processed"], 1)
        records = [
            row
            for _, rows in writer.successful
            for row in rows
            if row["RecordType"] == "allocation"
        ]
        complete = [
            row
            for _, rows in writer.successful
            for row in rows
            if row["RecordType"] == "run-complete"
        ]
        successful_run_id = complete[0]["RunId"]
        successful_records = [
            row for row in records if row["RunId"] == successful_run_id
        ]
        self.assertEqual(len(successful_records), 4)
        self.assertEqual(
            len({row["RecordId"] for row in successful_records}),
            4,
        )
        self.assertEqual(len(complete), 1)
        self.assertEqual(complete[0]["ExpectedRecordCount"], 4)

    def test_crash_after_upload_replays_and_republishes_completion(self):
        state = FailAllocatedTransitionOnce()
        writer = FailureWriter()

        with self.assertRaisesRegex(RuntimeError, "simulated crash after upload"):
            self._run(state, writer)
        result = self._run(state, writer)

        self.assertEqual(result["processed"], 1)
        records = [
            row
            for _, rows in writer.successful
            for row in rows
            if row["RecordType"] == "allocation"
        ]
        markers = [
            row
            for _, rows in writer.successful
            for row in rows
            if row["RecordType"] == "run-complete"
        ]
        self.assertEqual(len(records), 8)
        self.assertEqual(len({row["RecordId"] for row in records}), 8)
        self.assertEqual(len(markers), 2)
        self.assertNotEqual(markers[0]["RunId"], markers[1]["RunId"])
        self.assertEqual(markers[0]["ExpectedRecordCount"], 4)

    def test_unknown_meter_stays_unallocated_and_preserves_total(self):
        row = focus_row()
        row["SkuMeter"] = "Document Intelligence Pages"
        query = FakeUsageQuery()
        writer = FailureWriter()

        result = self._run(
            InMemoryStateStore(),
            writer,
            source=FakeSource(row),
            usage_query=query,
        )

        self.assertEqual(result["processed"], 1)
        self.assertEqual(query.calls, 0)
        allocations = [
            item
            for _, rows in writer.successful
            for item in rows
            if item["RecordType"] == "allocation"
            and item["AttributionStatus"] != (
                "actual-unavailable-at-resource-group-scope"
            )
        ]
        self.assertEqual(len(allocations), 1)
        self.assertEqual(
            allocations[0]["AttributionStatus"],
            "unallocated-unmatched-meter",
        )
        self.assertEqual(allocations[0]["UnallocatedBilledCost"], 9.0)
        self.assertEqual(allocations[0]["UnallocatedEffectiveCost"], 8.0)

    def test_known_meter_on_another_resource_is_not_allocated(self):
        row = focus_row()
        row["ResourceId"] = (
            RESOURCE_GROUP_ID
            + "/providers/Microsoft.CognitiveServices/accounts/other"
        )
        query = FakeUsageQuery()
        writer = FailureWriter()

        self._run(
            InMemoryStateStore(),
            writer,
            source=FakeSource(row),
            usage_query=query,
        )

        self.assertEqual(query.calls, 0)
        allocations = [
            item
            for _, rows in writer.successful
            for item in rows
            if item["RecordType"] == "allocation"
            and item["AttributionStatus"] != (
                "actual-unavailable-at-resource-group-scope"
            )
        ]
        self.assertEqual(
            allocations[0]["AttributionStatus"],
            "unallocated-resource-mismatch",
        )

    def test_external_context_uses_stable_identity_for_adjacent_windows(self):
        state = InMemoryStateStore()
        writer = FailureWriter()
        cost_query = FakeCostQuery(
            [
                [
                    external_cost("2026-08-06", "10"),
                    external_cost("2026-08-07", "11"),
                ],
                [
                    external_cost("2026-08-07", "12"),
                    external_cost("2026-08-08", "13"),
                ],
            ]
        )
        first_start = datetime(2026, 8, 1, tzinfo=timezone.utc)
        first_end = datetime(2026, 8, 8, tzinfo=timezone.utc)
        second_start = datetime(2026, 8, 2, tzinfo=timezone.utc)
        second_end = datetime(2026, 8, 9, tzinfo=timezone.utc)

        first = process_external_claude_context(
            settings=settings(),
            start=first_start,
            end=first_end,
            cost_query=cost_query,
            state_store=state,
            ingestion_writer=writer,
            validator=ContractValidator(),
        )
        second = process_external_claude_context(
            settings=settings(),
            start=second_start,
            end=second_end,
            cost_query=cost_query,
            state_store=state,
            ingestion_writer=writer,
            validator=ContractValidator(),
        )

        self.assertEqual(first, {"processed": 1, "rows": 2, "duplicate": False})
        self.assertEqual(second, {"processed": 1, "rows": 2, "duplicate": False})
        self.assertEqual(
            cost_query.calls,
            [(first_start, first_end), (second_start, second_end)],
        )
        completion_rows = [
            row
            for _, rows in writer.successful
            for row in rows
            if row["RecordType"] == "run-complete"
        ]
        self.assertEqual(len(completion_rows), 2)
        self.assertEqual(
            completion_rows[0]["SourcePath"],
            completion_rows[1]["SourcePath"],
        )
        self.assertNotIn("from=", completion_rows[0]["SourcePath"])
        self.assertNotIn("to=", completion_rows[0]["SourcePath"])

        first_run_id = completion_rows[0]["RunId"]
        second_run_id = completion_rows[1]["RunId"]
        allocation_rows = [
            row
            for _, rows in writer.successful
            for row in rows
            if row["RecordType"] == "allocation"
        ]
        first_revised_day = next(
            row
            for row in allocation_rows
            if row["RunId"] == first_run_id
            and row["ChargePeriodStart"].startswith("2026-08-07")
        )
        second_revised_day = next(
            row
            for row in allocation_rows
            if row["RunId"] == second_run_id
            and row["ChargePeriodStart"].startswith("2026-08-07")
        )
        self.assertEqual(first_revised_day["SourceBilledCost"], 11.0)
        self.assertEqual(second_revised_day["SourceBilledCost"], 12.0)

    def test_external_context_skips_repeated_snapshot(self):
        state = InMemoryStateStore()
        writer = FailureWriter()
        snapshot = [external_cost("2026-08-07", "11")]
        cost_query = FakeCostQuery([snapshot, snapshot])
        start = datetime(2026, 8, 2, tzinfo=timezone.utc)
        end = datetime(2026, 8, 9, tzinfo=timezone.utc)

        first = process_external_claude_context(
            settings=settings(),
            start=start,
            end=end,
            cost_query=cost_query,
            state_store=state,
            ingestion_writer=writer,
            validator=ContractValidator(),
        )
        second = process_external_claude_context(
            settings=settings(),
            start=start,
            end=end,
            cost_query=cost_query,
            state_store=state,
            ingestion_writer=writer,
            validator=ContractValidator(),
        )

        self.assertEqual(first, {"processed": 1, "rows": 1, "duplicate": False})
        self.assertEqual(second, {"processed": 0, "rows": 0, "duplicate": True})
        completion_rows = [
            row
            for _, rows in writer.successful
            for row in rows
            if row["RecordType"] == "run-complete"
        ]
        allocation_rows = [
            row
            for _, rows in writer.successful
            for row in rows
            if row["RecordType"] == "allocation"
        ]
        self.assertEqual(len(completion_rows), 1)
        self.assertEqual(len(allocation_rows), 1)

    def test_external_context_processes_shifted_window_with_same_rows(self):
        state = InMemoryStateStore()
        writer = FailureWriter()
        snapshot = [external_cost("2026-08-07", "11")]
        cost_query = FakeCostQuery([snapshot, snapshot])

        first = process_external_claude_context(
            settings=settings(),
            start=datetime(2026, 8, 2, tzinfo=timezone.utc),
            end=datetime(2026, 8, 9, tzinfo=timezone.utc),
            cost_query=cost_query,
            state_store=state,
            ingestion_writer=writer,
            validator=ContractValidator(),
        )
        second = process_external_claude_context(
            settings=settings(),
            start=datetime(2026, 8, 3, tzinfo=timezone.utc),
            end=datetime(2026, 8, 10, tzinfo=timezone.utc),
            cost_query=cost_query,
            state_store=state,
            ingestion_writer=writer,
            validator=ContractValidator(),
        )

        self.assertEqual(first, {"processed": 1, "rows": 1, "duplicate": False})
        self.assertEqual(second, {"processed": 1, "rows": 1, "duplicate": False})
        completion_rows = [
            row
            for _, rows in writer.successful
            for row in rows
            if row["RecordType"] == "run-complete"
        ]
        self.assertEqual(len(completion_rows), 2)
        self.assertEqual(
            completion_rows[0]["SourcePath"],
            completion_rows[1]["SourcePath"],
        )
        self.assertNotEqual(
            completion_rows[0]["SourceETag"],
            completion_rows[1]["SourceETag"],
        )

    def test_external_context_records_empty_snapshot_as_complete_run(self):
        state = InMemoryStateStore()
        writer = FailureWriter()
        cost_query = FakeCostQuery(
            [
                [external_cost("2026-08-07", "11")],
                [],
            ]
        )

        first = process_external_claude_context(
            settings=settings(),
            start=datetime(2026, 8, 2, tzinfo=timezone.utc),
            end=datetime(2026, 8, 9, tzinfo=timezone.utc),
            cost_query=cost_query,
            state_store=state,
            ingestion_writer=writer,
            validator=ContractValidator(),
        )
        second = process_external_claude_context(
            settings=settings(),
            start=datetime(2026, 8, 3, tzinfo=timezone.utc),
            end=datetime(2026, 8, 10, tzinfo=timezone.utc),
            cost_query=cost_query,
            state_store=state,
            ingestion_writer=writer,
            validator=ContractValidator(),
        )

        self.assertEqual(first, {"processed": 1, "rows": 1, "duplicate": False})
        self.assertEqual(second, {"processed": 1, "rows": 0, "duplicate": False})
        completion_rows = [
            row
            for _, rows in writer.successful
            for row in rows
            if row["RecordType"] == "run-complete"
        ]
        self.assertEqual(len(completion_rows), 2)
        self.assertEqual(completion_rows[1]["ExpectedRecordCount"], 0)
        empty_run_id = completion_rows[1]["RunId"]
        second_run_rows = [
            row
            for _, rows in writer.successful
            for row in rows
            if row["RecordType"] == "allocation" and row["RunId"] == empty_run_id
        ]
        self.assertEqual(second_run_rows, [])

    def test_default_external_query_range_is_a_rolling_seven_day_window(self):
        start, end = default_external_query_range(
            datetime(2026, 9, 6, 21, 3, 15, tzinfo=timezone.utc)
        )

        self.assertEqual(end, datetime(2026, 9, 6, tzinfo=timezone.utc))
        self.assertEqual(start, datetime(2026, 8, 30, tzinfo=timezone.utc))


if __name__ == "__main__":
    unittest.main()
