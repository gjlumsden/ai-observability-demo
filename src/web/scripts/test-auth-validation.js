// Regression coverage for this app's side of the Azure App Service Authentication (Easy
// Auth/MISE) integration: the APPLICATION/PLATFORM TRUST BOUNDARY, not token cryptography.
//
// This app does not parse or verify token signatures, issuers, audiences or lifetimes
// itself: Azure App Service Authentication validates all of that at the platform layer
// (MISE-backed) before forwarding the authenticated identity via X-MS-CLIENT-PRINCIPAL*
// request headers, which external callers cannot set once Easy Auth is enabled. The tests
// below only exercise what this repository IS responsible for: denying requests with no
// forwarded identity header, granting requests that carry a forwarded identity header (as
// Easy Auth would have already validated and set it), and sanitizing the post-login
// redirect target. They intentionally do NOT call these "valid token"/"invalid token"
// tests — actual signature/issuer/audience/lifetime acceptance and rejection can only be
// verified against a real deployment; see scripts/test-easyauth-token-acceptance.js for that
// separately-run, postdeployment-only harness.
const assert = require('node:assert/strict');

process.env.NODE_ENV = 'production';
const app = require('../app');

async function run() {
  const server = app.listen(0, '127.0.0.1');
  await new Promise((resolve, reject) => {
    server.once('listening', resolve);
    server.once('error', reject);
  });
  const base = `http://127.0.0.1:${server.address().port}`;

  try {
    // 1. No forwarded identity header present: a protected route must deny access by
    // default and redirect to sign-in, never serve the page. This tests this app's
    // fail-closed default, not platform token validation.
    const noIdentityHeaderResponse = await fetch(`${base}/model-comparison`, { redirect: 'manual' });
    assert.equal(noIdentityHeaderResponse.status, 302);
    assert.equal(
      new URL(noIdentityHeaderResponse.headers.get('location'), base).pathname,
      '/auth/signin'
    );

    // 2. A forwarded identity header present (as Easy Auth/MISE would have already
    // validated and set it) must be granted access, and the downstream provider access
    // token header must be available for API calls. This tests that this app trusts and
    // reads the platform-forwarded headers correctly; it does not itself validate a token.
    const forwardedIdentityResponse = await fetch(`${base}/model-comparison`, {
      headers: {
        'x-ms-client-principal-id': 'user-object-id',
        'x-ms-client-principal-name': 'demo@example.invalid',
        'x-ms-token-aad-access-token': 'downstream-access-token'
      },
      redirect: 'manual'
    });
    assert.equal(forwardedIdentityResponse.status, 200);

    // 3. An empty/blank principal id header must be treated the same as no header at all
    // (defense against a malformed forwarded identity).
    const blankPrincipalResponse = await fetch(`${base}/model-comparison`, {
      headers: { 'x-ms-client-principal-id': '' },
      redirect: 'manual'
    });
    assert.equal(blankPrincipalResponse.status, 302);

    // 4. Sign-in and sign-out must redirect to the platform's reserved Easy Auth paths, not
    // implement a custom OAuth exchange in this app.
    const signInResponse = await fetch(`${base}/auth/signin`, { redirect: 'manual' });
    assert.equal(signInResponse.status, 302);
    assert.match(signInResponse.headers.get('location'), /^\/\.auth\/login\/aad\?/);

    const signOutResponse = await fetch(`${base}/auth/signout`, { redirect: 'manual' });
    assert.equal(signOutResponse.status, 302);
    assert.match(signOutResponse.headers.get('location'), /^\/\.auth\/logout\?/);

    // 5. The post-login redirect target must be constrained to a same-origin local path.
    // "startsWith('/')" alone would permit protocol-relative/backslash host-confusion
    // variants; these must all fall back to the safe default rather than being echoed into
    // the redirect Location header. Each entry below is the exact raw query-string fragment
    // sent on the wire (not re-encoded by this test), so the encoding under test is explicit.
    const unsafeReturnToQueryFragments = [
      '//evil.example', // protocol-relative: browsers treat "//host" as an absolute URL
      '/\\evil.example', // backslash: some browsers/proxies normalize "\" to "/" -> "//host"
      '/%5Cevil.example', // single percent-encoded backslash, decodes to "/\evil.example"
      '/%2F%2Fevil.example', // single percent-encoded "//", decodes to "//evil.example"
      '/%255Cevil.example', // double-encoded backslash: after Express's one decode this is
      // still "/%5Cevil.example" (looks like a plain path); it must be decoded a second
      // time to reveal the backslash, or it would slip past a filter that decodes only once
      'https%3A%2F%2Fevil.example' // absolute URL with an explicit scheme, no leading slash
    ];
    for (const queryFragment of unsafeReturnToQueryFragments) {
      const response = await fetch(`${base}/auth/signin?returnTo=${queryFragment}`, { redirect: 'manual' });
      assert.equal(response.status, 302);
      const location = response.headers.get('location');
      assert.match(
        location,
        /post_login_redirect_uri=%2Fmodel-comparison$/,
        `Unsafe returnTo query fragment "${queryFragment}" must fall back to the default redirect target, got: ${location}`
      );
    }

    // A genuinely local, same-origin path with a query string must be preserved.
    const safeReturnToResponse = await fetch(
      `${base}/auth/signin?returnTo=${encodeURIComponent('/scientific-code-explainer?tab=history')}`,
      { redirect: 'manual' }
    );
    assert.equal(safeReturnToResponse.status, 302);
    assert.match(
      safeReturnToResponse.headers.get('location'),
      /post_login_redirect_uri=%2Fscientific-code-explainer%3Ftab%3Dhistory$/
    );

    console.log('Authentication validation test passed.');
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
