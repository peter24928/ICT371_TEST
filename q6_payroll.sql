-- =====================================================================
-- ICT371 Advanced Database - Question 6: Monthly Payroll Processing
-- Database: PostgreSQL
-- Run the whole file top to bottom (psql -f q6_payroll.sql)
-- Gross pay = basic salary + allowance. Net pay = gross pay - deduction.
-- Existing payroll rows are kept unchanged when a month is processed again.
-- =====================================================================

-- Clean start so the script can be rerun
DROP VIEW      IF EXISTS v_payroll_report;
DROP TABLE     IF EXISTS salary_audit CASCADE;
DROP TABLE     IF EXISTS payroll      CASCADE;
DROP TABLE     IF EXISTS employees    CASCADE;
DROP FUNCTION  IF EXISTS fn_net_pay(INT);
DROP PROCEDURE IF EXISTS pr_process_payroll(DATE);
DROP FUNCTION  IF EXISTS trg_fn_salary_audit();

-- =====================================================================
-- (a) Database tables (seed data comes after the function, procedure
--     and trigger)
-- =====================================================================

CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance    >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction    >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay   >= 0),
    -- pay_month must be the first date of a month
    CONSTRAINT chk_pay_month_start CHECK (EXTRACT(DAY FROM pay_month) = 1),
    CONSTRAINT uq_employee_month   UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP     NOT NULL DEFAULT now()
);

-- =====================================================================
-- (b) Function: fn_net_pay
-- Net pay from the employee's CURRENT salary, allowance and deduction.
-- Rejects an unknown employee or a negative computed net pay.
-- =====================================================================

CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic     NUMERIC(12,2);
    v_allowance NUMERIC(12,2);
    v_deduction NUMERIC(12,2);
    v_net       NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction
      INTO v_basic, v_allowance, v_deduction
      FROM employees
     WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := (v_basic + v_allowance) - v_deduction;

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_process_payroll
-- Query FOR loop over ACTIVE employees. Requires a month-start date.
-- Inserts each missing employee/month row and leaves an existing row
-- unchanged. If any calculation is invalid (fn_net_pay raises), the
-- exception aborts the whole call and every row it inserted is rolled back.
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    rec   RECORD;
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL THEN
        RAISE EXCEPTION 'Payroll month cannot be NULL';
    END IF;

    IF EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'Payroll month must be the first day of a month, got %', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active
        ORDER BY employee_id
    LOOP
        -- Existing payroll row: leave it unchanged
        CONTINUE WHEN EXISTS (
            SELECT 1 FROM payroll
            WHERE employee_id = rec.employee_id
              AND pay_month   = p_month
        );

        v_net := fn_net_pay(rec.employee_id);   -- raises on an invalid calculation

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, rec.basic_salary + rec.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- =====================================================================
-- (d) Trigger: AFTER UPDATE row trigger on employees
-- Logs OLD and NEW basic_salary only when it actually changes.
-- =====================================================================

CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- =====================================================================
-- (a) continued: Seed data
--
--  Employee 1, 2, 3: active when payroll is processed for two past months
--  Employee 3 is deactivated afterwards (keeps historical payroll rows)
--  Employee 4: inactive from the start (no payroll)
--
-- Payroll for the two previous months is loaded through pr_process_payroll.
-- pay_month values are first-of-month dates.
-- =====================================================================

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Mwila Chanda',      8000.00, 1500.00, 1200.00, TRUE),
    ('Njavwa Mulenga',    6000.00, 1000.00,  900.00, TRUE),
    ('Kabwe Zulu',        7000.00,  800.00, 1000.00, TRUE),
    ('Mutinta Hamoonga',  5000.00,  500.00,  700.00, FALSE);

-- Two previous months (first day of each month)
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE)::date - INTERVAL '2 months')::date);
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE)::date - INTERVAL '1 month')::date);

-- Employee 3 leaves: deactivate (not a salary change, so no audit row)
UPDATE employees SET active = FALSE WHERE employee_id = 3;

SELECT * FROM employees ORDER BY employee_id;
SELECT * FROM payroll ORDER BY pay_month, employee_id;

-- =====================================================================
-- Tests for (b), (c), (d)
-- =====================================================================

-- (b) net pay. Expected: 1 = 8300.00, 2 = 6100.00, 3 = 6800.00, 4 = 4800.00
SELECT employee_id, full_name, fn_net_pay(employee_id) AS net_pay
FROM employees
ORDER BY employee_id;

DO $$ BEGIN PERFORM fn_net_pay(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown employee): %', SQLERRM; END $$;

-- (c) invalid month arguments are rejected
DO $$ BEGIN CALL pr_process_payroll(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL month): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_process_payroll(date_trunc('month', CURRENT_DATE)::date + 5);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (not a month start): %', SQLERRM; END $$;

-- (c) one invalid employee fails the WHOLE call.
-- Employee 5 has a deduction larger than gross pay, so net pay is negative.
-- Employees 1 and 2 are valid, but NO row may be stored for this month.
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active)
VALUES ('Test Negative Net', 100.00, 0.00, 500.00, TRUE);

DO $$ BEGIN PERFORM fn_net_pay(5);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (negative net pay): %', SQLERRM; END $$;

SELECT COUNT(*) AS payroll_rows_before FROM payroll;      -- 6

DO $$ BEGIN CALL pr_process_payroll(date_trunc('month', CURRENT_DATE)::date);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Whole call failed: %', SQLERRM; END $$;

SELECT COUNT(*) AS payroll_rows_after_failed_call FROM payroll;   -- still 6

-- Remove the test employee, then process the current month for real.
-- Active employees are now 1 and 2, so exactly 2 rows are added (total 8).
DELETE FROM employees WHERE employee_id = 5;

CALL pr_process_payroll(date_trunc('month', CURRENT_DATE)::date);
SELECT COUNT(*) AS payroll_rows_after_valid_call FROM payroll;    -- 8

-- Running the same month again changes nothing
CALL pr_process_payroll(date_trunc('month', CURRENT_DATE)::date);
SELECT COUNT(*) AS payroll_rows_after_rerun FROM payroll;         -- still 8

-- (d) trigger tests
SELECT COUNT(*) AS audit_rows_start FROM salary_audit;            -- 0

-- No change to basic_salary -> no audit row (stays 0)
UPDATE employees SET basic_salary = basic_salary WHERE employee_id = 1;
UPDATE employees SET allowance = allowance + 100 WHERE employee_id = 2;   -- other column
UPDATE employees SET allowance = allowance - 100 WHERE employee_id = 2;   -- restore
SELECT COUNT(*) AS audit_rows_after_no_salary_change FROM salary_audit;

-- Real change: employee 1 raise 8000 -> 9000 (one audit row)
UPDATE employees SET basic_salary = 9000.00 WHERE employee_id = 1;
SELECT * FROM salary_audit ORDER BY audit_id;

-- Existing payroll rows stay unchanged when the month is processed again:
-- employee 1's current-month row still shows the old gross (9500.00),
-- although the current salary would now give 10500.00.
CALL pr_process_payroll(date_trunc('month', CURRENT_DATE)::date);
SELECT employee_id, pay_month, gross_pay, net_pay
FROM payroll
WHERE employee_id = 1
ORDER BY pay_month;

-- Restore employee 1's salary (second audit row: 9000 -> 8000)
UPDATE employees SET basic_salary = 8000.00 WHERE employee_id = 1;
SELECT * FROM salary_audit ORDER BY audit_id;

-- =====================================================================
-- (e) View: v_payroll_report
-- Joins employee names to their payroll rows. There is NO filter on
-- employees.active, so historical rows of employees who later became
-- inactive (employee 3) are still included.
-- =====================================================================

CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- Proof: payroll rows of an inactive employee are still reported
SELECT v.*
FROM v_payroll_report v
JOIN employees e ON e.employee_id = v.employee_id
WHERE e.active = FALSE
ORDER BY v.pay_month;

-- =====================================================================
-- (f) Index: report filtered by pay_month across all employees
-- Justification: the existing unique index is on (employee_id, pay_month).
-- Its leading column is employee_id, so it cannot efficiently answer
-- "all employees for one month". A separate index on (pay_month) alone
-- lets PostgreSQL jump straight to that month's rows. It is not a
-- duplicate of the unique index because the leading column is different.
-- =====================================================================

CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;

-- The seed table is tiny, so PostgreSQL may prefer a sequential scan.
-- This forces the planner to show index usage for demonstration only.
SET enable_seqscan = off;

EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = date_trunc('month', CURRENT_DATE)::date;

RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- Runs pr_process_payroll at 02:00 on the 1st of every month, passing the
-- first date of the PREVIOUS month. Because existing rows are left
-- unchanged, running it again never duplicates or alters payroll.
-- =====================================================================

-- What the job will run, tried by hand now (the previous month is already
-- processed, so this adds no rows)
SELECT COUNT(*) AS payroll_rows_before_manual_run FROM payroll;
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE)::date - INTERVAL '1 month')::date);
SELECT COUNT(*) AS payroll_rows_after_manual_run FROM payroll;   -- unchanged

-- Schedule with pg_cron: 02:00 on day 1 of each month
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
            'process_monthly_payroll',
            '0 2 1 * *',
            $job$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE)::date - INTERVAL '1 month')::date)$job$
        );
        RAISE NOTICE 'pg_cron job process_monthly_payroll scheduled: 0 2 1 * *';
    ELSE
        RAISE NOTICE 'pg_cron is not available on this server, so the job was not scheduled. The schedule command is shown in the comment below.';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not schedule the pg_cron job: %', SQLERRM;
END
$do$;

-- The same schedule written as a plain command (for servers where pg_cron is installed):
-- SELECT cron.schedule('process_monthly_payroll', '0 2 1 * *', $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE)::date - INTERVAL '1 month')::date)$$);

-- Inspect the job and its run history (uncomment where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active
-- FROM cron.job
-- WHERE jobname = 'process_monthly_payroll';
-- Inspect the run history (status, message and times of each run)
-- SELECT j.jobname, d.runid, d.status, d.return_message, d.start_time, d.end_time
-- FROM cron.job j
-- LEFT JOIN cron.job_run_details d ON d.jobid = j.jobid
-- WHERE j.jobname = 'process_monthly_payroll'
-- ORDER BY d.start_time DESC
-- LIMIT 10;

-- To remove the job if needed:
-- SELECT cron.unschedule('process_monthly_payroll');
