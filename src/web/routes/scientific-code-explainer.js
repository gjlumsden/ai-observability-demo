const crypto = require('crypto');
const express = require('express');
const { callApim } = require('../lib/apim');
const {
  getOpenAiGuardrailBlock,
  normalizeOpenAiResponse
} = require('../lib/openai');
const { renderMarkdown } = require('../lib/markdown');
const {
  codeExplainerSamples,
  protectedCodeDirectSample
} = require('../lib/scenario-prompts');
const { trackGuardrailDecision } = require('../lib/telemetry');
const { requireAuth } = require('../middleware/auth');

const router = express.Router();
const MAX_PROMPT_LENGTH = 6000;
const MAX_OUTPUT_TOKENS = 800;
const MIN_CODE_CHECK_LENGTH = 110;
const MAX_CODE_CHECK_LENGTH = 20000;

function extractCode(value) {
  const text = String(value || '');
  const blocks = [...text.matchAll(/```(?:[A-Za-z0-9_+-]+)?\s*\n([\s\S]*?)```/g)]
    .map((match) => match[1].trim())
    .filter(Boolean);
  return blocks.length > 0 ? blocks.join('\n\n') : text;
}

function normalizeProtectedMaterialCheck(payload) {
  const analysis = payload?.protectedMaterialAnalysis || {};
  return {
    completed: true,
    detected: analysis.detected === true,
    citations: (analysis.codeCitations || []).map((citation) => ({
      license: citation.license || 'Unknown',
      sourceUrls: (citation.sourceUrls || []).filter((url) => typeof url === 'string')
    }))
  };
}

async function runProtectedMaterialCheck({ code, bearerToken, correlationId }) {
  const check = await callApim({
    path: '/guardrails/protected-code/check',
    subscriptionKey: process.env.APIM_PRESENTER_KEY,
    bearerToken,
    body: {
      code
    },
    extraHeaders: {
      'x-correlation-id': correlationId
    }
  });
  return normalizeProtectedMaterialCheck(check);
}

function classifyGuardrail(details) {
  const result = JSON.stringify(details || {}).toLowerCase();
  if (result.includes('protected_material_code')) {
    return 'protected_material_code';
  }
  if (result.includes('jailbreak')) {
    return 'prompt_shield';
  }
  return 'content_filter';
}

router.get('/scientific-code-explainer', requireAuth, (req, res) => {
  res.render('scientific-code-explainer/index', {
    pageTitle: 'Scientific Code Explainer',
    samples: codeExplainerSamples,
    protectedCodeDirectSample
  });
});

router.post('/scientific-code-explainer/explain', requireAuth, async (req, res, next) => {
  const correlationId = crypto.randomUUID();
  let sampleKind = 'normal';
  try {
    const prompt = (req.body.prompt || '').trim();
    sampleKind = ['normal', 'prompt_shield', 'protected_material'].includes(req.body.sampleKind)
      ? req.body.sampleKind
      : 'normal';
    if (!prompt) {
      return res.status(400).json({ error: 'Enter scientific code or a code question.' });
    }
    if (prompt.length > MAX_PROMPT_LENGTH) {
      return res.status(400).json({ error: `The prompt must contain ${MAX_PROMPT_LENGTH} characters or fewer.` });
    }
    if (!process.env.APIM_PRESENTER_KEY) {
      throw new Error('APIM_PRESENTER_KEY is not configured.');
    }

    const startedAt = performance.now();
    const response = await callApim({
      path: '/models/openai/responses?api-version=2025-04-01-preview',
      subscriptionKey: process.env.APIM_PRESENTER_KEY,
      bearerToken: req.session.accessToken,
      includeMetadata: true,
      extraHeaders: {
        'x-correlation-id': correlationId
      },
      body: {
        input: `Act as a scientific software engineering assistant. Explain the supplied code or answer the code question. Identify assumptions, units, numerical risks, missing-value behavior, and useful tests. Do not invent repository context.\n\n${prompt}`,
        max_output_tokens: MAX_OUTPUT_TOKENS,
        reasoning: {
          effort: 'low'
        }
      }
    });

    const responseGuardrail = getOpenAiGuardrailBlock(response.payload);
    if (responseGuardrail) {
      const guardrail = responseGuardrail.category === 'protected_material_code'
        ? 'protected_material_code'
        : responseGuardrail.category;
      trackGuardrailDecision({
        correlationId,
        guardrail,
        stage: responseGuardrail.sourceType,
        outcome: 'blocked'
      });
      return res.status(200).json({
        correlationId,
        blocked: true,
        guardrail,
        message: guardrail === 'protected_material_code'
          ? 'Protected Material for Code stopped the model completion. No complete code response is returned.'
          : 'A Foundry guardrail stopped the model completion.'
      });
    }

    const result = normalizeOpenAiResponse(
      response.payload,
      response.headers,
      Math.round(performance.now() - startedAt)
    );
    let protectedMaterialCheck = null;
    if (sampleKind === 'protected_material') {
      const generatedCode = extractCode(result.text);
      if (generatedCode.trim().length >= MIN_CODE_CHECK_LENGTH) {
        try {
          protectedMaterialCheck = await runProtectedMaterialCheck({
            code: generatedCode,
            bearerToken: req.session.accessToken,
            correlationId
          });
          trackGuardrailDecision({
            correlationId,
            guardrail: 'protected_material_code',
            stage: 'direct_check',
            outcome: protectedMaterialCheck.detected ? 'detected' : 'not_detected'
          });
        } catch (checkError) {
          console.error('Direct protected-code check failed with status:', checkError.status || 'unknown');
          trackGuardrailDecision({
            correlationId,
            guardrail: 'protected_material_code',
            stage: 'direct_check',
            outcome: 'error'
          });
          protectedMaterialCheck = {
            completed: false,
            detected: null,
            citations: [],
            error: 'The direct protected-code check could not be completed.'
          };
        }
      } else {
        protectedMaterialCheck = {
          completed: false,
          detected: null,
          citations: [],
          error: `The generated response did not contain at least ${MIN_CODE_CHECK_LENGTH} characters of code for the direct check.`
        };
      }
    }
    result.html = renderMarkdown(result.text);

    return res.json({
      correlationId,
      blocked: false,
      modelGuardrailBlocked: false,
      result,
      protectedMaterialCheck
    });
  } catch (err) {
    const details = JSON.stringify(err.details || {}).toLowerCase();
    const isGuardrailBlock = [400, 403].includes(err.status) &&
      /content[_ ]filter|content safety|jailbreak|shield/.test(details);
    if (isGuardrailBlock) {
      const guardrail = sampleKind === 'prompt_shield'
        ? 'prompt_shield'
        : sampleKind === 'protected_material'
          ? 'protected_material_code'
          : classifyGuardrail(err.details);
      trackGuardrailDecision({
        correlationId,
        guardrail,
        stage: 'request',
        outcome: 'blocked'
      });
      return res.status(200).json({
        correlationId,
        blocked: true,
        guardrail,
        message: 'The Foundry guardrail blocked this request or its generated output. A block is a safety signal, not a legal conclusion.'
      });
    }
    return next(err);
  }
});

router.post('/scientific-code-explainer/check-protected-code', requireAuth, async (req, res, next) => {
  const correlationId = crypto.randomUUID();
  try {
    const code = (req.body.code || '').trim();
    if (code.length < MIN_CODE_CHECK_LENGTH) {
      return res.status(400).json({
        error: `Enter at least ${MIN_CODE_CHECK_LENGTH} characters of code.`
      });
    }
    if (code.length > MAX_CODE_CHECK_LENGTH) {
      return res.status(400).json({
        error: `The code must contain ${MAX_CODE_CHECK_LENGTH} characters or fewer.`
      });
    }
    if (!process.env.APIM_PRESENTER_KEY) {
      throw new Error('APIM_PRESENTER_KEY is not configured.');
    }

    const protectedMaterialCheck = await runProtectedMaterialCheck({
      code,
      bearerToken: req.session.accessToken,
      correlationId
    });
    trackGuardrailDecision({
      correlationId,
      guardrail: 'protected_material_code',
      stage: 'direct_check',
      outcome: protectedMaterialCheck.detected ? 'detected' : 'not_detected'
    });

    return res.json({
      correlationId,
      protectedMaterialCheck
    });
  } catch (err) {
    trackGuardrailDecision({
      correlationId,
      guardrail: 'protected_material_code',
      stage: 'direct_check',
      outcome: 'error'
    });
    return next(err);
  }
});

module.exports = router;
