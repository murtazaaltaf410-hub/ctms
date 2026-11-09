-- Student registration with admin approval and bus capacity (ADR-10).
-- No attendance tracking is stored or built: only registration, assignment and roster.
alter table public.buses add column if not exists capacity integer;
alter table public.buses drop constraint if exists buses_capacity_check;
alter table public.buses add constraint buses_capacity_check check (capacity is null or capacity >= 0);
comment on column public.buses.capacity is 'Seats for registered students. null = not set.';

create table if not exists public.student_profiles (
  user_id              uuid primary key references public.users (id) on delete cascade,
  full_name            text not null check (char_length(full_name) between 1 and 120),
  phone                text,
  department           text,
  route_id             uuid references public.routes (id),
  requested_bus_label  text,
  claims_registered    boolean not null default false,
  status               text not null default 'pending'
                       check (status in ('pending', 'approved', 'rejected')),
  bus_id               uuid references public.buses (id),
  admin_note           text,
  reviewed_by          uuid references public.users (id) on delete set null,
  reviewed_at          timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index if not exists student_profiles_bus_approved_idx
  on public.student_profiles (bus_id) where status = 'approved';
create index if not exists student_profiles_status_idx on public.student_profiles (status);
drop trigger if exists student_profiles_set_updated_at on public.student_profiles;
create trigger student_profiles_set_updated_at before update on public.student_profiles
  for each row execute function public.set_updated_at();
comment on table public.student_profiles is
  'One registration per student. pending -> approved (admin assigns bus_id) | rejected. Personal data: deleted with the student (cascade). Drivers only ever see name and department.';

alter table public.student_profiles enable row level security;
