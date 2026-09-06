// Local regression coverage for the postdeployment Easy Auth acceptance harness's own
// safety guards (src/web/scripts/test-easyauth-token-acceptance.js). Exercises only pure
// functions: no network calls, no real tokens, no live deployment required.

const assert = require('node:assert/strict');
const {
  validateBaseUrl,
  buildProtectedUrl,
  classifyOutcome,
  missingFixtureEnvVars,
  CASES
} = require('./test-easyauth-token-acceptance.js');

function expectThrows(fn, messageFragment) {
  assert.throws(fn, (error) => error.message.includes(messageFragment));
}

// (1) Base URL must be https, no credentials, no query/fragment.
expectThrows(() => validateBaseUrl('http://example.azurewebsites.net'), 'https');
expectThrows(() => validateBaseUrl('https://user:pass@example.azurewebsites.net'), 'credentials');
expectThrows(() => validateBaseUrl('https://example.azurewebsites.net?x=1'), 'query string');
expectThrows(() => validateBaseUrl('https://example.azurewebsites.net#frag'), 'query string');
expectThrows(() => validateBaseUrl('not a url'), 'valid absolute URL');
const validBase = validateBaseUrl('https://example.azurewebsites.net');
assert.equal(validBase.origin, 'https://example.azurewebsites.net');

// Resolved protected path must stay on the same origin as the validated base URL.
const sameOrigin = buildProtectedUrl(validBase, '/model-comparison');
assert.equal(sameOrigin.origin, validBase.origin);
assert.equal(sameOrigin.pathname, '/model-comparison');
expectThrows(
  () => buildProtectedUrl(validBase, 'https://attacker.example/steal'),
  'same origin'
);
expectThrows(() => buildProtectedUrl(validBase, '//attacker.example/steal'), 'same origin');

// (2) No token-masking helper is exported/used by the harness output path.
assert.equal(
  Object.prototype.hasOwnProperty.call(require('./test-easyauth-token-acceptance.js'), 'maskToken'),
  false,
  'harness must not export or print any token fragment/length helper'
);

// (3) Any missing fixture blocks the run, not only when all are missing.
const originalEnv = { ...process.env };
try {
  for (const c of CASES) {
    delete process.env[c.envVar];
  }
  assert.equal(missingFixtureEnvVars().length, CASES.length, 'all missing -> all reported');

  process.env[CASES[0].envVar] = 'placeholder-fixture-value';
  const partial = missingFixtureEnvVars();
  assert.equal(partial.length, CASES.length - 1, 'partial fixtures must still report as missing');
  assert.ok(!partial.includes(CASES[0].envVar));

  for (const c of CASES) {
    process.env[c.envVar] = 'placeholder-fixture-value';
  }
  assert.equal(missingFixtureEnvVars().length, 0, 'all present -> none missing');
} finally {
  process.env = originalEnv;
}

// (4) Only 401/403 count as a proven rejection; 200 is accepted; anything else
// (including 302, 500) is inconclusive, never treated as proof of rejection.
assert.equal(classifyOutcome(200), 'accepted');
assert.equal(classifyOutcome(401), 'rejected');
assert.equal(classifyOutcome(403), 'rejected');
assert.equal(classifyOutcome(302), 'inconclusive');
assert.equal(classifyOutcome(500), 'inconclusive');

console.log('Easy Auth acceptance harness guard tests passed.');
