-- =====================================================================
-- Portfolio 5: Distributed and cloud database
-- 04_replication_lag.sql  Measures how far the port-5433 replica falls
--                         behind the primary: when idle, and while the
--                         primary loads about a million ledger rows.
--
-- Run it through the runner, which starts the load and this sampler
-- together (from the repo root, in PowerShell):
--   .\portfolio-5-distributed-cloud\tests\04_replication_lag.ps1
--
-- The load is Portfolio 2's 01_seed_large.sql, run on the primary as a
-- separate psql session named p5_lag_load. It rebuilds the Portfolio 1
-- sample and adds 50,000 customers and about 1,040,000 ledger rows in one
-- transaction: the kind of batch job (a migration, a back-fill, end-of-day
-- processing) that a statement replica has to keep up with. The replica
-- ends up holding the same large data set as the primary.
--
-- This session, on the primary, samples pg_stat_replication every half
-- second from the moment the load connects until the replica has replayed
-- everything the load wrote, and keeps the samples in a temporary table.
-- Three measures of lag:
--   * bytes behind: primary's current WAL position minus the replica's
--     replay position, i.e. WAL written but not yet applied there;
--   * write_lag / flush_lag: time for WAL flushed on the primary to be
--     written / flushed to disk on the replica;
--   * replay_lag: time until it is also applied, so visible to queries.
-- The replica reports its positions every time it writes WAL, and at
-- least every 10 s (wal_receiver_status_interval), so its applied
-- position as seen here can trail the real one by a moment.
-- =====================================================================

\set ECHO queries

\echo
\echo '=== Part 1: lag while the primary is idle ==='
\echo

SELECT inet_server_port() AS port, application_name, state, sync_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_bytes_behind,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;

\echo
\echo '=== Part 2: lag while Portfolio 2''s 01_seed_large.sql runs on the primary ==='
\echo

CREATE TEMP TABLE lag_samples (
    sampled_at    timestamptz NOT NULL,
    load_running  boolean     NOT NULL,
    load_query    text,
    wal_bytes     numeric     NOT NULL,  -- WAL written since the load started
    bytes_behind  numeric     NOT NULL,  -- WAL not yet replayed on the replica
    write_lag     interval,
    flush_lag     interval,
    replay_lag    interval
);

-- The sampler. COMMIT after each sample keeps it from holding one long
-- transaction open on the primary for the whole load. It waits up to 30 s
-- for the load to connect, and up to 120 s after the load ends for the
-- replica to catch up; either limit raises an error.
DO $$
DECLARE
    started      timestamptz := clock_timestamp();
    start_lsn    pg_lsn;
    end_lsn      pg_lsn;
    load_ended   timestamptz;
    load_running boolean;
    load_query   text;
    rep          record;
BEGIN
    LOOP
        PERFORM pg_stat_clear_snapshot();

        SELECT regexp_replace(left(a.query, 200), '\s+', ' ', 'g') INTO load_query
        FROM pg_stat_activity a
        WHERE a.application_name = 'p5_lag_load';
        load_running := FOUND;

        IF start_lsn IS NULL THEN
            IF NOT load_running THEN
                IF clock_timestamp() - started > interval '30 seconds' THEN
                    RAISE EXCEPTION 'no session named p5_lag_load connected within 30 s: run this test through tests/04_replication_lag.ps1';
                END IF;
                PERFORM pg_sleep(0.1);
                CONTINUE;
            END IF;
            start_lsn := pg_current_wal_lsn();
            PERFORM set_config('p5.load_started', clock_timestamp()::text, false);
        END IF;

        SELECT * INTO rep FROM pg_stat_replication WHERE application_name = 'replica_5433';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'replica_5433 is not connected to the primary';
        END IF;

        IF NOT load_running AND end_lsn IS NULL THEN
            end_lsn    := pg_current_wal_lsn();
            load_ended := clock_timestamp();
            PERFORM set_config('p5.load_ended', load_ended::text, false);
            PERFORM set_config('p5.end_lsn', end_lsn::text, false);
        END IF;

        INSERT INTO lag_samples
        VALUES (clock_timestamp(), load_running, CASE WHEN load_running THEN load_query END,
                pg_wal_lsn_diff(pg_current_wal_lsn(), start_lsn),
                greatest(pg_wal_lsn_diff(pg_current_wal_lsn(), rep.replay_lsn), 0),
                rep.write_lag, rep.flush_lag, rep.replay_lag);
        COMMIT;

        IF end_lsn IS NOT NULL THEN
            EXIT WHEN rep.replay_lsn >= end_lsn;
            IF clock_timestamp() - load_ended > interval '120 seconds' THEN
                RAISE EXCEPTION 'replica did not replay up to % within 120 s of the load ending', end_lsn;
            END IF;
        END IF;

        PERFORM pg_sleep(0.5);
    END LOOP;
END
$$;

-- The samples in 10-second windows from the start of the load: WAL the
-- load wrote in the window, the worst lag seen, and what the load was
-- doing at the end of the window. Times are in milliseconds.
SELECT (extract(epoch FROM sampled_at - current_setting('p5.load_started')::timestamptz)::int / 10) * 10
           AS from_second,
       count(*) AS samples,
       round((max(wal_bytes) - min(wal_bytes)) / 1048576.0, 1) AS wal_mb_written,
       round(max(bytes_behind) / 1024.0) AS max_kb_behind,
       round(extract(epoch FROM max(write_lag))  * 1000, 1) AS max_write_ms,
       round(extract(epoch FROM max(flush_lag))  * 1000, 1) AS max_flush_ms,
       round(extract(epoch FROM max(replay_lag)) * 1000, 1) AS max_replay_ms,
       coalesce(left((array_agg(load_query ORDER BY sampled_at DESC))[1], 45), '(load finished)')
           AS load_statement
FROM lag_samples
GROUP BY 1
ORDER BY 1;

-- The whole run in one row. catch_up_ms: from the moment the load's
-- session ended until the replica had replayed all the WAL it wrote.
SELECT count(*) AS samples,
       round(extract(epoch FROM current_setting('p5.load_ended')::timestamptz
                              - current_setting('p5.load_started')::timestamptz)::numeric, 1) AS load_seconds,
       round(max(wal_bytes) / 1048576.0) AS wal_mb_total,
       round(max(bytes_behind) / 1024.0) AS peak_kb_behind,
       round(avg(bytes_behind) FILTER (WHERE load_running) / 1024.0) AS avg_kb_behind,
       round(extract(epoch FROM max(replay_lag)) * 1000, 1) AS peak_replay_ms,
       round(extract(epoch FROM avg(replay_lag) FILTER (WHERE load_running)) * 1000, 1) AS avg_replay_ms,
       round(extract(epoch FROM max(sampled_at) - current_setting('p5.load_ended')::timestamptz)::numeric * 1000)
           AS catch_up_ms
FROM lag_samples;

SELECT current_setting('p5.end_lsn') AS load_end_lsn \gset

-- Row counts on the primary after the load.
SELECT inet_server_port() AS port,
       (SELECT count(*) FROM customers)    AS customers,
       (SELECT count(*) FROM wallets)      AS wallets,
       (SELECT count(*) FROM transfers)    AS transfers,
       (SELECT count(*) FROM transactions) AS ledger_rows;

\echo
\echo '=== Part 3: the replica after the load ==='
\echo

\connect proclus postgres localhost 5433

-- The replica has replayed past the load's last WAL position, and holds
-- exactly the same rows.
SELECT inet_server_port() AS port, :'load_end_lsn' AS load_end_lsn,
       pg_last_wal_replay_lsn() AS replayed_lsn,
       pg_last_wal_replay_lsn() >= :'load_end_lsn'::pg_lsn AS load_fully_replayed;

SELECT inet_server_port() AS port,
       (SELECT count(*) FROM customers)    AS customers,
       (SELECT count(*) FROM wallets)      AS wallets,
       (SELECT count(*) FROM transfers)    AS transfers,
       (SELECT count(*) FROM transactions) AS ledger_rows;
