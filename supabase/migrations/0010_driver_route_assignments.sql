-- Driver route allow-list. A driver may start trips only on routes assigned here.
-- Existing linked drivers retain access to their active default route after this migration.
create table if not exists public.driver_route_assignments (
  driver_id   uuid not null references public.users (id) on delete cascade,
  route_id    uuid not null references public.routes (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (driver_id, route_id)
);
create index if not exists driver_route_assignments_route_idx
  on public.driver_route_assignments (route_id);
comment on table public.driver_route_assignments is
  'Admin-managed route allow-list for drivers. A driver can start a trip only on an assigned active route.';

-- Preserve current default-route operation for drivers already linked to buses.
insert into public.driver_route_assignments (driver_id, route_id)
select b.driver_id, b.default_route_id
from public.buses b
join public.users u on u.id = b.driver_id and u.role = 'driver'
join public.routes r on r.id = b.default_route_id and r.active and r.status = 'active'
where b.driver_id is not null and b.default_route_id is not null
on conflict do nothing;

-- Same second layer as 0002_rls.sql: RLS on, no policies.
alter table public.driver_route_assignments enable row level security;
