-- Runs once, on FRESH cluster init, via the postgres image's
-- /docker-entrypoint-initdb.d hook. Enables pgvector everywhere so no project
-- needs a manual CREATE EXTENSION:
--   * the current connection is the default POSTGRES_DB (e.g. `claude`), which
--     was created from template1 BEFORE this script runs, so enable it here;
--   * template1 is the template every future database is cloned from, so
--     enabling it there means bare `createdb foo` inherits vector automatically.
-- Idempotent (IF NOT EXISTS) and safe to re-run.
CREATE EXTENSION IF NOT EXISTS vector;
\connect template1
CREATE EXTENSION IF NOT EXISTS vector;
