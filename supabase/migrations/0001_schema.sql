-- =============================================================================
-- CTMS V1 — 0001_schema.sql — full Postgres schema (Supabase / Postgres 16)
-- =============================================================================
-- Run order: 0001_schema.sql -> 0002_rls.sql -> 0003_seed.sql
--
-- Source of truth: docs/v1/prd.txt (data model), docs/v1/api-spec.txt (field
-- names and enum values), docs/v1/trd.txt (retention), docs/v1/decisions.md.
--
-- RE-RUN BEHAVIOUR: this file is NOT re-runnable. If the table public.users
-- already exists the first statement raises
--   "CTMS schema already applied (public.users exists) ..."
-- and, because everything runs in one transaction, nothing is changed.
-- Schema changes after launch go in a NEW numbered file (0004_*.sql), never by
-- editing and re-running this one. This file contains no DROP statements.
--
-- Conventions
--   * UUID primary keys (gen_random_uuid()), except high-volume append-only
--     tables (locations, rejected_fixes, phone_otp_requests, audit_log) which
--     use bigint identity.
--   * All timestamps are timestamptz (stored UTC; the API speaks ISO-8601 UTC).
--   * Enumerations are text + CHECK constraints with the exact API spec values
--     (easier to extend than Postgres enum types).
--   * Emails are stored lower-case; phones are stored in E.164 (+<country><n>).
--   * Distances in metres (_m), speeds in metres per second (_mps).
--   * Deletes of business data are soft (active = false) so history keeps names.
--     Personal data (student account) is hard-deleted and cascades.
--   * Alembic runs these files through psycopg with NO bind parameters, so
--     percent signs and :name text are passed to Postgres untouched.
-- =============================================================================

begin;

do $$
begin
  if to_regclass('public.users') is not null then
    raise exception 'CTMS schema already applied (public.users exists). 0001_schema.sql is not re-runnable; put changes in a new migration file.';
  end if;
end
$$;

-- gen_random_uuid() is built into Postgres 13+; pgcrypto is kept for older
-- servers. On Supabase it is already installed, so this is a no-op.
create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- Shared trigger: keep updated_at current on every UPDATE.
-- -----------------------------------------------------------------------------
create function public.set_updated_at() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

-- =============================================================================
-- Identity and access
-- =============================================================================

create table public.users (
  id          uuid primary key default gen_random_uuid(),
  role        text not null check (role in ('student', 'driver', 'admin')),
  name        text not null default '' check (char_length(name) <= 120),
  email       text unique check (email = lower(email)),
  phone       text check (phone ~ '^\+[1-9][0-9]{6,14}$'),
  google_sub  text unique,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  -- Drivers sign in by phone OTP; students and admins sign in with Google.
  constraint users_login_identifier check (
    (role = 'driver' and phone is not null)
    or (role <> 'driver' and email is not null)
  )
);
-- A phone number may belong to only one ACTIVE user. A deactivated driver keeps
-- the number for history, and the number can be re-issued to a new driver (U3).
create unique index users_phone_active_uniq on public.users (phone) where active and phone is not null;
create index users_role_idx on public.users (role) where active;
create trigger users_set_updated_at before update on public.users
  for each row execute function public.set_updated_at();
comment on table public.users is
  'All accounts (student, driver, admin). Student rows are hard-deleted on DELETE /me; personal-data tables cascade. Drivers/admins are deactivated (active=false), not deleted. Retention: until account deletion.';

create table public.admin_allowlist (
  email       text primary key check (email = lower(email)),
  added_by    uuid references public.users (id) on delete set null,
  created_at  timestamptz not null default now()
);
comment on table public.admin_allowlist is
  'Google accounts whose email is listed here become admin on sign-in. SEED_ADMIN_EMAIL (env) is also honoured by the server. The last admin cannot be removed (LAST_ADMIN).';

create table public.sessions (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.users (id) on delete cascade,
  refresh_hash    text not null unique,
  device_id       text,
  created_at      timestamptz not null default now(),
  last_used_at    timestamptz not null default now(),
  expires_at      timestamptz not null,
  revoked_at      timestamptz,
  revoked_reason  text,
  constraint sessions_revoked_pair check ((revoked_at is null) = (revoked_reason is null))
);
create index sessions_user_active_idx on public.sessions (user_id) where revoked_at is null;
create index sessions_expires_idx on public.sessions (expires_at);
comment on table public.sessions is
  'One row per signed-in device. refresh_hash = SHA-256 of the rotating refresh token (never the token). The access JWT carries sid = sessions.id. revoked_reason examples: logout, replaced (driver signed in elsewhere -> SESSION_REPLACED), deactivated. Retention: purge rows past expires_at.';
comment on column public.sessions.revoked_reason is
  'Free text set by the server, e.g. logout | replaced | deactivated | rotated_reuse.';

-- ADR-1: Firebase Phone Auth sends the SMS. This table only tracks requests to
-- POST /auth/phone/request so the server can enforce 3 sends / 10 min per phone
-- (U4) and require a request within the last 5 minutes before verify.
create table public.phone_otp_requests (
  id          bigint generated always as identity primary key,
  phone_e164  text not null check (phone_e164 ~ '^\+[1-9][0-9]{6,14}$'),
  ip          inet,
  created_at  timestamptz not null default now()
);
create index phone_otp_requests_phone_time_idx on public.phone_otp_requests (phone_e164, created_at desc);
create index phone_otp_requests_created_idx on public.phone_otp_requests (created_at);
comment on table public.phone_otp_requests is
  'Driver OTP request log (no codes stored; Firebase verifies the code). Retention: purge rows older than 1 day.';

create table public.push_tokens (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users (id) on delete cascade,
  token       text not null unique,
  platform    text not null check (platform in ('android', 'ios')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index push_tokens_user_idx on public.push_tokens (user_id);
create trigger push_tokens_set_updated_at before update on public.push_tokens
  for each row execute function public.set_updated_at();
comment on table public.push_tokens is
  'FCM registration tokens. Retention: deleted on sign-out, on account deletion (cascade) or when FCM reports the token invalid.';

create table public.consents (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.users (id) on delete cascade,
  kind         text not null check (char_length(kind) between 1 and 64),
  version      text not null check (char_length(version) between 1 and 32),
  accepted_at  timestamptz not null default now(),
  constraint consents_user_kind_version_uniq unique (user_id, kind, version)
);
comment on table public.consents is
  'Privacy notice / location consent acceptances (runbook: student alert-mode consent, driver trip-location consent). kind examples: privacy_notice, student_location, driver_location. Retention: until account deletion.';

-- =============================================================================
-- Fleet, routes and timetable
-- =============================================================================

create table public.routes (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (char_length(name) between 1 and 120),
  polyline        text,
  cum_dist_m      jsonb,
  length_m        double precision check (length_m >= 0),
  status          text not null default 'draft' check (status in ('draft', 'active')),
  polyline_error  text,
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  -- U7: a route cannot be activated until a polyline exists.
  constraint routes_active_needs_polyline check (
    status <> 'active' or (polyline is not null and cum_dist_m is not null and length_m is not null)
  ),
  constraint routes_cum_dist_is_array check (cum_dist_m is null or jsonb_typeof(cum_dist_m) = 'array')
);
create trigger routes_set_updated_at before update on public.routes
  for each row execute function public.set_updated_at();
comment on table public.routes is
  'Bus routes. polyline = Google encoded polyline generated once from Directions when stops change; cum_dist_m = cumulative distance (m) for every decoded polyline point, used for server-side ETA. status draft|active; polyline_error holds the POLYLINE_FAILED message. active=false is the soft delete.';

create table public.stops (
  id            uuid primary key default gen_random_uuid(),
  route_id      uuid not null references public.routes (id),
  name          text not null check (char_length(name) between 1 and 120),
  lat           double precision not null check (lat between -90 and 90),
  lng           double precision not null check (lng between -180 and 180),
  sequence      integer not null check (sequence >= 1),
  dist_along_m  double precision check (dist_along_m >= 0),
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  -- One active stop per (route, sequence). Deferred so reordering stops inside
  -- one transaction does not trip over itself.
  constraint stops_route_sequence_uniq
    exclude using btree (route_id with =, sequence with =) where (active)
    deferrable initially deferred
);
create index stops_route_idx on public.stops (route_id, sequence) where active;
create trigger stops_set_updated_at before update on public.stops
  for each row execute function public.set_updated_at();
comment on table public.stops is
  'Ordered stops of a route. dist_along_m = the stop''s cumulative distance along the route polyline (filled when the polyline is generated). active=false is the soft delete.';

create table public.buses (
  id                uuid primary key default gen_random_uuid(),
  label             text not null check (char_length(label) between 1 and 60),
  plate             text not null unique check (char_length(plate) between 1 and 20),
  active            boolean not null default true,
  driver_id         uuid unique references public.users (id) on delete set null,
  default_route_id  uuid references public.routes (id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create trigger buses_set_updated_at before update on public.buses
  for each row execute function public.set_updated_at();
comment on table public.buses is
  'Buses. driver_id is the linked driver (one driver per bus; relinking is audited, U8). default_route_id is used by POST /trips/start when route_id is omitted. active=false is the soft delete (blocked while the bus has an active trip -> IN_USE).';

-- buses.driver_id must point at a user whose role is driver.
create function public.check_bus_driver_role() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.driver_id is not null and not exists (
    select 1 from public.users u where u.id = new.driver_id and u.role = 'driver'
  ) then
    raise exception 'buses.driver_id must reference a user with role driver'
      using errcode = 'check_violation';
  end if;
  return new;
end
$$;
create trigger buses_check_driver_role before insert or update of driver_id on public.buses
  for each row execute function public.check_bus_driver_role();

create table public.schedules (
  id              uuid primary key default gen_random_uuid(),
  route_id        uuid not null references public.routes (id),
  departure_time  time not null,
  days_of_week    smallint[] not null,
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  -- ISO weekdays: 1 = Monday ... 7 = Sunday (Python date.isoweekday()).
  constraint schedules_days_valid check (
    cardinality(days_of_week) between 1 and 7
    and days_of_week <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]
  )
);
create index schedules_route_idx on public.schedules (route_id) where active;
create trigger schedules_set_updated_at before update on public.schedules
  for each row execute function public.set_updated_at();
comment on table public.schedules is
  'Optional timetable slots. departure_time is LOCAL campus time (settings.timezone, default Asia/Kolkata); days_of_week uses ISO numbering 1=Mon..7=Sun. Ad hoc trips are always allowed.';

-- =============================================================================
-- Trips and tracking
-- =============================================================================

create table public.trips (
  id           uuid primary key default gen_random_uuid(),
  bus_id       uuid not null references public.buses (id),
  driver_id    uuid not null references public.users (id),
  route_id     uuid not null references public.routes (id),
  schedule_id  uuid references public.schedules (id),
  type         text not null check (type in ('scheduled', 'ad_hoc')),
  status       text not null default 'on_time' check (status in ('on_time', 'delayed', 'breakdown')),
  note         text check (char_length(note) <= 140),
  started_at   timestamptz not null default now(),
  ended_at     timestamptz,
  closed_by    text check (closed_by in ('driver', 'auto')),
  distance_m   double precision not null default 0 check (distance_m >= 0),
  last_fix_at  timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint trips_closed_pair check ((ended_at is null) = (closed_by is null)),
  constraint trips_end_after_start check (ended_at is null or ended_at >= started_at),
  constraint trips_scheduled_has_schedule check (type <> 'scheduled' or schedule_id is not null)
);
-- One active (not ended) trip per bus and per driver -> TRIP_ALREADY_ACTIVE (T10).
create unique index trips_one_active_per_bus on public.trips (bus_id) where ended_at is null;
create unique index trips_one_active_per_driver on public.trips (driver_id) where ended_at is null;
create index trips_started_idx on public.trips (started_at desc);
create index trips_bus_started_idx on public.trips (bus_id, started_at desc);
create index trips_route_active_idx on public.trips (route_id) where ended_at is null;
create trigger trips_set_updated_at before update on public.trips
  for each row execute function public.set_updated_at();
comment on table public.trips is
  'One row per bus run. driver_id is the ACTUAL driver at start (U8). ended_at null = active. closed_by driver|auto (auto = 15 min without fixes, T2). Retention: whole pilot.';

create table public.locations (
  id           bigint generated always as identity primary key,
  trip_id      uuid not null references public.trips (id) on delete cascade,
  fix_id       uuid not null unique,
  lat          double precision not null check (lat between -90 and 90),
  lng          double precision not null check (lng between -180 and 180),
  accuracy_m   real check (accuracy_m >= 0),
  speed_mps    real check (speed_mps >= 0),
  heading      real check (heading >= 0 and heading <= 360),
  recorded_at  timestamptz not null,
  received_at  timestamptz not null default now()
);
create index locations_trip_recorded_idx on public.locations (trip_id, recorded_at);
create index locations_recorded_idx on public.locations (recorded_at);
comment on table public.locations is
  'Accepted bus GPS fixes (history for reports and replay). fix_id is client-generated; the unique constraint makes uploads idempotent (repeats -> DUPLICATE). recorded_at = device time, received_at = server time. Retention: 90 days (settings.location_retention_days), then deleted; trips keep their summaries.';

create table public.rejected_fixes (
  id           bigint generated always as identity primary key,
  trip_id      uuid not null references public.trips (id) on delete cascade,
  fix_id       uuid,
  reason       text not null check (reason in ('ACCURACY_TOO_LOW', 'SPEED_IMPLAUSIBLE', 'DUPLICATE', 'OUT_OF_ORDER')),
  received_at  timestamptz not null default now()
);
create index rejected_fixes_trip_idx on public.rejected_fixes (trip_id);
create index rejected_fixes_received_idx on public.rejected_fixes (received_at);
comment on table public.rejected_fixes is
  'Fixes the server rejected, kept for quality metrics only (no coordinates). Retention: same as locations (90 days).';

-- =============================================================================
-- Students: alerts
-- =============================================================================

create table public.student_locations (
  user_id      uuid primary key references public.users (id) on delete cascade,
  lat          double precision not null check (lat between -90 and 90),
  lng          double precision not null check (lng between -180 and 180),
  accuracy_m   real check (accuracy_m >= 0),
  recorded_at  timestamptz not null,
  updated_at   timestamptz not null default now()
);
create trigger student_locations_set_updated_at before update on public.student_locations
  for each row execute function public.set_updated_at();
comment on table public.student_locations is
  'PRIVACY: latest student position only (one row per student, overwritten). Used solely to decide nearby-bus alerts; never shown to admins, never used for history or analytics. Retention: treated as expired after 5 minutes and purged by the retention job (settings.student_location_ttl_s); deleted with the account.';

create table public.alert_settings (
  user_id     uuid primary key references public.users (id) on delete cascade,
  enabled     boolean not null default false,
  updated_at  timestamptz not null default now()
);
create trigger alert_settings_set_updated_at before update on public.alert_settings
  for each row execute function public.set_updated_at();
comment on table public.alert_settings is
  'Student alert mode on/off. Enabling requires a registered push token (checked by the server).';

create table public.alert_log (
  student_id  uuid not null references public.users (id) on delete cascade,
  trip_id     uuid not null references public.trips (id) on delete cascade,
  sent_at     timestamptz not null default now(),
  primary key (student_id, trip_id)
);
create index alert_log_trip_idx on public.alert_log (trip_id);
comment on table public.alert_log is
  'At most one nearby-bus alert per student per trip. Retention: deleted with the student account (U2).';

-- =============================================================================
-- Announcements, settings, audit
-- =============================================================================

create table public.announcements (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (char_length(title) between 1 and 200),
  body        text not null check (char_length(body) <= 4000),
  urgent      boolean not null default false,
  created_by  uuid references public.users (id) on delete set null,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index announcements_feed_idx on public.announcements (created_at desc, id desc) where active;
create trigger announcements_set_updated_at before update on public.announcements
  for each row execute function public.set_updated_at();
comment on table public.announcements is
  'Admin announcements, newest first. DELETE is soft (active=false). Retention: whole pilot.';

create table public.settings (
  key         text primary key check (key ~ '^[a-z][a-z0-9_]*$'),
  value       jsonb not null,
  updated_by  uuid references public.users (id) on delete set null,
  updated_at  timestamptz not null default now()
);
create trigger settings_set_updated_at before update on public.settings
  for each row execute function public.set_updated_at();
comment on table public.settings is
  'Runtime thresholds as key -> jsonb value (defaults in 0003_seed.sql). Admins can change alert_radius_m via PUT /admin/settings; env vars (e.g. ALERT_RADIUS_M) are only fallbacks.';

create table public.audit_log (
  id           bigint generated always as identity primary key,
  actor_id     uuid references public.users (id) on delete set null,
  action       text not null check (char_length(action) between 1 and 100),
  target_type  text,
  target_id    text,
  meta         jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);
create index audit_log_created_idx on public.audit_log (created_at desc);
create index audit_log_target_idx on public.audit_log (target_type, target_id);
create index audit_log_actor_idx on public.audit_log (actor_id);
comment on table public.audit_log is
  'Security-relevant and admin actions (sign-ins, role changes, driver relinks, settings). actor_id becomes null if the actor is deleted; on student deletion the server also scrubs personal data from meta. Must never contain raw coordinates or tokens.';

commit;
