const assert = require('node:assert/strict');
const { normalizeOpenAiResponse } = require('../lib/openai');
const { normalizeClaudeResponse } = require('../lib/claude');
const { normalizeWeatherAgentResponse } = require('../lib/weather-agent');

function assertNoNaN(value) {
  for (const item of Object.values(value)) {
    if (typeof item === 'number') {
      assert.equal(Number.isNaN(item), false);
    }
  }
}

const openAi = normalizeOpenAiResponse({
  model: 'gpt-5.4',
  output: [{ content: [{ type: 'output_text', text: 'ok' }] }],
  usage: {
    input_tokens: 100,
    input_tokens_details: { cached_tokens: 40 },
    output_tokens: 60,
    output_tokens_details: { reasoning_tokens: 20 },
    total_tokens: 160
  }
}, { 'x-tokens-consumed': 'invalid' }, 10);

assert.equal(openAi.inputTokens, 100);
assert.equal(openAi.cachedInputTokens, 40);
assert.equal(openAi.uncachedInputTokens, 60);
assert.equal(openAi.outputTokens, 60);
assert.equal(openAi.reasoningTokens, 20);
assert.equal(openAi.visibleOutputTokens, 40);
assert.equal(openAi.totalTokens, 160);
assert.equal(openAi.consumedTokens, 160);
assertNoNaN(openAi);

const openAiChat = normalizeOpenAiResponse({
  model: 'gpt-5.4',
  usage: {
    prompt_tokens: 30,
    prompt_tokens_details: { cached_tokens: 10 },
    completion_tokens: 20,
    completion_tokens_details: { reasoning_tokens: 5 },
    total_tokens: 50
  }
}, {}, 10);

assert.equal(openAiChat.uncachedInputTokens, 20);
assert.equal(openAiChat.visibleOutputTokens, 15);
assertNoNaN(openAiChat);

const claude = normalizeClaudeResponse({
  model: 'claude-opus-5',
  content: [{ type: 'text', text: 'ok' }],
  usage: {
    input_tokens: 10,
    cache_read_input_tokens: 20,
    cache_creation_input_tokens: 30,
    cache_creation: {
      ephemeral_5m_input_tokens: 10,
      ephemeral_1h_input_tokens: 20
    },
    output_tokens: 40,
    output_tokens_details: { thinking_tokens: 15 }
  }
}, {}, 10);

assert.equal(claude.inputTokens, 60);
assert.equal(claude.uncachedInputTokens, 10);
assert.equal(claude.cacheReadTokens, 20);
assert.equal(claude.cacheCreationTokens, 30);
assert.equal(claude.cacheWrite5mTokens, 10);
assert.equal(claude.cacheWrite1hTokens, 20);
assert.equal(claude.outputTokens, 40);
assert.equal(claude.thinkingTokens, 15);
assert.equal(claude.visibleOutputTokens, 25);
assert.equal(claude.totalTokens, 100);
assertNoNaN(claude);

const weather = normalizeWeatherAgentResponse({
  id: 'response-1',
  output: [{ content: [{ type: 'output_text', text: 'Sunny' }] }],
  usage: {
    prompt_tokens: 12,
    prompt_tokens_details: { cached_tokens: 2 },
    completion_tokens: 8,
    completion_tokens_details: { reasoning_tokens: 3 },
    total_tokens: 20
  }
});

assert.equal(weather.uncachedInputTokens, 10);
assert.equal(weather.cachedInputTokens, 2);
assert.equal(weather.visibleOutputTokens, 5);
assert.equal(weather.totalTokens, 20);
assertNoNaN(weather);

console.log('Usage normalization tests passed.');
