const fs = require('fs');
const path = require('path');

const source = path.join(__dirname, '..', 'node_modules', 'govuk-frontend', 'dist', 'govuk', 'assets');
const target = path.join(__dirname, '..', 'public', 'assets');

if (!fs.existsSync(source)) {
  console.warn(`GOV.UK Frontend assets not found at ${source}; skipping copy.`);
  process.exit(0);
}

fs.rmSync(target, { recursive: true, force: true });
fs.mkdirSync(path.dirname(target), { recursive: true });
fs.cpSync(source, target, { recursive: true });
console.log(`Copied GOV.UK Frontend assets to ${target}`);
