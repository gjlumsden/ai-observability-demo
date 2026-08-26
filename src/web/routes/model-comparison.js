const crypto = require('crypto');
const express = require('express');
const { callApim } = require('../lib/apim');
const {
  getOpenAiGuardrailBlock,
  normalizeOpenAiResponse
} = require('../lib/openai');
const { normalizeClaudeResponse } = require('../lib/claude');
const { renderMarkdown } = require('../lib/markdown');
const { modelComparisonSamples } = require('../lib/scenario-prompts');
const { requireAuth } = require('../middleware/auth');

const router = express.Router();
const MAX_PROMPT_LENGTH = 4000;
const MAX_OUTPUT_TOKENS = 800;

async function callModel({ path, subscriptionKey, bearerToken, body, extraHeaders }) {
  const startedAt = performance.now();
  const response = await callApim({
    path,
    subscriptionKey,
    bearerToken,
    body,
    extraHeaders,
    includeMetadata: true
  });
  return {
    ...response,
    latencyMs: Math.round(performance.now() - startedAt)
  };
}

router.get('/model-comparison', requireAuth, (req, res) => {
  res.render('model-comparison/index', {
    pageTitle: 'Governed Model Comparison',
    samples: modelComparisonSamples
  });
});

router.post('/model-comparison/run', requireAuth, async (req, res, next) => {
  try {
    const prompt = (req.body.prompt || '').trim();
    if (!prompt) {
      return res.status(400).json({ error: 'Enter a prompt to compare.' });
    }
    if (prompt.length > MAX_PROMPT_LENGTH) {
      return res.status(400).json({ error: `The prompt must contain ${MAX_PROMPT_LENGTH} characters or fewer.` });
    }
    if (!process.env.APIM_PRESENTER_KEY) {
      throw new Error('APIM_PRESENTER_KEY is not configured.');
    }

    const correlationId = crypto.randomUUID();
    const sharedCall = {
      subscriptionKey: process.env.APIM_PRESENTER_KEY,
      bearerToken: req.session.accessToken
    };

    const [openAi, claude] = await Promise.all([
      callModel({
        ...sharedCall,
        path: '/models/openai/responses?api-version=2025-04-01-preview',
        body: {
          input: prompt,
          max_output_tokens: MAX_OUTPUT_TOKENS,
          reasoning: {
            effort: 'low'
          }
        },
        extraHeaders: {
          'x-correlation-id': correlationId
        }
      }),
      callModel({
        ...sharedCall,
        path: '/models/claude/v1/messages',
        body: {
          model: 'claude-opus-5',
          max_tokens: MAX_OUTPUT_TOKENS,
          thinking: {
            type: 'adaptive'
          },
          output_config: {
            effort: 'low'
          },
          stream: false,
          messages: [
            {
              role: 'user',
              content: prompt
            }
          ]
        },
        extraHeaders: {
          'anthropic-version': '2023-06-01',
          'x-correlation-id': correlationId
        }
      })
    ]);

    const openAiResult = normalizeOpenAiResponse(openAi.payload, openAi.headers, openAi.latencyMs);
    const openAiGuardrail = getOpenAiGuardrailBlock(openAi.payload);
    if (openAiGuardrail) {
      openAiResult.blocked = true;
      openAiResult.guardrail = openAiGuardrail.category;
      openAiResult.text = openAiGuardrail.category === 'protected_material_code'
        ? 'Protected Material for Code stopped this completion.'
        : 'A Foundry guardrail stopped this completion.';
    }

    const results = [
      openAiResult,
      normalizeClaudeResponse(claude.payload, claude.headers, claude.latencyMs)
    ].map((result) => ({
      ...result,
      html: renderMarkdown(result.text)
    }));

    return res.json({
      correlationId,
      results
    });
  } catch (err) {
    return next(err);
  }
});

module.exports = router;
