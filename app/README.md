# CTMS app (Flutter)

One app for students, drivers and admins (Android first; the iOS folder is kept).
Flutter 3.47 / Dart 3.13. Server contract: `docs/v1/api-spec.txt` and the server code under `server/app/modules/`.

## Flavours and configuration

| Flavour | Android package | Entry point |
|---|---|---|
| `staging` | `in.edu.uok.ctms.staging` | `lib/main_staging.dart` (also `lib/main.dart`) |
| `prod` | `in.edu.uok.ctms` | `lib/main_prod.dart` |

Runtime values come from `--dart-define`:

| Define | Example | Notes |
|---|---|---|
| `API_BASE_URL` | `https://ctms-staging.example.org/api/v1` | Includes `/api/v1`. Default `http://10.0.2.2:8000/api/v1` (emulator → host) |
| `WS_URL` | `wss://ctms-staging.example.org/api/v1/ws/live` | Optional; derived from `API_BASE_URL` when empty |
| `OTP_MODE` | `console` \| `firebase` | Must match the server's `OTP_PROVIDER` (ADR-7). Default `console` |
| `GOOGLE_SERVER_CLIENT_ID` | `1234-abc.apps.googleusercontent.com` | The OAuth **web** client ID listed in the server's `GOOGLE_OAUTH_CLIENT_IDS` |

```bash
cd app
flutter pub get

# Staging on an emulator against a local server (uvicorn on :8000)
flutter run --flavor staging -t lib/main_staging.dart \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=<web-client-id>

# Staging against the deployed staging server
flutter run --flavor staging -t lib/main_staging.dart \
  --dart-define=API_BASE_URL=https://<staging-host>/api/v1 \
  --dart-define=OTP_MODE=console \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=<web-client-id>

# Production release
flutter build apk --release --flavor prod -t lib/main_prod.dart \
  --dart-define=API_BASE_URL=https://<prod-host>/api/v1 \
  --dart-define=OTP_MODE=firebase \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=<web-client-id>
```

## Google Maps key (never committed)

`android/app/build.gradle.kts` fills the manifest placeholder `${mapsApiKey}` per flavour from, in order:
`MAPS_API_KEY_STAGING` / `MAPS_API_KEY_PROD`, then `MAPS_API_KEY`, read from `android/local.properties` (gitignored) or the environment.

```properties
# android/local.properties
MAPS_API_KEY_STAGING=AIza...
MAPS_API_KEY_PROD=AIza...
```

Restrict each key to *Android apps* with the package name and SHA-1 (debug and release) of its flavour.

## Firebase (push, optional phone auth)

Until Firebase is configured, `lib/firebase_options_staging.dart` and `lib/firebase_options_prod.dart` are placeholders that return `null`. The app then starts without Firebase: push registration is skipped and `OTP_MODE=firebase` falls back to the server code. To configure (once per flavour, from `app/`):

```bash
dart pub global activate flutterfire_cli
firebase login

flutterfire configure --project=<staging-project-id> \
  --out=lib/firebase_options_staging.dart \
  --android-package-name=in.edu.uok.ctms.staging \
  --ios-bundle-id=in.edu.uok.ctms.staging --platforms=android,ios

flutterfire configure --project=<prod-project-id> \
  --out=lib/firebase_options_prod.dart \
  --android-package-name=in.edu.uok.ctms \
  --ios-bundle-id=in.edu.uok.ctms --platforms=android,ios
```

- `flutterfire` may also write `android/app/google-services.json` and add the Google Services gradle plugin. The JSON is gitignored; with two flavours, place each one under `android/app/src/<flavor>/google-services.json`.
- Commit the regenerated `firebase_options_*.dart`. They contain only public client identifiers.
- Add the SHA-1 and SHA-256 of the debug and release keystores to each Firebase Android app (`cd android && ./gradlew signingReport`). Google sign-in and phone auth need them.
- Phone auth: enable it in the Firebase console, restrict the SMS region to India, and add test numbers for development.

## Layout and conventions

```
lib/
  main_staging.dart, main_prod.dart, bootstrap.dart, app.dart, router.dart
  core/      env, api (dio client, error mapping, refresh), auth/token_store,
             storage, models (hand-written fromJson, snake_case), ui (theme, widgets)
  auth/      Google + driver OTP sign-in, AuthController
  realtime/  WebSocket client + live buses state
  push/      FCM token registration, foreground messages
  privacy/   privacy notice, consent screens + ensureConsent, /config version gate
  features/  student/ driver/ admin/  ← Phase 8, one folder per role
```

- Riverpod 3 (`Notifier` / `AsyncNotifier`, no `StateNotifier`), go_router, dio 5 (`DioException`).
- No code generation. Models are written by hand.
- Every threshold the UI needs (stale/offline seconds, alert radius, batch size, ETA cap) comes from `appConfigProvider` (`GET /config`), not from literals.

## Checks

```bash
flutter analyze                               # 0 issues
flutter test                                  # unit + widget tests
dart format --set-exit-if-changed lib test
```
