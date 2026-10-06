// Regression guard for GHSA-x5fp-wj9c-mxmx (qs array-limit bypass, first patched in qs@6.16.0).
// qs is a transitive dependency of express and body-parser; there is no direct dependency to
// bump, so the fix is an npm "overrides" entry in package.json. This test locks that override
// in place and fails if a future change ever resolves qs back to a vulnerable version.
const assert = require('node:assert/strict');
const path = require('node:path');
const { readFileSync } = require('node:fs');
const { renderMarkdown } = require('../lib/markdown');

const FIRST_PATCHED_QS_VERSION = '6.16.0';

function parseVersion(version) {
  const [major, minor, patch] = version.split('.').map(Number);
  return { major, minor, patch };
}

function isAtLeast(version, minVersion) {
  const actual = parseVersion(version);
  const min = parseVersion(minVersion);
  if (actual.major !== min.major) {
    return actual.major > min.major;
  }
  if (actual.minor !== min.minor) {
    return actual.minor > min.minor;
  }
  return actual.patch >= min.patch;
}

const lockfilePath = path.join(__dirname, '..', 'package-lock.json');
const lockfile = JSON.parse(readFileSync(lockfilePath, 'utf8'));

const qsEntries = Object.entries(lockfile.packages)
  .filter(([packagePath]) => packagePath === 'node_modules/qs' || packagePath.endsWith('/node_modules/qs'));

assert.ok(
  qsEntries.length > 0,
  'Expected qs to be present in package-lock.json as a transitive dependency of express/body-parser.'
);

for (const [packagePath, entry] of qsEntries) {
  assert.ok(
    isAtLeast(entry.version, FIRST_PATCHED_QS_VERSION),
    `${packagePath} resolves to qs@${entry.version}, which is vulnerable to GHSA-x5fp-wj9c-mxmx. `
      + `Requires qs >= ${FIRST_PATCHED_QS_VERSION}. Check the "overrides" entry in package.json.`
  );
}

const sanitized = renderMarkdown(
  '[safe](https://example.com) [unsafe](javascript:alert(1)) <script>alert(1)</script>'
);
assert.match(sanitized, /<a rel="noopener noreferrer" href="https:\/\/example\.com">safe<\/a>/);
assert.doesNotMatch(sanitized, /href="javascript:/i);
assert.doesNotMatch(sanitized, /<script/i);

console.log(
  `Dependency security tests passed: qs resolves to >= ${FIRST_PATCHED_QS_VERSION}, and rendered Markdown removes unsafe HTML and URLs.`
);
