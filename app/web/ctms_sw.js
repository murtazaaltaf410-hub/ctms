/* CTMS service worker. Deliberately tiny.
 *
 * Does ONE thing: keep a safe offline app shell (same-origin static assets).
 * It NEVER caches API, auth, WebSocket, location, pickup, roster, tokens,
 * anything cross-origin (Google Maps tiles/scripts, Firebase, Google sign-in),
 * or any request carrying credentials. See docs/v1/web-pwa-caching.md.
 *
 * BUILD_ID is stamped by the release pipeline (sed). A changed BUILD_ID makes
 * this file byte-different, which is what triggers the browser update flow.
 * The cache name embeds BUILD_ID so assets of two builds are never mixed.
 */
'use strict';

const BUILD_ID = '__BUILD_ID__';
const CACHE_PREFIX = 'ctms-shell-';
const CACHE_NAME = CACHE_PREFIX + BUILD_ID;
const OFFLINE_URL = 'offline.html';
const PRECACHE = [OFFLINE_URL, 'offline.css', 'favicon.png', 'icons/Icon-192.png'];

// ---- Policy -------------------------------------------------------------

// Path prefixes (relative to the app scope) that must never touch Cache
// Storage. Checked first; wins over the allow-list.
const DENY_PATH_PREFIXES = [
  '/api', '/ws', '/auth', '/token', '/login', '/logout', '/session',
  '/location', '/pickup', '/roster', '/me', '/trips', '/buses',
  '/push', '/subscription', '/firebase', '/__', '/config', '/admin',
  '/maps', '/tiles',
];

// Host fragments that are never cached. Cross-origin is refused anyway; this
// is explicit documentation and a second line of defence.
const DENY_ORIGIN_FRAGMENTS = [
  'maps.googleapis.com', 'maps.gstatic.com', 'googleapis.com', 'gstatic.com',
  'google.com', 'firebaseapp.com', 'firebaseio.com', 'identitytoolkit',
  'securetoken', 'onrender.com',
];

// Same-origin static assets only.
const ALLOW_EXTENSIONS = [
  '.js', '.mjs', '.wasm', '.css', '.png', '.jpg', '.jpeg', '.webp', '.svg',
  '.ico', '.woff', '.woff2', '.ttf', '.otf', '.json', '.html', '.txt',
];
const ALLOW_DIRS = ['/assets/', '/canvaskit/', '/icons/'];

function isAllowListed(request) {
  if (request.method !== 'GET') return false;
  if (request.headers.has('authorization')) return false;
  if (request.headers.has('range')) return false;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return false;
  const host = url.hostname.toLowerCase();
  for (const o of DENY_ORIGIN_FRAGMENTS) if (host.indexOf(o) !== -1) return false;
  const path = url.pathname.toLowerCase();
  const scopePath = new URL(self.registration.scope).pathname.toLowerCase();
  const rel = '/' + (path.indexOf(scopePath) === 0 ? path.slice(scopePath.length) : path.replace(/^\//, ''));
  if (path.indexOf('/api/') !== -1) return false;
  for (const d of DENY_PATH_PREFIXES) if (rel.indexOf(d) === 0) return false;
  if (url.search.toLowerCase().indexOf('token') !== -1) return false;
  for (const d of ALLOW_DIRS) if (rel.indexOf(d) === 0) return true;
  for (const e of ALLOW_EXTENSIONS) if (rel.endsWith(e)) return true;
  return rel === '/';
}

function isCacheableResponse(response) {
  if (!response || response.status !== 200 || response.type !== 'basic') return false;
  if (response.redirected) return false;
  const cc = (response.headers.get('cache-control') || '').toLowerCase();
  if (cc.indexOf('no-store') !== -1 || cc.indexOf('private') !== -1) return false;
  if (response.headers.has('set-cookie')) return false;
  return true;
}

// ---- Lifecycle ----------------------------------------------------------

self.addEventListener('install', (event) => {
  // No skipWaiting here: the page decides when to switch (update prompt), so
  // an open tab never gets new JS under old HTML.
  event.waitUntil(caches.open(CACHE_NAME).then((c) => c.addAll(PRECACHE)));
});

function clearShellCaches(keep) {
  return caches.keys().then((names) => Promise.all(names
    .filter((n) => n.indexOf(CACHE_PREFIX) === 0 && n !== keep)
    .map((n) => caches.delete(n))));
}

self.addEventListener('activate', (event) => {
  event.waitUntil(clearShellCaches(CACHE_NAME).then(() => self.clients.claim()));
});

self.addEventListener('message', (event) => {
  const data = event.data || {};
  if (data.type === 'SKIP_WAITING') self.skipWaiting();
  if (data.type === 'CLEAR_CACHES') event.waitUntil(clearShellCaches(null));
});

// ---- Fetch --------------------------------------------------------------

self.addEventListener('fetch', (event) => {
  const request = event.request;
  // Anything not allow-listed is not intercepted at all: the browser handles
  // it directly, so the worker can neither cache nor alter it.
  if (!isAllowListed(request)) return;
  event.respondWith(networkFirst(request));
});

async function networkFirst(request) {
  try {
    const response = await fetch(request);
    if (isAllowListed(request) && isCacheableResponse(response)) {
      storeStatic(request, response.clone());
    }
    return response;
  } catch (err) {
    const cache = await caches.open(CACHE_NAME);
    const hit = await cache.match(request);
    if (hit) return hit;
    if (request.mode === 'navigate') {
      const shell = await cache.match(OFFLINE_URL);
      if (shell) return shell;
    }
    return new Response('Offline', { status: 503, statusText: 'Offline' });
  }
}

// The single Cache Storage write in this file. Only reached for allow-listed,
// cacheable, same-origin GET static responses (guarded by the caller).
function storeStatic(request, response) {
  caches.open(CACHE_NAME).then((c) => c.put(request, response)).catch(() => {});
}

// Exposed for the node policy test only (no effect in a browser).
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { isAllowListed, isCacheableResponse };
}
