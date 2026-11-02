-- =====================================================================
-- Portfolio 5: Distributed and cloud database
-- primary_replication_role.sql  Creates the replicator role the port-5433
--                               replica logs in as (step 1 of
--                               setup-replica.md).
--
-- Run on the primary as postgres, from the repo root, with the password
-- from .env (PGREPLICATION_PASSWORD) passed as a psql variable so it never
-- appears in the repo:
--   psql -X -w -U postgres -h localhost -p 5432 -d postgres -v ON_ERROR_STOP=1
--        -v replication_password="$env:PGREPLICATION_PASSWORD"
--        -f portfolio-5-distributed-cloud/config/primary_replication_role.sql
--
-- Re-runnable: the role is created only if it is missing, and the
-- password is set every time.
-- =====================================================================

-- REPLICATION lets the role open a WAL streaming connection and run
-- pg_basebackup. It is not a superuser and is granted no table access, so
-- the password stored for the replica cannot read or change Proclus data
-- through an ordinary connection.
SELECT 'CREATE ROLE replicator WITH LOGIN REPLICATION'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') \gexec

ALTER ROLE replicator WITH PASSWORD :'replication_password';

SELECT rolname, rolsuper, rolreplication, rolcanlogin,
       rolpassword LIKE 'SCRAM-SHA-256$%' AS password_is_scram
FROM pg_authid
WHERE rolname = 'replicator';
