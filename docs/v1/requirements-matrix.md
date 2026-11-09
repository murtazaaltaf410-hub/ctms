# CTMS V1 — Requirements matrix

Every requirement and case ID from the six spec docs is mapped to the plan phase that owns it (P1–P10, plan `i-have-added-the-adaptive-island.md`). Phase 10 re-walks this file and fills the **Evidence** column (test path or field note).

**ID namespaces.** PRD admin features and edge-case alert cases both use `A1…`. Here they are prefixed:
- **PRD-A1…A7** = admin features
- **EC-A1…A9** = alert/ETA edge cases

Other IDs are unique: S, D, T, N, U, TC.

**Doc pages:**
- prd = PRD, trd = TRD, api = API spec, ec = edge cases, tp = test plan, rb = runbook.
- `pN` = PDF page; the text is in `docs/v1/*.txt`.

Owner: primary phase first; `+Px` = also touches. Level: S = server test, A = app test, F = field/manual.

## 1. PRD goals, functional requirements, behaviours

| ID | Requirement (one line) | Owner | Level | Doc |
|---|---|---|---|---|
| G1 | Students see every active bus on a live map with ETA to any stop | P3+P8 | S,A | prd p1 |
| G2 | Student alerted when a bus is within ~500 m of their current location | P4+P8 | S,A | prd p1 |
| G3 | Drivers start/stop trips and report status in two taps | P3+P8 | A,F | prd p1 |
| G4 | Admins manage fleet/routes/stops/announcements; review trip history + distance | P5+P8 | S,A | prd p1 |
| G5 | Pilot runs end-to-end on 1–3 real buses with no paid infrastructure | P9+P10 | F | prd p1 |
| S1 | Live map: all active buses on Google Maps, updated ≤5 s, route polyline + stops; inactive hidden/"not running" | P3+P8 | S,A | prd p2 |
| S2 | Tap bus → route, driver status, next stop, ETA | P3+P8 | A | prd p3 |
| S3 | Pick any stop → ETA of next bus | P3+P8 | S,A | prd p3 |
| S4 | "Alert me when a bus is near me": push within ~500 m; one per bus per trip, cooldown | P4+P8 | S,A | prd p3 |
| S5 | Read-only announcement feed; push for urgent | P4+P8 | S,A | prd p3 |
| S6 | Google sign-in, sign-out, delete account and data | P2+P7+P8 | S,A | prd p3 |
| D1 | Phone + OTP sign-in; account pre-linked to one bus by admin | P2+P7 | S,A | prd p3 |
| D2 | Choose route (or default), Start; background upload with ongoing notification | P3+P8 | S,A,F | prd p3 |
| D3 | End trip; uploading stops; trip closed | P3+P8 | S,A | prd p3 |
| D4 | Status On time / Delayed / Breakdown + optional short note shown to students | P3+P8 | S,A | prd p3 |
| D5 | Show GPS + network state; buffer offline, send when back | P8 | A,F | prd p3 |
| PRD-A1 | Create/edit/deactivate buses; create driver accounts (phone) linked to one bus | P5+P8 | S,A | prd p3 |
| PRD-A2 | Routes with ordered stops via map pins; polyline generated once via Directions | P5+P8 | S,A | prd p3 |
| PRD-A3 | Optional timetables per route (daily departure times); ad hoc always allowed | P5+P8 | S,A | prd p3 |
| PRD-A4 | Live monitor: every active bus, driver status, last-seen on one map | P3+P8 | S,A | prd p3 |
| PRD-A5 | Create/edit/delete announcements, optional push | P4+P8 | S,A | prd p3 |
| PRD-A6 | Trip history: date, bus, driver, start/end, distance, avg speed; filter date/bus; replay path | P5+P8 | S,A | prd p3 |
| PRD-A7 | Existing admin adds/removes admins | P5+P8 | S,A | prd p3 |
| KB-ETA | ETA = remaining polyline distance / smoothed speed with floor; Google not called per ETA | P3 | S | prd p4, trd p3 |
| KB-ALERT | Student reports location only on meaningful movement; server decides; FCM delivers | P4+P8 | S,A | prd p4, trd p3 |
| KB-SCHED | Trip is Scheduled (matches timetable slot) or Ad hoc; scheduled shows planned time next to ETA | P3+P8 | S,A | prd p4 |
| ROLES | Three roles in one app; first admin seeded; further admins added in app | P1+P2+P7 | S,A | prd p2 |
| DATA | Data model (users, buses, routes, stops, schedules, trips, locations, announcements, alert_log) | P1 | S | prd p5 |

## 2. PRD non-functional requirements and success metrics

| ID | Requirement | Owner | Level | Doc |
|---|---|---|---|---|
| NFR-LAT | Driver position on student map within 5 s | P3+P8 | S,F | prd p6 |
| NFR-BAT | Upload every 3–5 s moving, slower stopped; <10 MB/hour | P8 | F | prd p6 |
| NFR-AVAIL | Reachable in service hours; "last updated" shown; stale never presented as live | P3+P8+P9 | S,A | prd p6 |
| NFR-SEC | HTTPS; short JWT; role check every endpoint; Supabase RLS; keys restricted by app signature | P1+P2+P9 | S | prd p6 |
| NFR-PRIV | Student location latest-only, deleted with account; drivers told location shared during trips only; retention agreed | P3+P4+P7 | S,A | prd p6 |
| NFR-COMPAT | Android first; iOS if time allows | P7+P8 | A | prd p6 |
| SM1 | ≥80 % of active trip time has a fix <10 s old | P10 (+P5 metric query) | F | prd p7, tp p4 |
| SM2 | Median ETA error <2 min | P10 | F | prd p7, tp p4 |
| SM3 | Alerts arrive before bus passes in ≥90 % of tested cases | P10 | F | prd p7, tp p4 |
| SM4 | ≥30 students install and use in first two weeks | P10 | F | prd p7, tp p4 |
| SM5 | No unresolved privacy complaint | P10 | F | tp p4 |

## 3. TRD technical requirements

| ID | Requirement | Owner | Level | Doc |
|---|---|---|---|---|
| TRD-PIPE | 5-step pipeline: FG-service GPS → batched POST → validate + memory + queue → WS fan-out → smooth marker + "last updated" | P3+P8 | S,A | trd p2 |
| TRD-P1 | Upload interval 3–5 s moving / 15 s stopped | P8 | A,F | trd p2 |
| TRD-P2 | Max 20 fixes per batch | P3 | S | trd p2 |
| TRD-P3 | Reject accuracy worse than 50 m | P3 | S | trd p3 |
| TRD-P4 | Reject implied speed >120 km/h | P3 | S | trd p3 |
| TRD-P5 | Stale after 30 s, offline after 2 min | P3 | S | trd p3 |
| TRD-P6 | DB write batch every 10 s | P3 | S | trd p3 |
| TRD-P7 | WS heartbeat 25 s | P3+P7 | S,A | trd p3 |
| TRD-RECON | On reconnect client calls GET /buses/live then resumes WS | P7 | A | trd p3, api p6 |
| TRD-ETA | Forward-only snapping; cum-distance diff; EMA ~60 s; v_min 10 km/h; "passed" + next scheduled | P3 | S | trd p3 |
| TRD-ALERT | <500 m (setting); bus fix <30 s; student fix <5 min & accuracy <100 m; distance decreasing over last two fixes; once per trip (alert_log); bbox pre-filter; text "Bus 2 (North Campus route) is about 400 m away" | P4 | S | trd p3–4 |
| TRD-STUMOVE | Student app reports after 100 m movement and at least every few minutes | P8 | A | trd p3 |
| TRD-AUTH | Google ID token → own short access + refresh; drivers phone OTP only for registered numbers; admin by email list; role from DB; ownership rules | P2 | S | trd p4 |
| TRD-PROT | HTTPS; no secrets in app; Maps keys restricted; Directions key server-only; rate limits per user/IP, tighter OTP + locations; input validation; RLS second layer | P2+P1+P9 | S | trd p4–5 |
| TRD-RET | Student location latest/5 min; bus history 90 days; trips/announcements whole pilot; account until deletion; push tokens until sign-out/invalid | P3+P4+P2 | S | trd p5 |
| TRD-FREE | Verify free-tier limits; keep-alive; downsample history; quotas + budget alerts | P9 | F | trd p5–6 |
| TRD-ARCH | Server single source of truth; apps never touch DB; in-memory live state, one instance | P2+P3 | S | trd p1–2, p6 |

## 4. Edge case catalogue (40)

| ID | Required behaviour | Owner | Level | Doc |
|---|---|---|---|---|
| T1 | No trip started → bus hidden from students; admin monitor shows no active trip | P3+P8 | S | ec p1 |
| T2 | Auto-close after 15 min without fixes; "auto-closed" in reports | P3 (+P5 report) | S | ec p1 |
| T3 | Accuracy >50 m discarded; last good position stays | P3 | S | ec p1 |
| T4 | Implied speed >120 km/h rejected + logged; next consistent fix accepted | P3 | S | ec p1 |
| T5 | GPS loss → "last seen"; stale 30 s, offline 2 min | P3+P8 | S,A | ec p1 |
| T6 | No internet → buffer locally, upload in order; history filled; live jumps to latest | P8 (+P3 ordering) | A,F | ec p1 |
| T7 | Battery saver kills app → warning on next open; admin sees offline; onboarding checklist | P8+P9 (docs) | A,F | ec p1 |
| T8 | Location permission denied → Start blocked, explanation + settings shortcut | P8 | A | ec p1 |
| T9 | Approximate location only → detect, ask for precise before start | P8 | A | ec p1 |
| T10 | Second trip while active → server rejects; app offers resume/end | P3+P8 | S,A | ec p1 |
| T11 | Two phones same driver → latest wins; older told signed out, stops uploading | P2+P7+P8 | S,A | ec p2 |
| T12 | Old/out-of-order fix → stored, not used for live | P3 | S | ec p2 |
| T13 | Wrong phone clock → server receive time for freshness; flag skew | P3 | S | ec p2 |
| T14 | Parked, engine running → "stopped" not offline while fixes arrive | P3+P8 | S,A | ec p2 |
| N1 | Server asleep → "Connecting…", backoff, cached routes visible; keep-alive | P7+P9 | A | ec p2 |
| N2 | Student WS drops → reconnect with backoff, "Reconnecting", refetch live buses | P7 (+P3) | A | ec p2 |
| N3 | Student offline → cached routes/stops; "You are offline"; no stale bus as live | P7+P8 | A | ec p2 |
| N4 | Server restart mid-trip → driver keeps uploading; live state rebuilt from next fix; trip not closed | P3 | S | ec p2 |
| N5 | DB unavailable → live continues from memory; writes queued to a limit; reports show "temporarily unavailable" (503) | P3+P5+P8 | S,A | ec p2 |
| N6 | Retry after timeout → duplicates ignored via fix_id | P3 | S | ec p2 |
| N7 | Rate limit → 429 + wait; apps back off; driver keeps buffering | P2+P7+P8 | S,A | ec p3 |
| N8 | Maps quota/key rejected → map error state; list view still shows buses/status/ETAs; admin notified | P8 (+P9 alerting) | A | ec p3 |
| N9 | Push fails/invalid token → delete invalid; one retry; alert also shown in-app next open | P4+P8 | S,A | ec p3 |
| EC-A1 | Student riding the bus (≤~50 m over consecutive updates) → suppressed | P4 | S | ec p3 |
| EC-A2 | Bus 400 m away on a road, student indoors → alert sent (documented limitation); alert mode pausable | P4+P8 | S,A | ec p3 |
| EC-A3 | Within 500 m but moving away → no alert | P4 | S | ec p3 |
| EC-A4 | Two buses within a minute → one combined "2 buses are nearby" | P4 | S | ec p3 |
| EC-A5 | Student location >5 min old → no alert; app shows "open the app to refresh your location" | P4+P8 | S,A | ec p3 |
| EC-A6 | Background location denied → alert mode can't be on; explain; offer foreground-only alerts | P8 | A | ec p3 |
| EC-A7 | Notifications denied/muted → persistent warning in alert settings | P8 | A | ec p3 |
| EC-A8 | Breakdown or trip ended → no approaching alerts; status text shown | P4+P8 | S,A | ec p4 |
| EC-A9 | Stationary bus → ETA capped "30+ min" | P3+P8 | S,A | ec p4 |
| U1 | Non-university Google account → allowed | P2 | S | ec p4 |
| U2 | Delete account with alert mode on → alerts stop; location, push token, alert log deleted | P2+P4 | S | ec p4 |
| U3 | Driver loses phone/changes number → admin deactivates old, adds new; old sessions signed out | P5+P2 | S | ec p4 |
| U4 | OTP not received/expired → 5 min expiry; 3 resends / 10 min; told to contact admin | P2+P7 | S,A | ec p4 |
| U5 | Remove last admin (or self while last) → blocked (LAST_ADMIN) | P5 | S | ec p4 |
| U6 | Edit/delete route or stop during active trip → delete blocked (IN_USE); edits apply next trip + warning; soft deletes | P5+P8 | S,A | ec p4 |
| U7 | Directions fails/no route → draft with error; cannot activate without polyline | P5 | S | ec p4 |
| U8 | Substitute driver → admin relinks bus; change logged; trips show actual driver | P5 | S | ec p4 |

## 5. Test cases TC1–TC20

| ID | Test → expected | Owner | Level | Doc |
|---|---|---|---|---|
| TC1 | Google sign-in incl. non-university → both succeed, role student (U1) | P2+P6 (+P8 app) | S,A | tp p2 |
| TC2 | Unregistered phone requests OTP → same response, no OTP sent (ADR-1 caveat) | P2+P6 | S | tp p2 |
| TC3 | Driver on second phone → first gets SESSION_REPLACED (T11) | P2+P6 | S | tp p2 |
| TC4 | Student → admin endpoint 403 FORBIDDEN_ROLE; driver → other's trip 403 NOT_YOUR_TRIP | P2+P3+P6 | S | tp p2 |
| TC5 | Start trip twice → 409 TRIP_ALREADY_ACTIVE (T10) | P3+P6 | S | tp p2 |
| TC6 | 80 m accuracy fix + 200 km/h fix → both rejected with reasons; last good kept (T3, T4) | P3+P6 | S | tp p2 |
| TC7 | Same fix_id twice → one stored (N6) | P3+P6 | S | tp p2 |
| TC8 | 2 min no fixes → stale at 30 s, offline at 2 min (T5) | P3+P6 | S (sim, time-mocked) | tp p2 |
| TC9 | Driver offline 3 min then back → buffered fixes upload in order; map catches up (T6) | P8+P10 | A,F | tp p2 |
| TC10 | Student app with simulator → marker moves within 5 s of each fix | P6+P8 | S(sim),A | tp p2 |
| TC11 | Kill/restore student connection → banner, reconnect, correct positions (N2) | P7+P8 | A | tp p2 |
| TC12 | Known distances/speeds → ETA within 5 % of formula | P3+P6 | S unit | tp p2 |
| TC13 | Bus approaches at 600/500/400 m → one alert near 500 m, not repeated | P4+P6 | S (sim) | tp p3 |
| TC14 | Moving away within 500 m; student riding → no alert (EC-A3, EC-A1) | P4+P6 | S (sim) | tp p3 |
| TC15 | Background location or notifications denied → clear message, no silent failure (EC-A6, EC-A7) | P8 | A | tp p3 |
| TC16 | Create route; Directions fails → draft + POLYLINE_FAILED (U7) | P5+P6 | S | tp p3 |
| TC17 | Delete route during active trip; remove last admin → both blocked (U5, U6) | P5+P6 | S | tp p3 |
| TC18 | Three simulated trips → distance and times within 2 % of simulator totals | P5+P6 | S (sim) | tp p3 |
| TC19 | Restart server mid-trip → trip continues; map recovers within one fix (N4) | P3+P6 | S (sim) | tp p3 |
| TC20 | Delete student account → location, push token, alert log gone (U2) | P2+P4+P6 | S | tp p3 |

## 6. Field test checklist and launch gate (test plan p3–p4)

| ID | Item | Owner | Level |
|---|---|---|---|
| FT-B1 | Driver app installed, signed in by phone, battery optimisation off | P8+P10 | F |
| FT-B2 | Student phones signed in, alert mode on, location "always", notifications allowed | P8+P10 | F |
| FT-B3 | Route + stops created; polyline correct on map | P5+P8+P10 | F |
| FT-B4 | Server awake; Maps keys restricted | P9+P10 | F |
| FT-D1 | Trip starts in two taps; bus visible to students within 5 s | P10 | F |
| FT-D2 | Marker follows bus without jumping (trees, buildings) | P10 | F |
| FT-D3 | "Delayed" appears on student phones | P10 | F |
| FT-D4 | Still student gets one alert at ~500 m | P10 | F |
| FT-D5 | Student on bus gets no alert | P10 | F |
| FT-D6 | Airplane mode 1 min → map catches up | P10 | F |
| FT-D7 | Phone locked 10 min → uploads continue | P10 | F |
| FT-D8 | ETA vs real arrival error noted | P10 | F |
| FT-A1 | Trip ends; report distance/times close to real | P10 | F |
| FT-A2 | Driver battery use recorded | P10 | F |
| FT-A3 | Dead spots / wrong alerts / slow updates logged with time and place | P10 | F |
| LG1 | TC1–TC20 pass on staging, no open high-severity bug | P10 | S,A |
| LG2 | Field test done on real bus, no blocking issue | P10 | F |
| LG3 | Driver completes full trip using only written onboarding steps | P9 (docs)+P10 | F |
| LG4 | Admin creates route, adds stop, posts announcement, **exports a trip report** unaided | P5+P8+P10 | F |
| LG5 | Maps quotas + budget alerts configured; keys restricted | P9 | F |
| LG6 | Privacy notice + location consent screens approved by university contact | P7+P10 | F |
| LG7 | Runbook rollback plan rehearsed once | P9+P10 | F |

## 7. Runbook requirements

| ID | Requirement | Owner | Doc |
|---|---|---|---|
| RB-ENV | Env vars: APP_ENV, DATABASE_URL, JWT_SECRET, GOOGLE_OAUTH_CLIENT_IDS, GOOGLE_DIRECTIONS_KEY, FCM_CREDENTIALS, SEED_ADMIN_EMAIL, ALERT_RADIUS_M | P2+P9 | rb p1 |
| RB-ENVSEP | Staging and production separate hosts, DBs, Firebase + Maps projects; flavours | P7+P9 | rb p1 |
| RB-DEPLOY | CI tests → image → Alembic migrations first (backward compatible) → deploy → wait /health → smoke (sign in, /buses/live, simulator 1 min) → keep-alive confirmed | P9 | rb p1–2 |
| RB-ROLLBACK | Redeploy previous version; don't roll back migrations unless corruption | P9 | rb p2 |
| RB-MOBILE | Signed release per flavour; closed testing/APK; **minimum supported version from server**; onboarding re-check per release | P7+P9 | rb p2 |
| RB-MON | Uptime check on /health; error tracking server + app; logs 7 days; daily: active buses, last-fix age, rejected fixes/h, push failures, sign-in failures, Maps usage | P9 (+P3/P4 metrics) | rb p2 |
| RB-BACKUP | Weekly pg_dump to team storage; test one restore | P9 | rb p2 |
| RB-INCIDENT | Incident table; >15 min incident → in-app announcement + note | P9 (docs) | rb p2–3 |
| RB-PRIV | Data table: student location server-only, not shown to admins; bus location visible without driver name; push token server-only | P3+P4 | rb p3 |
| RB-CONSENT | Separate consent screens: student (before background permission, only when enabling alerts), driver (before trips) | P7+P8 | rb p4 |
| RB-RIGHTS | DELETE /me; students never see driver personal details; trip history admin-only; **role changes logged**; breach procedure | P2+P3+P5+P9 | rb p4 |
| RB-ONBOARD | Driver + admin onboarding checklists | P9 (docs) | rb p4–5 |

## 8. API endpoints (api p2–p6) — 47 HTTP operations + 1 WebSocket

| # | Method + path | Roles | Owner | Notes / codes |
|---|---|---|---|---|
| 1 | POST /auth/google | public | P2 | creates student; admin via allow-list/SEED_ADMIN_EMAIL |
| 2 | POST /auth/phone/request | public | P2 | 202 uniform; 429 (ADR-1) |
| 3 | POST /auth/phone/verify | public | P2 | OTP_INVALID/OTP_EXPIRED (ADR-1) |
| 4 | POST /auth/refresh | any | P2 | rotating refresh in body |
| 5 | POST /auth/logout | any | P2 | 204; revokes refresh + removes push token |
| 6 | GET /me | any | P2 | driver: linked bus |
| 7 | PATCH /me | any | P2 | {name} |
| 8 | PUT /me/push-token | any | P2 | {token, platform} 204 |
| 9 | DELETE /me | student | P2 (+P4 tables) | 204; cascades (U2) |
| 10 | GET /trips/active | driver | P3 | trip or null |
| 11 | POST /trips/start | driver | P3 | 201; type scheduled/ad_hoc; 409 TRIP_ALREADY_ACTIVE |
| 12 | POST /trips/{id}/locations | driver own | P3 | ≤20; {accepted, rejected[reason]}; NOT_YOUR_TRIP |
| 13 | POST /trips/{id}/status | driver own | P3 | 204; on_time/delayed/breakdown; note ≤140 |
| 14 | POST /trips/{id}/end | driver own | P3 | summary distance_m, started_at, ended_at |
| 15 | GET /buses/live | signed-in | P3 | state live/stale/offline; no driver name |
| 16 | GET /routes | any | P5 | active routes + stop count |
| 17 | GET /routes/{id} | any | P5 | encoded polyline + ordered stops |
| 18 | GET /schedules?route_id= | any | P5 | |
| 19 | GET /stops/{id}/eta | any | P3 | per active bus eta_seconds, distance_m, state; next_scheduled; never error |
| 20 | POST /me/location | student | P4 | 204 latest only |
| 21 | PUT /me/alert-settings | student | P4 | enabling requires push token |
| 22 | GET /announcements?cursor= | any | P4 | newest first, urgent flag |
| 23–25 | GET, POST /admin/buses; PATCH /admin/buses/{id} | admin | P5 | deactivate blocked while active trip (IN_USE) |
| 26–28 | GET, POST /admin/drivers; PATCH /admin/drivers/{id} | admin | P5 | one driver per bus; bus change logged (U8); deactivate → sessions revoked (U3) |
| 29–31 | GET, POST /admin/routes; PATCH /admin/routes/{id} | admin | P5 | POLYLINE_FAILED draft; can't activate w/o polyline |
| 32–33 | POST /admin/routes/{id}/stops; PATCH /admin/stops/{id} | admin | P5 | regenerates polyline; edits apply next trip |
| 34–36 | GET, POST /admin/schedules; PATCH /admin/schedules/{id} | admin | P5 | |
| 37–39 | POST /admin/announcements; PATCH, DELETE /admin/announcements/{id} | admin | P4 | push:true → FCM to students + WS |
| 40–42 | GET, POST /admin/admins; DELETE /admin/admins/{id} | admin | P5 | LAST_ADMIN |
| 43 | GET /admin/trips?from&to&bus_id&cursor | admin | P5 | driver, times, distance_m, avg_speed, closed_by |
| 44 | GET /admin/trips/{id}/path | admin | P5 | ordered positions |
| 45 | GET /admin/reports/summary?from&to | admin | P5 | totals per bus |
| 46–47 | GET, PUT /admin/settings | admin | P5 | {alert_radius_m} |
| WS | /api/v1/ws/live | student, admin | P3 (+P4 announcement hook) | auth msg ≤5 s; ping/pong; bus_position, bus_status, trip_started, trip_ended, announcement |
| ext | GET /health | public | P2 | runbook p1–2 (not in API spec) |
| ext | GET /api/v1/config (min app version) | public | P9 (draft P2) | runbook p2 "minimum supported version"; not in API spec |

Error codes (api p6–7), owner P2 (`errors.py`): VALIDATION_ERROR 400, OTP_INVALID/OTP_EXPIRED 400, TOKEN_EXPIRED/TOKEN_INVALID/SESSION_REPLACED 401, FORBIDDEN_ROLE/NOT_YOUR_TRIP 403, NOT_FOUND 404, TRIP_ALREADY_ACTIVE/LAST_ADMIN/IN_USE 409, POLYLINE_FAILED 422, RATE_LIMITED 429, DB_UNAVAILABLE 503. Conventions (api p1): /api/v1, bearer, UTC ISO-8601, metres and m/s, UUIDs, `?limit` (50 default, 200 max) + `?cursor` → `next_cursor`, fix_id idempotency.

## 9. Gaps: doc requirements with no endpoint in the API spec (decide in the owning phase)

| Gap | Required by | Proposed resolution | Owner |
|---|---|---|---|
| Consent recording server-side | rb p4, LG6 | Extra `PUT /api/v1/me/consents {kind, version}`. Mark it as an extension in OpenAPI | P2 |
| Trip report **export** | LG4 | Client-side CSV from `GET /admin/trips` (no new endpoint) **or** `?format=csv`. Choose in P5 | P5+P8 |
| In-app copy of a failed alert | N9 | `GET /me/alerts` (recent alert_log for the student), extension | P4 |
| Admin notified on Maps quota/key failure | N8 | App reports a map-load failure to `POST /api/v1/client-events` → admin push, or a runbook budget alert only. Choose in P9 | P8+P9 |
| Delete route/stop | U6, TC17 | Spec has no DELETE: "Deletes are soft (an active flag)". `PATCH {active:false}` → 409 IN_USE while in use | P5 |
| Min supported app version | rb p2 | `GET /api/v1/config` | P9 |

## V1.1 extensions (ADR-9)

| ID | Requirement | Owner | Status |
|---|---|---|---|
| X1 | A trip has a direction (to_campus / from_campus); the driver chooses it at start; schedule slots carry a direction; ETAs and live state follow the reversed route for the return leg | server: `trips/service.py`, `schedules/router.py`; app: driver start screen | server done (`test_direction.py`), app in progress |
| X2 | Students place a temporary pickup pin for a leg (one waiting request per student) | server + app | server done (`test_pickups_api.py`, migration 0006), app in progress |
| X3 | The driver gets a push and a map marker when the bus nears a waiting student; the student gets a push when the bus nears their pin | server done (`test_pickup_alerts.py`), app in progress |


## V1.2 extensions (ADR-10)

| ID | Requirement | Owner | Status |
|---|---|---|---|
| X4 | Admin-managed driver accounts: userid / email / phone plus an admin-issued password (scrypt in Postgres), driver profile, forced first-login change, lockout, no OTP | server: `auth/`, `admin/drivers.py`; app: driver sign-in, admin driver form; migration 0007 | migration done (0007), server done (plan phase 2; tests in test-matrix X4), app planned (phase 3) |
| X5 | Student registration (name, phone, department, route, bus) with admin approval or rejection and a rejection note; unregistered students are gated | server + app; migration 0008 | migration done (0008), server planned (phase 4), app planned (phase 5) |
| X6 | Bus seat capacity; approval assigns a bus on the student's route with a free seat (409 `NO_SEAT`, race-safe); no attendance tracking | server: students/admin; migration 0008 | migration done (0008), server planned (phase 4) |
| X7 | Admin student view: list with filters, totals by status, per-route and per-bus capacity / assigned / seats left, driver roster of name and department only | server + app | planned (phases 4-5) |
| X8 | Start Journey: the trip start pushes "Bus started its journey" to the approved students of that bus | server: trip listener; app: driver start screen | planned (phase 6) |
| X9 | Arrival: `to_campus` trips end by geofence at the campus and `from_campus` trips at the route's last stop, plus the driver's button for both; `moved_at`, `arrived_at`, `closed_by = arrival` | server: tracking; migration 0009 | migration done (0009), server planned (phase 6) |
