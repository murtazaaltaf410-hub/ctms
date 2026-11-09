-- Start Journey / arrival (ADR-10): when the bus first moved, when it arrived, and
-- the campus point + radii that decide arrival. A to_campus trip ends at the campus
-- geofence; a from_campus trip ends at the route's last stop. The driver's button
-- ends either one too.
alter table public.trips add column if not exists moved_at timestamptz;
alter table public.trips add column if not exists arrived_at timestamptz;

alter table public.trips drop constraint if exists trips_closed_by_check;
alter table public.trips add constraint trips_closed_by_check
  check (closed_by in ('driver', 'auto', 'arrival'));

-- Thresholds are config (ADR-6). campus_lat / campus_lng are deliberately NOT seeded:
-- unset means the geofence is disabled until an admin pins the campus.
insert into public.settings (key, value) values
  ('campus_radius_m',       '150'),
  ('last_stop_radius_m',    '150'),
  ('moved_speed_mps',       '1.5'),
  ('arrival_min_trip_s',    '120'),
  ('login_max_failures',    '5'),
  ('login_lock_s',          '900')
on conflict (key) do nothing;
