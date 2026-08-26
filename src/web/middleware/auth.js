function requireAuth(req, res, next) {
  if (req.session?.accessToken) {
    return next();
  }

  req.session.returnTo = req.originalUrl;
  return res.redirect('/auth/signin');
}

module.exports = { requireAuth };
