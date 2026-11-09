-- docker-compose.dev.yml only (runs once, on an EMPTY volume, via psql).
-- 01..03 have already been applied to the dev database `ctms` by the
-- postgres entrypoint. This creates `ctms_test` for the server test suite and
-- applies the same schema files to it, without the optional demo data.

create database ctms_test;

\connect ctms_test
\set ON_ERROR_STOP on
\i /ctms/migrations/0001_schema.sql
\i /ctms/migrations/0002_rls.sql
set ctms.seed_demo = 'off';
\i /ctms/migrations/0003_seed.sql
\i /ctms/migrations/0004_firebase_email.sql
\i /ctms/migrations/0005_trip_direction.sql
\i /ctms/migrations/0006_pickups.sql
