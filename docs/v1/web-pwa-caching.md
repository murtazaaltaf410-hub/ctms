# Web/PWA caching, update and install

Implements plan sections 3.3, 6.2, 7 (browser lifecycle, operations) and W2 item 4.

## Files

| File | Role |
|---|---|
| `app/web/ctms_sw.js` | Hand-written service worker (offline shell only) |
| `app/web/pwa_register.js` | Registers the worker; captures `beforeinstallprompt`/update signals before Dart boots; exposes `window.__ctmsPwa` |
| `app/web/offline.html`, `offline.css` | Static offline shell; says "Live data unavailable"; no script, no bus data |
| `app/lib/core/pwa/` | Dart: `pwa_state.dart` (pure state machines), `pwa_providers.dart`, `pwa_widgets.dart`, `pwa_cleanup.dart`, bridge with conditional import (`pwa_bridge.dart` -> stub on native, web impl when `dart.library.js_interop`) |
| `app/test/core/pwa/` | State machine tests, worker static test, `sw_policy_check.js` (node) |

## Build flags (Flutter default worker must be off)

```
flutter build web --target lib/main_staging.dart --pwa-strategy=none \
  --dart-define=API_BASE_URL=...
```

`--pwa-strategy=none` stops Flutter from registering `flutter_service_worker.js` (which would precache unfingerprinted `main.dart.js` and fight our worker). Flutter currently still emits an empty `flutter_service_worker.js`; it is harmless and never registered. The flag is deprecated upstream (flutter/flutter#156910); our own registration in `pwa_register.js` does not depend on it. If a future Flutter drops the flag, ensure `flutter_bootstrap.js` is not given `serviceWorkerSettings`.

Release pipeline step (like the Maps key): replace `__BUILD_ID__` in `build/web/ctms_sw.js` with the release id (git SHA). The changed bytes are what makes browsers detect an update; cache names embed it (`ctms-shell-<id>`) so two builds never share cache entries. Without stamping everything still works but updates are not detected.

## Worker policy

- Intercepts only requests that pass `isAllowListed`: GET, same-origin, no `Authorization`, no `Range`, path not on the denylist, and either under `/assets/ /canvaskit/ /icons/`, a static extension, or `/`. Everything else is not handled by the worker at all (browser default).
- Denylist (path prefixes relative to scope): `/api /ws /auth /token /login /logout /session /location /pickup /roster /me /trips /buses /push /subscription /firebase /__ /config /admin /maps /tiles`; any `/api/` anywhere; any query containing `token`. Denied hosts: Google Maps/gstatic/googleapis/google, Firebase, identitytoolkit/securetoken, onrender.com. All cross-origin is refused regardless.
- Strategy: network-first; offline fallback to the cached copy, then (for navigations) `offline.html`, otherwise 503. Responses are cached only when status 200, `basic`, not redirected, no `no-store`/`private`, no `set-cookie`. There is exactly one `cache.put` (in `storeStatic`) and one `addAll` (fixed precache list); the test enforces this.
- Because Flutter assets are not content-hashed, cache-first is deliberately not used: online you always get the live build; the cache only matters offline.
- The offline shell never contains or implies live bus data; the app's connection banner/freshness logic remains the source of truth for the live view.

## Hosting headers (must be set in the static host; no hosting config exists in the repo yet)

- `no-cache`: `/`, `index.html`, `manifest.json`, `flutter_bootstrap.js`, `pwa_register.js`, `ctms_sw.js`, `offline.html`, `version.json`.
- Long-lived immutable only for truly fingerprinted files (none by default from Flutter; leave `main.dart.js` etc. revalidating).
- CSP must permit same-origin scripts (`pwa_register.js` is external; no inline script was added).

## Update flow

1. `ctms_sw.js` never calls `skipWaiting` on install. A new version installs and waits.
2. `pwa_register.js` sees `waiting` while a controller exists -> `updateReady`; checks for updates on tab visible/online (throttled 10 min).
3. `PwaUpdateBanner` (state `UpdatePhase.ready`) offers Update / Later. Only the **Update** tap calls `applyUpdate()` -> `SKIP_WAITING` -> `controllerchange` -> reload (only in the tab that asked).
4. Other tabs get `activatedElsewhere` -> `reloadRequired` (non-dismissible banner, reload on tap), never an automatic reload, so HTML/JS never silently mismatch.
5. Old caches are deleted on `activate`.

## Install

`PwaInstallCard`: Chromium shows "Install" once `beforeinstallprompt` was captured; the native prompt opens only inside the button's tap handler (`InstallController.install()`), and the event is single-use. iOS Safari not in standalone gets Add-to-Home-Screen steps. `display-mode: standalone`/`navigator.standalone` hides everything. Firefox/other: card is hidden, no promise. Dismissal lasts the session.

## Mounting (for the student shell owner; not done here)

Providers/widgets are in `core/pwa/pwa_widgets.dart`. Suggested mount: in `app.dart` `MaterialApp.builder`, wrap the child: `Column(children: [const PwaUpdateBanner(), Expanded(child: child!)])`, and place `const PwaInstallCard()` on the student Profile (or Live) screen. No `kIsWeb` is needed; on native both render nothing.

## Logout / account deletion hook

`clearPwaCaches(ref)` (`core/pwa/pwa_cleanup.dart`) deletes all `ctms-*` Cache Storage entries and returns the count. Call it from the logout, `SESSION_REPLACED` and account-deletion paths after tokens are cleared. The worker never stores authenticated data, so it should only remove the static shell; it is defence in depth. It does not unregister the worker (the shell remains useful and holds no user data). The worker also accepts a `CLEAR_CACHES` message.

## Tests

- `flutter test test/core/pwa` : state machines and controllers (fake bridge), worker source assertions (single `put`, denylist present, no auto `skipWaiting`), and `node test/core/pwa/sw_policy_check.js` which executes `isAllowListed` against allowed and denied URLs (skipped if `node` is missing).
- Manual (not automated): real offline reload, update across two tabs, iOS Home-Screen install, Chromium prompt.
