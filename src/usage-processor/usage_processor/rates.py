from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
import json
from math import isfinite
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker

from .normalization import NormalizedUsage


CONFIG_ROOT = Path(__file__).resolve().parents[1] / "config"
DEFAULT_RATE_CARD_PATH = CONFIG_ROOT / "rate-card.v2026-08-27.json"
DEFAULT_RATE_SCHEMA_PATH = CONFIG_ROOT / "rate-card.schema.json"
MILLION = Decimal("1000000")


def parse_datetime(value):
    if isinstance(value, datetime):
        parsed = value
    else:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


@dataclass(frozen=True)
class Estimate:
    status: str
    amount: float | None
    currency: str | None
    version: str | None


class RateCard:
    def __init__(self, document):
        self.version = document["version"]
        self.price_type = document["priceType"]
        self.rates = tuple(document["rates"])

    @classmethod
    def load(
        cls,
        rate_card_path=DEFAULT_RATE_CARD_PATH,
        schema_path=DEFAULT_RATE_SCHEMA_PATH,
    ):
        with Path(rate_card_path).open("r", encoding="utf-8") as rate_file:
            document = json.load(rate_file)
        with Path(schema_path).open("r", encoding="utf-8") as schema_file:
            schema = json.load(schema_file)
        Draft202012Validator(schema, format_checker=FormatChecker()).validate(document)
        return cls(document)

    def estimate(
        self,
        provider,
        model,
        deployment_type,
        event_time,
        usage: NormalizedUsage,
    ):
        components = _billable_components(provider, usage)
        if components is None:
            return Estimate("no-rate", None, None, None)
        if not components:
            return Estimate("no-usage", None, None, None)

        instant = parse_datetime(event_time)
        selected = {}
        for token_type in components:
            rate = self._select(
                provider, model, deployment_type, token_type, instant
            )
            if rate is None:
                return Estimate("no-rate", None, None, None)
            selected[token_type] = rate

        versions = {rate["version"] for rate in selected.values()}
        currencies = {rate["currency"] for rate in selected.values()}
        if len(versions) != 1 or len(currencies) != 1:
            return Estimate("no-rate", None, None, None)

        total = sum(
            Decimal(tokens) * Decimal(str(selected[token_type]["listPrice"])) / MILLION
            for token_type, tokens in components.items()
        )
        amount = float(total)
        if not isfinite(amount):
            return Estimate("no-rate", None, None, None)
        return Estimate(
            status="estimated",
            amount=amount,
            currency=next(iter(currencies)),
            version=next(iter(versions)),
        )

    def _select(self, provider, model, deployment_type, token_type, instant):
        candidates = []
        for rate in self.rates:
            if rate["provider"].casefold() != str(provider).casefold():
                continue
            if rate["model"].casefold() != str(model).casefold():
                continue
            if rate["deploymentType"].casefold() != str(deployment_type).casefold():
                continue
            if rate["tokenType"] != token_type:
                continue
            valid_from = parse_datetime(rate["validFrom"])
            valid_to = (
                parse_datetime(rate["validTo"]) if rate["validTo"] is not None else None
            )
            if valid_from <= instant and (valid_to is None or instant < valid_to):
                candidates.append((valid_from, rate))
        return max(candidates, key=lambda item: item[0])[1] if candidates else None


def _billable_components(provider, usage):
    if provider == "OpenAI":
        components = {}
        if usage.input_tokens is not None:
            cached = usage.cached_input_tokens or 0
            uncached = usage.uncached_input_tokens
            if uncached is None:
                uncached = max(usage.input_tokens - cached, 0)
            components["uncached_input"] = uncached
            components["cached_input"] = cached
        if usage.output_tokens is not None:
            components["output"] = usage.output_tokens
        return components

    if provider == "Anthropic":
        aggregate = usage.cache_creation_tokens
        child_total = (usage.cache_write_5m_tokens or 0) + (
            usage.cache_write_1h_tokens or 0
        )
        if aggregate is not None and aggregate != child_total:
            return None
        components = {}
        if usage.uncached_input_tokens is not None:
            components["uncached_input"] = usage.uncached_input_tokens
        if usage.cached_input_tokens is not None:
            components["cache_read"] = usage.cached_input_tokens
        if usage.cache_write_5m_tokens is not None:
            components["cache_write_5m"] = usage.cache_write_5m_tokens
        if usage.cache_write_1h_tokens is not None:
            components["cache_write_1h"] = usage.cache_write_1h_tokens
        if usage.output_tokens is not None:
            components["output"] = usage.output_tokens
        return components

    return None
