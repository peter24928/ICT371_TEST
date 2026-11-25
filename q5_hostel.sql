-- =====================================================================
-- ICT371 Advanced Database - Question 5: Hostel Room Allocation
-- Database: PostgreSQL
-- Run the whole file top to bottom (psql -f q5_hostel.sql)
-- Rules: a room cannot exceed its capacity. A student may have only one
-- ACTIVE allocation. ENDED allocations are history and occupy no bed.
-- =====================================================================

-- Clean start so the script can be rerun
DROP VIEW      IF EXISTS v_room_occupancy;
DROP TABLE     IF EXISTS occupancy_snapshot CASCADE;
DROP TABLE     IF EXISTS allocations        CASCADE;
DROP TABLE     IF EXISTS rooms              CASCADE;
DROP TABLE     IF EXISTS students           CASCADE;
DROP FUNCTION  IF EXISTS fn_free_beds(INT);
DROP PROCEDURE IF EXISTS pr_allocate_room(INT, INT, DATE);
DROP PROCEDURE IF EXISTS pr_refresh_occupancy();
DROP FUNCTION  IF EXISTS trg_fn_allocation_rules();

-- =====================================================================
-- (a) Database tables (seed data comes after the procedure and trigger)
-- =====================================================================

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER     NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER     NOT NULL REFERENCES students(student_id),
    room_id       INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE        NOT NULL,
    released_on   DATE        NULL,
    status        VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
    CONSTRAINT chk_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
    -- ACTIVE requires released_on NULL; ENDED requires a release date
    CONSTRAINT chk_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL)
    ),
    CONSTRAINT chk_release_after_alloc CHECK (released_on IS NULL OR released_on >= allocated_on)
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE    NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL CHECK (occupied_beds >= 0),
    free_beds     INTEGER NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

-- =====================================================================
-- (b) Function: fn_free_beds
-- Capacity minus the number of ACTIVE allocations. ENDED ones are ignored.
-- =====================================================================

CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    SELECT capacity INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_allocate_room
-- Validates IDs, makes sure the student has no ACTIVE allocation, checks
-- availability, and creates one ACTIVE allocation with released_on NULL.
-- The room row is locked so two requests cannot take the last bed together.
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INTEGER,
    p_room_id      INTEGER,
    p_allocated_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date cannot be NULL';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT capacity INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full (capacity %)', p_room_id, v_capacity;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- =====================================================================
-- (d) Trigger: BEFORE INSERT OR UPDATE row trigger on allocations
-- Enforces capacity and one ACTIVE allocation per student for direct SQL.
-- When counting other allocations, the row being updated is excluded
-- (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id), so updating
-- an allocation in a full room does not wrongly fail.
-- Only ACTIVE rows are checked: ENDED rows occupy no bed.
-- The room and student rows are locked to stop concurrent clashes.
-- =====================================================================

CREATE OR REPLACE FUNCTION trg_fn_allocation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity     INTEGER;
    v_other_active INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT capacity INTO v_capacity
        FROM rooms
        WHERE room_id = NEW.room_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
        END IF;

        PERFORM 1 FROM students WHERE student_id = NEW.student_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown student_id: %', NEW.student_id;
        END IF;

        -- One ACTIVE allocation per student
        IF EXISTS (
            SELECT 1
            FROM allocations a
            WHERE a.student_id = NEW.student_id
              AND a.status = 'ACTIVE'
              AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id)
        ) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        -- Capacity check
        SELECT COUNT(*) INTO v_other_active
        FROM allocations a
        WHERE a.room_id = NEW.room_id
          AND a.status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id);

        IF v_other_active >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocation_rules();

-- =====================================================================
-- (a) continued: Seed data
--
--  Room 101 (capacity 2): full          (students 1 and 2)
--  Room 102 (capacity 3): partly full   (students 3 and 4)
--  Room 103 (capacity 2): empty, only an ENDED allocation (student 5)
--  Room 104 (capacity 4): empty, never used
--  Student 6 has no allocation yet.
-- The ACTIVE allocations go through pr_allocate_room. The ENDED history
-- row is inserted directly.
-- =====================================================================

INSERT INTO students (student_number, full_name) VALUES
    ('S2026101', 'Chileshe Mwansa'),
    ('S2026102', 'Namukolo Sakala'),
    ('S2026103', 'Kelvin Mumba'),
    ('S2026104', 'Thandiwe Lungu'),
    ('S2026105', 'Brian Chola'),
    ('S2026106', 'Grace Mukuka');

INSERT INTO rooms (room_number, capacity) VALUES
    ('101', 2),
    ('102', 3),
    ('103', 2),
    ('104', 4);

CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 20);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 15);
CALL pr_allocate_room(4, 2, CURRENT_DATE - 10);

INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (5, 3, CURRENT_DATE - 60, CURRENT_DATE - 10, 'ENDED');

SELECT * FROM students ORDER BY student_id;
SELECT * FROM rooms ORDER BY room_id;
SELECT * FROM allocations ORDER BY allocation_id;

-- =====================================================================
-- Tests for (b), (c), (d)
-- =====================================================================

-- (b) free beds. Expected: room 1 = 0, room 2 = 1, room 3 = 2 (the ENDED
-- allocation does not reduce availability), room 4 = 4
SELECT room_id, room_number, capacity, fn_free_beds(room_id) AS free_beds
FROM rooms
ORDER BY room_id;

DO $$ BEGIN PERFORM fn_free_beds(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown room): %', SQLERRM; END $$;

-- (c) valid allocation: student 5 (only has ENDED history) into room 103
CALL pr_allocate_room(5, 3, CURRENT_DATE);
SELECT * FROM allocations WHERE student_id = 5 ORDER BY allocation_id;
SELECT fn_free_beds(3) AS room_103_free_beds_is_1;

-- (c) invalid allocations. Counts must not change (6 total, 5 ACTIVE).
SELECT (SELECT COUNT(*) FROM allocations)                     AS allocations_before,
       (SELECT COUNT(*) FROM allocations WHERE status = 'ACTIVE') AS active_before;

DO $$ BEGIN CALL pr_allocate_room(999, 4, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown student): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_allocate_room(6, 999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown room): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_allocate_room(1, 4, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (student already ACTIVE): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_allocate_room(6, 1, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (room full): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_allocate_room(6, 4, NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL date): %', SQLERRM; END $$;

SELECT (SELECT COUNT(*) FROM allocations)                     AS allocations_after,
       (SELECT COUNT(*) FROM allocations WHERE status = 'ACTIVE') AS active_after;

-- (d) trigger tests with direct SQL

-- Direct INSERT into a full room is rejected
DO $$ BEGIN
    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (6, 1, CURRENT_DATE, NULL, 'ACTIVE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct INSERT, room full): %', SQLERRM; END $$;

-- Direct INSERT giving a student a second ACTIVE allocation is rejected
DO $$ BEGIN
    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (1, 4, CURRENT_DATE, NULL, 'ACTIVE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct INSERT, second ACTIVE): %', SQLERRM; END $$;

-- UPDATE reactivating student 5's ENDED row is rejected (student 5 has an ACTIVE row)
DO $$ BEGIN
    UPDATE allocations SET status = 'ACTIVE', released_on = NULL WHERE allocation_id = 5;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (UPDATE, second ACTIVE): %', SQLERRM; END $$;

-- UPDATE of a row in a FULL room is allowed: the row is excluded from its own count
UPDATE allocations SET allocated_on = allocated_on WHERE allocation_id = 1;

-- Table constraints also reject inconsistent status/release data
DO $$ BEGIN
    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (6, 4, CURRENT_DATE, CURRENT_DATE, 'ACTIVE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (ACTIVE with release date): %', SQLERRM; END $$;

DO $$ BEGIN
    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (6, 4, CURRENT_DATE, NULL, 'ENDED');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (ENDED without release date): %', SQLERRM; END $$;

-- Ending an allocation frees the bed: end student 2's allocation (id 2)
UPDATE allocations SET status = 'ENDED', released_on = CURRENT_DATE WHERE allocation_id = 2;
SELECT fn_free_beds(1) AS room_101_free_beds_is_1;

-- Student 6 can now take that bed
CALL pr_allocate_room(6, 1, CURRENT_DATE);

-- Room 101 is full again: moving allocation 3 into it is rejected
DO $$ BEGIN
    UPDATE allocations SET room_id = 1 WHERE allocation_id = 3;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (UPDATE move into full room): %', SQLERRM; END $$;

SELECT * FROM allocations ORDER BY allocation_id;

-- =====================================================================
-- (e) View: v_room_occupancy
-- Every room with capacity, occupied beds and free beds. The LEFT JOIN
-- (with the ACTIVE filter in the ON clause) keeps rooms with no allocations.
-- =====================================================================

CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id
      AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

-- Expected: 101 = 2 occupied, 0 free; 102 = 2, 1; 103 = 1, 1; 104 = 0, 4
SELECT * FROM v_room_occupancy ORDER BY room_id;

-- =====================================================================
-- (f) Index: ACTIVE allocations filtered by room_id
-- Justification: occupancy checks, fn_free_beds, the trigger and the view
-- all count ACTIVE allocations for one room. A partial index on (room_id)
-- WHERE status = 'ACTIVE' holds only the rows that occupy beds, so it
-- stays small even as ENDED history grows, and lets PostgreSQL jump
-- straight to a room's ACTIVE rows. The query must repeat
-- status = 'ACTIVE' so the planner can use it.
-- =====================================================================

CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;

-- The seed table is tiny, so PostgreSQL may prefer a sequential scan.
-- This forces the planner to show index usage for demonstration only.
SET enable_seqscan = off;

EXPLAIN
SELECT allocation_id, student_id, allocated_on
FROM allocations
WHERE room_id = 2
  AND status = 'ACTIVE';

RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- pr_refresh_occupancy stores CURRENT_DATE occupancy for every room, one
-- row per (date, room). ON CONFLICT replaces the values on a rerun, so
-- nothing is duplicated.
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
        SET occupied_beds = EXCLUDED.occupied_beds,
            free_beds     = EXCLUDED.free_beds;
END;
$$;

-- Rerun test: three calls leave exactly one row per room (4 rows)
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();
SELECT COUNT(*) AS snapshot_rows_is_4 FROM occupancy_snapshot;

-- Values are replaced, not added: end student 5's allocation, then rerun.
-- Room 103 changes from 1 occupied / 1 free to 0 occupied / 2 free.
UPDATE allocations SET status = 'ENDED', released_on = CURRENT_DATE WHERE allocation_id = 6;
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;   -- still 4 rows

-- Schedule with pg_cron: every day at 23:55
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
            'refresh_occupancy',
            '55 23 * * *',
            $job$CALL pr_refresh_occupancy()$job$
        );
        RAISE NOTICE 'pg_cron job refresh_occupancy scheduled: 55 23 * * *';
    ELSE
        RAISE NOTICE 'pg_cron is not available on this server, so the job was not scheduled. The schedule command is shown in the comment below.';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not schedule the pg_cron job: %', SQLERRM;
END
$do$;

-- The same schedule written as a plain command (for servers where pg_cron is installed):
-- SELECT cron.schedule('refresh_occupancy', '55 23 * * *', $$CALL pr_refresh_occupancy()$$);

-- Inspect the job and its run history (uncomment where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;

-- To remove the job if needed:
-- SELECT cron.unschedule('refresh_occupancy');
