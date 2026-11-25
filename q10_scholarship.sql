-- =====================================================================
-- ICT371 Advanced Database - Question 10: Scholarship Application Assessment
-- Database: PostgreSQL
-- Run the whole file top to bottom (psql -f q10_scholarship.sql)
-- Eligible only when: age 18 to 25 inclusive, monthly household income
-- at most K3,000, and average mark at least 70.
-- Statuses: PENDING, APPROVED, REJECTED.
-- =====================================================================

-- Clean start so the script can be rerun
DROP VIEW      IF EXISTS v_approved_applicants;
DROP TABLE     IF EXISTS decision_audit CASCADE;
DROP TABLE     IF EXISTS applications   CASCADE;
DROP TABLE     IF EXISTS students       CASCADE;
DROP FUNCTION  IF EXISTS fn_scholarship_eligible(INT, NUMERIC, NUMERIC);
DROP PROCEDURE IF EXISTS pr_assess_application(INT);
DROP PROCEDURE IF EXISTS pr_assess_pending();
DROP FUNCTION  IF EXISTS trg_fn_decision_audit();

-- =====================================================================
-- (a) Database tables (seed data comes after the function and procedure)
-- =====================================================================

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER       NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE          NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT chk_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER     NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP   NOT NULL DEFAULT now()
);

-- =====================================================================
-- (b) Function: fn_scholarship_eligible
-- TRUE only when all three rules pass. Rejects NULL inputs, negative
-- income, non-positive age and marks outside 0 to 100.
-- =====================================================================

CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INTEGER,
    p_income NUMERIC,
    p_mark   NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark cannot be NULL';
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Invalid age: % (must be positive)', p_age;
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Invalid income: % (cannot be negative)', p_income;
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Invalid mark: % (must be between 0 and 100)', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_assess_application
-- Requires an existing PENDING application, calls the function, and sets
-- the status to APPROVED or REJECTED. Raises a clear exception for an
-- unknown or already assessed application. The row is locked first so it
-- cannot be assessed twice at the same time.
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_status VARCHAR(10);
    v_age    INTEGER;
    v_income NUMERIC(12,2);
    v_mark   NUMERIC(5,2);
BEGIN
    SELECT status, age_at_application, monthly_income, average_mark
      INTO v_status, v_age, v_income, v_mark
      FROM applications
     WHERE application_id = p_application_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status %)',
                        p_application_id, v_status;
    END IF;

    IF fn_scholarship_eligible(v_age, v_income, v_mark) THEN
        UPDATE applications SET status = 'APPROVED' WHERE application_id = p_application_id;
    ELSE
        UPDATE applications SET status = 'REJECTED' WHERE application_id = p_application_id;
    END IF;
END;
$$;

-- =====================================================================
-- (d) Trigger: AFTER UPDATE row trigger on applications
-- Records OLD and NEW status with a timestamp, only when the status
-- actually changes (WHEN clause with IS DISTINCT FROM).
-- =====================================================================

CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- =====================================================================
-- (a) continued: Seed data
-- Six PENDING applications across four students, with qualifying,
-- non-qualifying and boundary cases.
--
--  1  student 1: 18, K3000.00, 70.00 -> eligible (all three boundaries, inclusive)
--  2  student 2: 25, K1200.00, 88.50 -> eligible (upper age boundary)
--  3  student 3: 17, K1000.00, 90.00 -> not eligible (age just below 18)
--  4  student 4: 22, K3000.01, 85.00 -> not eligible (income just above K3000)
--  5  student 2: 21, K2000.00, 69.99 -> not eligible (mark just below 70)
--  6  student 3: 26, K1500.00, 95.00 -> not eligible (age just above 25)
-- =====================================================================

INSERT INTO students (student_number, full_name) VALUES
    ('S2026201', 'Mutale Bwalya'),
    ('S2026202', 'Chola Mumba'),
    ('S2026203', 'Nkandu Sinkala'),
    ('S2026204', 'Lweendo Hachamba');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 40, 'PENDING'),
    (2, 25, 1200.00, 88.50, CURRENT_DATE - 35, 'PENDING'),
    (3, 17, 1000.00, 90.00, CURRENT_DATE - 30, 'PENDING'),
    (4, 22, 3000.01, 85.00, CURRENT_DATE - 20, 'PENDING'),
    (2, 21, 2000.00, 69.99, CURRENT_DATE - 10, 'PENDING'),
    (3, 26, 1500.00, 95.00, CURRENT_DATE - 5,  'PENDING');

SELECT * FROM students ORDER BY student_id;
SELECT * FROM applications ORDER BY application_id;

-- =====================================================================
-- Tests for (b), (c), (d)
-- =====================================================================

-- (b) boundary cases. Expected: true, true, false, false, false, false
SELECT age, income, mark, fn_scholarship_eligible(age, income, mark) AS eligible
FROM (VALUES
    (18, 3000.00, 70.00),     -- all boundaries inclusive
    (25, 3000.00, 70.00),     -- upper age boundary
    (17, 3000.00, 70.00),     -- age just below
    (26, 3000.00, 70.00),     -- age just above
    (18, 3000.01, 70.00),     -- income just above
    (18, 3000.00, 69.99)      -- mark just below
) AS t(age, income, mark);

-- (b) invalid inputs are rejected
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL age): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_scholarship_eligible(20, NULL, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL income): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 1000, NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL mark): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (negative income): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 1000, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (age zero): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_scholarship_eligible(-5, 1000, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (negative age): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 1000, -1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (mark below 0): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 1000, 100.01);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (mark above 100): %', SQLERRM; END $$;

-- (c) assess two applications: 1 (eligible) -> APPROVED, 3 (age 17) -> REJECTED
CALL pr_assess_application(1);
CALL pr_assess_application(3);
SELECT application_id, status FROM applications ORDER BY application_id;

-- (c) invalid assessments. Statuses and audit rows must not change.
SELECT COUNT(*) AS audit_before FROM decision_audit;       -- 2

DO $$ BEGIN CALL pr_assess_application(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown application): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_assess_application(1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (already approved): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_assess_application(3);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (already rejected): %', SQLERRM; END $$;

SELECT COUNT(*) AS audit_after FROM decision_audit;        -- still 2

-- (d) trigger tests
-- An update that keeps the same status creates no audit row (stays 2)
UPDATE applications SET status = 'PENDING' WHERE application_id = 2;
UPDATE applications SET average_mark = average_mark WHERE application_id = 2;
SELECT COUNT(*) AS audit_after_no_status_change FROM decision_audit;

-- The two real changes made by the procedure were logged with OLD and NEW values
SELECT * FROM decision_audit ORDER BY audit_id;

-- Table constraint rejects an invalid status
DO $$ BEGIN
    UPDATE applications SET status = 'MAYBE' WHERE application_id = 2;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (invalid status): %', SQLERRM; END $$;

-- =====================================================================
-- (e) View: v_approved_applicants
-- APPROVED applications only. Household income is deliberately left out.
-- =====================================================================

CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- Expected now: only application 1 (S2026201, 70.00). Application 2 is still PENDING.
SELECT * FROM v_approved_applicants ORDER BY student_number;

-- =====================================================================
-- (f) Index: applications searched by status within a submitted_on range
-- Justification: the search uses equality on status and a range on
-- submitted_on. A composite index (status, submitted_on) takes PostgreSQL
-- to the rows with that status, already ordered by date, and reads only
-- the requested date range, instead of scanning every application.
-- Equality column first, range column second.
-- =====================================================================

CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;

-- The seed table is tiny, so PostgreSQL may prefer a sequential scan.
-- This forces the planner to show index usage for demonstration only.
SET enable_seqscan = off;

EXPLAIN
SELECT application_id, student_id, submitted_on
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 60 AND CURRENT_DATE;

RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- pr_assess_pending uses a query FOR loop over PENDING applications only
-- and sends each one through pr_assess_application. Completed applications
-- are never selected, so a rerun reassesses nothing and creates no extra
-- audit rows.
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

-- Before: applications 2, 4, 5 and 6 are still PENDING
SELECT application_id, status FROM applications ORDER BY application_id;
SELECT COUNT(*) AS audit_before_job FROM decision_audit;     -- 2

CALL pr_assess_pending();
-- Expected: 1 APPROVED, 2 APPROVED, 3 REJECTED, 4 REJECTED, 5 REJECTED, 6 REJECTED
SELECT application_id, status FROM applications ORDER BY application_id;
SELECT COUNT(*) AS audit_after_job FROM decision_audit;      -- 6 (4 new rows)

-- Rerun twice: nothing is reassessed, no duplicate audit rows
CALL pr_assess_pending();
CALL pr_assess_pending();
SELECT application_id, status FROM applications ORDER BY application_id;
SELECT COUNT(*) AS audit_after_reruns FROM decision_audit;   -- still 6

SELECT * FROM decision_audit ORDER BY audit_id;

-- The view now shows both approved applicants
SELECT * FROM v_approved_applicants ORDER BY student_number;

-- Schedule with pg_cron: every Monday at 08:00
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
            'assess_pending_applications',
            '0 8 * * 1',
            $job$CALL pr_assess_pending()$job$
        );
        RAISE NOTICE 'pg_cron job assess_pending_applications scheduled: 0 8 * * 1';
    ELSE
        RAISE NOTICE 'pg_cron is not available on this server, so the job was not scheduled. The schedule command is shown in the comment below.';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not schedule the pg_cron job: %', SQLERRM;
END
$do$;

-- The same schedule written as a plain command (for servers where pg_cron is installed):
-- SELECT cron.schedule('assess_pending_applications', '0 8 * * 1', $$CALL pr_assess_pending()$$);

-- Inspect the job and its run history (uncomment where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;

-- To remove the job if needed:
-- SELECT cron.unschedule('assess_pending_applications');
