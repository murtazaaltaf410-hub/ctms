-- Trip direction: the same route is driven home -> campus in the morning and
-- campus -> home in the evening. The stop order stored on a route is the
-- 'to_campus' order; 'from_campus' reads the same route in reverse.
-- Additive and defaulted, so the previous server version keeps working.
alter table public.trips
  add column if not exists direction text not null default 'to_campus'
  check (direction in ('to_campus', 'from_campus'));

alter table public.schedules
  add column if not exists direction text not null default 'to_campus'
  check (direction in ('to_campus', 'from_campus'));

comment on column public.trips.direction is
  'to_campus = the route in stored stop order; from_campus = the same route in reverse (polyline and stops).';
comment on column public.schedules.direction is
  'Which leg this slot is for. A trip only matches slots of its own direction.';
