// Confirms request access logs never leak the Easy Auth identity headers or the forwarded
// downstream access token (auth/body logging privacy requirement).
const assert = require('node:assert/strict');

process.env.NODE_ENV = 'production';
const app = require('../app');

const originalWrite = process.stdout.write.bind(process.stdout);
let output = '';
process.stdout.write = (chunk, encoding, callback) => {
  output += chunk instanceof Buffer ? chunk.toString(encoding) : String(chunk);
  return originalWrite(chunk, encoding, callback);
};

const server = app.listen(0, '127.0.0.1', async () => {
  const secretAccessToken = 'sensitive-downstream-access-token';
  const principalId = 'sensitive-principal-id';

  try {
    const { port } = server.address();
    const response = await fetch(`http://127.0.0.1:${port}/model-comparison`, {
      headers: {
        'x-forwarded-proto': 'https',
        'x-ms-client-principal-id': principalId,
        'x-ms-client-principal-name': 'demo@example.invalid',
        'x-ms-token-aad-access-token': secretAccessToken
      },
      redirect: 'manual'
    });
    await response.text();

    assert.equal(response.status, 200, 'Expected the Easy Auth principal headers to grant access.');
    if (output.includes(secretAccessToken) || output.includes(principalId)) {
      throw new Error('Authentication artifacts appeared in access logs.');
    }
    if (!output.includes('GET /model-comparison')) {
      throw new Error('The requested path was not present in access logs.');
    }

    originalWrite('Authentication logging test passed.\n');
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  } finally {
    process.stdout.write = originalWrite;
    server.close();
  }
});
