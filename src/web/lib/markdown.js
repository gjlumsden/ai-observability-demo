const MarkdownIt = require('markdown-it');
const { FilterXSS } = require('xss');

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

const whiteList = Object.fromEntries(allowedTags.map((tag) => [tag, []]));
whiteList.a = ['href', 'title'];
whiteList.code = ['class'];
whiteList.th = ['scope'];

const filter = new FilterXSS({
  whiteList,
  stripIgnoreTag: true,
  stripIgnoreTagBody: ['script', 'style']
});

function renderMarkdown(value) {
  const rendered = markdown.render(String(value || ''));
  const sanitized = filter.process(rendered);
  return sanitized.replace(/<a(?=\s|>)/g, '<a rel="noopener noreferrer"');
}

module.exports = { renderMarkdown };
