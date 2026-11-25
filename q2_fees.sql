-- =====================================================================
-- ICT371 Advanced Database - Question 2: University Fee Payments
-- Database: PostgreSQL
-- Run the whole file top to bottom (psql -f q2_fees.sql)
-- =====================================================================

-- Clean start so the script can be rerun
DROP VIEW      IF EXISTS v_fee_balances;
DROP TABLE     IF EXISTS daily_collections CASCADE;
DROP TABLE     IF EXISTS payment_audit     CASCADE;
DROP TABLE     IF EXISTS payments          CASCADE;
DROP TABLE     IF EXISTS students          CASCADE;
DROP FUNCTION  IF EXISTS fn_fee_balance(INT);
DROP PROCEDURE IF EXISTS pr_receive_payment(INT, NUMERIC, DATE);
DROP PROCEDURE IF EXISTS pr_refresh_collections(DATE);
DROP FUNCTION  IF EXISTS trg_fn_payment_audit();

-- =====================================================================
-- (a) Database tables (seed data comes after the procedure and trigger)
-- fee_due is never changed by payments. Balance = fee_due - SUM(payments).
-- =====================================================================

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)   NOT NULL UNIQUE,
    full_name      VARCHAR(100)  NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER       NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP     NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE          PRIMARY KEY,
    payment_count   INTEGER       NOT NULL CHECK (payment_count >= 0),
    total_amount    NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0)
);

-- =====================================================================
-- (b) Function: fn_fee_balance
-- Returns fee_due minus total payments. A student with no payments
-- gets the full fee (COALESCE turns the NULL sum into 0).
-- =====================================================================

CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee  NUMERIC(12,2);
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_receive_payment
-- Rejects NULL, zero or negative amounts and payments above the balance.
-- It inserts the payment only. It does NOT touch fee_due and does NOT
-- write the audit row (the trigger in part (d) does that).
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount     NUMERIC,
    p_paid_on    DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount: % (must be greater than zero)', p_amount;
    END IF;

    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date cannot be NULL';
    END IF;

    -- Lock the student row so two payments cannot overpay at the same time
    PERFORM 1
    FROM students
    WHERE student_id = p_student_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % for student %',
                        p_amount, v_balance, p_student_id;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- =====================================================================
-- (d) Trigger: AFTER INSERT row trigger on payments
-- Writes payment ID, student ID, amount and timestamp to payment_audit.
-- =====================================================================

CREATE OR REPLACE FUNCTION trg_fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

-- =====================================================================
-- (a) continued: Seed data
-- Three students with different balances. Student 3 has no payments.
-- All seven payments are loaded through pr_receive_payment, so the
-- trigger creates the audit rows automatically.
-- =====================================================================

INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('S2026001', 'Mwansa Chilufya', 5000.00),
    ('S2026002', 'Banda Joseph',    3000.00),
    ('S2026003', 'Phiri Natasha',   4500.00);

CALL pr_receive_payment(1, 1000.00, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 2);
CALL pr_receive_payment(1,  500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE);
CALL pr_receive_payment(1,  200.00, CURRENT_DATE);

SELECT * FROM students ORDER BY student_id;
SELECT * FROM payments ORDER BY payment_id;
SELECT * FROM payment_audit ORDER BY audit_id;

-- =====================================================================
-- Tests for (b), (c), (d)
-- Expected balances: student 1 = 1800, student 2 = 0, student 3 = 4500
-- =====================================================================

-- (b) valid balances, including the student with no payments (full fee)
SELECT student_id,
       fee_due,
       fn_fee_balance(student_id) AS balance
FROM students
ORDER BY student_id;

-- (b) unknown student is rejected
DO $$ BEGIN PERFORM fn_fee_balance(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown student): %', SQLERRM; END $$;

-- (c) invalid payments. Payment and audit counts must not change.
SELECT (SELECT COUNT(*) FROM payments)      AS payments_before,
       (SELECT COUNT(*) FROM payment_audit) AS audit_before;

DO $$ BEGIN CALL pr_receive_payment(3, NULL, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL amount): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_payment(3, 0, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (zero amount): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_payment(3, -100, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (negative amount): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_payment(3, 4600, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (above balance): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_payment(2, 1, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (fully settled student): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_receive_payment(999, 100, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown student): %', SQLERRM; END $$;

SELECT (SELECT COUNT(*) FROM payments)      AS payments_after,
       (SELECT COUNT(*) FROM payment_audit) AS audit_after;

-- (c) fee_due is unchanged by payments
SELECT student_id, fee_due FROM students ORDER BY student_id;

-- (d) trigger check: every payment has exactly one audit row, and the
-- procedure never inserted any audit row itself
SELECT p.payment_id,
       COUNT(a.audit_id) AS audit_rows
FROM payments p
LEFT JOIN payment_audit a ON a.payment_id = p.payment_id
GROUP BY p.payment_id
ORDER BY p.payment_id;

-- =====================================================================
-- (e) View: v_fee_balances
-- Students who still owe fees. Fully settled students are excluded.
-- =====================================================================

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(p.total_paid, 0) AS outstanding_balance
FROM students s
LEFT JOIN (
    SELECT student_id, SUM(amount) AS total_paid
    FROM payments
    GROUP BY student_id
) p ON p.student_id = s.student_id
WHERE s.fee_due - COALESCE(p.total_paid, 0) > 0;

-- Before: students 1 and 3 appear, student 2 (settled) does not
SELECT * FROM v_fee_balances ORDER BY student_number;

-- Settle student 1 completely, then query again: only student 3 remains
CALL pr_receive_payment(1, 1800.00, CURRENT_DATE);
SELECT * FROM v_fee_balances ORDER BY student_number;

-- =====================================================================
-- (f) Index: payments filtered by student_id and a paid_on date range
-- Justification: the query uses equality on student_id and a range on
-- paid_on. A composite index (student_id, paid_on) lets PostgreSQL go
-- straight to one student's entries and read only the requested date
-- range in order, instead of scanning the whole payments table.
-- Equality column first, range column second.
-- =====================================================================

CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;

-- The seed table is tiny, so PostgreSQL may prefer a sequential scan.
-- This forces the planner to show index usage for demonstration only.
SET enable_seqscan = off;

EXPLAIN
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- pr_refresh_collections stores the payment count and total for one date.
-- ON CONFLICT replaces an existing summary row, so reruns never
-- duplicate or double-count. A day with no payments is stored as 0 and 0.
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day cannot be NULL';
    END IF;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day,
           COUNT(*),
           COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
        SET payment_count = EXCLUDED.payment_count,
            total_amount  = EXCLUDED.total_amount;
END;
$$;

-- Rerun test: calling it three times for the same day gives the same result
CALL pr_refresh_collections(CURRENT_DATE);
SELECT * FROM daily_collections ORDER BY collection_date;
CALL pr_refresh_collections(CURRENT_DATE);
CALL pr_refresh_collections(CURRENT_DATE);
SELECT * FROM daily_collections ORDER BY collection_date;  -- still one row, same totals

-- Cross-check against the raw payments
SELECT paid_on, COUNT(*) AS payment_count, SUM(amount) AS total_amount
FROM payments
WHERE paid_on = CURRENT_DATE
GROUP BY paid_on;

-- Schedule with pg_cron: every day at 01:00, for the previous day
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
            'refresh_daily_collections',
            '0 1 * * *',
            $job$CALL pr_refresh_collections(CURRENT_DATE - 1)$job$
        );
        RAISE NOTICE 'pg_cron job refresh_daily_collections scheduled: 0 1 * * *';
    ELSE
        RAISE NOTICE 'pg_cron is not available on this server, so the job was not scheduled. The schedule command is shown in the comment below.';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not schedule the pg_cron job: %', SQLERRM;
END
$do$;

-- The same schedule written as a plain command (for servers where pg_cron is installed):
-- SELECT cron.schedule('refresh_daily_collections', '0 1 * * *', $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);

-- Inspect the job and its run history (uncomment where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;

-- To remove the job if needed:
-- SELECT cron.unschedule('refresh_daily_collections');
