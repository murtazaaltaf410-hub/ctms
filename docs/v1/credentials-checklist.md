# CTMS V1: credentials checklist

Every account, key and file CTMS needs, where to get it, and where it goes. Follow the steps in order. Do everything **twice**, once for **staging** and once for **production**. The runbook requires separate databases, Firebase projects and Google Cloud projects so a test never touches real data. Start with staging. Production can wait until the launch gate.

Secrets go in the **Render dashboard** (server) or in **gitignored files** (app). Never commit them, and never paste them into chat or issues.

## Summary table

| # | Value | Where to get it | Goes into | Used by | Secret? |
|---|---|---|---|---|---|
| 1 | Supabase DB connection string (session pooler, port **5432**) | Supabase → project → **Connect** → *Session pooler* | `DATABASE_URL` | server | **yes** |
| 2 | First admin's Google email | You | `SEED_ADMIN_EMAIL` (and the `admin_allowlist` row in `0003_seed.sql`) | server | no |
| 3 | JWT signing secret (random, 48+ chars, different per environment) | Generate it (step 3) | `JWT_SECRET` | server | **yes** |
| 4 | Firebase service-account JSON | Firebase → Project settings → Service accounts → *Generate new private key* | `FCM_CREDENTIALS` (the whole JSON as one line) | server (FCM push, and Firebase phone-auth token checks if `OTP_PROVIDER=firebase`) | **yes** |
| 5 | `google-services.json` | Firebase → Project settings → Your apps → Android app → download | `app/android/app/google-services.json` (gitignored; one per flavour) | app | no, but keep it out of git |
| 6 | App signing SHA-1 (debug + release) | `keytool` / `./gradlew signingReport` (step 5c) | Firebase Android app, Android OAuth client, Maps key restriction | console settings | no |
| 7 | OAuth **Web** client ID (`…apps.googleusercontent.com`) | Google Cloud → APIs & Services → Credentials | `GOOGLE_OAUTH_CLIENT_IDS` **and** the app's `serverClientId` | server + app | no |
| 8 | OAuth **Android** client ID | Google Cloud → Credentials (package name + SHA-1) | Optional extra entry in `GOOGLE_OAUTH_CLIENT_IDS`. Its main job is to make sign-in work on the device | app (implicit) | no |
| 9 | Maps SDK for Android key | Google Cloud → Credentials → API key, restricted to package + SHA-1 and to *Maps SDK for Android* | App build: `app/android/local.properties` or env `MAPS_API_KEY_STAGING` / `MAPS_API_KEY_PROD` (fallback `MAPS_API_KEY`). **Never on the server** | app | restricted client key |
| 10 | Routes API key (server only) | Google Cloud → Credentials → API key, restricted to *Routes API* | `GOOGLE_DIRECTIONS_KEY` | server | **yes** |
| 11 | `APP_ENV` | Fixed value | `staging` or `production` | server | no |
| 12 | `OTP_PROVIDER` | Decision (ADR-7) | `firebase` on Render (`console` is refused outside dev) | server | no |
| 13 | `PUSH_PROVIDER` | Fixed value | `fcm` (or leave unset: it defaults to `fcm` outside dev) | server | no |
| 14 | `MIN_APP_VERSION`, `APP_UPDATE_URL` | You, per release | env vars (optional) | server → app via `GET /api/v1/config` | no |

The full list of server environment variables is in [deploy.md](deploy.md#environment-variables). `server/app/config.py` is the source of truth for names and defaults.

---

## 1. Supabase: database and `DATABASE_URL`

Follow [supabase-setup.md](supabase-setup.md). Summary:

1. Create the project (`ctms-staging`), region **Mumbai (ap-south-1)**, and save the DB password.
2. Edit your copy of `0003_seed.sql` to replace `REPLACE_WITH_YOUR_EMAIL` with your Google email. Then run `0001`, `0002` and `0003` in the SQL editor.
   *Optional:* the server also runs these files on deploy (Alembic). It skips `0001` if the schema already exists, so running them by hand first is safe.
3. **Connect** → **Session pooler** (port **5432**, IPv4) → copy the URI and fill in the password → that is `DATABASE_URL`.
   - Not the Transaction pooler (6543): the server uses prepared statements.
   - Not "Direct connection" on the free plan: it is IPv6-only and Render's outbound traffic is IPv4.
4. Backups: on the free plan, assume Supabase backups **cannot be restored by you**. The weekly `pg_dump` in [runbook.md](runbook.md#backups) is the backup.

## 2. `SEED_ADMIN_EMAIL`

The Google account that is always an admin, even if the `admin_allowlist` row is removed. Use the same email you put in the seed. Lower case is applied automatically.

## 3. `JWT_SECRET`

Generate a different value for each environment:

```bash
python -c "import secrets; print(secrets.token_urlsafe(48))"
# or: openssl rand -base64 48
```

The server refuses to start outside dev with fewer than 32 characters. If you rotate it, everyone is signed out (their access and refresh tokens stop working). Rotate it after any suspected leak (runbook, privacy).

## 4. Firebase project (push, and later phone sign-in)

1. <https://console.firebase.google.com> → **Add project** → name `ctms-staging`. Google Analytics is not needed.
   - A Firebase project *is* a Google Cloud project. Use this same project for steps 6–8 so the OAuth clients, the Maps key and FCM all live in one place per environment.
2. **Billing plan.**
   - Push (FCM) is free on the **Spark** plan.
   - **Phone sign-in by SMS needs the Blaze (pay-as-you-go) plan.** Under ADR-7 the drivers use the dev console OTP for now, so you **do not need Blaze yet**.
   - Before launch, decide between Firebase phone auth (Blaze plus SMS cost) and an SMS provider. Either way, `OTP_PROVIDER` must not be `console` on Render (the server refuses to start).
   - *Phone numbers for testing* (Authentication → Sign-in method → Phone) work without sending real SMS.
3. **Service account → `FCM_CREDENTIALS`.**
   1. Project settings (gear) → **Service accounts** → **Firebase Admin SDK** → **Generate new private key** → this downloads a `.json` file.
   2. `config.py` accepts **either** the JSON text itself (it must start with `{`) **or** a file path. It does **not** accept base64.
   3. On Render, paste the JSON as **one line**. To minify it:
      ```bash
      python -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))" ctms-staging-firebase-adminsdk.json
      ```
      Paste the output as the value of `FCM_CREDENTIALS`.
   4. Delete the downloaded file from your Downloads folder afterwards, or keep it in your password manager. `*service-account*.json` and `firebase-adminsdk*.json` are gitignored, but don't rely on that.
4. **Register the Android app** (needed by P7; you can do it now):
   1. Project overview → **Add app** → Android.
   2. **Package name:** pick it now and tell the app agent. Suggested: `in.edu.uok.ctms` (production) and `in.edu.uok.ctms.staging` (staging flavour). Each package is a separate Android app in Firebase.
   3. Add the **SHA-1** from step 5c (debug now; add release later).
   4. Download **`google-services.json`** → it goes to `app/android/app/google-services.json` (gitignored; the flavour setup in P7 decides the exact folder). It contains only public client identifiers, but keep it out of git anyway.
5. **Cloud Messaging:** nothing to configure. FCM HTTP v1 is enabled by default, and the service account is enough.

### 5c. Getting the SHA-1 fingerprints

- **Debug** (every developer machine has its own):
  ```bash
  keytool -list -v -alias androiddebugkey -keystore ~/.android/debug.keystore -storepass android -keypass android
  # Windows: %USERPROFILE%\.android\debug.keystore
  ```
  Or, once `app/` exists: `cd app/android && ./gradlew signingReport`.
- **Release:** from the upload keystore you create for signed builds (P7). If you later publish through Google Play with Play App Signing, also add Play's **app signing key** SHA-1 (Play Console → App integrity).
- Add each SHA-1 in three places: the Firebase Android app, the Android OAuth client (step 6) and the Maps key restriction (step 7).

## 6. Google sign-in: OAuth clients → `GOOGLE_OAUTH_CLIENT_IDS`

In <https://console.cloud.google.com>, select the **Firebase project** (`ctms-staging`):

1. **APIs & Services → OAuth consent screen** (Google Auth Platform → Branding/Audience):
   - User type **External**, app name "CTMS", support email.
   - While it is in **Testing**, add the pilot users as test users, or **publish** it. The basic scopes (`openid`, `email`, `profile`) do not need Google verification.
2. **Credentials → Create credentials → OAuth client ID → Android:** enter the package name and SHA-1 (one client per package and SHA-1 pair). There is no secret. This client is what lets `google_sign_in` work on the phone.
3. **Credentials → Create credentials → OAuth client ID → Web application:**
   - Name it "CTMS server audience". It needs no redirect URIs.
   - Copy its **Client ID**. Ignore the client secret: CTMS does not use it.
   - If you enabled Google sign-in in Firebase Authentication, Firebase may already have created "Web client (auto created by Google Service)". You can use that one instead.
4. **What goes into `GOOGLE_OAUTH_CLIENT_IDS`** (comma-separated, no spaces needed):
   - **Always the Web client ID.** On Android the app passes it as `serverClientId`, so the ID token's audience (`aud`) is the **Web** client ID, not the Android one. The server checks `aud` against this list.
   - Optional: the Android client ID(s), and the iOS client ID if an iOS build is ever made.
   - Example: `GOOGLE_OAUTH_CLIENT_IDS=1234-web.apps.googleusercontent.com,1234-android.apps.googleusercontent.com`
5. **The app (P7)** gets the same Web client ID as `--dart-define=GOOGLE_SERVER_CLIENT_ID=<web client id>`. Client IDs are not secrets.

Symptom of a mismatch: students cannot sign in and get `401 TOKEN_INVALID` (runbook incident table). Check that the Web client ID in the app equals one entry in `GOOGLE_OAUTH_CLIENT_IDS` for that environment.

## 7. Maps SDK for Android key (app only)

1. **APIs & Services → Library** → enable **Maps SDK for Android**.
2. **Credentials → Create credentials → API key** → **Edit**:
   - **Application restrictions:** *Android apps* → add the package name + SHA-1 (debug and release, every flavour package).
   - **API restrictions:** *Restrict key* → **Maps SDK for Android** only.
3. This key goes into the app build: put `MAPS_API_KEY_STAGING=…` / `MAPS_API_KEY_PROD=…` in `app/android/local.properties` (gitignored) or set them as env vars (`MAPS_API_KEY` is the fallback for both). It is visible in the APK, which is why the restrictions matter.
4. **Billing:** Maps needs a billing account on the project, even within the free monthly credit.
   - Set a **budget alert** (Billing → Budgets & alerts, for example ₹500/month with 50/90/100 % emails).
   - Set **quotas** (APIs & Services → Maps SDK for Android → Quotas). This is part of the launch gate.

## 8. Routes API key (server only) → `GOOGLE_DIRECTIONS_KEY`

ADR-8: polylines come from the **Routes API** (`computeRoutes`). The env var keeps the runbook's name.

1. **Library** → enable **Routes API**. The legacy "Directions API" is not needed.
2. **Credentials → Create credentials → API key** → **Edit**:
   - **API restrictions:** **Routes API** only.
   - **Application restrictions:** *None*. Render free has no fixed outbound IP, so an IP restriction would break it. The API restriction plus keeping the key secret is the protection.
3. Put it in Render as `GOOGLE_DIRECTIONS_KEY`. **Never** put this key in the app.
4. It is called only when an admin changes a route's stops. Usage is tiny, but add a quota cap anyway (Routes API → Quotas, for example 500 requests/day).

## 9. Fixed values

```
APP_ENV=staging            # production for the prod environment
OTP_PROVIDER=firebase      # ADR-7; 'console' only works with APP_ENV=dev/test
PUSH_PROVIDER=fcm          # or leave unset (fcm outside dev)
TRUST_PROXY=true           # behind Render's proxy (already set in the Docker image)
ALERT_RADIUS_M=500         # default; the admin setting overrides it
MIN_APP_VERSION=1.0.0      # raise to force old builds to update
APP_UPDATE_URL=            # e.g. the Play testing link or direct APK link
```

> **Driver sign-in on Render today:** `OTP_PROVIDER=firebase` needs the app's Firebase phone-auth flow (P7) and, for real SMS, the Blaze plan. Until then, test driver sign-in **locally** (`APP_ENV=dev`, console OTP). Staging accepts driver sign-in only through Firebase test phone numbers once the app supports it.

## 10. Where each value ends up

| Place | Values |
|---|---|
| Render → service → Environment (per environment) | `APP_ENV`, `DATABASE_URL`, `JWT_SECRET`, `GOOGLE_OAUTH_CLIENT_IDS`, `FCM_CREDENTIALS`, `GOOGLE_DIRECTIONS_KEY`, `SEED_ADMIN_EMAIL`, `OTP_PROVIDER`, `PUSH_PROVIDER`, optional `ALERT_RADIUS_M`, `MIN_APP_VERSION`, `APP_UPDATE_URL`, `LOG_LEVEL` |
| GitHub → repo → Settings → Secrets and variables → Actions → **Variables** | `KEEPALIVE_URLS` (not secret) |
| GitHub → Actions **Secrets** (P7, when the app CI job is enabled) | `GOOGLE_SERVICES_JSON_STAGING` (base64 of the file) |
| `app/android/app/google-services.json` (gitignored) | Firebase Android config per flavour |
| App `--dart-define`s (P7) | `API_BASE_URL` (including `/api/v1`, e.g. `https://ctms-api.onrender.com/api/v1`), `WS_URL` (optional), `OTP_MODE=console\|firebase` (must match the server's `OTP_PROVIDER`), `GOOGLE_SERVER_CLIENT_ID` (the Web client ID) |
| `app/android/local.properties` or env (P7) | `MAPS_API_KEY_STAGING`, `MAPS_API_KEY_PROD` (fallback `MAPS_API_KEY`) |
| Your password manager | Supabase DB password, service-account JSON, `JWT_SECRET` per environment |
| Local `server/.env` (gitignored, dev only) | `APP_ENV=dev` and optionally a dev `DATABASE_URL`. Nothing else is required in dev |
