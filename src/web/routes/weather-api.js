const crypto = require('crypto');
const express = require('express');
const { getWeatherForecast } = require('../lib/weather');

const router = express.Router();

function hasValidBackendKey(req) {
  const configuredKey = process.env.MCP_WEATHER_KEY;
  const suppliedKey = req.get('x-mcp-key');
  if (!configuredKey || !suppliedKey) {
    return false;
  }

  const configured = Buffer.from(configuredKey);
  const supplied = Buffer.from(suppliedKey);
  return configured.length === supplied.length && crypto.timingSafeEqual(configured, supplied);
}

router.post('/api/weather/forecast', async (req, res, next) => {
  try {
    if (!process.env.MCP_WEATHER_KEY) {
      return res.status(503).json({ error: 'The weather API is not configured.' });
    }
    if (!hasValidBackendKey(req)) {
      return res.status(401).json({ error: 'Authentication is required.' });
    }

    const location = typeof req.body.location === 'string' ? req.body.location.trim() : '';
    const forecastDays = Number(req.body.forecastDays ?? 3);
    if (location.length < 2 || location.length > 120) {
      return res.status(400).json({ error: 'Location must contain between 2 and 120 characters.' });
    }
    if (!Number.isInteger(forecastDays) || forecastDays < 1 || forecastDays > 7) {
      return res.status(400).json({ error: 'forecastDays must be an integer from 1 through 7.' });
    }

    return res.json(await getWeatherForecast(location, forecastDays));
  } catch (error) {
    return next(error);
  }
});

module.exports = router;
