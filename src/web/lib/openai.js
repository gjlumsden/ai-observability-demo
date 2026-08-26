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
  return headers[name] === undefined ? null : Number(headers[name]);
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
  return {
    provider: 'OpenAI',
    model: payload.model || 'gpt-5.4',
    text: extractOpenAiText(payload),
    inputTokens: Number(usage.input_tokens || 0),
    outputTokens: Number(usage.output_tokens || 0),
    totalTokens: Number(usage.total_tokens || 0),
    latencyMs,
    consumedTokens: readNumberHeader(headers, 'x-tokens-consumed') ?? Number(usage.total_tokens || 0),
    remainingTokens: readNumberHeader(headers, 'x-tokens-remaining'),
    remainingQuotaTokens: readNumberHeader(headers, 'x-token-quota-remaining'),
    team: headers['x-attribution-team'] || 'Presenter',
    user: 'Validated Entra user'
  };
}

module.exports = { getOpenAiGuardrailBlock, normalizeOpenAiResponse };
