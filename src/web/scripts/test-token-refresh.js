// Regression coverage for the Easy Auth provider token expiry and refresh flow.
//
// Covers the APPLICATION/PLATFORM BOUNDARY: expiry detection via X-MS-TOKEN-AAD-EXPIRES-ON
// and the browser-driven /.auth/refresh retry. Not Microsoft cryptography.
// See: https://learn.microsoft.com/azure/app-service/configure-authentication-oauth-tokens
//
// Tests:
//   (1) parseProviderTokenExpiry — numeric Unix seconds, ISO UTC, ISO offset, invalid forms
//   (2) isProviderTokenExpired   — pure-function boundary values
//   (3) Server endpoints         — expired header → 401/PROVIDER_TOKEN_EXPIRED on all four
//                                  protected POST routes; fresh and absent headers must NOT
//                                  return PROVIDER_TOKEN_EXPIRED (APIM isolated via stub)
//   (4) Client helper            — platform token acquisition, bearer injection, refresh,
//                                  token reacquisition, malformed responses, no persistence

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

process.env.NODE_ENV = 'production';

function requireAuthForNodeEnv(nodeEnv) {
  const authPath = require.resolve('../middleware/auth');
  delete require.cache[authPath];

  const previousNodeEnv = process.env.NODE_ENV;
  if (nodeEnv === undefined) {
    delete process.env.NODE_ENV;
  } else {
    process.env.NODE_ENV = nodeEnv;
  }

  const auth = require('../middleware/auth');

  if (previousNodeEnv === undefined) {
    delete process.env.NODE_ENV;
  } else {
    process.env.NODE_ENV = previousNodeEnv;
  }

  return auth;
}

// ---------------------------------------------------------------------------
// (1) parseProviderTokenExpiry
// ---------------------------------------------------------------------------
const { isProviderTokenExpired, parseProviderTokenExpiry } = require('../middleware/auth');

// Numeric Unix-second strings
const nowS = Math.floor(Date.now() / 1000);
const freshNumeric = String(nowS + 3600);
const expiredNumeric = String(nowS - 120);

assert.ok(parseProviderTokenExpiry(freshNumeric) > nowS,
  '1: fresh numeric must parse to a future epoch');
assert.ok(parseProviderTokenExpiry(expiredNumeric) < nowS,
  '1: expired numeric must parse to a past epoch');

// ISO UTC (Z suffix)
assert.ok(parseProviderTokenExpiry('2099-01-01T00:00:00Z') > nowS,
  '1: far-future ISO UTC must parse to a future epoch');
assert.ok(parseProviderTokenExpiry('2020-01-01T00:00:00Z') < nowS,
  '1: past ISO UTC must parse to a past epoch');

// ISO with fixed offset (+HH:MM / -HH:MM)
assert.ok(parseProviderTokenExpiry('2099-01-01T01:00:00+01:00') > nowS,
  '1: far-future ISO offset must parse to a future epoch');
assert.ok(parseProviderTokenExpiry('2020-01-01T01:00:00+01:00') < nowS,
  '1: past ISO offset must parse to a past epoch');

// Expired flag round-trip through isProviderTokenExpired
assert.equal(isProviderTokenExpired(parseProviderTokenExpiry('2099-01-01T00:00:00Z')), false,
  '1: far-future ISO UTC must not be flagged as expired');
assert.equal(isProviderTokenExpired(parseProviderTokenExpiry('2020-01-01T00:00:00Z')), true,
  '1: past ISO UTC must be flagged as expired');
assert.equal(isProviderTokenExpired(parseProviderTokenExpiry(freshNumeric)), false,
  '1: fresh numeric must not be flagged as expired');
assert.equal(isProviderTokenExpired(parseProviderTokenExpiry(expiredNumeric)), true,
  '1: expired numeric must be flagged as expired');

// Invalid / unsafe forms — must return null (safe fallback: proceed to APIM)
assert.equal(parseProviderTokenExpiry(null), null,                  '1: null → null');
assert.equal(parseProviderTokenExpiry(undefined), null,             '1: undefined → null');
assert.equal(parseProviderTokenExpiry(''), null,                    '1: empty string → null');
assert.equal(parseProviderTokenExpiry('not-a-date'), null,          '1: arbitrary string → null');
assert.equal(parseProviderTokenExpiry('2026-09-06T23:59:59'), null, '1: ISO without timezone → null');
assert.equal(parseProviderTokenExpiry('2026'), null,                '1: bare year (too small) → null');
assert.equal(parseProviderTokenExpiry('123'), null,                 '1: small integer (too small) → null');
assert.equal(parseProviderTokenExpiry(1756988278), null,            '1: number, not string → null');

console.log('(1) parseProviderTokenExpiry tests passed.');

// ---------------------------------------------------------------------------
// (2) isProviderTokenExpired pure-function boundary values
// ---------------------------------------------------------------------------
assert.equal(isProviderTokenExpired(null), false,           '2: null → false');
assert.equal(isProviderTokenExpired(undefined), false,      '2: undefined → false');
assert.equal(isProviderTokenExpired(NaN), false,            '2: NaN → false');
assert.equal(isProviderTokenExpired(nowS + 3600), false,    '2: future → false');
assert.equal(isProviderTokenExpired(nowS + 59), true,       '2: within 60-s buffer → true');
assert.equal(isProviderTokenExpired(nowS - 1), true,        '2: past → true');

console.log('(2) isProviderTokenExpired pure-function tests passed.');

// ---------------------------------------------------------------------------
// Non-production/default mode must ignore spoofed Easy Auth headers.
// ---------------------------------------------------------------------------
{
  const { readAuth } = requireAuthForNodeEnv(undefined);
  const req = {
    headers: {
      'x-ms-client-principal-id': 'spoofed-user-id',
      'x-ms-client-principal-name': 'spoofed@example.invalid',
      'x-ms-token-aad-access-token': 'spoofed-downstream-token',
      'x-ms-token-aad-expires-on': freshNumeric
    }
  };
  let nextCalled = false;
  readAuth(req, {}, () => {
    nextCalled = true;
  });
  assert.equal(req.user, null, 'non-production must not populate req.user from spoofed headers');
  assert.equal(nextCalled, true, 'non-production must continue to the next middleware');
}

// Restore the production load before requiring app (isProduction flag in auth/routes).
delete require.cache[require.resolve('../middleware/auth')];
process.env.NODE_ENV = 'production';
const app = require('../app');

// Prevent any real outbound APIM call from the server under test.
// dotenv.config() runs inside require('../app'); override its values now so that
// request-time env reads in route handlers find no configured endpoint.
delete process.env.APIM_BASE_URL;
delete process.env.APIM_PRESENTER_KEY;

// ---------------------------------------------------------------------------
// (3) Server endpoint tests
// ---------------------------------------------------------------------------
async function runServerTests() {
  const server = app.listen(0, '127.0.0.1');
  await new Promise((resolve, reject) => {
    server.once('listening', resolve);
    server.once('error', reject);
  });
  const base = `http://127.0.0.1:${server.address().port}`;

  try {
    const expiredEpoch = String(nowS - 120);
    const freshEpoch = String(nowS + 3600);
    const expiredIso = '2020-01-01T00:00:00Z';
    const freshIso = '2099-01-01T00:00:00Z';
    const authHeaders = {
      'x-ms-client-principal-id': 'test-user-id',
      'x-ms-client-principal-name': 'test@example.invalid',
      'x-ms-token-aad-access-token': 'test-downstream-token',
      'Content-Type': 'application/json'
    };

    // Helper: assert a POST returns 401/PROVIDER_TOKEN_EXPIRED for a given route and expiry.
    async function assertExpired(path, body, expiresOnHeader, label) {
      const res = await fetch(`${base}${path}`, {
        method: 'POST',
        headers: { ...authHeaders, 'x-ms-token-aad-expires-on': expiresOnHeader },
        body: JSON.stringify(body)
      });
      assert.equal(res.status, 401, `${label}: expected HTTP 401`);
      // Expired check returns JSON before the handler runs; do not use a catch fallback.
      const payload = await res.json();
      assert.equal(payload.code, 'PROVIDER_TOKEN_EXPIRED',
        `${label}: expected PROVIDER_TOKEN_EXPIRED code`);
    }

    // Helper: assert a POST does NOT return PROVIDER_TOKEN_EXPIRED for a given route.
    // Fresh/no-expiry calls reach the handler, which fails because APIM is not configured
    // (guaranteed by deleting the env vars above). The status may be 4xx or 5xx; it must
    // not be 401 with PROVIDER_TOKEN_EXPIRED.
    async function assertNotExpired(path, body, expiresOnHeader, label) {
      const headers = expiresOnHeader
        ? { ...authHeaders, 'x-ms-token-aad-expires-on': expiresOnHeader }
        : authHeaders;
      const res = await fetch(`${base}${path}`, {
        method: 'POST',
        headers,
        body: JSON.stringify(body)
      });
      assert.notEqual(res.status, 401, `${label}: must not return 401`);
    }

    // 3a. All four protected POST routes return PROVIDER_TOKEN_EXPIRED for expired tokens.
    await assertExpired('/model-comparison/run',
      { prompt: 'test' }, expiredEpoch, '3a model-comparison numeric');
    await assertExpired('/model-comparison/run',
      { prompt: 'test' }, expiredIso, '3a model-comparison ISO UTC');
    await assertExpired('/scientific-code-explainer/explain',
      { prompt: 'test code' }, expiredEpoch, '3a explain numeric');
    await assertExpired('/scientific-code-explainer/check-protected-code',
      { code: 'x'.repeat(120) }, expiredEpoch, '3a check-protected-code numeric');
    await assertExpired('/weather-agent/run',
      { prompt: 'test weather' }, expiredEpoch, '3a weather-agent numeric');

    // 3b. Fresh token (numeric) — must NOT return PROVIDER_TOKEN_EXPIRED.
    await assertNotExpired('/model-comparison/run',
      { prompt: 'test' }, freshEpoch, '3b model-comparison fresh numeric');
    await assertNotExpired('/model-comparison/run',
      { prompt: 'test' }, freshIso, '3b model-comparison fresh ISO');

    // 3c. No expiry header — must NOT return PROVIDER_TOKEN_EXPIRED.
    await assertNotExpired('/model-comparison/run',
      { prompt: 'test' }, null, '3c model-comparison no expiry header');

    // 3d. Missing or empty provider access token — must be rejected early with
    //      401/PROVIDER_TOKEN_MISSING before any downstream handler or APIM call.
    const protectedPaths = [
      '/model-comparison/run',
      '/scientific-code-explainer/explain',
      '/scientific-code-explainer/check-protected-code',
      '/weather-agent/run'
    ];

    for (const path of protectedPaths) {
      const baseHeaders = {
        'x-ms-client-principal-id': 'test-user-id',
        'x-ms-client-principal-name': 'test@example.invalid',
        'Content-Type': 'application/json'
      };

      const bodyByPath = {
        '/model-comparison/run': { prompt: 'test' },
        '/scientific-code-explainer/explain': { prompt: 'test code' },
        '/scientific-code-explainer/check-protected-code': { code: 'x'.repeat(120) },
        '/weather-agent/run': { prompt: 'test weather' }
      };

      // Missing header
      const resMissing = await fetch(`${base}${path}`, {
        method: 'POST',
        headers: baseHeaders,
        body: JSON.stringify(bodyByPath[path])
      });
      assert.equal(resMissing.status, 401, `3d ${path} missing token: expected HTTP 401`);
      const payloadMissing = await resMissing.json();
      assert.equal(payloadMissing.code, 'PROVIDER_TOKEN_MISSING',
        `3d ${path} missing token: expected PROVIDER_TOKEN_MISSING code`);

      // Explicit empty token header
      const resEmpty = await fetch(`${base}${path}`, {
        method: 'POST',
        headers: { ...baseHeaders, 'x-ms-token-aad-access-token': '' },
        body: JSON.stringify(bodyByPath[path])
      });
      assert.equal(resEmpty.status, 401, `3d ${path} empty token: expected HTTP 401`);
      const payloadEmpty = await resEmpty.json();
      assert.equal(payloadEmpty.code, 'PROVIDER_TOKEN_MISSING',
        `3d ${path} empty token: expected PROVIDER_TOKEN_MISSING code`);
    }

    console.log('(3) Server endpoint token expiry tests passed.');
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

// ---------------------------------------------------------------------------
// (4) Client helper tests (mock fetch injected via the UMD factory)
// ---------------------------------------------------------------------------
class MockResponse {
  constructor(status, body) {
    this.status = status;
    this.ok = status >= 200 && status < 300;
    this._body = body;
  }
  clone() { return new MockResponse(this.status, this._body); }
  async json() { return JSON.parse(this._body); } // throws on empty/invalid JSON — no fallback
}

const makeFetchWithTokenRefresh = require('../public/easy-auth-refresh');

async function runClientTests() {
  const identityResponse = (token) => new MockResponse(200, JSON.stringify([
    { provider_name: 'aad', access_token: token }
  ]));

  // 4a. The helper gets the platform token and sends it without removing request headers.
  {
    const calls = [];
    const mockFetch = async (url, options) => {
      calls.push({ url, options });
      if (url === '/.auth/me') { return identityResponse('token-a'); }
      return new MockResponse(200, '{}');
    };
    const subject = makeFetchWithTokenRefresh(mockFetch);
    const res = await subject('/test', { method: 'POST', headers: { 'Content-Type': 'application/json' } });
    assert.equal(res.status, 200, '4a: 200 must be returned unchanged');
    assert.deepEqual(calls.map((call) => call.url), ['/.auth/me', '/test'],
      '4a: token acquisition must precede the protected action');
    assert.equal(calls[1].options.headers.Authorization, 'Bearer token-a',
      '4a: action must include the provider bearer token');
    assert.equal(calls[1].options.headers['Content-Type'], 'application/json',
      '4a: action must preserve caller headers');
    assert.equal(calls[1].options.credentials, 'same-origin',
      '4a: action must use same-origin credentials');
  }

  // 4b. A 401 with null JSON returns as-is and does not refresh.
  {
    let refreshCalled = false;
    const mockFetch = async (url) => {
      if (url === '/.auth/me') { return identityResponse('token-a'); }
      if (url === '/.auth/refresh') { refreshCalled = true; }
      return new MockResponse(401, 'null');
    };
    const subject = makeFetchWithTokenRefresh(mockFetch);
    const res = await subject('/test', {});
    assert.equal(res.status, 401, '4b: null-body 401 must be returned as-is');
    assert.equal(refreshCalled, false, '4b: refresh must not be called for null payload');
  }

  // 4c. A 401 with an unrelated code returns as-is and does not refresh.
  {
    let refreshCalled = false;
    const mockFetch = async (url) => {
      if (url === '/.auth/me') { return identityResponse('token-a'); }
      if (url === '/.auth/refresh') { refreshCalled = true; }
      return new MockResponse(401, JSON.stringify({ code: 'OTHER_ERROR' }));
    };
    const subject = makeFetchWithTokenRefresh(mockFetch);
    const res = await subject('/test', {});
    assert.equal(res.status, 401, '4c: unrelated 401 must be returned unchanged');
    assert.equal(refreshCalled, false, '4c: unrelated 401 must not start refresh');
  }

  // 4d. A refresh network error stops the request without a retry.
  {
    let actionCallCount = 0;
    const mockFetch = async (url) => {
      if (url === '/.auth/me') { return identityResponse('token-a'); }
      if (url === '/.auth/refresh') { throw new TypeError('Failed to fetch'); }
      actionCallCount++;
      return new MockResponse(401, JSON.stringify({ code: 'PROVIDER_TOKEN_EXPIRED' }));
    };
    const subject = makeFetchWithTokenRefresh(mockFetch);
    let caughtErr;
    try { await subject('/test', {}); } catch (e) { caughtErr = e; }
    assert.ok(caughtErr, '4d: refresh network error must throw');
    assert.equal(caughtErr.refreshFailed, true, '4d: error must have refreshFailed=true');
    assert.equal(actionCallCount, 1, '4d: action must not retry after refresh network error');
  }

  // 4e. A successful refresh reacquires the token and retries once.
  {
    let identityCallCount = 0;
    let actionCallCount = 0;
    const actionTokens = [];
    const mockFetch = async (url, options) => {
      if (url === '/.auth/me') {
        identityCallCount++;
        return identityResponse(identityCallCount === 1 ? 'token-old' : 'token-new');
      }
      if (url === '/.auth/refresh') { return new MockResponse(200, ''); }
      actionCallCount++;
      actionTokens.push(options.headers.Authorization);
      return actionCallCount === 1
        ? new MockResponse(401, JSON.stringify({ code: 'PROVIDER_TOKEN_EXPIRED' }))
        : new MockResponse(200, JSON.stringify({ ok: true }));
    };
    const subject = makeFetchWithTokenRefresh(mockFetch);
    const res = await subject('/test', {});
    assert.equal(identityCallCount, 2, '4e: refreshed request must reacquire the platform token');
    assert.equal(actionCallCount, 2, '4e: action must retry once');
    assert.deepEqual(actionTokens, ['Bearer token-old', 'Bearer token-new'],
      '4e: retry must use the refreshed token');
    assert.equal(res.status, 200, '4e: retry response must be returned');
  }

  // 4f. A non-success refresh response stops the request without a retry.
  {
    let actionCallCount = 0;
    const mockFetch = async (url) => {
      if (url === '/.auth/me') { return identityResponse('token-a'); }
      if (url === '/.auth/refresh') { return new MockResponse(401, ''); }
      actionCallCount++;
      return new MockResponse(401, JSON.stringify({ code: 'PROVIDER_TOKEN_EXPIRED' }));
    };
    const subject = makeFetchWithTokenRefresh(mockFetch);
    let caughtErr;
    try { await subject('/test', {}); } catch (e) { caughtErr = e; }
    assert.ok(caughtErr, '4f: non-success refresh must throw');
    assert.equal(caughtErr.refreshFailed, true, '4f: error must have refreshFailed=true');
    assert.equal(actionCallCount, 1, '4f: action must not retry after failed refresh');
  }

  // 4g. Missing or malformed platform tokens stop before the protected action.
  for (const [name, response] of [
    ['non-success', new MockResponse(401, '[]')],
    ['malformed JSON', new MockResponse(200, 'not-json')],
    ['missing token', new MockResponse(200, JSON.stringify([{ provider_name: 'aad' }]))]
  ]) {
    let actionCalled = false;
    const mockFetch = async (url) => {
      if (url === '/.auth/me') { return response; }
      actionCalled = true;
      return new MockResponse(200, '{}');
    };
    const subject = makeFetchWithTokenRefresh(mockFetch);
    let caughtErr;
    try { await subject('/test', {}); } catch (e) { caughtErr = e; }
    assert.ok(caughtErr, `4g ${name}: unavailable token must throw`);
    assert.equal(caughtErr.refreshFailed, true, `4g ${name}: error must have refreshFailed=true`);
    assert.equal(actionCalled, false, `4g ${name}: protected action must not run`);
  }

  const helperSource = fs.readFileSync(path.join(__dirname, '..', 'public', 'easy-auth-refresh.js'), 'utf8');
  assert.doesNotMatch(helperSource, /localStorage|sessionStorage|console\./,
    '4h: helper must not persist or log the provider token');

  console.log('(4) Client bearer-token and refresh helper tests passed.');
}

Promise.all([runServerTests(), runClientTests()]).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
