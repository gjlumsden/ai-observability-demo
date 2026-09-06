const express = require('express');

const router = express.Router();
const isProduction = process.env.NODE_ENV === 'production';
const DEFAULT_RETURN_TO = '/model-comparison';

// Only a single, in-app, same-origin relative path may be used as a post-login redirect
// target. `startsWith('/')` alone is not sufficient: a value such as "//evil.example" or
// "/\evil.example" still starts with a single slash but browsers (and some proxies, which
// normalize backslashes to forward slashes) treat it as a scheme-relative absolute URL to a
// different host. This check is enforced by this app regardless of any redirect-URI
// filtering Easy Auth itself performs, rather than relying solely on the platform.
function isSafeLocalReturnPath(value) {
  if (typeof value !== 'string' || value.length === 0 || value.length > 2048) {
    return false;
  }

  let decoded;
  try {
    // Decode first so an encoded backslash/slash (e.g. "%5C", "%2F%2F") can't smuggle a
    // scheme-relative or backslash-based host past the raw-string checks below.
    decoded = decodeURIComponent(value);
  } catch {
    return false;
  }

  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f]/.test(decoded)) {
    return false;
  }
  if (decoded.includes('\\')) {
    return false;
  }
  if (!decoded.startsWith('/') || decoded.startsWith('//')) {
    return false;
  }
  // Reject an explicit scheme (e.g. a value containing "javascript:" before any slash);
  // startsWith('/') already blocks "scheme://host" forms, this guards a bare "/x:y" edge case.
  if (/^\/[a-z][a-z0-9+.-]*:/i.test(decoded)) {
    return false;
  }

  return true;
}

// Sign-in and sign-out are handled by Azure App Service Authentication ("Easy Auth"), which
// exposes reserved `/.auth/*` paths at the platform layer, in front of this Node process.
// These routes only redirect the browser to those platform endpoints; they never see, store
// or validate a token themselves. See middleware/auth.js for how the resulting authenticated
// identity is consumed.
router.get('/auth/signin', (req, res) => {
  if (!isProduction) {
    // Easy Auth only exists once the app is deployed behind Azure App Service. There is no
    // supported local bypass: protected routes cannot be signed into on a developer machine.
    return res.status(503).render('auth/not-configured', {
      pageTitle: 'Sign-in is not available in local development'
    });
  }

  const returnTo = isSafeLocalReturnPath(req.query.returnTo) ? req.query.returnTo : DEFAULT_RETURN_TO;
  return res.redirect(`/.auth/login/aad?post_login_redirect_uri=${encodeURIComponent(returnTo)}`);
});

router.get('/auth/signout', (req, res) => {
  if (!isProduction) {
    return res.redirect('/');
  }

  return res.redirect('/.auth/logout?post_logout_redirect_uri=%2F');
});

module.exports = router;
