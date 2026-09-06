// Client-side helper: when the app server responds with HTTP 401 and code
// PROVIDER_TOKEN_EXPIRED, calls the platform /.auth/refresh endpoint so the token store
// renews the access token for this browser session, then retries the original action once.
//
// The App Service platform refreshes the provider token in its own token store. Subsequent
// same-origin requests from the browser carry the fresh token automatically. No token value
// is read, stored, or logged in this script.
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
  const REFRESH_URL = '/.auth/refresh';
  const REFRESH_TIMEOUT_MS = 10000;

  function makeRefreshFailedError() {
    const err = new Error(
      'Your session credentials have expired and could not be refreshed. Please sign out and sign back in.'
    );
    err.refreshFailed = true;
    return err;
  }

  return async function fetchWithTokenRefresh(url, options) {
    const response = await fetchFn(url, options);
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

    // Call the platform refresh endpoint. The browser session cookie is sent automatically
    // with same-origin credentials; no token is read or forwarded by this script.
    // redirect:'error' ensures an unexpected platform redirect is treated as a failure
    // rather than silently following it. A finite timeout prevents indefinite blocking.
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
      // Network error, unexpected redirect (with redirect:'error'), or timeout abort —
      // all are refresh failures; surface through the same clear message.
      throw makeRefreshFailedError();
    } finally {
      clearTimeout(timeoutId);
    }

    if (!refreshResponse.ok) {
      throw makeRefreshFailedError();
    }

    // Retry the original action once. The platform has renewed the token in its store, so
    // the next request carries a fresh X-MS-TOKEN-AAD-ACCESS-TOKEN header automatically.
    return fetchFn(url, options);
  };
}));
