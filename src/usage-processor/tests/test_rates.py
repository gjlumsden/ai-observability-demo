import math
import unittest

import bootstrap  # noqa: F401

from usage_processor.normalization import (
    normalize_claude_usage,
    normalize_openai_usage,
)
from usage_processor.rates import RateCard, load_azure_meter_map


class RateCardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.card = RateCard.load()

    def test_selects_gpt_snapshot_and_calculates_list_price(self):
        usage = normalize_openai_usage(
            {
                "input_tokens": 100,
                "input_tokens_details": {"cached_tokens": 40},
                "output_tokens": 60,
                "output_tokens_details": {"reasoning_tokens": 20},
                "total_tokens": 160,
            }
        )
        result = self.card.estimate(
            "OpenAI",
            "gpt-5.4",
            "GlobalStandard",
            "2026-08-28T00:00:00Z",
            usage,
        )

        self.assertEqual(result.status, "estimated")
        self.assertAlmostEqual(result.amount, 0.00106)
        self.assertEqual(result.currency, "USD")
        self.assertEqual(result.version, "list-price-2026-08-27")

    def test_claude_cache_rates_do_not_price_aggregate_twice(self):
        usage = normalize_claude_usage(
            {
                "input_tokens": 10,
                "cache_read_input_tokens": 20,
                "cache_creation_input_tokens": 30,
                "cache_creation": {
                    "ephemeral_5m_input_tokens": 10,
                    "ephemeral_1h_input_tokens": 20,
                },
                "output_tokens": 40,
                "thinking_tokens": 15,
            }
        )
        result = self.card.estimate(
            "Anthropic",
            "claude-opus-5",
            "GlobalStandard",
            "2026-08-28T00:00:00Z",
            usage,
        )

        self.assertEqual(result.status, "estimated")
        self.assertAlmostEqual(result.amount, 0.0013225)

    def test_missing_cache_write_split_has_no_rate(self):
        usage = normalize_claude_usage(
            {
                "input_tokens": 10,
                "cache_creation_input_tokens": 30,
                "output_tokens": 40,
            }
        )
        result = self.card.estimate(
            "Anthropic",
            "claude-opus-5",
            "GlobalStandard",
            "2026-08-28T00:00:00Z",
            usage,
        )

        self.assertEqual(result.status, "no-rate")
        self.assertIsNone(result.amount)

    def test_unknown_model_is_no_rate_not_zero_success(self):
        usage = normalize_openai_usage(
            {"input_tokens": 10, "output_tokens": 10, "total_tokens": 20}
        )
        result = self.card.estimate(
            "OpenAI",
            "gpt-unknown",
            "GlobalStandard",
            "2026-08-28T00:00:00Z",
            usage,
        )

        self.assertEqual(result.status, "no-rate")
        self.assertIsNone(result.amount)
        self.assertTrue(result.amount is None or math.isfinite(result.amount))

    def test_rate_does_not_apply_before_valid_from(self):
        usage = normalize_openai_usage(
            {"input_tokens": 10, "output_tokens": 10, "total_tokens": 20}
        )
        result = self.card.estimate(
            "OpenAI",
            "gpt-5.4",
            "GlobalStandard",
            "2026-08-26T23:59:59Z",
            usage,
        )
        self.assertEqual(result.status, "no-rate")

    def test_official_azure_meter_identifiers_map_exactly(self):
        mappings = load_azure_meter_map()

        self.assertEqual(
            (
                mappings["5.4 inp gl"].model,
                mappings["5.4 inp gl"].token_type,
            ),
            ("gpt-5.4", "uncached_input"),
        )
        self.assertEqual(
            (
                mappings["5.4 mini cd inp gl 1m tokens"].model,
                mappings["5.4 mini cd inp gl 1m tokens"].token_type,
            ),
            ("gpt-5.4-mini", "cached_input"),
        )
        self.assertEqual(
            (
                mappings["54 nano opt gl"].model,
                mappings["54 nano opt gl"].token_type,
            ),
            ("gpt-5.4-nano", "output"),
        )
        self.assertNotIn("gpt-5.4", mappings)

    def test_gpt_54_mini_cached_rate_matches_retail_record(self):
        usage = normalize_openai_usage(
            {
                "input_tokens": 1_000_000,
                "input_tokens_details": {"cached_tokens": 1_000_000},
                "total_tokens": 1_000_000,
            }
        )

        result = self.card.estimate(
            "OpenAI",
            "gpt-5.4-mini",
            "GlobalStandard",
            "2026-08-28T00:00:00Z",
            usage,
        )

        self.assertEqual(result.status, "estimated")
        self.assertEqual(result.amount, 0.075)


if __name__ == "__main__":
    unittest.main()
