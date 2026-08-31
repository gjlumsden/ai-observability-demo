function extractOpenAiText(payload) {
  const textParts = [];
  for (const item of payload.output || []) {
    for (const content of item.content || []) {
      if (content.type === 'output_text' && typeof content.text === 'string') {
        textParts.push(content.text);
      }
    }
  }
  return textParts.join('\n').trim();
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

function getOpenAiGuardrailBlock(payload) {
  const blockedResult = (payload.content_filters || []).find((result) => result.blocked === true);
  if (!blockedResult) {
    return null;
  }

  const categories = blockedResult.content_filter_results || {};
  const triggeredCategory = Object.entries(categories).find(([, value]) =>
    value?.filtered === true || value?.detected === true
  );
  const category = triggeredCategory?.[0] || 'content_filter';
  return {
    category,
    sourceType: blockedResult.source_type || 'completion'
  };
}

function normalizeOpenAiResponse(payload, headers, latencyMs) {
  const usage = payload.usage || {};
  const isChatCompletions = usage.prompt_tokens !== undefined ||
    usage.completion_tokens !== undefined;
  const inputTokens = tokenCount(
    isChatCompletions ? usage.prompt_tokens : usage.input_tokens
  );
  const outputTokens = tokenCount(
    isChatCompletions ? usage.completion_tokens : usage.output_tokens
  );
  const inputDetails = isChatCompletions
    ? usage.prompt_tokens_details
    : usage.input_tokens_details;
  const outputDetails = isChatCompletions
    ? usage.completion_tokens_details
    : usage.output_tokens_details;
  const cachedInputTokens = tokenCount(inputDetails?.cached_tokens);
  const uncachedInputTokens = Math.max(inputTokens - cachedInputTokens, 0);
  const reasoningTokens = tokenCount(outputDetails?.reasoning_tokens);
  const visibleOutputTokens = Math.max(outputTokens - reasoningTokens, 0);
  const totalTokens = tokenCount(usage.total_tokens, inputTokens + outputTokens);

  return {
    provider: 'OpenAI',
    model: payload.model || 'gpt-5.4',
    text: extractOpenAiText(payload),
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
    totalTokens,
    latencyMs,
    consumedTokens: readNumberHeader(headers, 'x-tokens-consumed') ?? totalTokens,
    remainingTokens: readNumberHeader(headers, 'x-tokens-remaining'),
    remainingQuotaTokens: readNumberHeader(headers, 'x-token-quota-remaining'),
    team: headers['x-attribution-team'] || 'Presenter',
    user: 'Validated Entra user'
  };
}

module.exports = { getOpenAiGuardrailBlock, normalizeOpenAiResponse };
