-- V1.3 stop alerts + pickup decisions (docs/v1/v13-spec.md decisions 8 and 9). Additive and idempotent.

-- One row per stationary episode of a trip: opened when the bus has not moved for
-- `stopped_alert_after_s`, closed (ended_at) when it moves again or the trip ends.
create table if not exists public.stop_events (
  id                 uuid primary key default gen_random_uuid(),
  trip_id            uuid not null references public.trips (id) on delete cascade,
  started_at         timestamptz not null default now(),
  ended_at           timestamptz,
  reason             text check (reason is null or reason in
                       ('waiting_for_student', 'traffic', 'breakdown', 'fuel', 'police_check', 'other')),
  note               text check (note is null or char_length(note) <= 140),
  auto_marked        boolean not null default false,   -- the server set the trip to delayed/"Stopped"
  driver_notified_at timestamptz
);
create index if not exists stop_events_trip_idx on public.stop_events (trip_id, started_at);
-- At most one open episode per trip.
create unique index if not exists stop_events_one_open_per_trip
  on public.stop_events (trip_id) where ended_at is null;
comment on table public.stop_events is
  'Stationary episodes of a trip (stop alert). auto_marked = the server set status delayed with note Stopped.';

-- The driver's own prompt preferences. Students still see the auto status when alerts are off.
create table if not exists public.driver_prefs (
  user_id             uuid primary key references public.users (id) on delete cascade,
  stop_alerts_enabled boolean not null default true,
  snooze_until        timestamptz,
  updated_at          timestamptz not null default now()
);

-- Pickup requests from a student who is not assigned to the trip's bus wait for the driver's decision.
alter table public.pickup_requests
  add column if not exists decision text not null default 'auto'
    check (decision in ('auto', 'needs_decision', 'accepted', 'rejected'));
alter table public.pickup_requests add column if not exists decided_at timestamptz;

-- Thresholds are config (ADR-6).
insert into public.settings (key, value) values
  ('stopped_alert_after_s', '300')
on conflict (key) do nothing;

-- Same second layer as 0002_rls.sql: RLS on, no policies, so PostgREST roles see nothing.
alter table public.stop_events enable row level security;
alter table public.driver_prefs enable row level security;
