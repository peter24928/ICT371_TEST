-- =====================================================================
-- ICT371 Advanced Database - Question 3: Library Returns and Overdue Fines
-- Database: PostgreSQL
-- Run the whole file top to bottom (psql -f q3_library.sql)
-- Fine rule: K2 per day after the due date. Returned on the due date = no fine.
-- =====================================================================

-- Clean start so the script can be rerun
DROP VIEW      IF EXISTS v_overdue_loans;
DROP TABLE     IF EXISTS overdue_summary CASCADE;
DROP TABLE     IF EXISTS loan_audit      CASCADE;
DROP TABLE     IF EXISTS loans           CASCADE;
DROP TABLE     IF EXISTS books           CASCADE;
DROP FUNCTION  IF EXISTS fn_loan_fine(INT, DATE);
DROP PROCEDURE IF EXISTS pr_return_loan(INT, DATE);
DROP PROCEDURE IF EXISTS pr_refresh_overdue(DATE);
DROP FUNCTION  IF EXISTS trg_fn_loan_audit();

-- =====================================================================
-- (a) Database tables (seed data comes after the function, procedure
--     and trigger so returns can be loaded through the procedure)
-- =====================================================================

CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER       NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100)  NOT NULL,
    borrowed_on   DATE          NOT NULL,
    due_on        DATE          NOT NULL,
    returned_on   DATE          NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrowed CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INTEGER   NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE      NULL,
    new_returned_on  DATE      NULL,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE          PRIMARY KEY,
    overdue_count INTEGER       NOT NULL CHECK (overdue_count >= 0),
    total_fine    NUMERIC(12,2) NOT NULL CHECK (total_fine >= 0)
);

-- =====================================================================
-- (b) Function: fn_loan_fine
-- K2 x overdue days, minimum zero.
-- If the loan has a return date, the earlier of p_as_of and returned_on
-- is used, so a returned loan stops accumulating fines.
-- =====================================================================

CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
    v_days     INTEGER;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'As-of date cannot be NULL';
    END IF;

    SELECT due_on, returned_on
      INTO v_due, v_returned
      FROM loans
     WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    -- Earlier of p_as_of and returned_on (if there is one)
    v_end  := LEAST(p_as_of, COALESCE(v_returned, p_as_of));
    v_days := GREATEST(v_end - v_due, 0);

    RETURN 2.00 * v_days;
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_return_loan
-- Rejects an unknown or already returned loan, and a return before
-- borrowed_on. The return date and the final fine are stored together
-- in one UPDATE.
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC(10,2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date cannot be NULL';
    END IF;

    -- Lock the loan row so it cannot be returned twice at the same time
    SELECT borrowed_on, returned_on
      INTO v_borrowed, v_returned
      FROM loans
     WHERE loan_id = p_loan_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;

    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before the borrowed date %',
                        p_returned_on, v_borrowed;
    END IF;

    -- The loan is still open here, so the function uses p_returned_on
    -- as the end date: this is the final fine.
    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
       SET returned_on = p_returned_on,
           fine_amount = v_fine
     WHERE loan_id = p_loan_id;
END;
$$;

-- =====================================================================
-- (d) Trigger: AFTER UPDATE row trigger on loans
-- Logs OLD and NEW returned_on only when the date actually changes.
-- IS DISTINCT FROM handles NULL correctly (NULL to a date counts as a change).
-- =====================================================================

CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_returned_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

-- =====================================================================
-- (a) continued: Seed data
-- Loans are inserted open, then the returned ones go through
-- pr_return_loan so the fine and the audit row are created properly.
--
--  loan 1  Alice  open, overdue (due 10 days ago)
--  loan 2  Bob    open, not yet due
--  loan 3  Carol  returned 5 days late
--  loan 4  Dan    returned exactly on the due date (on time)
--  loan 5  Eve    open, not yet due
--  loan 6  Frank  open, overdue (due 2 days ago)
-- =====================================================================

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Operating System Concepts'),
    ('Computer Networks');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Alice Mulenga', CURRENT_DATE - 20, CURRENT_DATE - 10),
    (2, 'Bob Tembo',     CURRENT_DATE - 5,  CURRENT_DATE + 9),
    (3, 'Carol Zulu',    CURRENT_DATE - 30, CURRENT_DATE - 20),
    (1, 'Dan Phiri',     CURRENT_DATE - 14, CURRENT_DATE - 7),
    (2, 'Eve Banda',     CURRENT_DATE - 3,  CURRENT_DATE + 11),
    (3, 'Frank Mwale',   CURRENT_DATE - 12, CURRENT_DATE - 2);

CALL pr_return_loan(3, CURRENT_DATE - 15);   -- 5 days late  -> K10
CALL pr_return_loan(4, CURRENT_DATE - 7);    -- on due date  -> K0

SELECT * FROM books ORDER BY book_id;
SELECT * FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;

-- =====================================================================
-- Tests for (b), (c), (d)
-- =====================================================================

-- (b) fines as of today
-- Expected: loan 1 = 20.00, loan 2 = 0, loan 3 = 10.00 (stops at return date),
--           loan 4 = 0 (returned on due date), loan 5 = 0, loan 6 = 4.00
SELECT loan_id, borrower_name, due_on, returned_on,
       fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today
FROM loans
ORDER BY loan_id;

-- (b) boundary checks on loan 1 (due 10 days ago)
SELECT fn_loan_fine(1, CURRENT_DATE - 15) AS before_due_is_zero,
       fn_loan_fine(1, CURRENT_DATE - 10) AS on_due_date_is_zero,
       fn_loan_fine(1, CURRENT_DATE - 9)  AS one_day_late_is_2;

-- (b) returned loan 3 uses the earlier of as_of and returned_on
SELECT fn_loan_fine(3, CURRENT_DATE - 17) AS as_of_before_return_is_6,
       fn_loan_fine(3, CURRENT_DATE)      AS as_of_after_return_is_10;

-- (b) invalid inputs are rejected
DO $$ BEGIN PERFORM fn_loan_fine(999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown loan): %', SQLERRM; END $$;

DO $$ BEGIN PERFORM fn_loan_fine(1, NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL date): %', SQLERRM; END $$;

-- (c) invalid returns. Returned-loan count and audit count must not change.
SELECT (SELECT COUNT(*) FROM loans WHERE returned_on IS NOT NULL) AS returned_before,
       (SELECT COUNT(*) FROM loan_audit)                          AS audit_before;

DO $$ BEGIN CALL pr_return_loan(999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown loan): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_return_loan(3, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (already returned): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_return_loan(1, CURRENT_DATE - 25);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (before borrowed date): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_return_loan(1, NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL date): %', SQLERRM; END $$;

SELECT (SELECT COUNT(*) FROM loans WHERE returned_on IS NOT NULL) AS returned_after,
       (SELECT COUNT(*) FROM loan_audit)                          AS audit_after;

-- (c) valid return: loan 2 returned today, return date and fine stored together
CALL pr_return_loan(2, CURRENT_DATE);
SELECT loan_id, due_on, returned_on, fine_amount
FROM loans
WHERE returned_on IS NOT NULL
ORDER BY loan_id;

-- (d) trigger tests. Audit rows so far: 3 (loans 3, 4, 2)
SELECT COUNT(*) AS audit_rows_start FROM loan_audit;

-- No change to returned_on -> no audit row (stays 3)
UPDATE loans SET returned_on = returned_on WHERE loan_id = 1;
UPDATE loans SET borrower_name = borrower_name WHERE loan_id = 1;
SELECT COUNT(*) AS audit_rows_after_no_change FROM loan_audit;

-- Real change by direct SQL: NULL -> date (one new row, total 4)
UPDATE loans SET returned_on = CURRENT_DATE WHERE loan_id = 5;
-- Real change back: date -> NULL (one new row, total 5). This restores loan 5.
UPDATE loans SET returned_on = NULL WHERE loan_id = 5;
SELECT COUNT(*) AS audit_rows_after_changes FROM loan_audit;

SELECT * FROM loan_audit ORDER BY audit_id;

-- =====================================================================
-- (e) View: v_overdue_loans
-- Loans currently unreturned and due before today, with the fine as of today.
-- =====================================================================

CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title                              AS book_title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- Expected: loan 1 (fine 20.00) and loan 6 (fine 4.00)
SELECT * FROM v_overdue_loans ORDER BY loan_id;

-- Return loan 6 (late): it leaves the view
CALL pr_return_loan(6, CURRENT_DATE);
SELECT * FROM v_overdue_loans ORDER BY loan_id;   -- only loan 1 remains

-- =====================================================================
-- (f) Index: a given book's unreturned loans
-- Justification: the search filters on one book_id and returned_on IS NULL.
-- A partial index on (book_id) WHERE returned_on IS NULL stores only open
-- loans. It stays small (returned loans are the majority over time), is
-- fast to search, and PostgreSQL can use it directly because the query
-- repeats the same WHERE returned_on IS NULL condition.
-- =====================================================================

CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;

-- The seed table is tiny, so PostgreSQL may prefer a sequential scan.
-- This forces the planner to show index usage for demonstration only.
SET enable_seqscan = off;

EXPLAIN
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;

RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- pr_refresh_overdue counts loans still unreturned as of p_as_of and sums
-- their fines as of that date. A loan returned after p_as_of still counts,
-- because it was unreturned on that date (fn_loan_fine already handles this
-- by using the earlier of p_as_of and returned_on).
-- ON CONFLICT replaces the same snapshot_date, so reruns never duplicate.
--
-- If your lecturer wants only OVERDUE loans counted, add this line to the
-- WHERE clause below:   AND due_on < p_as_of
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'As-of date cannot be NULL';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine    = EXCLUDED.total_fine;
END;
$$;

-- Rerun test: today's snapshot three times gives the same single row.
-- Expected now: loans 1 and 5 are unreturned -> count 2, total fine 20.00
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary ORDER BY snapshot_date;
CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary ORDER BY snapshot_date;   -- still one row for today

-- Past date test: as of 5 days ago. Expected: count 3 (loans 1, 2, 6), total fine 10.00
CALL pr_refresh_overdue(CURRENT_DATE - 5);
SELECT * FROM overdue_summary ORDER BY snapshot_date;

-- Schedule with pg_cron: every day at 00:10, for CURRENT_DATE
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
            'refresh_overdue_summary',
            '10 0 * * *',
            $job$CALL pr_refresh_overdue(CURRENT_DATE)$job$
        );
        RAISE NOTICE 'pg_cron job refresh_overdue_summary scheduled: 10 0 * * *';
    ELSE
        RAISE NOTICE 'pg_cron is not available on this server, so the job was not scheduled. The schedule command is shown in the comment below.';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not schedule the pg_cron job: %', SQLERRM;
END
$do$;

-- The same schedule written as a plain command (for servers where pg_cron is installed):
-- SELECT cron.schedule('refresh_overdue_summary', '10 0 * * *', $$CALL pr_refresh_overdue(CURRENT_DATE)$$);

-- Inspect the job and its run history (uncomment where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;

-- To remove the job if needed:
-- SELECT cron.unschedule('refresh_overdue_summary');
