import math
import unittest

import bootstrap  # noqa: F401

from usage_processor.normalization import (
    normalize_claude_usage,
    normalize_openai_usage,
)


class OpenAINormalizationTests(unittest.TestCase):
    def test_responses_cache_and_reasoning_are_subsets(self):
        usage = normalize_openai_usage(
            {
                "input_tokens": 100,
                "input_tokens_details": {"cached_tokens": 40},
                "output_tokens": 60,
                "output_tokens_details": {"reasoning_tokens": 20},
                "total_tokens": 160,
            }
        )

        self.assertEqual(usage.input_tokens, 100)
        self.assertEqual(usage.cached_input_tokens, 40)
        self.assertEqual(usage.uncached_input_tokens, 60)
        self.assertEqual(usage.output_tokens, 60)
        self.assertEqual(usage.reasoning_tokens, 20)
        self.assertEqual(usage.visible_output_tokens, 40)
        self.assertEqual(usage.total_tokens, 160)

    def test_chat_completions_uses_prompt_and_completion_semantics(self):
        usage = normalize_openai_usage(
            {
                "prompt_tokens": 80,
                "prompt_tokens_details": {"cached_tokens": 30},
                "completion_tokens": 50,
                "completion_tokens_details": {"reasoning_tokens": 10},
                "total_tokens": 130,
            }
        )

        self.assertEqual(usage.input_tokens, 80)
        self.assertEqual(usage.cached_input_tokens, 30)
        self.assertEqual(usage.uncached_input_tokens, 50)
        self.assertEqual(usage.output_tokens, 50)
        self.assertEqual(usage.reasoning_tokens, 10)
        self.assertEqual(usage.visible_output_tokens, 40)


class ClaudeNormalizationTests(unittest.TestCase):
    def test_cache_aggregate_and_children_are_not_double_counted(self):
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
                "output_tokens_details": {"thinking_tokens": 15},
            }
        )

        self.assertEqual(usage.uncached_input_tokens, 10)
        self.assertEqual(usage.cached_input_tokens, 20)
        self.assertEqual(usage.cache_creation_tokens, 30)
        self.assertEqual(usage.cache_write_5m_tokens, 10)
        self.assertEqual(usage.cache_write_1h_tokens, 20)
        self.assertEqual(usage.input_tokens, 60)
        self.assertEqual(usage.output_tokens, 40)
        self.assertEqual(usage.reasoning_tokens, 15)
        self.assertEqual(usage.visible_output_tokens, 25)
        self.assertEqual(usage.total_tokens, 100)

    def test_missing_usage_does_not_create_nan(self):
        usage = normalize_openai_usage({})
        for value in usage.__dict__.values():
            self.assertTrue(value is None or math.isfinite(value))


if __name__ == "__main__":
    unittest.main()
