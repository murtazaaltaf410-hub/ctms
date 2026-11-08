# CTMS V1 — Allowed APIs (Phase 0)

Every library call used in `server/` and `app/` must appear here with a source. If you need an API that is not listed, look it up with context7 (`resolve-library-id` → `query-docs`), add it here with the citation, then use it. Do not invent methods or parameters.

Retrieved 2026-11-08 via context7. "ctx7:" = context7 library id; URL = the page the snippet came from.
Entries marked **UNCONFIRMED** could not be confirmed through context7. Verify them before relying on them.

---

## Server (Python 3.12)

### FastAPI — ctx7: `/websites/fastapi_tiangolo`

| API | Exact usage | Source |
|---|---|---|
| App + lifespan | `@asynccontextmanager async def lifespan(app: FastAPI): <startup>; yield; <shutdown>` → `FastAPI(lifespan=lifespan)` | fastapi.tiangolo.com/advanced/events/ |
| `on_event("startup")` | **Anti-pattern.** Superseded by `lifespan` since 0.93.0. Do not use it. | fastapi.tiangolo.com/release-notes/ (0.93.0) |
| `APIRouter` | `APIRouter(prefix="/x", tags=[...], dependencies=[Depends(fn)])`; `app.include_router(router, prefix="/api/v1", tags=[...], dependencies=[...])` | fastapi.tiangolo.com/reference/apirouter/ |
| `Depends` + `Annotated` | `def ep(x: Annotated[T, Depends(dep)])`; dependencies may be `async def` and may `yield` | fastapi.tiangolo.com/advanced/testing-dependencies/ |
| `dependency_overrides` | `app.dependency_overrides[original_dep] = fake_dep` (a dict; clear it in teardown) | fastapi.tiangolo.com/advanced/testing-dependencies/ |
| Custom exception handler | `@app.exception_handler(AppError) async def h(request: Request, exc: AppError) -> JSONResponse` (or `app.add_exception_handler(cls, h)`) | fastapi.tiangolo.com/tutorial/handling-errors/ |
| Validation override | `from fastapi.exceptions import RequestValidationError`; `@app.exception_handler(RequestValidationError)` returns `JSONResponse(status_code=400, content={"error": {"code": "VALIDATION_ERROR", "message": ...}})`. `exc.errors()` and `exc.body` are available. The FastAPI default is 422, but the spec requires **400**. | fastapi.tiangolo.com/tutorial/handling-errors/ |
| WebSocket route | `@router.websocket("/ws/live") async def ws(websocket: WebSocket)` | fastapi.tiangolo.com/advanced/testing-websockets/ |
| WebSocket methods | `await ws.accept(subprotocol=None, headers=None)`, `await ws.receive_json(mode="text")`, `await ws.send_json(data, mode="text")`, `await ws.close(code=1000, reason=None)`; raises `WebSocketDisconnect` when the client disconnects | fastapi.tiangolo.com/reference/websockets/ |
| Receive with timeout (5 s auth) | No built-in timeout. Use `await asyncio.wait_for(ws.receive_json(), timeout=settings.ws_auth_timeout_s)` and catch `TimeoutError` (on 3.11+ `asyncio.TimeoutError` is an alias). Then `await ws.close(code=4401)` (app-defined 4xxx code) | docs.python.org asyncio-task `wait_for` (ctx7 `/python/cpython`) |
| Tests (HTTP) | `async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac: ...` | fastapi.tiangolo.com/advanced/async-tests/ |
| ⚠ Lifespan in tests | `AsyncClient`/`ASGITransport` **does not run lifespan**. Either use `asgi_lifespan.LifespanManager(app)` or (preferred here) build state in fixtures and inject it through dependencies | fastapi.tiangolo.com/advanced/async-tests/ (warning box) |
| Tests (WebSocket) | httpx has no WS support. Use `fastapi.testclient.TestClient(app)` with `with client.websocket_connect("/api/v1/ws/live") as ws: ws.send_json(...); ws.receive_json()`. `with TestClient(app)` runs lifespan | fastapi.tiangolo.com/advanced/testing-websockets/, /advanced/testing-events/ |

### Pydantic v2 + pydantic-settings — ctx7: `/pydantic/pydantic` (v2.12.x), `/pydantic/pydantic-settings` (v2.16)

| API | Usage | Source |
|---|---|---|
| Settings | `class Settings(BaseSettings): model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")` | pydantic-settings docs/index.md "Dotenv support" |
| List from env (`GOOGLE_OAUTH_CLIENT_IDS`) | Complex types are parsed as JSON by default. For a comma-separated value, use `SettingsConfigDict(enable_decoding=False)` plus `@field_validator("google_oauth_client_ids", mode="before")` that splits on `,` | pydantic-settings docs/index.md "enable_decoding" |
| Fail-fast validation | `@model_validator(mode="after") def check(self) -> "Settings": ...; return self` (it runs after all sources are merged). In it, raise `ValueError` when `app_env != "dev"` and a secret is missing or is a default | pydantic-settings tests/test_settings.py |
| ⚠ Anti-pattern | Pydantic v1 `class Config:` / `BaseSettings` from `pydantic` (moved to `pydantic_settings`); `.dict()` → use `.model_dump()` | pydantic v2 migration (ctx7 `/pydantic/pydantic`) |

### DB layer — **plain asyncpg** (see decisions.md ADR-2) — ctx7: `/magicstack/asyncpg` (v0.31)

| API | Usage | Source |
|---|---|---|
| Pool | `pool = await asyncpg.create_pool(dsn, min_size=1, max_size=5, statement_cache_size=0 \| default, init=init_conn, command_timeout=10)`; `await pool.close()` in lifespan shutdown | asyncpg _autodocs/api-reference/pool.md |
| Acquire | `async with pool.acquire() as con: ...` | same |
| Queries | `await con.fetch(q, *args)`, `fetchrow`, `fetchval(q, *args, column=0)`, `execute(q, *args)`, `executemany(q, args_iter)`; placeholders are `$1, $2…` | asyncpg _autodocs/api-reference/connection.md |
| Transactions | `async with con.transaction(): ...`. A **nested** `con.transaction()` creates a SAVEPOINT, which the test fixture relies on | asyncpg docs/api/index.rst "Nested transactions" |
| jsonb codec | `await con.set_type_codec("jsonb", schema="pg_catalog", encoder=json.dumps, decoder=json.loads, format="text")` in `init=` | asyncpg connection-io.md `set_type_codec` |
| Errors | `asyncpg.UniqueViolationError` (`.constraint_name`), `asyncpg.ForeignKeyViolationError`, `asyncpg.PostgresConnectionError`; also `OSError`/`TimeoutError` on network loss → map to 503 `DB_UNAVAILABLE` | asyncpg _autodocs/errors.md |
| PgBouncer/Supavisor | With the transaction pooler (port 6543), pass `statement_cache_size=0` and never call `con.prepare()`. With the session pooler or a direct connection (5432) the default cache is fine | asyncpg docs/faq.rst; supabase.com/docs/guides/database/connecting-to-postgres |

**Supabase connection string** — ctx7 `/websites/supabase_guides`, supabase.com/docs/guides/database/connecting-to-postgres. A direct connection is **IPv6-only on the free plan**. Render and Railway need IPv4, so use the **Shared pooler, session mode** (`aws-N-REGION.pooler.supabase.com:5432`). Do not use the transaction pooler for the long-running server. Keep `max_size` small because the pooler limits clients.

### Alembic — ctx7: `/websites/alembic_sqlalchemy_en`; SQLAlchemy ctx7: `/sqlalchemy/sqlalchemy/rel_2_0_55`

| API | Usage | Source |
|---|---|---|
| `op.execute(sqltext)` | Accepts a str or Executable. ⚠ A plain str is coerced to `text()`, so `:word` is parsed as a bind param. That breaks SQL files containing JSON literals such as `'{"a":1}'`, so do **not** feed whole SQL files to `op.execute` | alembic.sqlalchemy.org/en/latest/ops.html |
| Raw file execution (use this) | `op.get_bind().exec_driver_sql(Path(f).read_text())`. This runs the string on the DBAPI cursor with no `text()` compilation | SQLAlchemy core/connections.rst `Connection.exec_driver_sql` (1.4+) |
| Migration driver | Use a **sync** psycopg (v3) URL for Alembic only: `postgresql+psycopg://...`. The asyncpg dialect prepares every statement, and multi-statement files fail. **UNCONFIRMED:** that psycopg3 runs a multi-statement string with no params. P1 must verify it against docker postgres | (P1 to verify) |
| URL from env | Edit `env.py` to read `DATABASE_URL` (the alembic docs explicitly recommend this over `sqlalchemy.url` in the ini file) | alembic tutorial "sqlalchemy.url" |

### Testing — pytest-asyncio ctx7: `/pytest-dev/pytest-asyncio/v1.3.0`

| API | Usage | Source |
|---|---|---|
| Mode | `pyproject.toml`: `[tool.pytest.ini_options] asyncio_mode = "auto"`, `asyncio_default_fixture_loop_scope = "session"` | docs/concepts.rst; how-to-guides/change_default_fixture_loop.rst |
| ⚠ Anti-pattern | Overriding the `event_loop` fixture was removed in pytest-asyncio 1.x; use `loop_scope` instead | v1.x changelog (ctx7) |
| Per-test rollback (asyncpg) | Session fixture creates the pool. A per-test fixture does `con = await pool.acquire(); tr = con.transaction(); await tr.start()` and overrides the `get_conn` dependency to yield `con`. App code calling `con.transaction()` gets a savepoint. Teardown: `await tr.rollback(); await pool.release(con)` | asyncpg nested-transaction doc (above) |

### PyJWT — ctx7: `/jpadilla/pyjwt` (2.15)

| API | Usage | Source |
|---|---|---|
| Encode | `jwt.encode({"sub": str(user_id), "sid": str(session_id), "role": role, "exp": datetime.now(tz=timezone.utc)+timedelta(minutes=15), "iat": ...}, secret, algorithm="HS256")` → `str` | pyjwt docs/usage.rst |
| Decode | `jwt.decode(token, secret, algorithms=["HS256"], options={"require": ["exp", "sub", "sid"]}, leeway=0)`. **Always pass `algorithms=`** | same |
| Errors | `jwt.ExpiredSignatureError` → 401 `TOKEN_EXPIRED`; `jwt.InvalidTokenError` (base class, which includes `MissingRequiredClaimError`) → 401 `TOKEN_INVALID`. Catch Expired **first** (it subclasses InvalidTokenError) | same |
| Note | Keep `sub` a **string**. Recent PyJWT versions validate `sub` type (**UNCONFIRMED** via ctx7; harmless to follow) | — |

### google-auth — ctx7: `/googleapis/google-auth-library-python`

| API | Usage | Source |
|---|---|---|
| Verify Google ID token | `from google.oauth2 import id_token; from google.auth.transport import requests as g_requests; info = id_token.verify_oauth2_token(token, g_requests.Request(), audience=CLIENT_ID)`. Raises `ValueError` on failure → 401 `TOKEN_INVALID` | docs/reference/google.oauth2.id_token.rst |
| Multiple client IDs | `verify_oauth2_token` documents `audience: str`. For the list in `GOOGLE_OAUTH_CLIENT_IDS`, use `id_token.verify_token(token, request, audience=[...ids])` (documented `str or list`) **and** check `info["iss"] in {"accounts.google.com", "https://accounts.google.com"}` yourself, because `verify_token` skips the issuer check | same (`verify_token`) |
| Claims used | `sub` (→ `users.google_sub`), `email`, `email_verified`, `name` | same |
| Blocking I/O | It is a sync function that may fetch certs, so call it via `await asyncio.to_thread(...)` | (python stdlib) |
| Android audience | **UNCONFIRMED via ctx7:** on Android the ID token `aud` = the `serverClientId` (Web client ID) passed to `GoogleSignIn.instance.initialize`. Put the Web client ID in `GOOGLE_OAUTH_CLIENT_IDS` | — |

### firebase-admin (Python) — ctx7: `/firebase/firebase-admin-python`

| API | Usage | Source |
|---|---|---|
| Init | `cred = credentials.Certificate(json.loads(settings.fcm_credentials))` (dict or path); `firebase_admin.initialize_app(cred)`. Do it once in lifespan | firebase-admin-python `Certificate.__init__` |
| Send | `messaging.send_each(messages: list[Message], dry_run=False) -> BatchResponse` (≤500 per call); async variant `messaging.send_each_async(...)` | `send_each` API doc |
| Message | `messaging.Message(token=tok, notification=messaging.Notification(title=..., body=...), data={...str: str})` | same |
| Per-message result | `resp.responses[i].success`, `.exception`. Delete the token when `isinstance(exc, messaging.UnregisteredError)` (and `SenderIdMismatchError`); retry **once** on other errors (N9) | `_messaging_utils.py` FCM error table |
| ⚠ Anti-pattern | `messaging.send_all` / `send_multicast` (deprecated batch API, removed). Use `send_each` / `send_each_for_multicast` | firebase-admin-python "Send APIs" table |
| Verify Firebase ID token (driver OTP, ADR-1) | `auth.verify_id_token(id_token, check_revoked=False, clock_skew_seconds=0..60) -> dict`. Errors: `auth.ExpiredIdTokenError`, `auth.RevokedIdTokenError`, `auth.InvalidIdTokenError`, `auth.CertificateFetchError`, `auth.UserDisabledError`. Phone claim: `claims["phone_number"]` (E.164); sign-in time: `claims["auth_time"]` | `verify_id_token` API doc |

### Google Directions REST + polyline — **UNCONFIRMED via context7**

- context7 has no index for the Google Directions web service or the Python `polyline` package. Searches found only Rust, .NET and Node wrappers.
- Use (from developers.google.com/maps/documentation/directions/get-directions, to be re-checked by P5 before coding): `GET https://maps.googleapis.com/maps/api/directions/json?origin=lat,lng&destination=lat,lng&waypoints=lat,lng|lat,lng&key=...`. Response: `status` (`OK`, `ZERO_RESULTS`, `NOT_FOUND`, `OVER_QUERY_LIMIT`, `REQUEST_DENIED`, `INVALID_REQUEST`, …), `routes[0].overview_polyline.points` (encoded polyline). Anything except `OK` → route saved as draft + 422 `POLYLINE_FAILED`.
- Note: Google labels the Directions API "Legacy" in favour of Routes API `computeRoutes`. P5 must confirm the user's GCP project can still enable it. If not, use Routes API (`POST https://routes.googleapis.com/directions/v2:computeRoutes`, `X-Goog-FieldMask: routes.polyline.encodedPolyline`).
- Polyline decode/encode: **implement in-house** (`server/app/modules/eta/polyline.py`, about 30 lines, Google's "Encoded Polyline Algorithm Format", precision 1e5). Unit-test it against Google's documented example `_p~iF~ps|U_ulLnnqC_mqNvxq`@` → `[(38.5,-120.2),(40.7,-120.95),(43.252,-126.453)]`. This avoids depending on a package context7 cannot confirm. The Flutter app gets the same 20-line decoder.
- HTTP client for Directions: `httpx.AsyncClient` (ships with the test stack); timeout 10 s.

### Rate limiting — **custom in-memory limiter** (ADR-3); slowapi rejected — ctx7: `/laurents/slowapi`

slowapi facts that drove the rejection (ctx7 `_autodocs/api-reference/extension.md`):
- Its default `_rate_limit_exceeded_handler` returns `{"error": "Rate limit exceeded: ..."}`, which is not the spec envelope.
- `headers_enabled` defaults to False.
- The decorator requires a `request` param on every endpoint.
- `get_remote_address` ignores `X-Forwarded-For`, which is wrong behind the Render/Railway proxy.

### Background jobs — **plain asyncio tasks** (ADR-4); APScheduler not used

| API | Usage | Source |
|---|---|---|
| Start/stop | In lifespan: `t = asyncio.create_task(loop_fn())`. On shutdown: `t.cancel()`, then `await` it, catching `asyncio.CancelledError` | ctx7 `/python/cpython` asyncio-task.rst |
| Timeouts | `asyncio.wait_for(aw, timeout)` raises `TimeoutError`; `async with asyncio.timeout(s):` | same |
| Blocking SDK calls | `await asyncio.to_thread(fn, *args)` for google-auth / firebase-admin sync calls | python stdlib |

---


### Added by P2 (verified via context7 /websites/fastapi_tiangolo)
- `fastapi.security.HTTPBearer(auto_error=False, description=...)` → `HTTPAuthorizationCredentials | None` (`.scheme`, `.credentials`). Source: fastapi.tiangolo.com/reference/security/
- `@app.exception_handler(StarletteHTTPException)` to render 404/405 in the spec envelope. Source: fastapi.tiangolo.com/tutorial/handling-errors/
- `asyncpg.CannotConnectNowError` (with `PostgresConnectionError`, `OSError`, `TimeoutError`) → 503 `DB_UNAVAILABLE`.
- Installed versions (P2): fastapi 0.162.2, asyncpg 0.32.0, PyJWT 2.15.1, pydantic 2.14.3, pydantic-settings 2.16.2, firebase-admin 7.7.0, google-auth 2.62.1.

## App (Flutter, Dart)

### google_sign_in **v7.x** — ctx7: `/websites/pub_dev_packages_google_sign_in`, `/websites/pub_dev_google_sign_in`

| API | Usage | Source |
|---|---|---|
| Init (required, once) | `await GoogleSignIn.instance.initialize(clientId: ..., serverClientId: WEB_CLIENT_ID)` **before any other call** | pub.dev/packages/google_sign_in (README + example) |
| Sign in | `if (GoogleSignIn.instance.supportsAuthenticate()) { final account = await GoogleSignIn.instance.authenticate(); }` → `Future<GoogleSignInAccount>` | pub.dev/documentation/google_sign_in/latest/google_sign_in/GoogleSignIn-class.html |
| ID token | `account.authentication.idToken` (`String?`; `authentication` is a **sync getter** in v7) → `POST /auth/google {id_token}` | GoogleSignInAuthentication-class.html |
| Events / silent | `GoogleSignIn.instance.authenticationEvents` stream; `attemptLightweightAuthentication()` | example/main.dart |
| Errors | `GoogleSignInException` with `.code == GoogleSignInExceptionCode.canceled` | example |
| Sign out | `GoogleSignIn.instance.signOut()` / `disconnect()` | example |
| ⚠ Anti-pattern (v6 API, removed in 7.0.0) | `GoogleSignIn(scopes: ...)` constructor, `.signIn()`, `.signInSilently()`, `await account.authentication` (it was a Future in v6), `currentUser` | changelog 7.0.0 |

### firebase_core — ctx7: `/firebase/flutterfire`
- `WidgetsFlutterBinding.ensureInitialized(); await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);` (generated by `flutterfire configure`, one file per flavor). Source: flutterfire docs/setup/_setup_main.md

### firebase_messaging — ctx7: `/firebase/flutterfire`
| API | Usage | Source |
|---|---|---|
| Permission | `await FirebaseMessaging.instance.requestPermission()` (Android 13+ needs it to show notifications; `getToken()` does not prompt) | docs/cloud-messaging/client.md |
| Token | `await FirebaseMessaging.instance.getToken()` → `PUT /me/push-token`; `FirebaseMessaging.instance.onTokenRefresh.listen(...)` (does not emit on every start) | same |
| Foreground | `FirebaseMessaging.onMessage.listen((RemoteMessage m) {...})` | docs/cloud-messaging/receive.md |
| Background | top-level `@pragma('vm:entry-point') Future<void> handler(RemoteMessage m)`; `FirebaseMessaging.onBackgroundMessage(handler)` | same |

### firebase_auth (driver phone OTP, ADR-1) — ctx7: `/firebase/flutterfire` docs/auth/phone-auth.md
- `await FirebaseAuth.instance.verifyPhoneNumber(phoneNumber: e164, timeout: Duration(seconds: 60), forceResendingToken: token, verificationCompleted: (PhoneAuthCredential c) {...}, verificationFailed: (FirebaseAuthException e) {...}, codeSent: (String verificationId, int? resendToken) {...}, codeAutoRetrievalTimeout: (String verificationId) {...});`
- `final cred = PhoneAuthProvider.credential(verificationId: id, smsCode: code); final uc = await FirebaseAuth.instance.signInWithCredential(cred);`
- `final firebaseIdToken = await uc.user!.getIdToken();` → `POST /auth/phone/verify`. **UNCONFIRMED:** `getIdToken` was not shown in the ctx7 snippet; it is the standard `User` method.
- Android auto-retrieval: `verificationCompleted` (Android only); `resendToken` is null on iOS.
- Error codes to map: `invalid-verification-code` → OTP_INVALID; `session-expired` → OTP_EXPIRED; `too-many-requests` → RATE_LIMITED. **UNCONFIRMED** code strings: confirm in P7.

### google_maps_flutter — ctx7: `/websites/pub_dev_google_maps_flutter`
| API | Usage | Source |
|---|---|---|
| Widget | `GoogleMap(initialCameraPosition: CameraPosition(target: LatLng(..), zoom: 15), markers: Set<Marker>, polylines: Set<Polyline>, onMapCreated: (GoogleMapController c) {...}, myLocationEnabled: ..., style: jsonString)` | pub.dev/documentation/google_maps_flutter/latest/google_maps_flutter/GoogleMap-class.html |
| Controller | `controller.animateCamera(CameraUpdate.newCameraPosition(..), duration: ..)`, `moveCamera`, `getVisibleRegion()` | GoogleMapController-class.html |
| ⚠ Deprecated | `cloudMapId` → use `mapId`. `controller.setMapStyle()` → use the `style:` widget param | GoogleMap-class.html (deprecation note) |
| Size | GoogleMap must be in a bounded-size parent | index.html |
| Android key | `<meta-data android:name="com.google.android.geo.API_KEY" android:value="${MAPS_API_KEY}"/>` via gradle manifestPlaceholders per flavor. **UNCONFIRMED** in this ctx7 session (standard README setup) | — |
| Marker animation | No built-in tween. Interpolate the `LatLng` in an `AnimationController` and rebuild the marker set | (design note) |

### geolocator — ctx7: `/baseflow/flutter-geolocator`
| API | Usage | Source |
|---|---|---|
| Permission | `Geolocator.checkPermission()`, `Geolocator.requestPermission()` → `LocationPermission.{denied, deniedForever, whileInUse, always}`; `Geolocator.openAppSettings()`, `Geolocator.openLocationSettings()`, `Geolocator.isLocationServiceEnabled()` | geolocator/README.md |
| **Precise check (T9)** | `await Geolocator.getLocationAccuracy()` → `LocationAccuracyStatus.reduced \| precise`. On Android it **throws `PlatformException(PERMISSION_DENIED)` if called before permission is granted**, so call it after permission | README "Location accuracy" |
| Stream | `Geolocator.getPositionStream(locationSettings: AndroidSettings(accuracy: LocationAccuracy.high, distanceFilter: 0, intervalDuration: Duration(seconds: 4), foregroundNotificationConfig: ForegroundNotificationConfig(notificationTitle:, notificationText:, enableWakeLock: true)))` | README platform-specific settings |
| Position fields | `latitude, longitude, accuracy (m), speed (m/s), heading, timestamp` | README |

### Foreground service — **flutter_foreground_task** (ADR-5) — ctx7: `/dev-hwang/flutter_foreground_task`
| API | Usage | Source |
|---|---|---|
| Init | `FlutterForegroundTask.init(androidNotificationOptions: AndroidNotificationOptions(channelId:, channelName:, channelDescription:, onlyAlertOnce: true), iosNotificationOptions: const IOSNotificationOptions(showNotification: true, playSound: false), foregroundTaskOptions: ForegroundTaskOptions(eventAction: ForegroundTaskEventAction.repeat(4000), allowWakeLock: true, allowWifiLock: true))`. Must be called before `startService` (else `ServiceNotInitializedException`) | README; _autodocs/api-reference/flutter_foreground_task.md |
| Handler | top-level `@pragma('vm:entry-point') void startCallback() { FlutterForegroundTask.setTaskHandler(TripTaskHandler()); }`; `class TripTaskHandler extends TaskHandler { Future<void> onStart(DateTime t, TaskStarter s); void onRepeatEvent(DateTime t); Future<void> onDestroy(DateTime t, bool isTimeout); void onReceiveData(Object data); }` | README |
| Comms | `FlutterForegroundTask.sendDataToMain(map)` / `addTaskDataCallback(cb)` / `sendDataToTask(data)` | README |
| Update | `FlutterForegroundTask.updateService(notificationTitle:, notificationText:, foregroundTaskOptions:)` (switch 4 s ↔ 15 s cadence) | README |
| Permissions | `checkNotificationPermission()` / `requestNotificationPermission()`; `isIgnoringBatteryOptimizations` / `requestIgnoreBatteryOptimization()` (T7 onboarding) | README |
| ⚠ | Do **not** use `openAlarmsAndRemindersSettings` / exact alarms (Play policy risk, not needed) | README warning |
| **UNCONFIRMED** | `startService(serviceTypes: [ForegroundServiceTypes.location], notificationTitle:, notificationText:, callback: startCallback)` signature, and the Android 14 manifest `foregroundServiceType="location"` + `FOREGROUND_SERVICE_LOCATION` permission. P8-driver must query ctx7 for `startService` before coding | — |

### sqflite — ctx7: `/tekartik/sqflite`
- `openDatabase(join(await getDatabasesPath(), 'ctms.db'), version: 1, onCreate: (db, v) async => db.execute('CREATE TABLE fixes(fix_id TEXT PRIMARY KEY, trip_id TEXT, lat REAL, ...)'))`
- `db.insert(table, map, conflictAlgorithm: ConflictAlgorithm.ignore)`, `db.query(table, where:, whereArgs:, orderBy: 'recorded_at', limit: 20)`, `db.delete(table, where: 'fix_id IN (...)', whereArgs:)`, `db.transaction((txn) async {...})`, `final b = db.batch(); ...; await b.commit(noResult: true)`. Source: sqflite/README.md, skills/sqflite-crud-and-transactions/SKILL.md
- Unit tests: `sqflite_common_ffi` (ctx7 `/websites/pub_dev_packages_sqflite_common_ffi`).

### web_socket_channel — ctx7: `/websites/pub_dev_web_socket_channel`
- `final ch = WebSocketChannel.connect(Uri.parse('wss://host/api/v1/ws/live')); await ch.ready;` (catch `SocketException`, `WebSocketChannelException`); `ch.sink.add(jsonEncode({'type':'auth','token':t}))`; `ch.stream.listen(onData, onError:, onDone:)`; `ch.sink.close(status.goingAway)` (`import 'package:web_socket_channel/status.dart' as status;`). Source: pub.dev/documentation/web_socket_channel/latest/
- App-level ping every 25 s (`{"type":"ping"}`); reconnect with backoff on `onDone`/`onError`; after reconnect, `GET /buses/live` **before** resuming (spec p.6).

### dio — ctx7: `/cfug/dio`, `/websites/pub_dev_dio`
- `QueuedInterceptorsWrapper(onRequest: (options, handler) => handler.next(options), onResponse: ..., onError: (DioException e, ErrorInterceptorHandler handler) async {...})` or `class AuthInterceptor extends QueuedInterceptor`. A queued interceptor serializes callbacks, so concurrent 401s trigger **one** refresh. Source: pub.dev/documentation/dio/latest/dio/QueuedInterceptorsWrapper-class.html
- Refresh flow: on 401 with `error.code == TOKEN_EXPIRED`, call `/auth/refresh` with a **separate** Dio instance (no interceptor, which avoids deadlock), store the tokens, then `handler.resolve(await dio.fetch(e.requestOptions..headers['Authorization']='Bearer $new'))`. Otherwise `handler.next(e)`. Handler methods are `next` / `resolve` / `reject`. Source: dio README "Interceptors"
- `DioException` fields: `requestOptions, response, type (DioExceptionType), error, message`. Map `response.data['error']['code']` → typed exceptions.
- ⚠ Anti-pattern: `DioError` (renamed to `DioException` in dio 5); `dio.lock()/unlock()` (removed; use QueuedInterceptor).

### flutter_riverpod **3.x** — ctx7: `/websites/pub_dev_flutter_riverpod/3.4.2`
- `ProviderScope(overrides: [p.overrideWithValue(fake)], child: App())`; `NotifierProvider<N, T>(N.new)`, `AsyncNotifierProvider<N, T>(N.new)` (the create fn takes **no ref**; use `ref` inside the notifier); `isAutoDispose`, `retry`. Source: pub.dev/documentation/flutter_riverpod/3.4.2/
- ⚠ Anti-pattern: `StateNotifierProvider` / `StateProvider` / `ChangeNotifierProvider` (legacy in 3.x, moved to `flutter_riverpod/legacy.dart`). Use Notifier/AsyncNotifier. **UNCONFIRMED** in snippet. Do not use them in any case.

### go_router — ctx7: `/websites/pub_dev_packages_go_router`
- `GoRouter(routes: [...], redirect: (BuildContext context, GoRouterState state) { ... return '/login' or null; }, refreshListenable: authListenable)`; `MaterialApp.router(routerConfig: router)`. Redirect may be async (`FutureOr<String?>`). `state.uri` and `state.matchedLocation` are available. Source: go_router changelog 5.0.0 (redirect redesign, context added, `RouterConfig`), 13.2.0 (`Uri` on state), 16.2.5 (context.go inside redirect)
- ⚠ Anti-pattern: `GoRouterRefreshStream` (removed in 5.0), `navigatorBuilder`, `urlPathStrategy`.
- **UNCONFIRMED:** a full redirect example was not returned by ctx7. Signature is from the changelog.

### flutter_secure_storage **v10+/v11** — ctx7: `/juliansteenbakker/flutter_secure_storage/flutter_secure_storage-v11.2.0`
- `const storage = FlutterSecureStorage(); await storage.write(key:, value:); await storage.read(key:); await storage.delete(key:); deleteAll()`. Source: README v11.2.0
- v10 changed the Android cipher with auto-migration (`AndroidOptions(migrateOnAlgorithmChange: true)` default). ⚠ Anti-pattern: `AndroidOptions(encryptedSharedPreferences: true)` (v9-era option). **UNCONFIRMED** that it is removed, so don't use it.
- Store **only the refresh token** here. The access token stays in memory (spec: short JWT).

---

## Cross-cutting anti-patterns (reject in review)
- Any `/api/` path without `/v1`. Socket.IO. MySQL syntax.
- Trusting the role from the JWT alone (TRD p.4: load the user from the DB).
- Refresh token in a cookie.
- `slowapi` default handler. `on_event`. `send_all`/`send_multicast`.
- google_sign_in v6 calls. `DioError`. `StateNotifier`.
- A 422 for validation (the spec says 400 `VALIDATION_ERROR`).
- Hard-coded thresholds (see plan "Thresholds as config").
