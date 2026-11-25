-- =====================================================================
-- ICT371 Advanced Database - Question 1: Pharmacy Stock and Daily Sales
-- Database: PostgreSQL
-- Run the whole file top to bottom (psql -f q1_pharmacy.sql)
-- =====================================================================

-- Clean start so the script can be rerun
DROP VIEW      IF EXISTS v_low_stock;
DROP TABLE     IF EXISTS daily_sales  CASCADE;
DROP TABLE     IF EXISTS stock_audit  CASCADE;
DROP TABLE     IF EXISTS sales        CASCADE;
DROP TABLE     IF EXISTS medicines    CASCADE;
DROP FUNCTION  IF EXISTS fn_sale_value(INT, INT);
DROP PROCEDURE IF EXISTS pr_record_sale(INT, INT, DATE);
DROP PROCEDURE IF EXISTS pr_refresh_sales(DATE);
DROP FUNCTION  IF EXISTS trg_fn_stock_audit();

-- =====================================================================
-- (a) Database tables (seed data comes after the procedure, see below)
-- =====================================================================

CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100)  NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER       NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER       NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER       NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER   NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER   NOT NULL,
    new_qty     INTEGER   NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE          PRIMARY KEY,
    total_qty    INTEGER       NOT NULL CHECK (total_qty >= 0),
    total_amount NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0)
);

-- =====================================================================
-- (b) Function: fn_sale_value
-- =====================================================================

CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_record_sale
-- Checks stock, stores the current price, deducts stock exactly once.
-- Any RAISE EXCEPTION rolls back the whole call, so tables stay unchanged.
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;

    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date cannot be NULL';
    END IF;

    -- Lock the row so two sales cannot oversell at the same time
    SELECT unit_price, stock_qty
      INTO v_price, v_stock
      FROM medicines
     WHERE medicine_id = p_medicine_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: available %, requested %',
                        p_medicine_id, v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
       SET stock_qty = stock_qty - p_quantity
     WHERE medicine_id = p_medicine_id;
END;
$$;

-- =====================================================================
-- (d) Trigger: AFTER UPDATE row trigger on medicines
-- Logs OLD and NEW stock only when stock_qty actually changes.
-- =====================================================================

CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_fn_stock_audit();

-- =====================================================================
-- (a) continued: Seed data
-- Medicines are inserted directly (this does not fire the UPDATE trigger).
-- The six sales are loaded through pr_record_sale.
-- =====================================================================

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.00,  40),
    ('Ibuprofen 400mg',   4.00,  25),
    ('ORS Sachet',        3.00,  12);

CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(2,  5, CURRENT_DATE - 2);
CALL pr_record_sale(3, 10, CURRENT_DATE - 1);
CALL pr_record_sale(1, 20, CURRENT_DATE - 1);
CALL pr_record_sale(3,  6, CURRENT_DATE);
CALL pr_record_sale(4,  4, CURRENT_DATE);

SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;

-- =====================================================================
-- Tests for (b), (c), (d)
-- =====================================================================

-- (b) valid: 3 x 2.50 = 7.50
SELECT fn_sale_value(1, 3) AS valid_sale_value;

-- (b) invalid cases are rejected (messages appear as NOTICE)
DO $$ BEGIN PERFORM fn_sale_value(999, 2);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown medicine): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_sale_value(1, 0);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (zero quantity): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_sale_value(1, -5);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (negative quantity): %', SQLERRM; END $$;

-- (c) invalid sale: oversell. Row counts and stock must not change.
SELECT (SELECT COUNT(*) FROM sales) AS sales_before,
       (SELECT stock_qty FROM medicines WHERE medicine_id = 2) AS stock_before;

DO $$ BEGIN CALL pr_record_sale(2, 9999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (oversell): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_record_sale(999, 1, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown medicine): %', SQLERRM; END $$;

SELECT (SELECT COUNT(*) FROM sales) AS sales_after,
       (SELECT stock_qty FROM medicines WHERE medicine_id = 2) AS stock_after;

-- (d) trigger: an update that does NOT change stock must create no audit row
SELECT COUNT(*) AS audit_rows_before FROM stock_audit;
UPDATE medicines SET unit_price = unit_price WHERE medicine_id = 1;
UPDATE medicines SET stock_qty  = stock_qty  WHERE medicine_id = 1;
SELECT COUNT(*) AS audit_rows_after_no_change FROM stock_audit;

-- (d) trigger: a real stock change creates exactly one audit row
UPDATE medicines SET stock_qty = stock_qty + 5 WHERE medicine_id = 1;
SELECT COUNT(*) AS audit_rows_after_real_change FROM stock_audit;
SELECT * FROM stock_audit ORDER BY audit_id;

-- =====================================================================
-- (e) View: v_low_stock (stock_qty below 10)
-- =====================================================================

CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id,
       medicine_name,
       unit_price,
       stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- Query the view before and after a sale
SELECT * FROM v_low_stock;                 -- Ibuprofen (9) and ORS (8)
CALL pr_record_sale(2, 32, CURRENT_DATE);  -- Amoxicillin 35 -> 3, now low
SELECT * FROM v_low_stock;                 -- Amoxicillin appears too

-- =====================================================================
-- (f) Index: one medicine's sales within a sold_on date range
-- Justification: the query filters on medicine_id with equality and
-- sold_on with a range. A composite index (medicine_id, sold_on) lets
-- PostgreSQL jump straight to that medicine's entries and scan only the
-- requested date range in order, instead of reading the whole sales table.
-- Equality column goes first, range column second.
-- =====================================================================

CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;

-- The seed table is tiny, so PostgreSQL may prefer a sequential scan.
-- This forces the planner to show index usage for demonstration only.
SET enable_seqscan = off;

EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- pr_refresh_sales replaces the day's row (upsert), so reruns never
-- duplicate or double-count: totals are recalculated from sales each time.
-- A day with no sales is stored as 0 and 0.
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day cannot be NULL';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty    = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

-- Rerun test: calling it three times for the same day gives the same result
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales ORDER BY sales_date;
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales ORDER BY sales_date;   -- still one row, same totals

-- Cross-check against the raw sales
SELECT sold_on, SUM(quantity) AS qty, SUM(quantity * unit_price) AS amount
FROM sales
WHERE sold_on = CURRENT_DATE - 1
GROUP BY sold_on;

-- Schedule with pg_cron: every day at 00:15, for the previous day
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
            'refresh_daily_sales',
            '15 0 * * *',
            $job$CALL pr_refresh_sales(CURRENT_DATE - 1)$job$
        );
        RAISE NOTICE 'pg_cron job refresh_daily_sales scheduled: 15 0 * * *';
    ELSE
        RAISE NOTICE 'pg_cron is not available on this server, so the job was not scheduled. The schedule command is shown in the comment below.';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not schedule the pg_cron job: %', SQLERRM;
END
$do$;

-- The same schedule written as a plain command (for servers where pg_cron is installed):
-- SELECT cron.schedule('refresh_daily_sales', '15 0 * * *', $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$);

-- Inspect the job and its run history (uncomment where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;

-- To remove the job if needed:
-- SELECT cron.unschedule('refresh_daily_sales');
