import { test } from 'node:test';
import assert from 'node:assert/strict';
import { haversineKm, etaMinutes } from '../src/utils/eta.js';
import { hashPassword, verifyPassword } from '../src/utils/password.js';
import { signAccessToken, verifyAccessToken, generateRefreshToken, hashToken } from '../src/utils/jwt.js';

test('haversine: same point is ~0 km', () => {
  assert.ok(haversineKm(34.128, 74.837, 34.128, 74.837) < 0.001);
});

test('haversine: Hazratbal -> Sopore is ~25-30 km', () => {
  const d = haversineKm(34.128, 74.837, 34.287, 74.469);
  assert.ok(d > 25 && d < 40, `got ${d}`);
});

test('etaMinutes: stationary bus uses assumed avg speed, never < 1', () => {
  assert.ok(etaMinutes(10, 0) >= 1);
  assert.equal(etaMinutes(0, 30), 1);
});

test('password hashing round-trips and rejects wrong password', async () => {
  const hash = await hashPassword('Student@123');
  assert.ok(await verifyPassword('Student@123', hash));
  assert.equal(await verifyPassword('wrong', hash), false);
});

test('jwt access token signs and verifies with correct claims', () => {
  const token = signAccessToken({ id: 7, role: 'student', full_name: 'Aisha' });
  const payload = verifyAccessToken(token);
  assert.equal(payload.sub, 7);
  assert.equal(payload.role, 'student');
});

test('refresh token hashing is deterministic and 64 hex chars', () => {
  const rt = generateRefreshToken();
  assert.equal(hashToken(rt), hashToken(rt));
  assert.match(hashToken(rt), /^[a-f0-9]{64}$/);
});
