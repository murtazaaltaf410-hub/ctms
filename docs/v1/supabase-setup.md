# Setting up the CTMS database on Supabase

This guide creates the whole CTMS V1 database in a Supabase project, using three SQL files from this repository. You do not need to know SQL. It takes about 15 minutes.

| File | What it does | Safe to run twice? |
|---|---|---|
| `supabase/migrations/0001_schema.sql` | Creates all 19 tables, indexes and rules | **No.** The second run stops with "CTMS schema already applied" and changes nothing |
| `supabase/migrations/0002_rls.sql` | Locks the tables so only the CTMS server can read them | Yes |
| `supabase/migrations/0003_seed.sql` | Default settings, the first admin, optional demo data | Yes. It never overwrites values you changed later |

---

## 1. Create the project

1. Go to <https://supabase.com/dashboard> and sign in.
2. Click **New project**.
3. Fill in:
   - **Name:** `ctms` (or `ctms-staging` / `ctms-prod` if you want two).
   - **Database password:** click **Generate a password** and save it in your password manager. You need it in step 5.
   - **Region:** the region closest to Srinagar, for example **Mumbai (ap-south-1)**.
4. Click **Create new project** and wait about 2 minutes until the dashboard is ready.

## 2. Put your email in the seed file

1. Open `supabase/migrations/0003_seed.sql` in a text editor.
2. Find this line, in section 2 ("First admin"):

   ```sql
   (lower('REPLACE_WITH_YOUR_EMAIL'))
   ```

3. Replace `REPLACE_WITH_YOUR_EMAIL` with the Google account that should be the first admin. Keep the quotes:

   ```sql
   (lower('someone@gmail.com'))
   ```

4. **Demo data (optional).** Section 3 adds a sample route "North Campus" with 4 stops, "Bus 1", a "Demo Driver" and an 08:30 schedule. This is useful for a first test.
   - **To skip it:** change `include_demo boolean := coalesce(...)` to `include_demo boolean := false;`
   - **To keep it:** change the demo driver phone `+910000000001` to a Firebase **test phone number** (Firebase console → Authentication → Sign-in method → Phone → *Phone numbers for testing*) or to a real driver's number.
5. **Do not commit** the edited file with your real email. Edit a copy, or undo the change after running it.

## 3. Run the three files, in order

1. In the Supabase dashboard, open **SQL Editor** (left sidebar) → **New query**.
2. Open `supabase/migrations/0001_schema.sql`, copy **all** of it, paste it into the editor and click **Run**.
   - Expected: "Success. No rows returned".
3. Click **New query** again. Paste all of `0002_rls.sql` → **Run**. Expected: "Success".
4. Click **New query** again. Paste all of your edited `0003_seed.sql` → **Run**. Expected: "Success".
   - If you see the warning *admin_allowlist still contains the placeholder*, you forgot step 2. Fix it with the SQL below (put your email in), then continue:

     ```sql
     insert into public.admin_allowlist (email) values (lower('someone@gmail.com'));
     delete from public.admin_allowlist where email = 'replace_with_your_email';
     ```

If a file fails halfway, nothing from that file is saved, because each file runs as one transaction. Fix the problem and run the same file again.

## 4. Check that it worked

Run each query in a new SQL Editor query.

**a) All 19 tables exist**

```sql
select table_name from information_schema.tables
where table_schema = 'public' order by 1;
```

Expected: `admin_allowlist, alert_log, alert_settings, announcements, audit_log, buses, consents, locations, phone_otp_requests, push_tokens, rejected_fixes, routes, schedules, sessions, settings, stops, student_locations, trips, users`.

**b) Row Level Security is on for every table**

```sql
select relname, relrowsecurity
from pg_class
where relnamespace = 'public'::regnamespace and relkind = 'r'
order by 1;
```

Expected: every row shows `relrowsecurity = true`. In **Table Editor** each table also shows an "RLS enabled" badge. Supabase may warn *"RLS enabled, no policies"*. That is intended (see section 6).

**c) Settings and the first admin**

```sql
select count(*) from public.settings;      -- expected: 29
select * from public.admin_allowlist;      -- expected: your email, in lower case
select key, value from public.settings where key = 'alert_radius_m';  -- expected: 500
```

**d) Demo data (only if you kept it)**

```sql
select r.name, r.status, count(s.*) as stops
from public.routes r join public.stops s on s.route_id = r.id
group by r.id;                                -- expected: North Campus | active | 4
```

## 5. Copy the connection string for the server (`DATABASE_URL`)

The CTMS server needs one secret: the database connection string.

1. In the dashboard click **Connect** (top of the project page).
2. Choose **Session pooler**. It is labelled IPv4-compatible and uses **port 5432**.
3. Copy the URI. It looks like:

   ```
   postgresql://postgres.<project-ref>:[YOUR-PASSWORD]@aws-<n>-<region>.pooler.supabase.com:5432/postgres
   ```

   Copy the host from the dialog. You cannot work it out from the region name.
4. Replace `[YOUR-PASSWORD]` with the database password from step 1. If the password has special characters (`@ : / ? # %`), percent-encode them, or reset it to a letters-and-digits password under **Project Settings → Database**.
5. Set it as `DATABASE_URL` in the server host's dashboard (Render/Railway environment variables). **Never** put it in the Flutter app or commit it to git.

## 6. What NOT to do

- **Don't use the Transaction pooler (port 6543).** The server uses prepared statements, which transaction mode does not support. Use the Session pooler (5432).
- **Don't use the "Direct connection" string** on the free plan unless your host supports IPv6. It is IPv6-only there.
- **Don't add RLS policies.** No policies means the public API keys (`anon`, `authenticated`) can read nothing, which is what we want. The apps only talk to our server, never to Supabase directly.
- **Don't put the `service_role` key, or any Supabase key, in the app.** The app needs no Supabase keys at all.
- **Don't re-run `0001_schema.sql` to "fix" something.** It refuses to run twice. Schema changes after launch go in a new file (`0004_...sql`).
- **Don't edit tables by hand in Table Editor** for normal admin work (buses, drivers, routes). Use the app, so changes are validated and audit-logged.

---

## For developers

### Local database (instead of Supabase)

```bash
docker compose -f docker-compose.dev.yml up -d
# dev database, with demo data:
DATABASE_URL=postgresql://postgres:postgres@localhost:55432/ctms
# test database, same schema, no demo data:
TEST_DATABASE_URL=postgresql://postgres:postgres@localhost:55432/ctms_test
```

- Host port **55432** avoids clashing with a local Postgres (5432) and the Supabase CLI (54322).
- The SQL files run only on an **empty** volume. After changing them, run `docker compose -f docker-compose.dev.yml down -v` and then `up -d`.
- On plain Postgres the `anon`/`authenticated` roles don't exist, so 0002 only enables RLS.

### Alembic (for Phase 2 / deploy)

Alembic here is only a runner for the SQL files (ADR-2). It does not autogenerate anything.

- `server/alembic.ini`, `server/migrations/env.py`
- Revisions `0001`, `0002`, `0003` each execute the matching SQL file through `server/migrations/sqlfile.py`.

**Dependencies Phase 2 must add to `server/pyproject.toml`:** `alembic`, `sqlalchemy>=2`, `psycopg[binary]>=3`. Verified with alembic 1.18.x, SQLAlchemy 2.1.x, psycopg 3.3.x.

```bash
cd server
DATABASE_URL=postgresql://... uv run alembic upgrade head
# or from the repo root:  uv run --project server alembic -c server/alembic.ini upgrade head
```

How it behaves:
- `DATABASE_URL` may be `postgresql://`, `postgres://` or `postgresql+asyncpg://`. `env.py` rewrites it to `postgresql+psycopg://`.
- **Already ran the files in the SQL editor?** Revision 0001 sees `public.users` and skips. 0002 and 0003 are idempotent and run again. The second 0002 run also enables RLS on `alembic_version`.
- The files' own `begin;`/`commit;` lines are stripped, and each file runs inside Alembic's transaction. SQL is executed with `exec_driver_sql` + `no_parameters=True`, so `:name` and `%` reach Postgres untouched.
- `CTMS_SQL_DIR` overrides where the SQL files are read from, for a container image that doesn't include `supabase/`.
- Downgrades raise `NotImplementedError`. Migrations are forward-only; to roll back, restore a backup.
- To skip demo data in an Alembic-managed database, run `alter database <db> set ctms.seed_demo = 'off';` before upgrading.

### Schema notes for server code

- **Enumerations** are text + CHECK with the exact API values:
  - `role` student/driver/admin
  - trip `type` scheduled/ad_hoc
  - `status` on_time/delayed/breakdown
  - `closed_by` driver/auto
  - route `status` draft/active
  - `platform` android/ios
  - rejection `reason` ACCURACY_TOO_LOW/SPEED_IMPLAUSIBLE/DUPLICATE/OUT_OF_ORDER
- **Emails** must be stored lower-case (CHECK). **Phones** must be E.164 (`+91...`).
- **One active trip per bus and per driver:** partial unique indexes `trips_one_active_per_bus` / `trips_one_active_per_driver`. Map a unique violation on them to 409 `TRIP_ALREADY_ACTIVE`.
- **Trip end:** `ended_at` and `closed_by` must be set together. A `scheduled` trip must have `schedule_id`.
- **Fix idempotency:** `locations.fix_id` is unique. Use `insert ... on conflict (fix_id) do nothing`.
- **Activating a route:** `routes.status = 'active'` requires `polyline`, `cum_dist_m` (jsonb array) and `length_m`. This is U7, enforced by the DB.
- **Stop order:** at most one active stop per `(route_id, sequence)`. The constraint is deferred to commit, so stops can be reordered inside one transaction.
- **Bus driver link:** `buses.driver_id` is unique (one driver per bus) and a trigger requires the user's role to be `driver`.
- **Phone reuse:** a phone is unique among **active** users only, so a number can move to a new driver after the old one is deactivated (U3).
- **Schedules:** `days_of_week` uses ISO weekdays, 1 = Monday … 7 = Sunday. `departure_time` is local time in `settings.timezone` (`Asia/Kolkata`).
- **Deleting a student** (`delete from users`) cascades to sessions, push_tokens, consents, student_locations, alert_settings and alert_log. `audit_log.actor_id` becomes null; scrub `meta` in code.
- **Retention** rules are in `COMMENT ON TABLE` and in `settings`:
  - `location_retention_days` 90
  - `student_location_ttl_s` 300
  - `otp_request_retention_s` 86400
  - sessions past `expires_at`
