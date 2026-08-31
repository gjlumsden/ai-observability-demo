from datetime import datetime, timezone
import json
from types import SimpleNamespace
import unittest

import bootstrap  # noqa: F401

from usage_processor.event_service import process_event_batch
from usage_processor.rates import RateCard
from usage_processor.state import InMemoryStateStore
from usage_processor.validation import ContractValidator

from helpers import RESOURCE_GROUP_ID, valid_event


class FakeEvent:
    def __init__(self, body):
        self._body = body
        self.metadata = {"PartitionId": "1"}
        self.sequence_number = 7
        self.offset = "99"
        self.enqueued_time = datetime(2026, 8, 28, 12, tzinfo=timezone.utc)

    def get_body(self):
        return self._body


class RecordingWriter:
    def __init__(self):
        self.calls = []

    def upload(self, stream, rows):
        self.calls.append((stream, rows))


class FailOnceWriter(RecordingWriter):
    def __init__(self):
        super().__init__()
        self.attempts = 0

    def upload(self, stream, rows):
        self.attempts += 1
        if self.attempts == 1:
            raise RuntimeError("simulated DCR failure")
        super().upload(stream, rows)


class RecordingQuarantine:
    def __init__(self):
        self.records = []

    def write(self, record):
        self.records.append(record)


def settings():
    return SimpleNamespace(
        workload_resource_group_id=RESOURCE_GROUP_ID,
        workload_model_resource_ids=(),
        dcr_usage_stream="Custom-AIRequestUsage_CL",
        event_hub_namespace="example.servicebus.windows.net",
        event_hub_name="ai-usage",
        capture_container_name="capture",
    )


class EventServiceTests(unittest.TestCase):
    def test_valid_event_is_ingested_once(self):
        state = InMemoryStateStore()
        ingestion = RecordingWriter()
        quarantine = RecordingQuarantine()
        body = json.dumps(valid_event()).encode()
        event = FakeEvent(body)
        dependencies = {
            "settings": settings(),
            "validator": ContractValidator(),
            "rate_card": RateCard.load(),
            "state_store": state,
            "quarantine_writer": quarantine,
            "ingestion_writer": ingestion,
        }

        first = process_event_batch([event], **dependencies)
        second = process_event_batch([event], **dependencies)

        self.assertEqual(first["accepted"], 1)
        self.assertEqual(second["duplicates"], 1)
        self.assertEqual(len(ingestion.calls), 1)
        row = ingestion.calls[0][1][0]
        self.assertEqual(row["EventHubPartition"], 1)
        self.assertEqual(row["EventHubSequenceNumber"], 7)
        self.assertIn("/1/2026/08/28/12/", row["ArchivePath"])
        self.assertEqual(quarantine.records, [])

    def test_malformed_event_is_quarantined_without_raw_payload(self):
        state = InMemoryStateStore()
        ingestion = RecordingWriter()
        quarantine = RecordingQuarantine()
        body = b'{"email":"person@example.test","prompt":"private"}'

        result = process_event_batch(
            [FakeEvent(body)],
            settings=settings(),
            validator=ContractValidator(),
            rate_card=RateCard.load(),
            state_store=state,
            quarantine_writer=quarantine,
            ingestion_writer=ingestion,
        )

        self.assertEqual(result["quarantined"], 1)
        self.assertEqual(ingestion.calls, [])
        serialized = json.dumps(quarantine.records)
        self.assertNotIn("person@example.test", serialized)
        self.assertNotIn("private", serialized)

    def test_ambiguous_ingestion_is_uploaded_for_kql_deduplication(self):
        state = InMemoryStateStore()
        body = json.dumps(valid_event()).encode()
        first = state.claim_event(valid_event()["eventId"])
        state.transition(first, "ingesting")
        ingestion = RecordingWriter()

        result = process_event_batch(
            [FakeEvent(body)],
            settings=settings(),
            validator=ContractValidator(),
            rate_card=RateCard.load(),
            state_store=state,
            quarantine_writer=RecordingQuarantine(),
            ingestion_writer=ingestion,
        )

        self.assertEqual(result["accepted"], 1)
        self.assertEqual(len(ingestion.calls), 1)

    def test_capture_archive_replay_recovers_after_dcr_failure(self):
        state = InMemoryStateStore()
        ingestion = FailOnceWriter()
        event = FakeEvent(json.dumps(valid_event()).encode())
        dependencies = {
            "settings": settings(),
            "validator": ContractValidator(),
            "rate_card": RateCard.load(),
            "state_store": state,
            "quarantine_writer": RecordingQuarantine(),
            "ingestion_writer": ingestion,
        }

        with self.assertRaisesRegex(RuntimeError, "simulated DCR failure"):
            process_event_batch([event], **dependencies)

        replay = process_event_batch([event], **dependencies)
        duplicate = process_event_batch([event], **dependencies)

        self.assertEqual(replay["accepted"], 1)
        self.assertEqual(duplicate["duplicates"], 1)
        self.assertEqual(ingestion.attempts, 2)
        self.assertEqual(len(ingestion.calls), 1)

    def test_cross_resource_group_usage_is_quarantined(self):
        event = valid_event(
            resourceGroupId=(
                "/subscriptions/11111111-1111-1111-1111-111111111111"
                "/resourceGroups/other"
            ),
            modelResourceId=(
                "/subscriptions/11111111-1111-1111-1111-111111111111"
                "/resourceGroups/other/providers/"
                "Microsoft.CognitiveServices/accounts/model"
            ),
        )
        quarantine = RecordingQuarantine()
        ingestion = RecordingWriter()

        result = process_event_batch(
            [FakeEvent(json.dumps(event).encode())],
            settings=settings(),
            validator=ContractValidator(),
            rate_card=RateCard.load(),
            state_store=InMemoryStateStore(),
            quarantine_writer=quarantine,
            ingestion_writer=ingestion,
        )

        self.assertEqual(result["quarantined"], 1)
        self.assertEqual(ingestion.calls, [])
        self.assertEqual(
            quarantine.records[0]["reason"],
            "usage-resource-group-mismatch",
        )


if __name__ == "__main__":
    unittest.main()
