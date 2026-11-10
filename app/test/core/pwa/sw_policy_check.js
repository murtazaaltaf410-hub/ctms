// Run from app/: node test/core/pwa/sw_policy_check.js
const assert = require('assert');
global.self = {
  location: { origin: 'https://app.example' },
  registration: { scope: 'https://app.example/' },
  addEventListener() {},
};
const { isAllowListed } = require('../../../web/ctms_sw.js');
function req(url, { method = 'GET', headers = {} } = {}) {
  const h = new Map(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
  return { url, method, headers: { has: (k) => h.has(k.toLowerCase()) } };
}
const yes = ['/', '/main.dart.js', '/flutter.js', '/canvaskit/canvaskit.wasm',
  '/assets/FontManifest.json', '/icons/Icon-192.png', '/offline.html',
  '/manifest.json', '/assets/fonts/MaterialIcons-Regular.otf'];
const no = ['/api/v1/buses/live', '/api/v1/me', '/api/v1/trips/1/locations', '/ws',
  '/api/v1/ws/live', '/auth/callback', '/__/auth/handler', '/api/v1/pickup',
  '/roster.json', '/token.json', '/location.js', '/buses/live.json',
  '/maps/tile.png', '/main.dart.js?token=abc', '/firebase-messaging-sw.js'];
for (const p of yes) assert(isAllowListed(req('https://app.example' + p)), 'should allow ' + p);
for (const p of no) assert(!isAllowListed(req('https://app.example' + p)), 'should deny ' + p);
for (const u of ['https://maps.googleapis.com/maps/api/js', 'https://maps.gstatic.com/a.png',
  'https://khms0.googleapis.com/kh?v=1', 'https://api.onrender.com/main.js', 'https://cdn.example/x.js']) {
  assert(!isAllowListed(req(u)), 'should deny ' + u);
}
assert(!isAllowListed(req('https://app.example/main.dart.js', { method: 'POST' })));
assert(!isAllowListed(req('https://app.example/main.dart.js', { headers: { Authorization: 'Bearer x' } })));
assert(!isAllowListed(req('https://app.example/main.dart.js', { headers: { Range: 'bytes=0-1' } })));
console.log('sw policy ok');
