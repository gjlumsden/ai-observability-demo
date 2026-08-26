const express = require('express');

const router = express.Router();

router.get('/', (req, res) => {
  res.render('index', {
    pageTitle: 'AI Observability Demo',
    cards: [
      {
        title: 'Governed Model Comparison',
        href: '/model-comparison',
        description: 'Run one scientific coding task through GPT and Claude, then compare governed usage and performance.'
      },
      {
        title: 'Scientific Code Explainer',
        href: '/scientific-code-explainer',
        description: 'Explain public scientific code and demonstrate code-generation guardrails.'
      },
      {
        title: 'Weather Forecasting Agent',
        href: '/weather-agent',
        description: 'Use a Foundry prompt agent with one governed weather MCP tool.'
      }
    ]
  });
});

module.exports = router;
