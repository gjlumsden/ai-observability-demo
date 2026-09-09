from datetime import datetime, timezone
from io import BytesIO
import json
from types import SimpleNamespace
import unittest

import bootstrap  # noqa: F401

from usage_processor.cost_context import (
    SubscriptionCostQuery,
    query_claude_ccu_usage_details,
)


class ThrottledError(Exception):
    def __init__(self, retry_after="1"):
        super().__init__("throttled")
        self.status_code = 429
        headers = {} if retry_after is None else {"Retry-After": retry_after}
        self.response = SimpleNamespace(status_code=429, headers=headers)


class FakeUsageQuery:
    def __init__(self, outcomes):
        self._outcomes = iter(outcomes)
        self.calls = 0
        self.parameters = None

    def usage(self, **kwargs):
        self.calls += 1
        self.parameters = kwargs["parameters"]
        outcome = next(self._outcomes)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


class FakeResponse(BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


class SubscriptionCostQueryRetryTests(unittest.TestCase):
    def _query(self, outcomes, max_attempts=3):
        delays = []
        query = SubscriptionCostQuery.__new__(SubscriptionCostQuery)
        query._client = SimpleNamespace(query=FakeUsageQuery(outcomes))
        query._scope = "/subscriptions/test"
        query._resource_group_name = "ai-observability-demo"
        query._max_attempts = max_attempts
        query._sleep = delays.append
        return query, delays

    @staticmethod
    def _empty_result():
        names = [
            "PreTaxCost",
            "UsageDate",
            "Currency",
            "ResourceGroupName",
            "PublisherType",
            "Meter",
        ]
        return SimpleNamespace(
            columns=[SimpleNamespace(name=name) for name in names],
            rows=[],
        )

    def test_usage_details_encodes_continuation_urls(self):
        payloads = iter(
            [
                {
                    "value": [],
                    "nextLink": (
                        "https://management.azure.com/subscriptions/test/"
                        "providers/Microsoft.Consumption/usageDetails?"
                        "$filter=properties/usageEnd ge '2026-08-01'&sessiontoken=a+b"
                    ),
                },
                {"value": []},
            ]
        )
        urls = []

        def open_url(request, timeout):
            self.assertEqual(timeout, 120)
            urls.append(request.full_url)
            return FakeResponse(json.dumps(next(payloads)).encode("utf-8"))

        credential = SimpleNamespace(
            get_token=lambda _scope: SimpleNamespace(token="token")
        )
        result = query_claude_ccu_usage_details(
            "test",
            credential,
            datetime(2026, 8, 1, tzinfo=timezone.utc),
            datetime(2026, 8, 2, tzinfo=timezone.utc),
            open_url=open_url,
        )

        self.assertEqual([], result)
        self.assertEqual(2, len(urls))
        self.assertTrue(all(" " not in url and "'" not in url for url in urls))
        self.assertIn("sessiontoken=a+b", urls[1])

    def test_uses_usage_details_when_cost_query_suppresses_zero_rows(self):
        query, delays = self._query([self._empty_result()])
        fallback_result = ["zero-cost-ccu"]
        query._usage_details_query = lambda _start, _end: fallback_result

        result = query.query_claude_ccu(
            datetime(2026, 8, 1, tzinfo=timezone.utc),
            datetime(2026, 8, 2, tzinfo=timezone.utc),
        )

        self.assertIs(result, fallback_result)
        self.assertEqual([], delays)
        self.assertEqual(1, query._client.query.calls)

    def test_retries_429_and_respects_retry_after(self):
        query, delays = self._query([ThrottledError("2"), self._empty_result()])

        result = query.query_claude_ccu(
            datetime(2026, 8, 1, tzinfo=timezone.utc),
            datetime(2026, 8, 2, tzinfo=timezone.utc),
        )

        self.assertEqual([], result)
        self.assertEqual([2.0], delays)
        self.assertEqual(2, query._client.query.calls)
        grouping_names = [
            item.name for item in query._client.query.parameters.dataset.grouping
        ]
        self.assertEqual(
            ["ResourceGroupName", "PublisherType", "Meter"],
            grouping_names,
        )

    def test_uses_sixty_seconds_when_429_has_no_retry_header(self):
        query, delays = self._query(
            [ThrottledError(None), self._empty_result()]
        )

        result = query.query_claude_ccu(
            datetime(2026, 8, 1, tzinfo=timezone.utc),
            datetime(2026, 8, 2, tzinfo=timezone.utc),
        )

        self.assertEqual([], result)
        self.assertEqual([60.0], delays)

    def test_uses_usage_details_after_bounded_429_attempts(self):
        query, delays = self._query(
            [ThrottledError("120"), ThrottledError("120")],
            max_attempts=2,
        )
        fallback_result = self._empty_result()
        query._usage_details_query = lambda _start, _end: fallback_result

        result = query.query_claude_ccu(
            datetime(2026, 8, 1, tzinfo=timezone.utc),
            datetime(2026, 8, 2, tzinfo=timezone.utc),
        )

        self.assertIs(result, fallback_result)
        self.assertEqual([60.0], delays)
        self.assertEqual(2, query._client.query.calls)

    def test_raises_after_bounded_429_attempts_without_fallback(self):
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
