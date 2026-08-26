const express = require('express');
const crypto = require('crypto');
const msal = require('@azure/msal-node');

const router = express.Router();
const isProduction = process.env.NODE_ENV === 'production';
const authStateCookieName = 'ai-observability-demo.auth-state';

function getAuthStateCookieOptions() {
  return {
    httpOnly: true,
    secure: true,
    sameSite: 'none',
    path: '/auth/callback'
  };
}

function isAuthConfigured() {
  return Boolean(process.env.ENTRA_CLIENT_ID && process.env.ENTRA_TENANT_ID && process.env.ENTRA_CLIENT_SECRET);
}

function getScopes() {
  return (process.env.ENTRA_SCOPES || 'User.Read')
    .split(/[ ,]+/)
    .map((scope) => scope.trim())
    .filter(Boolean);
}

function getRedirectUri(req) {
  if (process.env.ENTRA_REDIRECT_URI) {
    return process.env.ENTRA_REDIRECT_URI;
  }

  return `${req.protocol}://${req.get('host')}/auth/callback`;
}

function getClient() {
  return new msal.ConfidentialClientApplication({
    auth: {
      clientId: process.env.ENTRA_CLIENT_ID,
      authority: `https://login.microsoftonline.com/${process.env.ENTRA_TENANT_ID}`,
      clientSecret: process.env.ENTRA_CLIENT_SECRET
    }
  });
}

router.get('/auth/signin', async (req, res, next) => {
  try {
    if (!isAuthConfigured()) {
      return res.status(503).render('auth/not-configured', {
        pageTitle: 'Authentication not configured'
      });
    }

    const state = crypto.randomUUID();
    if (isProduction) {
      res.cookie(authStateCookieName, state, {
        ...getAuthStateCookieOptions(),
        maxAge: 10 * 60 * 1000
      });
    } else {
      req.session.authState = state;
    }

    const authUrl = await getClient().getAuthCodeUrl({
      scopes: getScopes(),
      redirectUri: getRedirectUri(req),
      state,
      responseMode: isProduction ? msal.ResponseMode.FORM_POST : msal.ResponseMode.QUERY
    });

    return res.redirect(authUrl);
  } catch (err) {
    return next(err);
  }
});

async function handleAuthCallback(req, res, next) {
  try {
    if (!isAuthConfigured()) {
      return res.status(503).render('auth/not-configured', {
        pageTitle: 'Authentication not configured'
      });
    }

    const response = isProduction ? req.body : req.query;
    const expectedState = isProduction
      ? req.cookies[authStateCookieName]
      : req.session.authState;

    if (!response.code || !expectedState || response.state !== expectedState) {
      if (isProduction) {
        res.clearCookie(authStateCookieName, getAuthStateCookieOptions());
      } else {
        delete req.session.authState;
      }
      return res.status(400).render('error', {
        pageTitle: 'Sign in failed',
        message: 'Sign in failed',
        details: 'The authentication response was invalid. Try signing in again.'
      });
    }

    const tokenResponse = await getClient().acquireTokenByCode({
      code: response.code,
      scopes: getScopes(),
      redirectUri: getRedirectUri(req)
    });

    req.session.account = tokenResponse.account;
    req.session.accessToken = tokenResponse.accessToken;
    if (isProduction) {
      res.clearCookie(authStateCookieName, getAuthStateCookieOptions());
    } else {
      delete req.session.authState;
    }

    const returnTo = req.session.returnTo || '/model-comparison';
    delete req.session.returnTo;
    return res.redirect(returnTo);
  } catch (err) {
    return next(err);
  }
}

if (isProduction) {
  router.post('/auth/callback', handleAuthCallback);
} else {
  router.get('/auth/callback', handleAuthCallback);
}

router.get('/auth/signout', (req, res, next) => {
  req.session.destroy((err) => {
    if (err) {
      return next(err);
    }

    return res.redirect('/');
  });
});

module.exports = router;
