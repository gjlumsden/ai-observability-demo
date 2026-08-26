const crypto = require('crypto');
const express = require('express');
const { callApim } = require('../lib/apim');
const { normalizeWeatherAgentResponse } = require('../lib/weather-agent');
const { renderMarkdown } = require('../lib/markdown');
const { weatherAgentPrompts } = require('../lib/scenario-prompts');
const { requireAuth } = require('../middleware/auth');

const router = express.Router();
const MAX_PROMPT_LENGTH = 2000;

router.get('/weather-agent', requireAuth, (req, res) => {
  res.render('weather-agent/index', {
    pageTitle: 'Weather Forecasting Agent',
    prompts: weatherAgentPrompts
  });
});

router.post('/weather-agent/run', requireAuth, async (req, res, next) => {
  try {
    const prompt = (req.body.prompt || '').trim();
    if (!prompt) {
      return res.status(400).json({ error: 'Enter a weather planning question.' });
    }
    if (prompt.length > MAX_PROMPT_LENGTH) {
      return res.status(400).json({ error: `The prompt must contain ${MAX_PROMPT_LENGTH} characters or fewer.` });
    }
    if (!process.env.APIM_PRESENTER_KEY) {
      throw new Error('APIM_PRESENTER_KEY is not configured.');
    }

    const correlationId = crypto.randomUUID();
    const response = await callApim({
      path: '/agents/weather/responses',
      subscriptionKey: process.env.APIM_PRESENTER_KEY,
      bearerToken: req.session.accessToken,
      includeMetadata: true,
      extraHeaders: {
        'x-correlation-id': correlationId
      },
      body: {
        input: prompt
      }
    });
    const result = normalizeWeatherAgentResponse(response.payload);
    return res.json({
      ...result,
      correlationId,
      html: renderMarkdown(result.text)
    });
  } catch (error) {
    return next(error);
  }
});

module.exports = router;
