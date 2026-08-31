from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class NormalizedUsage:
    input_tokens: int | None
    cached_input_tokens: int | None
    uncached_input_tokens: int | None
    cache_creation_tokens: int | None
    cache_write_5m_tokens: int | None
    cache_write_1h_tokens: int | None
    output_tokens: int | None
    reasoning_tokens: int | None
    visible_output_tokens: int | None
    total_tokens: int | None


def _token(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def _nested_token(value, parent, child):
    details = value.get(parent)
    if not isinstance(details, dict):
        return None
    return _token(details.get(child))


def normalize_openai_usage(raw_usage):
    if not isinstance(raw_usage, dict):
        return _empty_usage()

    is_chat = "prompt_tokens" in raw_usage or "completion_tokens" in raw_usage
    input_name = "prompt_tokens" if is_chat else "input_tokens"
    output_name = "completion_tokens" if is_chat else "output_tokens"
    input_details_name = (
        "prompt_tokens_details" if is_chat else "input_tokens_details"
    )
    output_details_name = (
        "completion_tokens_details" if is_chat else "output_tokens_details"
    )

    input_tokens = _token(raw_usage.get(input_name))
    cached_tokens = _nested_token(raw_usage, input_details_name, "cached_tokens")
    uncached_tokens = (
        max(input_tokens - cached_tokens, 0)
        if input_tokens is not None and cached_tokens is not None
        else None
    )
    output_tokens = _token(raw_usage.get(output_name))
    reasoning_tokens = _nested_token(
        raw_usage, output_details_name, "reasoning_tokens"
    )
    visible_tokens = (
        max(output_tokens - reasoning_tokens, 0)
        if output_tokens is not None and reasoning_tokens is not None
        else None
    )
    total_tokens = _token(raw_usage.get("total_tokens"))
    if total_tokens is None and input_tokens is not None and output_tokens is not None:
        total_tokens = input_tokens + output_tokens

    return NormalizedUsage(
        input_tokens=input_tokens,
        cached_input_tokens=cached_tokens,
        uncached_input_tokens=uncached_tokens,
        cache_creation_tokens=None,
        cache_write_5m_tokens=None,
        cache_write_1h_tokens=None,
        output_tokens=output_tokens,
        reasoning_tokens=reasoning_tokens,
        visible_output_tokens=visible_tokens,
        total_tokens=total_tokens,
    )


def normalize_claude_usage(raw_usage):
    if not isinstance(raw_usage, dict):
        return _empty_usage()

    base_input_tokens = _token(raw_usage.get("input_tokens"))
    cache_read_tokens = _token(raw_usage.get("cache_read_input_tokens"))
    if cache_read_tokens is None:
        cache_read_tokens = 0
    cache_creation_tokens = _token(raw_usage.get("cache_creation_input_tokens"))
    cache_write_5m_tokens = _nested_token(
        raw_usage, "cache_creation", "ephemeral_5m_input_tokens"
    )
    cache_write_1h_tokens = _nested_token(
        raw_usage, "cache_creation", "ephemeral_1h_input_tokens"
    )
    child_cache_writes = (cache_write_5m_tokens or 0) + (
        cache_write_1h_tokens or 0
    )
    effective_cache_creation = (
        cache_creation_tokens
        if cache_creation_tokens is not None
        else child_cache_writes
    )
    input_tokens = (
        base_input_tokens + cache_read_tokens + effective_cache_creation
        if base_input_tokens is not None
        else None
    )
    output_tokens = _token(raw_usage.get("output_tokens"))
    thinking_tokens = _token(raw_usage.get("thinking_tokens"))
    if thinking_tokens is None:
        thinking_tokens = _nested_token(
            raw_usage, "output_tokens_details", "thinking_tokens"
        )
    visible_tokens = (
        max(output_tokens - thinking_tokens, 0)
        if output_tokens is not None and thinking_tokens is not None
        else None
    )
    total_tokens = (
        input_tokens + output_tokens
        if input_tokens is not None and output_tokens is not None
        else None
    )

    return NormalizedUsage(
        input_tokens=input_tokens,
        cached_input_tokens=cache_read_tokens,
        uncached_input_tokens=base_input_tokens,
        cache_creation_tokens=cache_creation_tokens,
        cache_write_5m_tokens=cache_write_5m_tokens,
        cache_write_1h_tokens=cache_write_1h_tokens,
        output_tokens=output_tokens,
        reasoning_tokens=thinking_tokens,
        visible_output_tokens=visible_tokens,
        total_tokens=total_tokens,
    )


def normalize_event_usage(event):
    raw_usage = event.get("rawUsage")
    if isinstance(raw_usage, dict):
        if event.get("provider") == "OpenAI":
            return normalize_openai_usage(raw_usage)
        if event.get("provider") == "Anthropic":
            return normalize_claude_usage(raw_usage)

    return NormalizedUsage(
        input_tokens=_token(event.get("inputTokens")),
        cached_input_tokens=_token(event.get("cachedInputTokens")),
        uncached_input_tokens=_token(event.get("uncachedInputTokens")),
        cache_creation_tokens=None,
        cache_write_5m_tokens=_token(event.get("cacheWrite5mTokens")),
        cache_write_1h_tokens=_token(event.get("cacheWrite1hTokens")),
        output_tokens=_token(event.get("outputTokens")),
        reasoning_tokens=_token(event.get("reasoningTokens")),
        visible_output_tokens=_token(event.get("visibleOutputTokens")),
        total_tokens=_token(event.get("totalTokens")),
    )


def _empty_usage():
    return NormalizedUsage(
        input_tokens=None,
        cached_input_tokens=None,
        uncached_input_tokens=None,
        cache_creation_tokens=None,
        cache_write_5m_tokens=None,
        cache_write_1h_tokens=None,
        output_tokens=None,
        reasoning_tokens=None,
        visible_output_tokens=None,
        total_tokens=None,
    )
