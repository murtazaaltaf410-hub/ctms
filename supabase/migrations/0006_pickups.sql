-- Student pickup pins (ADR-9): a temporary "pick me up here" request for one leg
-- of one route. It is not an admin stop and never changes a route. A student has
-- at most one waiting request; it expires after `pickup_request_ttl_s`.
create table if not exists public.pickup_requests (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid not null references public.users (id) on delete cascade,
  route_id    uuid not null references public.routes (id),
  direction   text not null check (direction in ('to_campus', 'from_campus')),
  lat         double precision not null check (lat between -90 and 90),
  lng         double precision not null check (lng between -180 and 180),
  label       text check (char_length(label) between 1 and 60),
  status      text not null default 'waiting'
              check (status in ('waiting', 'picked_up', 'cancelled', 'expired')),
  trip_id     uuid references public.trips (id) on delete set null,  -- the trip that picked the student up
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  updated_at  timestamptz not null default now()
);
create unique index if not exists pickup_one_waiting_per_student
  on public.pickup_requests (student_id) where status = 'waiting';
create index if not exists pickup_waiting_route_idx
  on public.pickup_requests (route_id, direction) where status = 'waiting';
drop trigger if exists pickup_requests_set_updated_at on public.pickup_requests;
create trigger pickup_requests_set_updated_at before update on public.pickup_requests
  for each row execute function public.set_updated_at();
comment on table public.pickup_requests is
  'Temporary student pickup pins. status waiting -> picked_up (bus passed the pin) | cancelled | expired (expires_at). Personal data: deleted with the student (cascade).';

-- One alert per (request, trip), like alert_log for nearby-bus alerts.
create table if not exists public.pickup_alert_log (
  request_id  uuid not null references public.pickup_requests (id) on delete cascade,
  trip_id     uuid not null references public.trips (id) on delete cascade,
  sent_at     timestamptz not null default now(),
  primary key (request_id, trip_id)
);

-- Same second layer as 0002_rls.sql: RLS on, no policies, so PostgREST roles see nothing.
alter table public.pickup_requests enable row level security;
alter table public.pickup_alert_log enable row level security;
