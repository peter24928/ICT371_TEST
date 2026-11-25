-- =====================================================================
-- ICT371 Advanced Database - Question 8: Transport Fleet Maintenance
-- Database: PostgreSQL
-- Run the whole file top to bottom (psql -f q8_fleet.sql)
-- Service rule: a vehicle is due when current_odometer - last_service_odometer
-- is at least 5,000 km. Each new trip must start at the current odometer.
-- =====================================================================

-- Clean start so the script can be rerun
DROP VIEW      IF EXISTS v_service_due;
DROP TABLE     IF EXISTS service_alerts CASCADE;
DROP TABLE     IF EXISTS trips          CASCADE;
DROP TABLE     IF EXISTS vehicles       CASCADE;
DROP FUNCTION  IF EXISTS fn_service_due(INT);
DROP PROCEDURE IF EXISTS pr_record_trip(INT, DATE, INT, INT);
DROP PROCEDURE IF EXISTS pr_refresh_service_alerts();
DROP FUNCTION  IF EXISTS trg_fn_trip_odometer();

-- =====================================================================
-- (a) Database tables (seed trips come after the trigger is installed)
-- =====================================================================

CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(20) NOT NULL UNIQUE,
    current_odometer      INTEGER     NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER     NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE    NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer   >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL CHECK (km_since_service >= 0),
    flagged_on       DATE    NOT NULL DEFAULT CURRENT_DATE
);

-- =====================================================================
-- (b) Function: fn_service_due
-- TRUE when the vehicle has travelled at least 5,000 km since its last
-- service. Rejects an unknown vehicle.
-- =====================================================================

CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
    v_last    INTEGER;
BEGIN
    SELECT current_odometer, last_service_odometer
      INTO v_current, v_last
      FROM vehicles
     WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_last) >= 5000;
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_record_trip
-- Validates the vehicle, requires end_odometer > start_odometer, and
-- inserts the trip. It does NOT update the vehicle odometer: the trigger
-- in part (d) does that.
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      INTEGER,
    p_end        INTEGER
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start and end odometer cannot be NULL';
    END IF;

    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer (%) must be greater than start odometer (%)',
                        p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- =====================================================================
-- (d) Trigger: BEFORE INSERT row trigger on trips
-- 1. rejects invalid mileage (NULL, negative, end not greater than start)
-- 2. locks the vehicle row and checks start_odometer equals its current value
-- 3. sets current_odometer to the trip end, exactly once per inserted trip
-- If the INSERT fails afterwards for any reason, the whole statement
-- (including this odometer update) is rolled back.
-- =====================================================================

CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
BEGIN
    IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL THEN
        RAISE EXCEPTION 'Start and end odometer cannot be NULL';
    END IF;

    IF NEW.start_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: start %, end % (end must be greater than start)',
                        NEW.start_odometer, NEW.end_odometer;
    END IF;

    SELECT current_odometer INTO v_current
      FROM vehicles
     WHERE vehicle_id = NEW.vehicle_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Start odometer % does not match the vehicle current odometer %',
                        NEW.start_odometer, v_current;
    END IF;

    UPDATE vehicles
       SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

-- =====================================================================
-- (a) continued: Seed data
--
--  Vehicle 1: odometer 20000, last service 18000 -> 2000 km (not due)
--  Vehicle 2: odometer 30000, last service 24000 -> 6000 km (due)
--  Vehicle 3: odometer 14500, last service 10000 -> 4500 km (close)
--
-- Six trips are added through pr_record_trip. After them:
--  Vehicle 1 = 20800 (2800 since service), Vehicle 2 = 31000 (7000, due),
--  Vehicle 3 = 15000 (exactly 5000, due, boundary case)
-- =====================================================================

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ZM 1001 A', 20000, 18000),
    ('ZM 2002 B', 30000, 24000),
    ('ZM 3003 C', 14500, 10000);

CALL pr_record_trip(1, CURRENT_DATE - 5, 20000, 20300);
CALL pr_record_trip(1, CURRENT_DATE - 3, 20300, 20800);
CALL pr_record_trip(2, CURRENT_DATE - 6, 30000, 30400);
CALL pr_record_trip(2, CURRENT_DATE - 2, 30400, 31000);
CALL pr_record_trip(3, CURRENT_DATE - 4, 14500, 14750);
CALL pr_record_trip(3, CURRENT_DATE - 1, 14750, 15000);

SELECT * FROM vehicles ORDER BY vehicle_id;
SELECT * FROM trips ORDER BY trip_id;

-- =====================================================================
-- Tests for (b), (c), (d)
-- =====================================================================

-- (b) service rule. Expected: vehicle 1 = false, vehicle 2 = true, vehicle 3 = true (exactly 5000)
SELECT vehicle_id,
       registration,
       current_odometer - last_service_odometer AS km_since_service,
       fn_service_due(vehicle_id)               AS service_due
FROM vehicles
ORDER BY vehicle_id;

DO $$ BEGIN PERFORM fn_service_due(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown vehicle): %', SQLERRM; END $$;

-- (c) invalid trips. Trip count (6) and odometers must not change.
SELECT (SELECT COUNT(*) FROM trips) AS trips_before,
       (SELECT current_odometer FROM vehicles WHERE vehicle_id = 1) AS v1_odometer_before;

DO $$ BEGIN CALL pr_record_trip(999, CURRENT_DATE, 100, 200);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown vehicle): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 20800, 20800);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (end equals start): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 20800, 20700);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (end below start): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 20800, NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL end): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_record_trip(1, NULL, 20800, 20900);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL date): %', SQLERRM; END $$;

-- Start does not match the vehicle's current odometer: rejected by the trigger
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12345, 12999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (start mismatch, via trigger): %', SQLERRM; END $$;

SELECT (SELECT COUNT(*) FROM trips) AS trips_after,
       (SELECT current_odometer FROM vehicles WHERE vehicle_id = 1) AS v1_odometer_after;

-- (d) trigger tests with direct SQL. Each rejected insert leaves everything unchanged.
DO $$ BEGIN
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (1, CURRENT_DATE, 20000, 20500);          -- start does not match 20800
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct INSERT, wrong start): %', SQLERRM; END $$;

DO $$ BEGIN
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (1, CURRENT_DATE, 20800, 20700);          -- end below start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct INSERT, end below start): %', SQLERRM; END $$;

DO $$ BEGIN
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (1, CURRENT_DATE, 20800, 20800);          -- end equals start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct INSERT, end equals start): %', SQLERRM; END $$;

DO $$ BEGIN
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (1, CURRENT_DATE, -10, 100);              -- negative start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct INSERT, negative start): %', SQLERRM; END $$;

SELECT vehicle_id, current_odometer FROM vehicles ORDER BY vehicle_id;   -- unchanged

-- A valid direct insert is accepted and the odometer is updated exactly
-- once: it becomes 20900 (the trip end), not 21000 or anything doubled.
INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
VALUES (1, CURRENT_DATE, 20800, 20900);

SELECT vehicle_id, current_odometer FROM vehicles WHERE vehicle_id = 1;  -- 20900
SELECT COUNT(*) AS trips_total FROM trips;                               -- 7

-- =====================================================================
-- (e) View: v_service_due
-- Registration and kilometres since service for vehicles that currently
-- meet the 5,000 km threshold.
-- =====================================================================

CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

-- Expected: ZM 2002 B = 7000, ZM 3003 C = 5000. Vehicle 1 (2900 km) is not listed.
SELECT * FROM v_service_due ORDER BY registration;

-- =====================================================================
-- (f) Index: one vehicle's trips within a trip_on date range
-- Justification: the query filters on one vehicle_id (equality) and a
-- trip_on range. A composite index (vehicle_id, trip_on) takes PostgreSQL
-- directly to that vehicle's entries and reads only the requested dates
-- in order, instead of scanning every trip of every vehicle.
-- Equality column first, range column second.
-- =====================================================================

CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;

-- The seed table is tiny, so PostgreSQL may prefer a sequential scan.
-- This forces the planner to show index usage for demonstration only.
SET enable_seqscan = off;

EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- pr_refresh_service_alerts keeps one alert per due vehicle:
--  1. inserts an alert for each due vehicle, or updates km_since_service
--     if the alert already exists (flagged_on keeps the date it was
--     first flagged)
--  2. deletes the alert of any vehicle that is no longer due
-- Reruns are safe: the primary key on vehicle_id gives one row per vehicle.
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id,
           current_odometer - last_service_odometer,
           CURRENT_DATE
    FROM vehicles
    WHERE fn_service_due(vehicle_id)
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service;

    DELETE FROM service_alerts sa
    WHERE NOT fn_service_due(sa.vehicle_id);
END;
$$;

-- First run. Expected: vehicle 2 (7000) and vehicle 3 (5000)
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;

-- Rerun twice: still one row per due vehicle, nothing duplicated
CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;

-- Change the fleet, then refresh again:
--  vehicle 1 travels 3100 km  -> becomes due (24000 - 18000 = 6000)  -> alert inserted
--  vehicle 3 travels 400 km   -> already due, km grows to 5400       -> alert updated
--  vehicle 2 is serviced      -> no longer due                       -> alert removed
CALL pr_record_trip(1, CURRENT_DATE, 20900, 24000);
CALL pr_record_trip(3, CURRENT_DATE, 15000, 15400);
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;   -- vehicle 1 = 6000, vehicle 3 = 5400

-- Schedule with pg_cron: every Monday at 06:00
-- This block checks that pg_cron is available. If it is not (for example on
-- Windows), it prints a NOTICE and the script still finishes without an error.
-- (When pg_cron is installed it must be listed in shared_preload_libraries.
--  It runs in the cron.database_name database, usually 'postgres'; if your
--  tables are in another database use cron.schedule_in_database(...) instead.
--  Cron times use cron.timezone, default GMT.)
DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule(
            'refresh_service_alerts',
            '0 6 * * 1',
            $job$CALL pr_refresh_service_alerts()$job$
        );
        RAISE NOTICE 'pg_cron job refresh_service_alerts scheduled: 0 6 * * 1';
    ELSE
        RAISE NOTICE 'pg_cron is not available on this server, so the job was not scheduled. The schedule command is shown in the comment below.';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not schedule the pg_cron job: %', SQLERRM;
END
$do$;

-- The same schedule written as a plain command (for servers where pg_cron is installed):
-- SELECT cron.schedule('refresh_service_alerts', '0 6 * * 1', $$CALL pr_refresh_service_alerts()$$);

-- Inspect the job and its run history (uncomment where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;

-- To remove the job if needed:
-- SELECT cron.unschedule('refresh_service_alerts');
