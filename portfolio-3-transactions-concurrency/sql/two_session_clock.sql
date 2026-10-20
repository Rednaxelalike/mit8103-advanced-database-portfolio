-- =====================================================================
-- Portfolio 3: Transactions and concurrency
-- two_session_clock.sql  Shared set-up for the two-session scripts
--                        (03 onwards). Each session script sets :session
--                        and then includes this file with \ir.
--
-- Two psql processes cannot see each other, so they are kept in step by
-- the clock. run_two_sessions.ps1 asks the server for a start time a few
-- seconds ahead and passes the same value to both sessions as
-- -v start=... . Step n of either session runs at start + n seconds:
-- pg_temp.step(n) sleeps until then and prints the time. If a session is
-- held up (for example waiting for a row lock), its next step runs as
-- soon as it is free, and the printed time shows how long it waited.
-- =====================================================================

\set QUIET on

\if :{?start}
\else
    \echo 'Missing -v start=<timestamp>. Run both sessions with run_two_sessions.ps1.'
    \quit
\endif

-- The name shows in pg_stat_activity, so one session can see the other.
SET application_name = :'session';
SET proclus.start = :'start';

-- Time since the shared start, for example 'session_b at t+4.0 s'.
CREATE FUNCTION pg_temp.clock() RETURNS text
LANGUAGE sql VOLATILE AS $$
    SELECT format('%s at t+%s s', current_setting('application_name'),
                  to_char(extract(epoch FROM clock_timestamp()
                                  - current_setting('proclus.start')::timestamptz),
                          'FM9990.0'));
$$;

-- Wait until step n (start + n seconds), then say when it ran.
CREATE FUNCTION pg_temp.step(n integer) RETURNS text
LANGUAGE sql VOLATILE AS $$
    SELECT pg_sleep_until(current_setting('proclus.start')::timestamptz
                          + n * interval '1 second');
    SELECT format('step %s: ', n) || pg_temp.clock();
$$;

-- Session A rebuilds the sample data first. If that took longer than the
-- lead time, the steps would no longer line up, so stop here instead.
SELECT clock_timestamp() < current_setting('proclus.start')::timestamptz AS on_time \gset
\if :on_time
\else
    \echo 'The start time had already passed. Run the pair again.'
    \quit
\endif

\set QUIET off
