from datetime import datetime, timezone
from types import SimpleNamespace
import unittest

import bootstrap  # noqa: F401

from usage_processor.cost_context import SubscriptionCostQuery


class ThrottledError(Exception):
    def __init__(self, retry_after="1"):
        super().__init__("throttled")
        self.status_code = 429
        self.response = SimpleNamespace(
            status_code=429,
            headers={"Retry-After": retry_after},
        )


class FakeUsageQuery:
    def __init__(self, outcomes):
        self._outcomes = iter(outcomes)
        self.calls = 0

    def usage(self, **_kwargs):
        self.calls += 1
        outcome = next(self._outcomes)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


class SubscriptionCostQueryRetryTests(unittest.TestCase):
    def _query(self, outcomes, max_attempts=3):
        delays = []
        query = SubscriptionCostQuery.__new__(SubscriptionCostQuery)
        query._client = SimpleNamespace(query=FakeUsageQuery(outcomes))
        query._scope = "/subscriptions/test"
        query._max_attempts = max_attempts
        query._sleep = delays.append
        return query, delays

    @staticmethod
    def _empty_result():
        names = [
            "PreTaxCost",
            "UsageDate",
            "Currency",
            "PublisherName",
            "PublisherType",
            "Meter",
        ]
        return SimpleNamespace(
            columns=[SimpleNamespace(name=name) for name in names],
            rows=[],
        )

    def test_retries_429_and_respects_retry_after(self):
        query, delays = self._query([ThrottledError("2"), self._empty_result()])

        result = query.query_claude_ccu(
            datetime(2026, 8, 1, tzinfo=timezone.utc),
            datetime(2026, 8, 2, tzinfo=timezone.utc),
        )

        self.assertEqual([], result)
        self.assertEqual([2.0], delays)
        self.assertEqual(2, query._client.query.calls)

    def test_raises_after_bounded_429_attempts(self):
        query, delays = self._query(
            [ThrottledError("120"), ThrottledError("120")],
            max_attempts=2,
        )

        with self.assertRaises(ThrottledError):
            query.query_claude_ccu(
                datetime(2026, 8, 1, tzinfo=timezone.utc),
                datetime(2026, 8, 2, tzinfo=timezone.utc),
            )

        self.assertEqual([60.0], delays)
        self.assertEqual(2, query._client.query.calls)


if __name__ == "__main__":
    unittest.main()
