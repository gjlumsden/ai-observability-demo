import json
import unittest

import bootstrap  # noqa: F401

from usage_processor.quarantine import build_quarantine_record
from usage_processor.state import InMemoryStateStore

from helpers import evidence


class StateTests(unittest.TestCase):
    def test_ingested_event_is_a_complete_duplicate(self):
        store = InMemoryStateStore()
        first = store.claim_event("event-1")
        self.assertEqual(first.outcome, "new")
        first = store.transition(first, "ingesting")
        store.transition(first, "ingested")

        duplicate = store.claim_event("event-1")
        self.assertEqual(duplicate.outcome, "complete")

    def test_ambiguous_event_state_is_retried(self):
        store = InMemoryStateStore()
        first = store.claim_event("event-1")
        store.transition(first, "ingesting")
        retry = store.claim_event("event-1")
        self.assertEqual(retry.outcome, "retry")
        self.assertEqual(retry.status, "ingesting")

    def test_changed_cost_etag_is_a_new_correction(self):
        store = InMemoryStateStore()
        first = store.claim_cost("Costs/path/manifest.json", "etag-1")
        store.transition(first, "allocated")
        correction = store.claim_cost("Costs/path/manifest.json", "etag-2")
        self.assertEqual(correction.outcome, "new")


class QuarantineTests(unittest.TestCase):
    def test_quarantine_record_contains_only_digest_and_safe_evidence(self):
        payload = b'{"email":"person@example.test","prompt":"secret"}'
        record = build_quarantine_record(
            payload,
            "forbidden-field",
            evidence(),
            ("$.email", "$.prompt"),
        )
        serialized = json.dumps(record)

        self.assertNotIn("person@example.test", serialized)
        self.assertNotIn("secret", serialized)
        self.assertEqual(record["payloadBytes"], len(payload))
        self.assertEqual(len(record["payloadSha256"]), 64)
        self.assertEqual(record["eventHubSequenceNumber"], 42)


if __name__ == "__main__":
    unittest.main()
