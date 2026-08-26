const MarkdownIt = require('markdown-it');
const sanitizeHtml = require('sanitize-html');

const markdown = new MarkdownIt({
  html: false,
  linkify: true,
  typographer: false
});

const allowedTags = [
  'p',
  'br',
  'ul',
  'ol',
  'li',
  'strong',
  'em',
  'code',
  'pre',
  'blockquote',
  'h2',
  'h3',
  'h4',
  'table',
  'thead',
  'tbody',
  'tr',
  'th',
  'td',
  'hr',
  'a'
];

function renderMarkdown(value) {
  const rendered = markdown.render(String(value || ''));
  return sanitizeHtml(rendered, {
    allowedTags,
    allowedAttributes: {
      a: ['href', 'title', 'rel'],
      code: ['class'],
      th: ['scope']
    },
    allowedSchemes: ['http', 'https', 'mailto'],
    transformTags: {
      a: sanitizeHtml.simpleTransform('a', {
        rel: 'noopener noreferrer'
      }, true)
    }
  });
}

module.exports = { renderMarkdown };
