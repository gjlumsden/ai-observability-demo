const assert = require('node:assert/strict');

process.env.MCP_WEATHER_KEY = 'test-weather-key';
const app = require('../app');

async function run() {
  const httpServer = app.listen(0);
  await new Promise((resolve, reject) => {
    httpServer.once('listening', resolve);
    httpServer.once('error', reject);
  });

  try {
    const { port } = httpServer.address();
    const endpoint = `http://127.0.0.1:${port}/api/weather/forecast`;
    const unauthorized = await fetch(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ location: 'Exeter, UK', forecastDays: 1 })
    });
    assert.equal(unauthorized.status, 401);

    const response = await fetch(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-mcp-key': process.env.MCP_WEATHER_KEY
      },
      body: JSON.stringify({ location: 'Exeter, UK', forecastDays: 1 })
    });
    assert.equal(response.status, 200);
    const payload = await response.json();
    assert.equal(payload.source, undefined);
    assert.equal(payload.forecast.length, 1);
    assert.match(payload.location.country, /United Kingdom/i);

    console.log('Weather API integration test passed.');
  } finally {
    await new Promise((resolve) => httpServer.close(resolve));
  }
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
