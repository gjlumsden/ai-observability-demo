import copy
from pathlib import Path
import unittest

import bootstrap  # noqa: F401

from jsonschema import Draft202012Validator

from usage_processor.errors import EventValidationError
from usage_processor.validation import (
    DEFAULT_ALLOCATION_SCHEMA_PATH,
    DEFAULT_USAGE_SCHEMA_PATH,
    ContractValidator,
    find_forbidden_paths,
    load_schema,
)

from helpers import valid_allocation, valid_event


class EventValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.validator = ContractValidator()

    def test_accepts_pseudonymous_contract(self):
        self.validator.validate_event(valid_event())

    def test_rejects_raw_object_id_in_subject(self):
        event = valid_event(
            subjectId="22222222-2222-2222-2222-222222222222"
        )
        with self.assertRaises(EventValidationError) as context:
            self.validator.validate_event(event)
        self.assertEqual(context.exception.code, "schema-validation-failed")

    def test_rejects_forbidden_fields_recursively(self):
        event = copy.deepcopy(valid_event())
        event["rawUsage"]["input_tokens_details"]["email"] = "person@example.test"
        with self.assertRaises(EventValidationError) as context:
            self.validator.validate_event(event)
        self.assertEqual(context.exception.code, "forbidden-field")
        self.assertIn("$.rawUsage.input_tokens_details.email", context.exception.paths)

    def test_forbidden_scan_does_not_reject_token_field_names(self):
        paths = find_forbidden_paths(
            {
                "prompt_tokens": 1,
                "completion_tokens": 2,
                "output_tokens_details": {"reasoning_tokens": 1},
            }
        )
        self.assertEqual(paths, [])

    def test_contract_schemas_are_valid_draft_2020_12_json(self):
        for path in (DEFAULT_USAGE_SCHEMA_PATH, DEFAULT_ALLOCATION_SCHEMA_PATH):
            with self.subTest(path=path):
                Draft202012Validator.check_schema(load_schema(path))

    def test_contract_schemas_are_packaged_with_the_function(self):
        processor_root = Path(__file__).resolve().parents[1]
        for path in (DEFAULT_USAGE_SCHEMA_PATH, DEFAULT_ALLOCATION_SCHEMA_PATH):
            with self.subTest(path=path):
                self.assertTrue(path.is_relative_to(processor_root))
                self.assertTrue(path.is_file())

    def test_usage_schema_rejects_raw_content_at_the_root(self):
        event = valid_event(prompt="private")
        with self.assertRaises(EventValidationError) as context:
            self.validator.validate_event(event)
        self.assertEqual(context.exception.code, "forbidden-field")
        self.assertIn("$.prompt", context.exception.paths)

    def test_allocation_schema_rejects_raw_identity_and_content_fields(self):
        for field in ("email", "prompt", "content", "objectId"):
            with self.subTest(field=field):
                row = valid_allocation(**{field: "forbidden"})
                with self.assertRaises(EventValidationError) as context:
                    self.validator.validate_allocation(row)
                self.assertEqual(
                    context.exception.code,
                    "allocation-schema-validation-failed",
                )


if __name__ == "__main__":
    unittest.main()
