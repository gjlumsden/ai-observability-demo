// POSTDEPLOYMENT-ONLY acceptance harness for Azure App Service Authentication (Easy
// Auth/MISE) token handling: valid, expired, wrong-audience, wrong-issuer and
// invalid-signature access tokens against a REAL deployed instance.
//
// Separate from `test:auth-validation` (predeployment, local process, exercises only this
// app's own forwarded-identity trust boundary). Real signature/issuer/audience/lifetime
// acceptance or rejection is performed entirely by the Azure App Service Authentication
// platform (MISE-backed) and cannot be exercised without a real deployment. This script
// never mints a pretend token and never logs token values or fragments.
//
// Usage: set EASYAUTH_ACCEPTANCE_BASE_URL to the deployed app's https URL for the specific
// deployment to verify right now -- no default, never reuse a stale/previous value. ALL
// five token fixture env vars below are required; partial coverage never runs and never
// exits 0.
//
// Exit codes:
//   0 = all five cases ran and passed
//   1 = ran and at least one case failed
//   2 = NOT RUN: base URL and/or one or more token fixtures missing, or base URL invalid
//
// Required:
//   EASYAUTH_ACCEPTANCE_BASE_URL                 e.g. https://<app>.azurewebsites.net
//   EASYAUTH_ACCEPTANCE_VALID_TOKEN
//   EASYAUTH_ACCEPTANCE_EXPIRED_TOKEN
//   EASYAUTH_ACCEPTANCE_WRONG_AUDIENCE_TOKEN
//   EASYAUTH_ACCEPTANCE_WRONG_ISSUER_TOKEN
//   EASYAUTH_ACCEPTANCE_INVALID_SIGNATURE_TOKEN
// Optional:
//   EASYAUTH_ACCEPTANCE_PROTECTED_PATH           default: /model-comparison

const NOT_RUN_EXIT_CODE = 2;
const REQUEST_TIMEOUT_MS = 10000;

const CASES = [
  { name: 'valid token', envVar: 'EASYAUTH_ACCEPTANCE_VALID_TOKEN', expect: 'accepted' },
  { name: 'expired token', envVar: 'EASYAUTH_ACCEPTANCE_EXPIRED_TOKEN', expect: 'rejected' },
  {
    name: 'wrong-audience token',
    envVar: 'EASYAUTH_ACCEPTANCE_WRONG_AUDIENCE_TOKEN',
    expect: 'rejected'
  },
  {
    name: 'wrong-issuer token',
    envVar: 'EASYAUTH_ACCEPTANCE_WRONG_ISSUER_TOKEN',
    expect: 'rejected'
  },
  {
    name: 'invalid-signature token',
    envVar: 'EASYAUTH_ACCEPTANCE_INVALID_SIGNATURE_TOKEN',
    expect: 'rejected'
  }
];

// Rejects anything that is not a plain https origin: no credentials, no query, no
// fragment. Bearer credentials must never be sent over a non-HTTPS or ambiguous URL.
function validateBaseUrl(rawUrl) {
  let parsed;
  try {
    parsed = new URL(rawUrl);
  } catch {
    throw new Error('base URL is not a valid absolute URL');
  }
  if (parsed.protocol !== 'https:') {
    throw new Error('base URL must use https');
  }
  if (parsed.username || parsed.password) {
    throw new Error('base URL must not contain credentials');
  }
  if (parsed.search || parsed.hash) {
    throw new Error('base URL must not contain a query string or fragment');
  }
  return parsed;
}

// Resolves the protected path against the validated base and requires the result to stay
// on the same origin -- an absolute-URL path value must not silently redirect the request
// (and its bearer token) to a different host.
function buildProtectedUrl(baseUrl, protectedPath) {
  const resolved = new URL(protectedPath, baseUrl);
  if (resolved.origin !== baseUrl.origin) {
    throw new Error('resolved protected URL must stay on the same origin as the base URL');
  }
  return resolved;
}

// Only an explicit platform-level auth rejection (401/403) proves the credential was
// rejected. A 302 is inconclusive: it could be this app's own unauthenticated redirect,
// unrelated navigation, or something else -- it does not prove platform validation ran.
function classifyOutcome(status) {
  if (status === 200) {
    return 'accepted';
  }
  if (status === 401 || status === 403) {
    return 'rejected';
  }
  return 'inconclusive';
}

function missingFixtureEnvVars() {
  return CASES.filter((c) => !process.env[c.envVar]).map((c) => c.envVar);
}

async function runCase({ name, envVar, expect }, url) {
  const token = process.env[envVar];
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  let response;
  try {
    response = await fetch(url, {
      headers: { Authorization: `Bearer ${token}` },
      redirect: 'manual',
      signal: controller.signal
    });
  } catch (error) {
    return { name, outcome: 'fail', status: null, detail: `request error: ${error.message}` };
  } finally {
    clearTimeout(timeout);
  }

  const classified = classifyOutcome(response.status);
  return {
    name,
    outcome: classified === expect ? 'pass' : 'fail',
    status: response.status,
    detail: classified
  };
}

async function run() {
  const rawBaseUrl = process.env.EASYAUTH_ACCEPTANCE_BASE_URL;
  const protectedPath = process.env.EASYAUTH_ACCEPTANCE_PROTECTED_PATH || '/model-comparison';

  if (!rawBaseUrl) {
    console.log('NOT RUN: EASYAUTH_ACCEPTANCE_BASE_URL is not set.');
    console.log('Expected before deployment; this is not a test failure and not a pass.');
    process.exitCode = NOT_RUN_EXIT_CODE;
    return;
  }

  let baseUrl;
  let protectedUrl;
  try {
    baseUrl = validateBaseUrl(rawBaseUrl);
    protectedUrl = buildProtectedUrl(baseUrl, protectedPath);
  } catch (error) {
    console.log(`NOT RUN: ${error.message}.`);
    process.exitCode = NOT_RUN_EXIT_CODE;
    return;
  }

  const missing = missingFixtureEnvVars();
  if (missing.length > 0) {
    console.log(`NOT RUN: missing token fixture(s): ${missing.join(', ')}.`);
    console.log('All five fixtures are required; partial coverage never runs and never passes.');
    process.exitCode = NOT_RUN_EXIT_CODE;
    return;
  }

  const results = [];
  for (const testCase of CASES) {
    // eslint-disable-next-line no-await-in-loop -- sequential, low-volume acceptance checks
    results.push(await runCase(testCase, protectedUrl));
  }

  console.log(`Easy Auth token acceptance results against ${protectedUrl.toString()}:`);
  let anyFail = false;
  for (const result of results) {
    console.log(`  [${result.outcome.toUpperCase()}] ${result.name} -- status=${result.status} outcome=${result.detail}`);
    if (result.outcome === 'fail') {
      anyFail = true;
    }
  }

  if (anyFail) {
    console.error('Easy Auth token acceptance check FAILED for one or more cases.');
    process.exitCode = 1;
    return;
  }

  console.log('Easy Auth token acceptance check passed for all cases.');
}

module.exports = { validateBaseUrl, buildProtectedUrl, classifyOutcome, missingFixtureEnvVars, CASES };

if (require.main === module) {
  run().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
