process.env.NODE_ENV = 'production';
process.env.SESSION_SECRET = 'test-session-secret-that-is-long-enough-for-this-check';
process.env.ENTRA_CLIENT_ID = '00000000-0000-0000-0000-000000000001';
process.env.ENTRA_TENANT_ID = '00000000-0000-0000-0000-000000000002';
process.env.ENTRA_CLIENT_SECRET = 'test-client-secret';

const msal = require('@azure/msal-node');
msal.ConfidentialClientApplication.prototype.getAuthCodeUrl = async ({ state }) =>
  `https://login.example.invalid/authorize?state=${encodeURIComponent(state)}`;
msal.ConfidentialClientApplication.prototype.acquireTokenByCode = async () => ({
  account: { username: 'demo@example.invalid' },
  accessToken: 'test-access-token'
});
const app = require('../app');

const originalWrite = process.stdout.write.bind(process.stdout);
let output = '';
process.stdout.write = (chunk, encoding, callback) => {
  output += chunk instanceof Buffer ? chunk.toString(encoding) : String(chunk);
  return originalWrite(chunk, encoding, callback);
};

const server = app.listen(0, '127.0.0.1', async () => {
  const code = 'sensitive-authorization-code';

  try {
    const signInResponse = await fetch(`http://127.0.0.1:${server.address().port}/auth/signin`, {
      headers: {
        'x-forwarded-proto': 'https'
      },
      redirect: 'manual'
    });
    const stateCookie = signInResponse.headers.getSetCookie()
      .find((value) => value.startsWith('ai-observability-demo.auth-state='));
    if (!stateCookie || !stateCookie.includes('SameSite=None') || !stateCookie.includes('Secure')) {
      throw new Error('The short-lived authentication state cookie is not cross-site secure.');
    }
    const cookieHeader = stateCookie.split(';', 1)[0];
    const returnedState = new URL(signInResponse.headers.get('location')).searchParams.get('state');

    const response = await fetch(`http://127.0.0.1:${server.address().port}/auth/callback`, {
      method: 'POST',
      headers: {
        'content-type': 'application/x-www-form-urlencoded',
        cookie: cookieHeader,
        'x-forwarded-proto': 'https'
      },
      body: new URLSearchParams({ code, state: returnedState }),
      redirect: 'manual'
    });

    await response.text();
    await new Promise((resolve) => setTimeout(resolve, 50));

    const sessionCookie = response.headers.getSetCookie()
      .find((value) => value.startsWith('ai-observability-demo.sid='));
    if (!sessionCookie || !sessionCookie.includes('SameSite=Lax') || !sessionCookie.includes('Secure')) {
      throw new Error('The authenticated session cookie does not enforce SameSite=Lax.');
    }
    if (output.includes(code) || output.includes(returnedState)) {
      throw new Error('Authentication artifacts appeared in access logs.');
    }
    if (!output.includes('POST /auth/callback')) {
      throw new Error('The callback path was not present in access logs.');
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
