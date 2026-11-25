-- =====================================================================
-- ICT371 Advanced Database - Question 9: Farmer Cooperative Maize Deliveries
-- Database: PostgreSQL
-- Run the whole file top to bottom (psql -f q9_maize.sql)
-- Prices: grade A = K5 per kg, grade B = K4, grade C = K3.
-- unit_rate and total_value are always set by the trigger, so direct SQL
-- follows the same pricing rule as the procedure.
-- =====================================================================

-- Clean start so the script can be rerun
DROP VIEW      IF EXISTS v_farmer_amount_due;
DROP TABLE     IF EXISTS daily_purchases CASCADE;
DROP TABLE     IF EXISTS deliveries      CASCADE;
DROP TABLE     IF EXISTS farmers         CASCADE;
DROP FUNCTION  IF EXISTS fn_maize_rate(VARCHAR);
DROP PROCEDURE IF EXISTS pr_receive_delivery(INT, VARCHAR, NUMERIC, DATE);
DROP PROCEDURE IF EXISTS pr_refresh_purchases(DATE);
DROP FUNCTION  IF EXISTS trg_fn_price_delivery();

-- =====================================================================
-- (a) Database tables (seed data comes after the trigger is installed)
-- unit_rate and total_value are NOT NULL, but the BEFORE trigger fills
-- them in before the constraint is checked.
-- =====================================================================

CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER       NOT NULL REFERENCES farmers(farmer_id),
    grade        VARCHAR(1)    NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10,2) NOT NULL CHECK (unit_rate > 0),
    total_value  NUMERIC(12,2) NOT NULL CHECK (total_value > 0),
    delivered_on DATE          NOT NULL,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE          PRIMARY KEY,
    total_weight  NUMERIC(12,2) NOT NULL CHECK (total_weight >= 0),
    total_value   NUMERIC(14,2) NOT NULL CHECK (total_value  >= 0)
);

-- =====================================================================
-- (b) Function: fn_maize_rate
-- Returns the rate for grade A, B or C. Rejects NULL or any other grade.
-- =====================================================================

CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade VARCHAR)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL';
    END IF;

    CASE p_grade
        WHEN 'A' THEN RETURN 5.00;
        WHEN 'B' THEN RETURN 4.00;
        WHEN 'C' THEN RETURN 3.00;
        ELSE
            RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
    END CASE;
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_receive_delivery
-- Rejects unknown farmers and invalid inputs. Inserts only the basic
-- fields with is_paid FALSE. The trigger supplies unit_rate and total_value.
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     VARCHAR,
    p_weight    NUMERIC,
    p_date      DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date cannot be NULL';
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Invalid weight: % (must be greater than zero)', p_weight;
    END IF;

    PERFORM fn_maize_rate(p_grade);          -- raises for NULL or unsupported grade

    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- =====================================================================
-- (d) Trigger: BEFORE INSERT OR UPDATE row trigger on deliveries
-- Rejects non-positive weight, calls fn_maize_rate, and sets
-- NEW.unit_rate and NEW.total_value. Whatever values direct SQL supplies
-- for those two columns are overwritten, so the pricing rule always applies.
-- =====================================================================

CREATE OR REPLACE FUNCTION trg_fn_price_delivery()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Invalid weight: % (must be greater than zero)', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_price
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_price_delivery();

-- =====================================================================
-- (a) continued: Seed data (loaded after the trigger is installed)
-- unit_rate and total_value are NOT supplied: the trigger prices each row.
-- Covers all three grades and both payment states.
--
--  1  farmer 1, A, 100 kg,  paid     -> 500.00
--  2  farmer 1, B,  80 kg,  unpaid   -> 320.00
--  3  farmer 2, C, 150 kg,  paid     -> 450.00
--  4  farmer 2, A, 60.5 kg, paid     -> 302.50
--  5  farmer 3, B, 200 kg,  unpaid   -> 800.00
--  6  farmer 3, C,  40 kg,  paid     -> 120.00
-- Farmer 2 has no unpaid deliveries.
-- =====================================================================

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Mulenga Chisanga'),
    ('F002', 'Bwalya Mutale'),
    ('F003', 'Nsofwa Kapambwe');

INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
    (1, 'A', 100.00, CURRENT_DATE - 6, TRUE),
    (1, 'B',  80.00, CURRENT_DATE - 5, FALSE),
    (2, 'C', 150.00, CURRENT_DATE - 5, TRUE),
    (2, 'A',  60.50, CURRENT_DATE - 3, TRUE),
    (3, 'B', 200.00, CURRENT_DATE - 2, FALSE),
    (3, 'C',  40.00, CURRENT_DATE - 1, TRUE);

SELECT * FROM farmers ORDER BY farmer_id;
SELECT * FROM deliveries ORDER BY delivery_id;

-- =====================================================================
-- Tests for (b), (c), (d)
-- =====================================================================

-- (b) rates. Expected: A = 5.00, B = 4.00, C = 3.00
SELECT g AS grade, fn_maize_rate(g) AS rate
FROM (VALUES ('A'), ('B'), ('C')) AS t(g);

DO $$ BEGIN PERFORM fn_maize_rate(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL grade): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_maize_rate('D');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unsupported grade D): %', SQLERRM; END $$;

-- (c) invalid deliveries. The delivery count (6) must not change.
SELECT COUNT(*) AS deliveries_before FROM deliveries;

DO $$ BEGIN CALL pr_receive_delivery(999, 'A', 10, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown farmer): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_delivery(NULL, 'A', 10, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL farmer): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_delivery(1, 'A', 0, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (zero weight): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (negative weight): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_delivery(1, 'A', NULL, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL weight): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_delivery(1, 'D', 10, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unsupported grade): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_delivery(1, NULL, 10, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL grade): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_delivery(1, 'A', 10, NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL date): %', SQLERRM; END $$;

SELECT COUNT(*) AS deliveries_after FROM deliveries;

-- (c) valid delivery: farmer 3, grade A, 12.5 kg -> rate 5.00, total 62.50, unpaid
CALL pr_receive_delivery(3, 'A', 12.5, CURRENT_DATE);
SELECT * FROM deliveries WHERE delivery_id = 7;

-- (d) trigger: direct SQL cannot bypass the pricing rule.
-- The supplied rate 99 and total 9999 are overwritten: rate 3.00, total 30.00.
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
VALUES (1, 'C', 10, 99.00, 9999.00, CURRENT_DATE, FALSE);
SELECT delivery_id, grade, weight_kg, unit_rate, total_value
FROM deliveries
WHERE delivery_id = 8;

DELETE FROM deliveries WHERE delivery_id = 8;     -- remove the test row

-- (d) trigger rejects non-positive weight and unsupported grades in direct SQL
DO $$ BEGIN
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on)
    VALUES (1, 'A', 0, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct INSERT, zero weight): %', SQLERRM; END $$;

DO $$ BEGIN
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on)
    VALUES (1, 'A', -3, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct INSERT, negative weight): %', SQLERRM; END $$;

DO $$ BEGIN
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on)
    VALUES (1, 'D', 10, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct INSERT, grade D): %', SQLERRM; END $$;

-- (d) trigger on UPDATE: the value is recalculated whenever a row is changed
UPDATE deliveries SET weight_kg = 20 WHERE delivery_id = 7;        -- A: 20 x 5 = 100.00
SELECT delivery_id, grade, weight_kg, unit_rate, total_value FROM deliveries WHERE delivery_id = 7;

UPDATE deliveries SET grade = 'B' WHERE delivery_id = 7;           -- B: 20 x 4 = 80.00
SELECT delivery_id, grade, weight_kg, unit_rate, total_value FROM deliveries WHERE delivery_id = 7;

UPDATE deliveries SET total_value = 1 WHERE delivery_id = 7;       -- tampering is overwritten: 80.00
SELECT delivery_id, grade, weight_kg, unit_rate, total_value FROM deliveries WHERE delivery_id = 7;

DO $$ BEGIN
    UPDATE deliveries SET weight_kg = -1 WHERE delivery_id = 7;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (UPDATE, negative weight): %', SQLERRM; END $$;

-- Restore delivery 7 to its original values (grade A, 12.5 kg -> 62.50)
UPDATE deliveries SET grade = 'A', weight_kg = 12.5 WHERE delivery_id = 7;
SELECT delivery_id, grade, weight_kg, unit_rate, total_value FROM deliveries WHERE delivery_id = 7;

-- =====================================================================
-- (e) View: v_farmer_amount_due
-- Each farmer's number, name and total unpaid delivery value. The LEFT JOIN
-- keeps farmers with no unpaid deliveries, and COALESCE shows them as 0.
-- =====================================================================

CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE d.is_paid = FALSE), 0) AS total_unpaid
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- Expected: F001 = 320.00, F002 = 0.00 (nothing unpaid), F003 = 862.50 (800 + 62.50)
SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

-- =====================================================================
-- (f) Index: a farmer's deliveries between two dates
-- Justification: the query filters on one farmer_id (equality) and a
-- delivered_on range. A composite index (farmer_id, delivered_on) takes
-- PostgreSQL directly to that farmer's entries and reads only the
-- requested dates, instead of scanning all deliveries.
-- Equality column first, range column second.
-- =====================================================================

CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;

-- The seed table is tiny, so PostgreSQL may prefer a sequential scan.
-- This forces the planner to show index usage for demonstration only.
SET enable_seqscan = off;

EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value, delivered_on
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 10 AND CURRENT_DATE;

RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- pr_refresh_purchases stores the purchased weight and value for one date.
-- It recalculates from deliveries each time and uses ON CONFLICT to
-- replace the row, so repeated runs never add totals twice.
-- A day with no deliveries is stored as 0 and 0.
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day cannot be NULL';
    END IF;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day,
           COALESCE(SUM(weight_kg), 0),
           COALESCE(SUM(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
        SET total_weight = EXCLUDED.total_weight,
            total_value  = EXCLUDED.total_value;
END;
$$;

-- Rerun test. Five days ago has deliveries 2 and 3.
-- Expected: weight 230.00 (80 + 150), value 770.00 (320 + 450)
CALL pr_refresh_purchases(CURRENT_DATE - 5);
SELECT * FROM daily_purchases ORDER BY purchase_date;
CALL pr_refresh_purchases(CURRENT_DATE - 5);
CALL pr_refresh_purchases(CURRENT_DATE - 5);
SELECT * FROM daily_purchases ORDER BY purchase_date;   -- one row, still 230.00 / 770.00

-- A new delivery on that day, then rerun: totals are REPLACED, not added.
-- Expected: weight 240.00, value 820.00 (not 470 / 1590)
CALL pr_receive_delivery(1, 'A', 10, CURRENT_DATE - 5);
CALL pr_refresh_purchases(CURRENT_DATE - 5);
SELECT * FROM daily_purchases ORDER BY purchase_date;
CALL pr_refresh_purchases(CURRENT_DATE - 5);
SELECT * FROM daily_purchases ORDER BY purchase_date;   -- still 240.00 / 820.00

-- Today has only delivery 7: expected 12.50 kg and 62.50
CALL pr_refresh_purchases(CURRENT_DATE);
SELECT * FROM daily_purchases ORDER BY purchase_date;

-- Cross-check against the raw deliveries
SELECT delivered_on, SUM(weight_kg) AS weight, SUM(total_value) AS value
FROM deliveries
WHERE delivered_on IN (CURRENT_DATE - 5, CURRENT_DATE)
GROUP BY delivered_on
ORDER BY delivered_on;

-- Schedule with pg_cron: every day at 01:30, for the previous day
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
            'refresh_daily_purchases',
            '30 1 * * *',
            $job$CALL pr_refresh_purchases(CURRENT_DATE - 1)$job$
        );
        RAISE NOTICE 'pg_cron job refresh_daily_purchases scheduled: 30 1 * * *';
    ELSE
        RAISE NOTICE 'pg_cron is not available on this server, so the job was not scheduled. The schedule command is shown in the comment below.';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not schedule the pg_cron job: %', SQLERRM;
END
$do$;

-- The same schedule written as a plain command (for servers where pg_cron is installed):
-- SELECT cron.schedule('refresh_daily_purchases', '30 1 * * *', $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);

-- Inspect the job and its run history (uncomment where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;

-- To remove the job if needed:
-- SELECT cron.unschedule('refresh_daily_purchases');
