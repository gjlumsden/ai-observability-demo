require('dotenv').config();

if (process.env.APPLICATIONINSIGHTS_CONNECTION_STRING) {
  const { useAzureMonitor } = require('@azure/monitor-opentelemetry');
  useAzureMonitor();
}

const path = require('path');
const crypto = require('crypto');
const express = require('express');
const nunjucks = require('nunjucks');
const session = require('express-session');
const cookieParser = require('cookie-parser');
const helmet = require('helmet');
const morgan = require('morgan');

const indexRoutes = require('./routes/index');
const modelComparisonRoutes = require('./routes/model-comparison');
const scientificCodeExplainerRoutes = require('./routes/scientific-code-explainer');
const authRoutes = require('./routes/auth');
const healthRoutes = require('./routes/health');
const weatherApiRoutes = require('./routes/weather-api');
const weatherAgentRoutes = require('./routes/weather-agent');
const { trackRequestException } = require('./lib/telemetry');

const app = express();
const isProduction = process.env.NODE_ENV === 'production';
const sessionSecret = process.env.SESSION_SECRET
  || (!isProduction ? crypto.randomBytes(48).toString('base64url') : null);

if (!sessionSecret) {
  throw new Error('SESSION_SECRET is required when NODE_ENV is production.');
}

const env = nunjucks.configure([
  path.join(__dirname, 'views'),
  path.join(__dirname, 'node_modules', 'govuk-frontend', 'dist')
], {
  autoescape: true,
  express: app,
  noCache: !isProduction
});

env.addGlobal('serviceName', 'AI Observability Demo');

app.set('view engine', 'njk');
app.set('views', path.join(__dirname, 'views'));

// Behind App Service / any reverse proxy, trust X-Forwarded-* so req.protocol
// reports 'https' and Set-Cookie Secure works correctly.
app.set('trust proxy', 1);

app.use((req, res, next) => {
  res.locals.cspNonce = crypto.randomBytes(16).toString('base64');
  next();
});
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'", (req, res) => `'nonce-${res.locals.cspNonce}'`],
      styleSrc: ["'self'", (req, res) => `'nonce-${res.locals.cspNonce}'`],
      imgSrc: ["'self'", 'data:'],
      fontSrc: ["'self'", 'data:'],
      connectSrc: ["'self'"],
      objectSrc: ["'none'"],
      baseUri: ["'self'"],
      formAction: ["'self'"],
      frameAncestors: ["'none'"],
      upgradeInsecureRequests: isProduction ? [] : null
    }
  },
  strictTransportSecurity: isProduction
    ? { maxAge: 31536000, includeSubDomains: true }
    : false
}));
morgan.token('safe-url', (req) => req.path);
const accessLogFormat = isProduction
  ? ':remote-addr - :remote-user [:date[clf]] ":method :safe-url HTTP/:http-version" :status :res[content-length] ":referrer" ":user-agent"'
  : ':method :safe-url :status :response-time ms - :res[content-length]';
app.use(morgan(accessLogFormat));
app.use(cookieParser());
app.use(express.urlencoded({ extended: true, limit: '1mb' }));
app.use(express.json({ limit: '1mb' }));
app.use(weatherApiRoutes);
app.use('/govuk', express.static(path.join(__dirname, 'node_modules', 'govuk-frontend', 'dist', 'govuk')));
app.use(express.static(path.join(__dirname, 'public')));

app.use(session({
  name: 'ai-observability-demo.sid',
  secret: sessionSecret,
  resave: false,
  saveUninitialized: false,
  cookie: {
    httpOnly: true,
    secure: isProduction,
    sameSite: 'lax'
  }
  // Demo only: MemoryStore is not suitable for production scale-out.
}));

app.use((req, res, next) => {
  res.locals.currentPath = req.path;
  res.locals.isAuthenticated = Boolean(req.session?.account);
  res.locals.user = req.session?.account || null;
  res.locals.navigation = [
    { href: '/', text: 'Home', active: req.path === '/' },
    { href: '/model-comparison', text: 'Model comparison', active: req.path.startsWith('/model-comparison') },
    { href: '/scientific-code-explainer', text: 'Code explainer', active: req.path.startsWith('/scientific-code-explainer') },
    { href: '/weather-agent', text: 'Weather agent', active: req.path.startsWith('/weather-agent') },
    req.session?.account
      ? { href: '/auth/signout', text: 'Sign out', active: false }
      : { href: '/auth/signin', text: 'Sign in', active: req.path.startsWith('/auth') }
  ];
  next();
});

app.use(healthRoutes);
app.use(indexRoutes);
app.use(authRoutes);
app.use(modelComparisonRoutes);
app.use(scientificCodeExplainerRoutes);
app.use(weatherAgentRoutes);

app.use((req, res) => {
  res.status(404).render('error', {
    pageTitle: 'Page not found',
    message: 'Page not found',
    details: 'Check the web address or use the main navigation.'
  });
});

app.use((err, req, res, next) => {
  const status = err.status || 500;
  trackRequestException({ error: err, status });
  console.error(`Request failed: name=${err.name || 'Error'} status=${status} path=${req.path}`);
  res.status(status).render('error', {
    pageTitle: 'Sorry, there is a problem with the service',
    message: 'Sorry, there is a problem with the service',
    details: isProduction ? 'Try again later.' : err.message
  });
});

const port = process.env.PORT || 3000;
if (require.main === module) {
  app.listen(port, () => {
    console.log(`AI Observability Demo web app listening on port ${port}`);
  });
}

module.exports = app;
