-- Admin-managed driver accounts (ADR-10): drivers sign in with a userid, email or
-- phone plus a password the admin issues. The password hash (scrypt) lives here,
-- never in an API response or a log. Supersedes the phone-OTP login (ADR-1/ADR-7).
alter table public.users add column if not exists userid text;
alter table public.users add column if not exists password_hash text;
alter table public.users add column if not exists must_change_password boolean not null default true;
alter table public.users add column if not exists failed_logins integer not null default 0;
alter table public.users add column if not exists locked_until timestamptz;

alter table public.users drop constraint if exists users_userid_format;
alter table public.users add constraint users_userid_format
  check (userid is null or (userid = lower(userid) and char_length(userid) between 3 and 40));
create unique index if not exists users_userid_uniq on public.users (userid) where userid is not null;

-- Was: driver needs a phone, everyone else an email. Now a driver needs at least
-- one of phone / email / userid; students and admins still need an email.
alter table public.users drop constraint if exists users_login_identifier;
alter table public.users add constraint users_login_identifier check (
  (role = 'driver' and (phone is not null or email is not null or userid is not null))
  or (role <> 'driver' and email is not null)
);

comment on column public.users.password_hash is
  'scrypt hash (salted) of the driver password, set by an admin. Never returned by the API, never logged.';
comment on column public.users.must_change_password is
  'true after an admin issues or resets a temporary password; cleared by POST /auth/change-password.';

create table if not exists public.driver_profiles (
  user_id          uuid primary key references public.users (id) on delete cascade,
  employee_id      text,
  licence_no       text,
  licence_expiry   date,
  address          text,
  emergency_name   text,
  emergency_phone  text,
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
drop trigger if exists driver_profiles_set_updated_at on public.driver_profiles;
create trigger driver_profiles_set_updated_at before update on public.driver_profiles
  for each row execute function public.set_updated_at();
comment on table public.driver_profiles is
  'Admin-entered driver details. Personal data: deleted with the driver (cascade). Visible to admins only.';

-- Same second layer as 0002_rls.sql: RLS on, no policies.
alter table public.driver_profiles enable row level security;
