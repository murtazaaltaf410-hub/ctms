# CTMS Web/PWA Cross-Platform Plan

**Status:** proposed implementation plan

**Branch:** `plan/web-pwa-cross-platform`

**Audience:** CTMS developers splitting work across backend, Flutter, web infrastructure, QA, and design.

## 1. Product Decision

CTMS will remain one Flutter codebase, delivering:

| Surface | Primary users | Supported use |
|---|---|---|
| Android app | Students, drivers, admins | Full product; Android is the only driver-tracking platform. |
| Installable PWA | Students and admins | Live tracking, ETA, pickup, notices, registration, and admin operations while open. |
| iPhone/iPad PWA | Students and admins | Safari **Add to Home Screen** install; no App Store submission is needed. |
| Apple App Store | Out of scope | A PWA alone cannot be published to the App Store; no native iOS build or wrapper is planned. |

### Non-negotiable platform boundary

**Drivers cannot start or continue trips in the PWA.** Browser/PWA execution cannot reliably provide Android foreground-service GPS, durable offline location buffering, or background continuity. Driver web sessions may be read-only in a later phase, but the PWA must display a clear Android-app-required screen for trip operations.

### PWA launch scope

1. Student PWA is the first public web release.
2. Admin PWA follows after student browser authentication, Maps, realtime, and CORS are stable. It is desktop-first but remains usable on tablets/mobile.
3. Driver web tracking is explicitly out of scope.
4. Android remains regression-protected throughout; no web work may weaken foreground tracking, Android Maps, Firebase push, or offline fix buffering.

## 2. Current Gaps

The current app is Android-first and does not yet compile safely for web:

- `app/web/` does not exist.
- Firebase staging options throw on web; production Firebase options are placeholders.
- `push_service.dart` imports `dart:io` for `Platform`.
- `bootstrap.dart` always initializes `flutter_foreground_task`.
- Driver tracking depends on Android foreground services and SQLite buffering.
- The server has no CORS middleware or WebSocket Origin policy.
- Web Maps requires a browser-restricted Maps JavaScript API key, separate from Android's package/SHA key.
- The existing specs call a separate web dashboard a V1 non-goal. This document supersedes that non-goal only after product approval is recorded in `docs/v1/decisions.md`.

## 3. Architecture

### 3.1 Deployment topology

Use separate HTTPS origins and separate staging/production resources:

| Environment | PWA static host | API | Notes |
|---|---|---|---|
| Staging | `staging-app.<domain>` | `staging-api.<domain>` | Separate Firebase, Supabase, Render, Maps key, OAuth origin, and Web Push configuration. |
| Production | `app.<domain>` | `api.<domain>` | Firebase Hosting serves the Flutter web output; Render continues serving FastAPI. |

Firebase Hosting is the recommended static host because CTMS already uses Firebase. It must provide HTTPS, SPA rewrites, immutable static asset caching, deployment rollback, and PWA support. Render continues to host only the API.

### 3.2 Shared Flutter code and platform boundaries

Keep shared models, REST, WebSocket, route/map data, role authorization, UI tokens, and server contracts in common Dart code. Replace platform-specific imports with narrow interfaces and conditional imports:

| Interface | Android implementation | Web implementation |
|---|---|---|
| Firebase bootstrap | Android Firebase options and background handler | Web Firebase options and service-worker registration |
| Push registration | FCM mobile token | Web Push/FCM Web subscription; capability-aware and optional |
| Platform label | `android` / `ios` | `web` |
| Driver tracking | Foreground task + Geolocator + durable queue | Unsupported; returns an explicit capability failure |
| Student location | Geolocator stream | Browser `watchPosition` only while the page is visible |
| Secure/token storage | Existing native storage | Web-specific storage abstraction with documented XSS threat model |

Do not add `kIsWeb` checks throughout screens. Keep web/native differences behind adapters so shared role UI stays testable.

### 3.3 API and realtime rules to preserve

- REST remains under `/api/v1`; WebSocket remains `/api/v1/ws/live`.
- The bearer token is sent in the first WebSocket message, never a query string or URL.
- The server remains authoritative for role checks, route scope, ETAs, freshness, alerts, retention, and permissions.
- On any socket reconnect, refresh `GET /buses/live` before applying new messages.
- Browser WebSocket reconnect must be bounded, jittered, paused while offline/hidden where appropriate, and resumed on `online`, `pageshow`, and visible-page events.
- No API response, token, location, pickup, roster, or map content is stored in service-worker Cache Storage.

## 4. Role UX and Responsive Design

### 4.1 Visual direction

Use the existing Kashmir-valley campus green (`#2F5D50`) with warm neutral surfaces. The web product should feel like a **campus control room in your pocket**, not a generic card dashboard.

- Route lines, numbered stops, and operational state are the visual signature.
- Semantic status colors remain: live/on-time green, delayed/stopped amber, stale slate, offline neutral, breakdown red.
- Never use color alone: every status carries icon, text, and a time/freshness label.
- Use tabular numerals for time, ETA, capacity, distance, and coordinates.
- Keep surfaces restrained: no card-within-card stacks, decorative gradients, or persistent motion.

### 4.2 Breakpoints

| Width | Student / driver Android & PWA | Admin web |
|---|---|---|
| `<600px` | Bottom navigation, map-first pages, bottom sheets | Mobile fallback with compact navigation and overflow actions |
| `600–1023px` | Navigation rail and optional map/content split | Collapsible rail; list/detail split |
| `1024–1439px` | Tablet two-pane workspace | Desktop admin workspace with fixed rail and inspector |
| `>=1440px` | Centered multi-zone layout | Dense three-pane control room capped near 1600px |

Touch targets are at least 48 dp. Desktop tables retain at least 44 px rows. Hover enriches desktop UI but is never required to reveal action or status.

### 4.3 Student PWA

**Phone:**

1. Bottom navigation: Live, Notices, Alerts, Profile.
2. Live screen starts map-first with a draggable inspector sheet.
3. The sheet holds the assigned route/bus, stop ETA selector, active buses, pickup action, and connection/freshness status.
4. Keep an explicit Map/List toggle as the required Maps-failure and low-bandwidth fallback.

**Tablet:**

1. Map occupies 55–65% of the workspace.
2. A persistent sidebar shows stop ETA, active bus list, pickup state, and stop sequence.
3. Selecting a bus or stop focuses the map and inspector without replacing the route context.

Required states:

- pending/rejected registration: clear status and next action; no disabled but tempting live controls;
- no active bus: show route/stops plus scheduled next departure;
- stale/offline bus: show `Last seen <time>`, never “live”;
- Maps failure: usable status and ETA list with a visible explanation;
- connection loss: non-blocking connection banner and last successful refresh time.

### 4.4 Driver Android UI

The driver workflow remains a single-task Android workspace, not a web feature:

- Start screen shows bus, assigned routes, direction, permission/network/foreground-service preflight, and one full-width Start Journey action.
- Active screen prioritizes journey state, tracking/upload health, pickup requests, roster, status update, and end journey.
- Do not require map interaction while driving.
- Web driver session shows: “Trip tracking requires the CTMS Android app” with an Android download/update action. It must not expose Start Journey.

### 4.5 Admin web console

Admin is **desktop-first**.

1. Fixed rail: Live Operations, Fleet & Students, Routes, Timetables, Announcements, Reports, Settings & Access.
2. Command bar: search, filters, connection state, refresh, account menu.
3. URL/deep-link every entity and inspector state; do not retain the current tab-index-only navigation model for web.

**Live Operations:** left fleet list, centre multi-route live map, right selected-bus inspector. Show active journeys, stale tracking, delays/breakdowns, and pending approvals.

**Fleet & Students:** accessible data tables with search/filter/sort and an inspector editor. Approval panel shows route, valid buses, capacity, and seats remaining before submit. Driver detail exposes assigned route allow-list.

**Routes:** list, map editor, and ordered stop rail. Draft route failures keep placed stops, explain the failure, and offer retry. Never activate a route with no usable polyline.

**Reports and settings:** preserve trip history/replay, clear filtering, export, campus geofence settings, and access management.

### 4.6 Accessibility and motion

- Meet WCAG 2.2 AA contrast; support 200% text scale without clipping.
- Keyboard access: skip link, visible focus, rail → toolbar → workspace order, map controls with non-map equivalents.
- Screen readers announce entity, status, and freshness, for example: “Bus NC-01, delayed, last seen 42 seconds ago.”
- Debounce live announcements; do not narrate every location update.
- Respect reduced motion. Bus markers interpolate only while live; stale recovery, reconnect, and errors update statically.
- Motion vocabulary for implementation:
  - **Layout animation** for a selected bus inspector moving between compact and desktop layouts.
  - **Shared element transition** only when a list entity opens its inspector and spatial continuity is preserved.
  - **Accordion / Collapse** for narrow-screen filters and detail sections.
  - **Skeleton / Shimmer** for initial map/table loading only.
  - **Press / Tap feedback** on touch controls.
  - No ambient loops except a subdued live indicator; no animation for critical failure banners.

## 5. Browser Location, Push, and Privacy

### 5.1 Supported browser location model

| User state | Location behavior | Realtime behavior | Notification behavior |
|---|---|---|---|
| Student, visible PWA/tab | Opt-in `watchPosition` after CTMS consent and browser permission; validate and upload acceptable fixes | REST + WebSocket | In-app alerts; Web Push where supported |
| Student, hidden page | Do not promise cadence; mark foreground monitoring unavailable | Socket may pause; refetch on return | Push can announce bus events, not current-location proximity guarantees |
| Student, closed PWA | No location collection | No socket | Web Push only if a valid installed-PWA subscription exists |
| Driver, browser/PWA | No trip tracking | Optional future read-only view | No driver tracking notifications |
| Driver, Android | Existing foreground service and durable queue | REST upload; server fan-out | Existing native behavior |

### 5.2 Rules

1. Location is requested only from a user gesture after CTMS privacy consent.
2. Browser location requires HTTPS, a top-level context, visible-page UI, and a clear purpose explanation.
3. Never use a service worker as a geolocation daemon or WebSocket owner. Service workers cannot provide durable background location tracking.
4. On `visibilitychange` to hidden, stop claiming active location monitoring. On visible/online/pageshow, restart the watcher, fetch a fresh position, reconnect/refetch live state, then display monitoring as active.
5. Browser fixes must obey the same server thresholds for freshness/accuracy. Old queued browser fixes are discarded rather than replayed to create alerts.
6. Consent, browser geolocation permission, and notification permission are separate gates.
7. On iOS/iPadOS, Web Push is offered only after Home-Screen installation and a direct user action. It never implies background geolocation.
8. Student location stays latest-only, server-expiring, invisible to admins, excluded from logs/audit/analytics, and deleted with the account.

### 5.3 Web Push data model

Do not store a web push subscription in the existing mobile FCM token field.

- Add a web delivery/subscription model with endpoint, public key, auth key, user ownership, environment, creation time, and invalidation state.
- Support `web` as a platform while keeping mobile FCM/APNs semantics separate.
- Remove invalid endpoints after a failed send.
- Notification click opens the safe PWA route and refetches state.
- Never include location, bearer tokens, phone numbers, or sensitive roster content in notification payloads.

## 6. Security and Hosting

### 6.1 CORS, WebSocket Origin, and headers

Add explicit staging/production allow-lists. Never use `*` for bearer-authenticated APIs.

- Allow required methods and `Authorization`, `Content-Type`, `X-Request-ID` headers only.
- Do not enable CORS credentials unless cookie authentication is intentionally introduced.
- Validate WebSocket Origin against the same allow-list.
- Start CSP in report-only mode; enforce only after sign-in, Maps, Firebase, and WebSocket flows are proven.
- Add `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, frame protection via CSP `frame-ancestors 'none'`, a limited `Permissions-Policy`, and HSTS after all production hosts use HTTPS.

### 6.2 PWA caching

| Resource | Policy |
|---|---|
| Fingerprinted JS/WASM/assets | Immutable cache, one year |
| `index.html`, manifest, bootstrap/worker registration | `no-cache` |
| API, auth, WebSocket, location, pickup, roster, tokens | Never Cache Storage-cache |
| App config | Network-first; retain only existing short safe cache semantics |
| Google map tiles | No custom caching outside Maps terms |

Offline mode shows a safe app shell and clearly marks live data unavailable. It never presents a cached bus position as live.

### 6.3 Credentials and configuration

- Create separate staging/production Firebase web apps, OAuth origins, Maps browser keys, VAPID/Web Push configuration, and Hosting sites.
- Browser Maps keys use exact HTTPS referrer restrictions; Android package/SHA keys and server Routes keys remain separate.
- Add the correct web OAuth client IDs to `GOOGLE_OAUTH_CLIENT_IDS`.
- Build defines contain only public values: API URL, WebSocket URL, web OAuth client ID, release identifier, and Firebase public config. Render remains the sole home for server secrets.
- Rotate any local Firebase service-account key found outside approved secret storage before web deployment work begins. Never commit it.

## 7. Edge-Case Checklist

### Browser lifecycle

- first visit offline, captive portal, Render cold start, DNS/TLS failure, slow 3G;
- hidden/frozen/discarded tab, back-forward cache restore, browser restart, PWA restart;
- multiple tabs: duplicate sockets, refresh races, duplicate alerts/location uploads, logout/session replacement propagation;
- private mode/storage unavailable/storage quota exceeded or evicted;
- browser zoom, virtual keyboard, orientation/split-screen, 80–200% text zoom, reduced motion, screen reader, high contrast;
- Android Chrome, Android Firefox, iOS Safari, iOS Home-Screen PWA, desktop Chrome/Edge/Firefox/Safari capability differences.

### Auth and authorization

- blocked Google popup, cancelled account picker, wrong Google account, OAuth origin mismatch, expired token, Firebase test-user restriction;
- concurrent refreshes and 401s across tabs;
- reload before `/me`/registration gate resolves;
- role removal, driver deactivation, student registration status change while tab stays open;
- logout/account deletion clears open sockets, local state, outbox, subscription association, and safe caches;
- no refresh token in URLs, localStorage without an approved threat-model decision, logs, service-worker cache, analytics, or push payloads.

### Realtime, maps, and data correctness

- WebSocket handshake/auth timeout, `1013`, `4401`, token expiry, proxy timeout, page resume, duplicate/out-of-order messages, missed trip end, server restart;
- refetch live state before resumed messages; stale coordinates never displayed as live;
- Maps script/key/referrer/CSP/ad-blocker/quota/WebGL failure; fall back to list/ETA;
- zero/one/many routes/stops, camera bounds, no active buses, draft route, route edit during an active trip;
- bus states: live, stopped, stale, offline, breakdown; preserve server receive-time freshness;
- browser location denied, approximate, stale, poor accuracy, timeout, OS service disabled, permission later revoked;
- pickup manual pin works without location; never reveal student identity/location to drivers beyond existing privacy contract.

### Operations and release safety

- PWA deployment during an open session; update prompt prevents HTML/JS chunk mismatch;
- web/API schema deploy order remains backward compatible with prior Android and PWA releases;
- static-host rollback independent from API rollback; migrations stay forward-only;
- Maps quota, Firebase quota, Hosting outage, Render free sleep, Supabase pause, third-party DNS/certificate delay;
- dashboards/alerts track browser sign-in, CORS/preflight, CSP, map, WebSocket, push subscription, service-worker update, and cache failures without PII.

## 8. Delivery Phases and Agent Ownership

### Phase W0: Decisions and security inventory

**Owner: architecture/security agent**

1. Record ADR: student/admin PWA supported, Android-only driver tracking, iOS Home-Screen PWA supported, Apple App Store explicitly out of scope.
2. Define exact supported browser matrix and privacy wording.
3. Rotate exposed/local service credentials; confirm no credentials enter Git.
4. Decide auth storage approach and document the XSS threat model.

**Exit criteria:** approved ADR, support matrix, secret rotation record, staging/prod hostnames and owners.

### Phase W1: Web build enablement

**Owner: Flutter platform agent**

1. Add Flutter web project files, manifest, icons, branded shell, and web build entrypoints for staging/prod.
2. Introduce conditional platform adapters for bootstrap, Firebase, push, storage, and driver tracking.
3. Register Firebase web apps and generate real per-flavor web Firebase options.
4. Block driver trip actions on web with accessible capability messaging.
5. Configure browser Maps key injection and Maps JS API restrictions.

**Exit criteria:** `flutter build web` succeeds for both flavors; web student/admin shell launches; Android remains green.

### Phase W2: Student PWA and foreground location

**Owner: student web agent**

1. Deliver responsive Live, Notices, Alerts, and Profile layouts.
2. Implement capability-aware foreground-only browser location adapter.
3. Add visibility/online/pageshow lifecycle behavior and bounded fresh-fix outbox.
4. Implement map/list fallback, freshness states, install prompt, and permission guidance.

**Exit criteria:** student sign-in, route-scoped live buses, ETA, pickup, registration gate, safe location states, offline shell, and WSS reconnect pass on browser matrix.

### Phase W3: Admin desktop console

**Owner: admin web agent**

1. Replace tab-index navigation with deep-linkable rail/workspace/inspector layout.
2. Deliver Live Operations, Fleet & Students, routes, timetables, announcements, reports, and settings at desktop/tablet breakpoints.
3. Reuse server authorization and existing admin APIs; do not expose student location.
4. Add browser-safe tables, bulk-safe confirmation flows, and explicit temporary-password handling.

**Exit criteria:** admin can operate fleet, approve students, assign driver routes, edit routes, and inspect live buses at 1024+ widths; mobile fallback remains usable.

### Phase W4: Browser backend and delivery security

**Owner: backend/DevOps agent**

1. Add strict CORS, WebSocket Origin validation, security headers, CSP rollout, and tests.
2. Add Hosting staging/prod sites, HTTPS/custom domains, SPA rewrites, cache headers, release manifest, and rollback flow.
3. Add Web Push subscription model and capability-aware alert settings only after W2 passes.
4. Extend CI with web build, browser E2E, header/CORS, manifest, service-worker, dependency, and secret checks.

**Exit criteria:** hosted staging PWA passes automated browser smoke tests; unauthorized origins and unsafe caching are blocked.

### Phase W5: QA, launch gate, and operations

**Owner: QA/accessibility/release agent**

1. Run device/browser matrix and accessibility audit.
2. Verify privacy deletion, no PII in caches/logs, origin isolation, push invalidation, and Maps fallback.
3. Rehearse PWA/static/API rollback and Render restart recovery.
4. Update deploy/runbook/credentials/API docs and release checklists.

**Exit criteria:** signed launch report; staging field test succeeds; Android regressions are green; support/incident owner accepts operational handoff.

## 9. Branch and Collaboration Protocol

1. This document lives on `plan/web-pwa-cross-platform` and is the planning source for external developers.
2. No feature code goes directly to this branch after planning sign-off. Create focused branches from current `main`:
   - `feature/web-platform-boundary`
   - `feature/student-pwa`
   - `feature/admin-web-console`
   - `feature/web-cors-hosting`
   - `feature/web-push-capabilities`
3. One owner per file area. Shared files (`bootstrap.dart`, Firebase options, `main.py`, deployment docs) require an integration owner and a written handoff before merge.
4. Each branch carries its own tests and updates this plan's phase checklist only when its acceptance criteria pass.
5. Merge order: W0 → W1 platform boundary → W4 browser security minimum → W2 student PWA → W3 admin console → Web Push → W5 launch gate.
6. Every server schema change remains additive and backward compatible with prior Android/PWA builds.
7. Do not put secrets, Firebase service accounts, Maps server keys, or production refresh tokens in branches, test fixtures, browser defines, screenshots, or plan attachments.

## 10. Required Test Matrix

### Automated

- Flutter unit/widget tests for adapters, responsive layouts, permission states, outbox expiry, lifecycle transitions, stale/fresh rendering, and web driver block.
- `flutter analyze`, Android build, and staging/prod `flutter build web`.
- Browser E2E for sign-in, registration gate, live map/list fallback, ETA, pickup, admin fleet/student flows, route assignment, logout, and reconnect.
- FastAPI tests for CORS allow/deny, preflight, WebSocket Origin, web push subscription ownership/deletion, alert mode, and browser-origin denial for driver operations.
- Service-worker tests proving no authenticated response or location data reaches Cache Storage.

### Manual device matrix

| Device/browser | Required validation |
|---|---|
| Android Chrome, tab + installed PWA | sign-in, maps, foreground location, install/update, push if enabled |
| Android Firefox | supported feature fallback and no Chrome-only promises |
| iPhone/iPad Safari + Home Screen PWA | live/ETA/pickup, foreground location, install instructions, Web Push only if claimed |
| Desktop Chrome/Edge/Firefox/Safari | admin console, keyboard, tables, maps, zoom, session handling |
| Android native app | full driver tracking, buffering, Maps/push/location regression |

## 11. Definition of Done

The PWA is ready only when:

1. It installs and updates safely over HTTPS.
2. Students can use live tracking, ETAs, pickup, registration, notices, and explicitly foreground-only browser alerts.
3. Admins can operate the desktop console without losing role/privacy constraints.
4. Browser driver trip tracking is visibly blocked; Android remains the only supported tracking client.
5. CORS, WebSocket Origin, CSP, cache behavior, token handling, and Maps keys are restricted and tested.
6. Browser shutdown, offline, stale data, and Maps failure show honest, usable states.
7. Android and server regression suites pass.
8. Rollback, monitoring, incident runbook, privacy wording, and support matrix are complete.
