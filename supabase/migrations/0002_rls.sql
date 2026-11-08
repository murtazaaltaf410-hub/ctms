-- =============================================================================
-- CTMS V1 — 0002_rls.sql — Row Level Security as a second layer
-- =============================================================================
-- Run after 0001_schema.sql. Safe to re-run (every statement is idempotent).
--
-- Model: the apps NEVER talk to the database. Only the FastAPI server connects,
-- as the database owner (postgres), which bypasses RLS because it owns the
-- tables (FORCE ROW LEVEL SECURITY is deliberately NOT set).
--
-- On Supabase the REST/GraphQL APIs (PostgREST) connect as the roles `anon` and
-- `authenticated`. This file:
--   1. enables RLS on every table in schema public, with NO policies, so those
--      roles see zero rows even if a grant slips through;
--   2. revokes every privilege those roles have on our tables, sequences and
--      functions, and stops Supabase's default privileges from granting them
--      on objects created later.
-- Do NOT add policies for anon/authenticated. Do NOT use the service_role key
-- in the app.
--
-- On plain Postgres (docker-compose.dev.yml, CI) the Supabase roles do not
-- exist; the role-specific steps are skipped, RLS is still enabled.
-- =============================================================================

begin;

do $$
declare
  t record;
  r text;
begin
  -- 1. RLS on every ordinary table in public (also covers alembic_version when
  --    the server's migration runner has created it).
  for t in
    select c.relname
    from pg_class c
    where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
  loop
    execute format('alter table public.%I enable row level security', t.relname);
  end loop;

  -- 2. Strip API roles, only where they exist (Supabase).
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on all tables in schema public from %I', r);
      execute format('revoke all on all sequences in schema public from %I', r);
      execute format('revoke all on all functions in schema public from %I', r);
      -- Objects the current role (postgres) creates in public from now on.
      execute format('alter default privileges in schema public revoke all on tables from %I', r);
      execute format('alter default privileges in schema public revoke all on sequences from %I', r);
      execute format('alter default privileges in schema public revoke all on functions from %I', r);
    end if;
  end loop;
end
$$;

-- Trigger functions are not meant to be called directly by anyone.
revoke all on function public.set_updated_at() from public;
revoke all on function public.check_bus_driver_role() from public;

commit;
