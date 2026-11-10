-- V1.3 identity + bus card (docs/v1/v13-spec.md decisions 4-6, 9, 11, 12). Additive and idempotent.
-- Photos are stored in Postgres (bytea), never in a list query and never behind a public URL.

alter table public.student_profiles add column if not exists enrollment_no text;
alter table public.student_profiles add column if not exists home_address text;
alter table public.student_profiles add column if not exists photo bytea;
alter table public.student_profiles add column if not exists photo_mime text;
alter table public.student_profiles add column if not exists photo_updated_at timestamptz;
alter table public.student_profiles drop constraint if exists student_profiles_photo_mime_check;
alter table public.student_profiles add constraint student_profiles_photo_mime_check
  check (photo_mime is null or photo_mime in ('image/jpeg', 'image/png'));
create index if not exists student_profiles_enrollment_idx
  on public.student_profiles (lower(enrollment_no)) where enrollment_no is not null;
comment on column public.student_profiles.photo is
  'Passport-style face photo (JPEG/PNG, <= student_photo_max_bytes). Personal data: served only by authenticated endpoints, deleted with the account.';
comment on column public.student_profiles.home_address is
  'Personal data: visible to the student and admins only; never logged, never in audit meta.';

alter table public.driver_profiles add column if not exists photo bytea;
alter table public.driver_profiles add column if not exists photo_mime text;
alter table public.driver_profiles add column if not exists photo_updated_at timestamptz;
alter table public.driver_profiles drop constraint if exists driver_profiles_photo_mime_check;
alter table public.driver_profiles add constraint driver_profiles_photo_mime_check
  check (photo_mime is null or photo_mime in ('image/jpeg', 'image/png'));

-- Students cannot delete their own account: they ask, an admin approves (account + data deleted) or rejects.
create table if not exists public.deregistration_requests (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.users (id) on delete cascade,
  reason       text check (reason is null or char_length(reason) <= 500),
  status       text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  admin_note   text check (admin_note is null or char_length(admin_note) <= 500),
  created_at   timestamptz not null default now(),
  reviewed_by  uuid references public.users (id) on delete set null,
  reviewed_at  timestamptz
);
create unique index if not exists deregistration_one_pending_per_user
  on public.deregistration_requests (user_id) where status = 'pending';
create index if not exists deregistration_status_idx
  on public.deregistration_requests (status, created_at);
comment on table public.deregistration_requests is
  'Student deregistration requests. Approving one deletes the account (the row goes with it by cascade; the audit log keeps who approved and when, no personal data). Rejected rows are deleted with the account.';

-- Bus card validity end (ISO date, jsonb string): the next 31 July. PUT /admin/settings may be extended later.
insert into public.settings (key, value)
select 'bus_card_valid_until',
       to_jsonb(to_char(case when current_date > make_date(extract(year from current_date)::int, 7, 31)
                             then make_date(extract(year from current_date)::int + 1, 7, 31)
                             else make_date(extract(year from current_date)::int, 7, 31) end, 'YYYY-MM-DD'))
on conflict (key) do nothing;

alter table public.deregistration_requests enable row level security;
