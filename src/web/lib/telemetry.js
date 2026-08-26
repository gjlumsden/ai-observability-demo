const { SeverityNumber, logs } = require('@opentelemetry/api-logs');
const { SpanStatusCode, trace } = require('@opentelemetry/api');

const logger = logs.getLogger('ai-observability-demo-web');

function trackGuardrailDecision({
  correlationId,
  guardrail,
  stage,
  outcome
}) {
  try {
    logger.emit({
      body: 'guardrail.decision',
      severityNumber: SeverityNumber.INFO,
      attributes: {
        'microsoft.custom_event.name': 'guardrail.decision',
        correlationId,
        guardrail,
        stage,
        outcome,
        source: 'scientific-code-explainer'
      }
    });
  } catch (error) {
    console.warn('Guardrail telemetry failed:', error.message);
  }
}

function trackRequestException({ error, status }) {
  const span = trace.getActiveSpan();
  if (!span) {
    return;
  }

  const stack = typeof error.stack === 'string'
    ? error.stack.split('\n').slice(1).join('\n')
    : undefined;

  span.recordException({
    name: error.name || 'Error',
    message: `Request failed with HTTP ${status}.`,
    stack
  });
  span.setAttribute('http.response.status_code', status);
  span.setStatus({
    code: SpanStatusCode.ERROR,
    message: `HTTP ${status}`
  });
}

module.exports = {
  trackGuardrailDecision,
  trackRequestException
};
