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
    accessToken: req.headers['x-ms-token-aad-access-token'] || null
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

module.exports = { readAuth, requireAuth };
