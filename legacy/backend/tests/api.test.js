import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/app.js';

let server, base;
before(async () => {
  const app = createApp();
  await new Promise((res) => { server = app.listen(0, res); });
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => server && server.close());

test('GET /health returns ok', async () => {
  const r = await fetch(`${base}/health`);
  const j = await r.json();
  assert.equal(r.status, 200);
  assert.equal(j.status, 'ok');
});

test('protected route without token returns 401', async () => {
  const r = await fetch(`${base}/api/buses`);
  assert.equal(r.status, 401);
});

test('register with missing fields returns 400 (validation runs before DB)', async () => {
  const r = await fetch(`${base}/api/auth/register`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: 'not-an-email' }),
  });
  assert.equal(r.status, 400);
  const j = await r.json();
  assert.equal(j.error, 'Validation failed');
});

test('OpenAPI spec is served', async () => {
  const r = await fetch(`${base}/api/docs.json`);
  const j = await r.json();
  assert.equal(j.openapi, '3.0.3');
});
