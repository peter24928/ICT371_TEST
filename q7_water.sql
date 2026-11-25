-- =====================================================================
-- ICT371 Advanced Database - Question 7: Water Meter Readings and Billing
-- Database: PostgreSQL
-- Run the whole file top to bottom (psql -f q7_water.sql)
-- Tariff: first 10 units K5 each, units above 10 cost K8 each. Zero units = K0.
-- =====================================================================

-- Clean start so the script can be rerun
DROP VIEW      IF EXISTS v_overdue_bills;
DROP TABLE     IF EXISTS receivable_snapshot CASCADE;
DROP TABLE     IF EXISTS bills               CASCADE;
DROP TABLE     IF EXISTS readings            CASCADE;
DROP TABLE     IF EXISTS customers           CASCADE;
DROP FUNCTION  IF EXISTS fn_water_charge(NUMERIC);
DROP PROCEDURE IF EXISTS pr_generate_bill(INT, DATE);
DROP PROCEDURE IF EXISTS pr_refresh_receivables();
DROP FUNCTION  IF EXISTS trg_fn_check_reading();

-- =====================================================================
-- (a) Database tables (seed data comes after the function, procedure
--     and trigger)
-- =====================================================================

CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER       NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE          NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading  >= 0),
    -- reading_month must be the first date of a month
    CONSTRAINT chk_reading_month_start CHECK (EXTRACT(DAY FROM reading_month) = 1),
    CONSTRAINT uq_customer_month       UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER       NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    -- amount_paid must be between zero and the charge
    CONSTRAINT chk_amount_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE          PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL CHECK (total_due >= 0)
);

-- =====================================================================
-- (b) Function: fn_water_charge
-- Two tariff bands. Rejects NULL or negative units. ROUND(..., 2) gives
-- an exact two-decimal charge.
-- =====================================================================

CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION 'Consumption cannot be NULL';
    END IF;

    IF p_units < 0 THEN
        RAISE EXCEPTION 'Consumption cannot be negative: %', p_units;
    END IF;

    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);                        -- first band: K5 per unit
    END IF;

    RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);            -- K50 + K8 for each unit above 10
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_generate_bill
-- Derives consumption (current - previous), calls the function, and
-- inserts a bill with amount_paid zero. Rejects an unknown reading and a
-- reading that already has a bill.
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_previous NUMERIC(10,2);
    v_current  NUMERIC(10,2);
    v_charge   NUMERIC(12,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date cannot be NULL';
    END IF;

    -- Lock the reading so two calls cannot create two bills for it
    SELECT previous_reading, current_reading
      INTO v_previous, v_current
      FROM readings
     WHERE reading_id = p_reading_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_current - v_previous);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

-- =====================================================================
-- (d) Trigger: BEFORE INSERT OR UPDATE row trigger on readings
-- Rejects current_reading below previous_reading, including direct SQL
-- imports. The exception aborts the statement, so a rejected reading
-- is never stored.
-- =====================================================================

CREATE OR REPLACE FUNCTION trg_fn_check_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Current reading (%) is below previous reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_reading();

-- =====================================================================
-- (a) continued: Seed data
-- Three customers, six readings covering zero, exactly 10 and above 10
-- units, over two month-start dates.
--
--  reading 1: customer 1, 2 months ago,  0 units  -> K0.00
--  reading 2: customer 1, last month,   10 units  -> K50.00
--  reading 3: customer 2, 2 months ago,  8 units  -> K40.00
--  reading 4: customer 2, last month,   15 units  -> K90.00
--  reading 5: customer 3, 2 months ago, 30 units  -> K210.00
--  reading 6: customer 3, last month,    0 units  -> K0.00
-- =====================================================================

INSERT INTO customers (full_name) VALUES
    ('Chipo Mwanza'),
    ('Daniel Kabwe'),
    ('Esther Lungu');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, (date_trunc('month', CURRENT_DATE)::date - INTERVAL '2 months')::date, 100, 100),
    (1, (date_trunc('month', CURRENT_DATE)::date - INTERVAL '1 month')::date,  100, 110),
    (2, (date_trunc('month', CURRENT_DATE)::date - INTERVAL '2 months')::date,  50,  58),
    (2, (date_trunc('month', CURRENT_DATE)::date - INTERVAL '1 month')::date,   58,  73),
    (3, (date_trunc('month', CURRENT_DATE)::date - INTERVAL '2 months')::date, 200, 230),
    (3, (date_trunc('month', CURRENT_DATE)::date - INTERVAL '1 month')::date,  230, 230);

-- Bills for readings 1 to 5 through the procedure (reading 6 is left unbilled
-- on purpose, for the tests below). Different due dates give overdue and
-- not-yet-due bills.
CALL pr_generate_bill(1, CURRENT_DATE - 40);
CALL pr_generate_bill(2, CURRENT_DATE - 10);
CALL pr_generate_bill(3, CURRENT_DATE - 20);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(5, CURRENT_DATE - 5);

-- Payments: bill 3 paid in full, bill 5 partly paid
UPDATE bills SET amount_paid = charge WHERE bill_id = 3;
UPDATE bills SET amount_paid = 100    WHERE bill_id = 5;

SELECT * FROM customers ORDER BY customer_id;
SELECT * FROM readings ORDER BY reading_id;
SELECT * FROM bills ORDER BY bill_id;

-- =====================================================================
-- Tests for (b), (c), (d)
-- =====================================================================

-- (b) tariff bands. Expected: 0.00, 25.00, 50.00, 54.00, 90.00, 210.00
SELECT units, fn_water_charge(units) AS charge
FROM (VALUES (0), (5), (10), (10.5), (15), (30)) AS t(units);

DO $$ BEGIN PERFORM fn_water_charge(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL units): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_water_charge(-3);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (negative units): %', SQLERRM; END $$;

-- (c) valid bill: reading 6 (0 units) -> charge 0.00, amount_paid 0
CALL pr_generate_bill(6, CURRENT_DATE + 15);

-- (c) valid bill for a new above-10 reading: customer 1, current month, 15 units -> 90.00
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
VALUES (1, date_trunc('month', CURRENT_DATE)::date, 110, 125);

CALL pr_generate_bill(7, CURRENT_DATE + 20);
SELECT * FROM bills WHERE bill_id IN (6, 7) ORDER BY bill_id;

-- (c) invalid bills. The bill count must not change (stays 7).
SELECT COUNT(*) AS bills_before FROM bills;

DO $$ BEGIN CALL pr_generate_bill(999, CURRENT_DATE + 5);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown reading): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_generate_bill(2, CURRENT_DATE + 5);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (already billed): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_generate_bill(7, NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL due date): %', SQLERRM; END $$;

SELECT COUNT(*) AS bills_after FROM bills;

-- (d) trigger: a reading below the previous one is rejected and NOT stored
SELECT COUNT(*) AS readings_before FROM readings;   -- 7

DO $$ BEGIN
    INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
    VALUES (2, date_trunc('month', CURRENT_DATE)::date, 73, 70);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct INSERT, current < previous): %', SQLERRM; END $$;

-- An UPDATE that makes current_reading too low is rejected too
DO $$ BEGIN
    UPDATE readings SET current_reading = 50 WHERE reading_id = 4;   -- previous is 58
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (UPDATE, current < previous): %', SQLERRM; END $$;

SELECT COUNT(*) AS readings_after FROM readings;    -- still 7
SELECT reading_id, previous_reading, current_reading FROM readings WHERE reading_id = 4;  -- still 73

-- A valid direct insert is accepted (current equal to previous = zero units)
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
VALUES (2, date_trunc('month', CURRENT_DATE)::date, 73, 73);

-- Table constraints also reject bad data
DO $$ BEGIN
    INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
    VALUES (3, date_trunc('month', CURRENT_DATE)::date + 3, 230, 240);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (not a month start): %', SQLERRM; END $$;

DO $$ BEGIN
    UPDATE bills SET amount_paid = 9999 WHERE bill_id = 2;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (amount_paid above charge): %', SQLERRM; END $$;

-- =====================================================================
-- (e) View: v_overdue_bills
-- Customer name, due date and outstanding amount, where due_on is before
-- today and the bill is not fully paid.
-- =====================================================================

CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT b.bill_id,
       c.full_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings  r ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- Expected: bill 2 (Chipo Mwanza, 50.00) and bill 5 (Esther Lungu, 110.00).
-- Bill 3 is fully paid, bill 4 is not due yet, bills 1 and 6 have zero charge.
SELECT * FROM v_overdue_bills ORDER BY due_on;

-- =====================================================================
-- (f) Index: date-based searches for overdue bills
-- Justification: overdue searches only care about bills that are not fully
-- paid and whose due date has passed. A partial index on (due_on) WHERE
-- amount_paid < charge holds only unpaid bills, so it stays small as paid
-- bills pile up, and it supports the range condition due_on < today.
-- The query repeats the same unpaid condition so the planner can use it.
-- =====================================================================

CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;

-- The seed table is tiny, so PostgreSQL may prefer a sequential scan.
-- This forces the planner to show index usage for demonstration only.
SET enable_seqscan = off;

EXPLAIN
SELECT bill_id, reading_id, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE;

RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- pr_refresh_receivables stores today's total of unpaid bill balances
-- (charge - amount_paid over all bills). ON CONFLICT replaces the same
-- date's total, so reruns never add to it.
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE,
           COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    ON CONFLICT (snapshot_date) DO UPDATE
        SET total_due = EXCLUDED.total_due;
END;
$$;

-- Rerun test. Expected total: 50 + 0 + 90 + 110 + 90 = 340.00
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot ORDER BY snapshot_date;
CALL pr_refresh_receivables();
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot ORDER BY snapshot_date;   -- one row, still 340.00

-- A payment changes the balance; the rerun REPLACES the total (340 - 30 = 310)
UPDATE bills SET amount_paid = 30 WHERE bill_id = 4;
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot ORDER BY snapshot_date;   -- one row, 310.00

-- Cross-check against the raw bills
SELECT SUM(charge - amount_paid) AS unpaid_total FROM bills;

-- Schedule with pg_cron: every day at 00:30
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
            'refresh_receivables',
            '30 0 * * *',
            $job$CALL pr_refresh_receivables()$job$
        );
        RAISE NOTICE 'pg_cron job refresh_receivables scheduled: 30 0 * * *';
    ELSE
        RAISE NOTICE 'pg_cron is not available on this server, so the job was not scheduled. The schedule command is shown in the comment below.';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not schedule the pg_cron job: %', SQLERRM;
END
$do$;

-- The same schedule written as a plain command (for servers where pg_cron is installed):
-- SELECT cron.schedule('refresh_receivables', '30 0 * * *', $$CALL pr_refresh_receivables()$$);

-- Inspect the job and its run history (uncomment where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;

-- To remove the job if needed:
-- SELECT cron.unschedule('refresh_receivables');
