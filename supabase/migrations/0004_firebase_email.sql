-- Firebase verifies email/password credentials. Postgres remains the CTMS role
-- and session authority, and stores the linked Firebase identity.
alter table public.users add column if not exists firebase_uid text unique;

comment on column public.users.firebase_uid is
  'Firebase Auth UID linked after a verified Firebase email/password sign-in.';
