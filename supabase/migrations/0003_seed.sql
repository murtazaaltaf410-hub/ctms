-- =============================================================================
-- CTMS V1 — 0003_seed.sql — default settings, first admin, optional demo data
-- =============================================================================
-- Run after 0002_rls.sql. Safe to re-run: every insert is
-- "on conflict do nothing", so values an admin has changed are never
-- overwritten.
--
-- ############################################################################
-- ##  BEFORE RUNNING: replace REPLACE_WITH_YOUR_EMAIL below with the Google  ##
-- ##  account (lower-case) that should be the FIRST ADMIN. Further admins    ##
-- ##  are added in the app. Never commit a real email to the repository.     ##
-- ############################################################################
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Settings defaults (thresholds are config, never literals in code).
--    Units are in the key name: _m metres, _s seconds, _kmh km/h, _mps m/s.
-- -----------------------------------------------------------------------------
insert into public.settings (key, value) values
  -- GPS fix acceptance (TRD p.2, edge cases T*)
  ('gps_accuracy_max_m',          '50'),
  ('max_speed_kmh',               '120'),
  ('location_batch_max',          '20'),
  ('clock_skew_flag_s',           '30'),
  ('stopped_speed_mps',           '0.5'),
  -- Live state (live -> stale -> offline) and trip auto-close (T2)
  ('stale_after_s',               '30'),
  ('offline_after_s',             '120'),
  ('trip_auto_close_s',           '900'),
  ('db_batch_interval_s',         '10'),
  ('history_downsample_s',        '0'),
  -- WebSocket
  ('ws_heartbeat_s',              '25'),
  ('ws_auth_timeout_s',           '5'),
  -- ETA (TRD p.3, edge case A9)
  ('eta_ema_window_s',            '60'),
  ('eta_v_min_kmh',               '10'),
  ('eta_display_cap_s',           '1800'),
  -- Nearby-bus alerts (TRD p.3-4, edge cases A1-A8). PUT /admin/settings.
  ('alert_radius_m',              '500'),
  ('alert_bus_fix_max_age_s',     '30'),
  ('student_fix_max_age_s',       '300'),
  ('student_fix_max_accuracy_m',  '100'),
  ('student_move_report_m',       '100'),
  ('alert_rider_suppress_m',      '50'),
  ('alert_combine_window_s',      '60'),
  -- Driver phone OTP (edge case U4, ADR-1)
  ('otp_ttl_s',                   '300'),
  ('otp_request_per_phone',       '3'),
  ('otp_request_window_s',        '600'),
  -- Retention (TRD p.4-5, runbook privacy table)
  ('location_retention_days',     '90'),
  ('student_location_ttl_s',      '300'),
  ('otp_request_retention_s',     '86400'),
  -- Local time zone for schedules.departure_time
  ('timezone',                    '"Asia/Kolkata"')
on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- 2. First admin.  >>> EDIT THIS LINE BEFORE RUNNING <<<
--    Put the Google account email of the first admin between the quotes;
--    lower() normalises it (emails are stored lower-case).
-- -----------------------------------------------------------------------------
insert into public.admin_allowlist (email) values
  (lower('REPLACE_WITH_YOUR_EMAIL'))
on conflict (email) do nothing;

do $$
begin
  if exists (select 1 from public.admin_allowlist where email = 'replace_with_your_email') then
    raise warning 'admin_allowlist still contains the placeholder. Fix with: insert into public.admin_allowlist (email) values (lower(''you@example.com'')); delete from public.admin_allowlist where email = ''replace_with_your_email''; (or set SEED_ADMIN_EMAIL on the server).';
  end if;
end
$$;

-- -----------------------------------------------------------------------------
-- 3. OPTIONAL DEMO DATA ======================================================
--    One route "North Campus" (University of Kashmir, Hazratbal) with 4 stops,
--    one bus, one driver with a PLACEHOLDER phone, one schedule.
--    Coordinates are illustrative, not surveyed.
--
--    TO SKIP: change  include_demo boolean := ...  below to  := false
--    (or delete this whole section). The test database skips it by running
--    `set ctms.seed_demo = 'off';` before this file.
--
--    The demo driver phone +910000000001 is a placeholder: change it to a
--    Firebase "test phone number" (Firebase console > Authentication > Sign-in
--    method > Phone) or to the real driver's number.
-- -----------------------------------------------------------------------------
do $$
declare
  include_demo boolean := coalesce(current_setting('ctms.seed_demo', true), 'on') <> 'off';
  v_route  uuid := '00000000-0000-4000-8000-00000000d001';
  v_bus    uuid := '00000000-0000-4000-8000-00000000d002';
  v_driver uuid := '00000000-0000-4000-8000-00000000d003';
begin
  if not include_demo then
    raise notice 'CTMS seed: demo data skipped';
    return;
  end if;

  -- Polyline: Google encoded polyline of 7 points; cum_dist_m is the haversine
  -- cumulative distance (m) of each decoded point. Precomputed so the demo
  -- route can be active without a Directions call.
  insert into public.routes (id, name, polyline, cum_dist_m, length_m, status)
  values (v_route, 'North Campus',
          'ofhoEwewgMsDsDsDsDiDkCiDkCgEiDgEiD',
          '[0.0, 129.9, 259.8, 374.2, 488.6, 624.6, 760.6]'::jsonb,
          760.6, 'active')
  on conflict (id) do nothing;

  insert into public.stops (id, route_id, name, lat, lng, sequence, dist_along_m) values
    ('00000000-0000-4000-8000-00000000d011', v_route, 'Main Gate',       34.12600, 74.83500, 1,   0.0),
    ('00000000-0000-4000-8000-00000000d012', v_route, 'Central Library', 34.12780, 74.83680, 2, 259.8),
    ('00000000-0000-4000-8000-00000000d013', v_route, 'Science Block',   34.12950, 74.83820, 3, 488.6),
    ('00000000-0000-4000-8000-00000000d014', v_route, 'Girls Hostel',    34.13150, 74.83990, 4, 760.6)
  on conflict (id) do nothing;

  insert into public.users (id, role, name, phone)
  values (v_driver, 'driver', 'Demo Driver', '+910000000001')
  on conflict (id) do nothing;

  insert into public.buses (id, label, plate, driver_id, default_route_id)
  values (v_bus, 'Bus 1', 'JK01DEMO01', v_driver, v_route)
  on conflict (id) do nothing;

  -- 08:30 local time, Monday to Saturday.
  insert into public.schedules (id, route_id, departure_time, days_of_week)
  values ('00000000-0000-4000-8000-00000000d021', v_route, '08:30', array[1, 2, 3, 4, 5, 6]::smallint[])
  on conflict (id) do nothing;

  raise notice 'CTMS seed: demo data present (route North Campus, Bus 1, Demo Driver)';
end
$$;
-- END OF OPTIONAL DEMO DATA ===================================================

commit;
