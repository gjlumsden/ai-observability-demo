// Client-side helper for protected same-origin requests. It reads the short-lived provider
// access token from the App Service token store and sends it as a bearer token. If the app
// reports PROVIDER_TOKEN_EXPIRED, it refreshes the token and retries the action once.
//
// The token stays in local function scope. This script does not persist or log it.
//
// See: https://learn.microsoft.com/azure/app-service/configure-authentication-oauth-tokens
//
// UMD pattern: in Node.js (test environment) the factory is exported for dependency
// injection of a mock fetch. In the browser the factory runs immediately using real fetch,
// and window.fetchWithTokenRefresh is set.
(function (root, factory) {
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') {
    module.exports = factory;
  } else {
    root.fetchWithTokenRefresh = factory(root.fetch.bind(root));
  }
}(typeof globalThis !== 'undefined' ? globalThis : this, function makeFetchWithTokenRefresh(fetchFn) {
  const IDENTITY_URL = '/.auth/me';
  const REFRESH_URL = '/.auth/refresh';
  const REFRESH_TIMEOUT_MS = 10000;

  function makeRefreshFailedError() {
    const err = new Error(
      'Your session credentials have expired and could not be refreshed. Please sign out and sign back in.'
    );
    err.refreshFailed = true;
    return err;
  }

  function makeTokenUnavailableError() {
    const err = new Error(
      'Your signed-in access token is unavailable. Please sign out and sign back in.'
    );
    err.refreshFailed = true;
    return err;
  }

  async function getProviderAccessToken() {
    let response;
    try {
      response = await fetchFn(IDENTITY_URL, {
        credentials: 'same-origin',
        cache: 'no-store',
        headers: { Accept: 'application/json' }
      });
    } catch {
      throw makeTokenUnavailableError();
    }

    if (!response.ok) {
      throw makeTokenUnavailableError();
    }

    let identities;
    try {
      identities = await response.json();
    } catch {
      throw makeTokenUnavailableError();
    }

    const identity = Array.isArray(identities)
      ? identities.find((item) => item && typeof item.access_token === 'string' && item.access_token.length > 0)
      : null;
    if (!identity) {
      throw makeTokenUnavailableError();
    }

    return identity.access_token;
  }

  function withBearerToken(options, accessToken) {
    const requestOptions = Object.assign({}, options || {});
    requestOptions.credentials = 'same-origin';
    requestOptions.headers = Object.assign({}, requestOptions.headers || {}, {
      Authorization: `Bearer ${accessToken}`
    });
    return requestOptions;
  }

  return async function fetchWithTokenRefresh(url, options) {
    let accessToken = await getProviderAccessToken();
    let response = await fetchFn(url, withBearerToken(options, accessToken));
    if (response.status !== 401) {
      return response;
    }

    let payload;
    try {
      // Clone so the original response body remains readable by the caller.
      payload = await response.clone().json();
    } catch {
      return response;
    }

    // Guard against null, arrays, primitives, or any non-object JSON body.
    if (!payload || typeof payload !== 'object' || payload.code !== 'PROVIDER_TOKEN_EXPIRED') {
      return response;
    }

    // redirect:'error' treats an unexpected platform redirect as a failure.
    // The finite timeout prevents indefinite blocking.
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), REFRESH_TIMEOUT_MS);
    let refreshResponse;
    try {
      refreshResponse = await fetchFn(REFRESH_URL, {
        credentials: 'same-origin',
        redirect: 'error',
        signal: controller.signal
      });
    } catch {
      throw makeRefreshFailedError();
    } finally {
      clearTimeout(timeoutId);
    }

    if (!refreshResponse.ok) {
      throw makeRefreshFailedError();
    }

    accessToken = await getProviderAccessToken();
    response = await fetchFn(url, withBearerToken(options, accessToken));
    return response;
  };
}));
