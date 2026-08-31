function extractClaudeText(payload) {
  return (payload.content || [])
    .filter((item) => item.type === 'text' && typeof item.text === 'string')
    .map((item) => item.text)
    .join('\n')
    .trim();
}

function readNumberHeader(headers, name) {
  if (headers[name] === undefined) {
    return null;
  }
  const value = Number(headers[name]);
  return Number.isFinite(value) ? value : null;
}

function tokenCount(value, fallback = 0) {
  const count = Number(value);
  return Number.isFinite(count) && count >= 0 ? count : fallback;
}

function normalizeClaudeResponse(payload, headers, latencyMs) {
  const usage = payload.usage || {};
  const uncachedInputTokens = tokenCount(usage.input_tokens);
  const cacheReadTokens = tokenCount(usage.cache_read_input_tokens);
  const cacheWrite5mTokens = tokenCount(
    usage.cache_creation?.ephemeral_5m_input_tokens
  );
  const cacheWrite1hTokens = tokenCount(
    usage.cache_creation?.ephemeral_1h_input_tokens
  );
  const cacheCreationTokens = tokenCount(
    usage.cache_creation_input_tokens,
    cacheWrite5mTokens + cacheWrite1hTokens
  );
  const inputTokens = uncachedInputTokens + cacheReadTokens + cacheCreationTokens;
  const outputTokens = tokenCount(usage.output_tokens);
  const thinkingTokens = tokenCount(
    usage.thinking_tokens ?? usage.output_tokens_details?.thinking_tokens
  );
  const visibleOutputTokens = Math.max(outputTokens - thinkingTokens, 0);
  const totalTokens = tokenCount(usage.total_tokens, inputTokens + outputTokens);
  const text = extractClaudeText(payload);
  return {
    provider: 'Anthropic',
    model: payload.model || 'claude-opus-5',
    text: text || (
      payload.stop_reason === 'max_tokens'
        ? 'Claude reached the output token limit before it produced a text answer.'
        : 'Claude returned no text content.'
    ),
    inputTokens,
    cachedInputTokens: cacheReadTokens,
    cacheReadTokens,
    uncachedInputTokens,
    cacheCreationTokens,
    cacheWrite5mTokens,
    cacheWrite1hTokens,
    outputTokens,
    reasoningTokens: thinkingTokens,
    thinkingTokens,
    visibleOutputTokens,
    totalTokens,
    latencyMs,
    stopReason: payload.stop_reason || null,
    consumedTokens: readNumberHeader(headers, 'x-tokens-consumed') ?? inputTokens + outputTokens,
    remainingTokens: readNumberHeader(headers, 'x-tokens-remaining'),
    remainingQuotaTokens: readNumberHeader(headers, 'x-token-quota-remaining'),
    team: headers['x-attribution-team'] || 'Presenter',
    user: 'Validated Entra user'
  };
}

module.exports = { normalizeClaudeResponse };
