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

function normalizeWeatherAgentResponse(payload) {
  const text = extractText(payload);
  if (!text) {
    const error = new Error('The weather agent returned no text.');
    error.status = 502;
    throw error;
  }

  return {
    responseId: payload.id,
    agentName: 'weather-forecast-agent',
    text,
    tools: extractToolNames(payload.output),
    inputTokens: Number(payload.usage?.input_tokens || 0),
    outputTokens: Number(payload.usage?.output_tokens || 0),
    reasoningTokens: Number(payload.usage?.output_tokens_details?.reasoning_tokens || 0),
    totalTokens: Number(payload.usage?.total_tokens || 0)
  };
}

module.exports = { normalizeWeatherAgentResponse };
