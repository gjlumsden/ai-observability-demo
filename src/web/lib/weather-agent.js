function extractText(payload) {
  const parts = [];
  for (const item of payload.output || []) {
    for (const content of item.content || []) {
      if (content.type === 'output_text' && typeof content.text === 'string') {
        parts.push(content.text);
      }
    }
  }
  return parts.join('\n').trim();
}

function extractToolNames(output) {
  return (output || [])
    .filter((item) => item.type === 'mcp_call')
    .map((item) => item.name || item.tool_name)
    .filter(Boolean);
}

function tokenCount(value, fallback = 0) {
  const count = Number(value);
  return Number.isFinite(count) && count >= 0 ? count : fallback;
}

function normalizeWeatherAgentResponse(payload) {
  const text = extractText(payload);
  if (!text) {
    const error = new Error('The weather agent returned no text.');
    error.status = 502;
    throw error;
  }

  const usage = payload.usage || {};
  const inputTokens = tokenCount(usage.input_tokens ?? usage.prompt_tokens);
  const cachedInputTokens = tokenCount(
    usage.input_tokens_details?.cached_tokens ??
    usage.prompt_tokens_details?.cached_tokens
  );
  const uncachedInputTokens = Math.max(inputTokens - cachedInputTokens, 0);
  const outputTokens = tokenCount(usage.output_tokens ?? usage.completion_tokens);
  const reasoningTokens = tokenCount(
    usage.output_tokens_details?.reasoning_tokens ??
    usage.completion_tokens_details?.reasoning_tokens
  );
  const visibleOutputTokens = Math.max(outputTokens - reasoningTokens, 0);
  const totalTokens = tokenCount(usage.total_tokens, inputTokens + outputTokens);

  return {
    responseId: payload.id,
    agentName: 'weather-forecast-agent',
    text,
    tools: extractToolNames(payload.output),
    inputTokens,
    cachedInputTokens,
    cacheReadTokens: cachedInputTokens,
    uncachedInputTokens,
    cacheCreationTokens: 0,
    cacheWrite5mTokens: 0,
    cacheWrite1hTokens: 0,
    outputTokens,
    reasoningTokens,
    thinkingTokens: 0,
    visibleOutputTokens,
    totalTokens
  };
}

module.exports = { normalizeWeatherAgentResponse };
