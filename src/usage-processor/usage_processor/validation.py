import json
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker

from .errors import EventValidationError


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_USAGE_SCHEMA_PATH = PACKAGE_ROOT / "schemas" / "ai-usage-event.v1.json"
DEFAULT_ALLOCATION_SCHEMA_PATH = PACKAGE_ROOT / "schemas" / "ai-cost-allocation.v1.json"

FORBIDDEN_KEYS = {
    "accesstoken",
    "apikey",
    "authorization",
    "clientip",
    "clientipaddress",
    "completion",
    "content",
    "email",
    "ip",
    "ipaddress",
    "mail",
    "messages",
    "objectid",
    "ocpapimsubscriptionkey",
    "oid",
    "prompt",
    "subscriptionkey",
    "text",
    "upn",
    "xforwardedfor",
}


def _normalized_key(key):
    return "".join(character for character in str(key).lower() if character.isalnum())


def find_forbidden_paths(value, path="$"):
    matches = []
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}"
            if _normalized_key(key) in FORBIDDEN_KEYS:
                matches.append(child_path)
            matches.extend(find_forbidden_paths(child, child_path))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            matches.extend(find_forbidden_paths(child, f"{path}[{index}]"))
    return matches


def load_schema(path):
    with Path(path).open("r", encoding="utf-8") as schema_file:
        return json.load(schema_file)


class ContractValidator:
    def __init__(
        self,
        usage_schema_path=DEFAULT_USAGE_SCHEMA_PATH,
        allocation_schema_path=DEFAULT_ALLOCATION_SCHEMA_PATH,
    ):
        self._usage = Draft202012Validator(
            load_schema(usage_schema_path), format_checker=FormatChecker()
        )
        self._allocation = Draft202012Validator(
            load_schema(allocation_schema_path), format_checker=FormatChecker()
        )

    def validate_event(self, event):
        if not isinstance(event, dict):
            raise EventValidationError("event-not-object")
        forbidden = find_forbidden_paths(event)
        if forbidden:
            raise EventValidationError("forbidden-field", forbidden)
        errors = sorted(self._usage.iter_errors(event), key=lambda item: list(item.path))
        if errors:
            paths = tuple(
                "$"
                + "".join(
                    f"[{part}]" if isinstance(part, int) else f".{part}"
                    for part in error.path
                )
                for error in errors[:10]
            )
            raise EventValidationError("schema-validation-failed", paths)

    def validate_allocation(self, row):
        errors = sorted(
            self._allocation.iter_errors(row), key=lambda item: list(item.path)
        )
        if errors:
            paths = tuple(
                "$"
                + "".join(
                    f"[{part}]" if isinstance(part, int) else f".{part}"
                    for part in error.path
                )
                for error in errors[:10]
            )
            raise EventValidationError("allocation-schema-validation-failed", paths)
