// Inbound authentication is provided by Azure App Service Authentication ("Easy Auth")
// running in front of this Node process, with MISE (Microsoft Identity Service Essentials)
// enabled as the platform's token-validation engine. The platform validates the caller's
// token signature, issuer, audience and lifetime BEFORE the request reaches Express, then
// forwards the authenticated identity using the `X-MS-CLIENT-PRINCIPAL*` request headers.
// App Service strips any client-supplied copies of these headers, so they can be trusted
// here in production. This module does not perform its own JWT parsing or validation: that
// would substitute a custom implementation for the approved MISE-backed platform control.
//
// See: https://learn.microsoft.com/azure/app-service/overview-authentication-authorization
// and: https://learn.microsoft.com/azure/app-service/configure-authentication-user-identities
//
// There is no application-level bypass of this platform check, in any environment. Easy Auth
// only runs once the app is deployed behind Azure App Service, so protected routes cannot be
// exercised on a local development machine; see routes/auth.js for the local sign-in message
// shown to developers, and scripts/test-auth-validation.js for how this trust boundary (not
// token cryptography, which the platform alone performs) is covered by automated tests.

// Treat the provider token as expired this far before its actual expiry time (seconds).
// This buffer avoids race conditions where the token expires mid-request.
// See: https://learn.microsoft.com/azure/app-service/configure-authentication-oauth-tokens
const PROVIDER_TOKEN_REFRESH_BUFFER_S = 60;

// Any plausible future token expiry exceeds this Unix epoch value (2001-09-09).
// Values below this threshold are rejected as implausible (e.g. a bare year number).
const MIN_PLAUSIBLE_EPOCH_S = 1000000000;

// Parses the X-MS-TOKEN-AAD-EXPIRES-ON header to a Unix epoch timestamp in seconds.
// The platform documentation does not specify a single canonical format; both
// representations below are therefore supported without assuming either will always appear.
//   - Complete all-digit strings are treated as Unix epoch seconds.
//   - ISO 8601 strings with an explicit UTC (Z) or fixed-offset (+/-HH:MM) designator
//     are converted via Date.parse; bare timestamps without a timezone are rejected to
//     avoid locale-dependent parsing.
// Any other form, or a value too small to be a plausible future expiry, returns null.
// Null is safe: isProviderTokenExpired returns false and the downstream call proceeds.
function parseProviderTokenExpiry(rawValue) {
  if (!rawValue || typeof rawValue !== 'string') {
    return null;
  }
  const trimmed = rawValue.trim();
  if (/^\d+$/.test(trimmed)) {
    const epochS = Number(trimmed);
    return Number.isFinite(epochS) && epochS >= MIN_PLAUSIBLE_EPOCH_S ? epochS : null;
  }
  if (/Z$|[+-]\d{2}:\d{2}$/.test(trimmed)) {
    const asDate = new Date(trimmed);
    if (!isNaN(asDate.getTime())) {
      return Math.floor(asDate.getTime() / 1000);
    }
  }
  return null;
}

// Returns true when the provider token is expired or within the refresh buffer.
// expiresAt is a Unix epoch timestamp in seconds from parseProviderTokenExpiry.
// Returns false when expiresAt is absent or non-finite: state is unknown;
// the downstream call proceeds and APIM handles any actual expiry.
function isProviderTokenExpired(expiresAt) {
  if (expiresAt == null || !Number.isFinite(expiresAt)) {
    return false;
  }
  return Math.floor(Date.now() / 1000) >= expiresAt - PROVIDER_TOKEN_REFRESH_BUFFER_S;
}

function getEasyAuthPrincipal(req) {
  const principalId = req.headers['x-ms-client-principal-id'];
  if (!principalId) {
    return null;
  }

  return {
    id: principalId,
    name: req.headers['x-ms-client-principal-name'] || null,
    // Provider token forwarded by Easy Auth's token store, scoped by the Microsoft Entra
    // app registration's configured login scopes. Used as the bearer token for downstream
    // API calls; never parsed or validated by this app.
    accessToken: req.headers['x-ms-token-aad-access-token'] || null,
    // Expiry of the provider token in Unix epoch seconds, parsed from
    // X-MS-TOKEN-AAD-EXPIRES-ON. Used only to detect expiry before forwarding to APIM;
    // never used for JWT validation or any cryptographic purpose.
    tokenExpiresAt: parseProviderTokenExpiry(req.headers['x-ms-token-aad-expires-on'])
  };
}

function readAuth(req, res, next) {
  req.user = getEasyAuthPrincipal(req);
  next();
}

function requireAuth(req, res, next) {
  if (req.user) {
    return next();
  }

  const returnTo = encodeURIComponent(req.originalUrl);
  return res.redirect(`/auth/signin?returnTo=${returnTo}`);
}

// Use on JSON API routes that forward req.user.accessToken to downstream services.
// Returns HTTP 401 with code PROVIDER_TOKEN_EXPIRED when the provider token is expired
// or within the refresh buffer, so the browser client can call /.auth/refresh and retry.
// Must be placed after requireAuth in the middleware chain.
function requireFreshProviderToken(req, res, next) {
  if (req.user && isProviderTokenExpired(req.user.tokenExpiresAt)) {
    return res.status(401).json({
      code: 'PROVIDER_TOKEN_EXPIRED',
      error: 'The provider access token has expired. Refresh the session and try again.'
    });
  }
  return next();
}

module.exports = { readAuth, requireAuth, requireFreshProviderToken, isProviderTokenExpired, parseProviderTokenExpiry };
