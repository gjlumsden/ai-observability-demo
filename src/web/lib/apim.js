const {
  SpanKind,
  SpanStatusCode,
  context,
  propagation,
  trace
} = require('@opentelemetry/api');

const tracer = trace.getTracer('ai-observability-demo-web');

function getBaseUrl() {
  const baseUrl = process.env.APIM_BASE_URL;
  if (!baseUrl) {
    const err = new Error('APIM_BASE_URL is not configured.');
    err.status = 503;
    throw err;
  }

  return baseUrl.replace(/\/$/, '');
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function callApim({ path, subscriptionKey, bearerToken, body, extraHeaders = {}, includeMetadata = false }) {
  if (!subscriptionKey) {
    const err = new Error('APIM subscription key is not configured.');
    err.status = 503;
    throw err;
  }

  const url = `${getBaseUrl()}${path.startsWith('/') ? path : `/${path}`}`;
  const headers = {
    'Content-Type': 'application/json',
    ...extraHeaders,
    'Ocp-Apim-Subscription-Key': subscriptionKey
  };

  if (bearerToken) {
    headers.Authorization = `Bearer ${bearerToken}`;
  }

  const requestUrl = new URL(url);
  return tracer.startActiveSpan(
    `POST ${requestUrl.pathname}`,
    {
      kind: SpanKind.CLIENT,
      attributes: {
        'http.request.method': 'POST',
        'server.address': requestUrl.hostname,
        'url.full': url
      }
    },
    async (span) => {
      propagation.inject(context.active(), headers);

      try {
        let response = await fetch(url, {
          method: 'POST',
          headers,
          body: JSON.stringify(body)
        });

        if (response.status === 429) {
          span.setAttribute('http.request.resend_count', 1);
          await sleep(1000);
          response = await fetch(url, {
            method: 'POST',
            headers,
            body: JSON.stringify(body)
          });
        }

        span.setAttribute('http.response.status_code', response.status);

        const text = await response.text();
        let payload;
        try {
          payload = text ? JSON.parse(text) : {};
        } catch {
          payload = text;
        }

        if (!response.ok) {
          const err = new Error(typeof payload === 'string' ? payload : payload.message || 'APIM request failed.');
          err.status = response.status;
          err.details = payload;
          throw err;
        }

        span.setStatus({ code: SpanStatusCode.OK });

        if (includeMetadata) {
          return {
            payload,
            headers: Object.fromEntries(response.headers.entries())
          };
        }

        return payload;
      } catch (error) {
        span.recordException(new Error('The APIM dependency failed.'));
        span.setStatus({
          code: SpanStatusCode.ERROR,
          message: error.status ? `HTTP ${error.status}` : 'APIM dependency failed'
        });
        throw error;
      } finally {
        span.end();
      }
    }
  );
}

module.exports = { callApim };
