function extractClaudeText(payload) {
  return (payload.content || [])
    .filter((item) => item.type === 'text' && typeof item.text === 'string')
    .map((item) => item.text)
    .join('\n')
    .trim();
}

function readNumberHeader(headers, name) {
  return headers[name] === undefined ? null : Number(headers[name]);
}

function normalizeClaudeResponse(payload, headers, latencyMs) {
  const usage = payload.usage || {};
  const inputTokens = Number(usage.input_tokens || 0);
  const outputTokens = Number(usage.output_tokens || 0);
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
    outputTokens,
    totalTokens: inputTokens + outputTokens,
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
