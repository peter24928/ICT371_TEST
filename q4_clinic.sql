-- =====================================================================
-- ICT371 Advanced Database - Question 4: Clinic Appointment Scheduling
-- Database: PostgreSQL
-- Run the whole file top to bottom (psql -f q4_clinic.sql)
-- Slots: 09:00, 10:00, 11:00, 12:00. Two non-cancelled appointments
-- must never share the same doctor, date and slot.
-- =====================================================================

-- Clean start so the script can be rerun
DROP VIEW      IF EXISTS v_today_appointments;
DROP TABLE     IF EXISTS clinic_summary CASCADE;
DROP TABLE     IF EXISTS appointments   CASCADE;
DROP TABLE     IF EXISTS patients       CASCADE;
DROP TABLE     IF EXISTS doctors        CASCADE;
DROP FUNCTION  IF EXISTS fn_daily_load(INT, DATE);
DROP PROCEDURE IF EXISTS pr_book_appointment(INT, INT, DATE, TIME);
DROP PROCEDURE IF EXISTS pr_refresh_clinic_summary(DATE);
DROP FUNCTION  IF EXISTS trg_fn_check_clash();

-- =====================================================================
-- (a) Database tables (seed data comes after the trigger, so the
--     slot rule is enforced while the data is loaded)
-- =====================================================================

CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER     NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER     NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE        NOT NULL,
    slot_time       TIME        NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT chk_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED')),
    CONSTRAINT chk_slot   CHECK (slot_time IN (TIME '09:00', TIME '10:00',
                                               TIME '11:00', TIME '12:00'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE    PRIMARY KEY,
    booked_count    INTEGER NOT NULL CHECK (booked_count    >= 0),
    attended_count  INTEGER NOT NULL CHECK (attended_count  >= 0),
    cancelled_count INTEGER NOT NULL CHECK (cancelled_count >= 0)
);

-- =====================================================================
-- (b) Function: fn_daily_load
-- Number of the doctor's NON-cancelled appointments on a day.
-- Returns 0 when there are none. Rejects an unknown doctor.
-- =====================================================================

CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_load INTEGER;
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day cannot be NULL';
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_load
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_load;   -- COUNT gives 0 when there are no rows
END;
$$;

-- =====================================================================
-- (c) Procedure: pr_book_appointment
-- Validates IDs, rejects a past date or unsupported slot, and inserts a
-- BOOKED appointment. A slot clash is rejected by the trigger in (d).
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id  INTEGER,
    p_day        DATE,
    p_slot       TIME
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL OR p_slot IS NULL THEN
        RAISE EXCEPTION 'Day and slot cannot be NULL';
    END IF;

    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book a past date: %', p_day;
    END IF;

    IF p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- =====================================================================
-- (d) Trigger: BEFORE INSERT OR UPDATE row trigger on appointments
-- Rejects a clash with another non-cancelled appointment (same doctor,
-- date and slot). On UPDATE the row being changed is excluded from the
-- clash search. A CANCELLED row never occupies a slot, so it is not checked.
-- The doctor row is locked first so two simultaneous bookings for the
-- same doctor cannot both pass the check.
-- =====================================================================

CREATE OR REPLACE FUNCTION trg_fn_check_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        PERFORM 1 FROM doctors WHERE doctor_id = NEW.doctor_id FOR UPDATE;

        IF EXISTS (
            SELECT 1
            FROM appointments a
            WHERE a.doctor_id       = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time       = NEW.slot_time
              AND a.status         <> 'CANCELLED'
              AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)
        ) THEN
            RAISE EXCEPTION 'Slot clash: doctor % already has an appointment on % at %',
                            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_clash();

-- =====================================================================
-- (a) continued: Seed data
-- Three patients, three doctors, six appointments with no slot clash.
-- Appointments are inserted directly (not through the procedure) because
-- ATTENDED and past-dated rows are needed, and the procedure rejects
-- past dates. The trigger still validates every row.
--
--  1  patient 1, doctor 1, yesterday 09:00, ATTENDED
--  2  patient 2, doctor 1, yesterday 10:00, ATTENDED
--  3  patient 3, doctor 2, yesterday 09:00, CANCELLED
--  4  patient 1, doctor 1, today     09:00, BOOKED
--  5  patient 2, doctor 2, today     09:00, BOOKED
--  6  patient 3, doctor 1, today     10:00, BOOKED
-- =====================================================================

INSERT INTO patients (full_name) VALUES
    ('Chanda Mutale'),
    ('Bwalya Kasonde'),
    ('Mapalo Ngoma');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Mulenga Kunda'),
    ('Dr. Tembo Phiri'),
    ('Dr. Zulu Banda');

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
    (2, 1, CURRENT_DATE - 1, '10:00', 'ATTENDED'),
    (3, 2, CURRENT_DATE - 1, '09:00', 'CANCELLED'),
    (1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
    (2, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
    (3, 1, CURRENT_DATE,     '10:00', 'BOOKED');

SELECT * FROM patients ORDER BY patient_id;
SELECT * FROM doctors ORDER BY doctor_id;
SELECT * FROM appointments ORDER BY appointment_id;

-- =====================================================================
-- Tests for (b), (c), (d)
-- =====================================================================

-- (b) daily load
-- Expected: doctor 1 = 2 today, 2 yesterday; doctor 2 = 1 today, 0 yesterday
--           (its only yesterday appointment is cancelled); doctor 3 = 0 and 0
SELECT d.doctor_id,
       d.full_name,
       fn_daily_load(d.doctor_id, CURRENT_DATE)     AS today_load,
       fn_daily_load(d.doctor_id, CURRENT_DATE - 1) AS yesterday_load
FROM doctors d
ORDER BY d.doctor_id;

-- (b) a day with no bookings returns 0; unknown doctor is rejected
SELECT fn_daily_load(1, CURRENT_DATE + 30) AS empty_day_is_zero;

DO $$ BEGIN PERFORM fn_daily_load(999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown doctor): %', SQLERRM; END $$;

-- (c) valid booking: patient 2 with doctor 3 tomorrow at 10:00
CALL pr_book_appointment(2, 3, CURRENT_DATE + 1, '10:00');
SELECT * FROM appointments WHERE doctor_id = 3;

-- (c) invalid bookings. The appointment count must not change (stays 7).
SELECT COUNT(*) AS appointments_before FROM appointments;

DO $$ BEGIN CALL pr_book_appointment(999, 1, CURRENT_DATE + 1, '11:00');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown patient): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_book_appointment(1, 999, CURRENT_DATE + 1, '11:00');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown doctor): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '11:00');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (past date): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '13:00');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unsupported slot 13:00): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '09:30');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unsupported slot 09:30): %', SQLERRM; END $$;

DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (slot clash via trigger): %', SQLERRM; END $$;

SELECT COUNT(*) AS appointments_after FROM appointments;

-- (d) trigger tests with direct SQL

-- Direct INSERT into a taken slot is rejected
DO $$ BEGIN
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (2, 1, CURRENT_DATE, '09:00', 'BOOKED');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct INSERT clash): %', SQLERRM; END $$;

-- UPDATE moving appointment 6 into doctor 1's 09:00 slot is rejected
DO $$ BEGIN
    UPDATE appointments SET slot_time = '09:00' WHERE appointment_id = 6;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (UPDATE clash): %', SQLERRM; END $$;

-- UPDATE that keeps the same slot is allowed: the row is excluded from
-- its own clash search
UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 4;

-- A cancelled appointment does not block its slot:
-- cancel appointment 5, then book the same doctor/day/slot for patient 3 (allowed)
UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = 5;
CALL pr_book_appointment(3, 2, CURRENT_DATE, '09:00');

-- ...but un-cancelling appointment 5 now clashes with the new booking
DO $$ BEGIN
    UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 5;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (un-cancel clash): %', SQLERRM; END $$;

-- Table constraints also reject bad direct data
DO $$ BEGIN
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (1, 3, CURRENT_DATE + 2, '09:00', 'DONE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (invalid status): %', SQLERRM; END $$;

DO $$ BEGIN
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (1, 3, CURRENT_DATE + 2, '15:00', 'BOOKED');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (invalid slot): %', SQLERRM; END $$;

SELECT * FROM appointments ORDER BY appointment_id;

-- =====================================================================
-- (e) View: v_today_appointments
-- Today's BOOKED appointments with patient name, doctor name and slot.
-- It exposes no patient IDs or other patient data.
-- =====================================================================

CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.slot_time,
       p.full_name AS patient_name,
       d.full_name AS doctor_name
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

-- Expected: three rows (the cancelled appointment 5 is not shown)
SELECT * FROM v_today_appointments ORDER BY slot_time, doctor_name;

-- =====================================================================
-- (f) Index: appointments searched by appointment_day and doctor_id
-- Justification: the search filters on a day and a doctor. A composite
-- non-unique index (appointment_day, doctor_id) finds those rows directly
-- instead of scanning the whole table. appointment_day is the leading
-- column, so the same index also serves day-only queries such as the
-- daily summary and today's list. It supports the clash check in the
-- trigger and fn_daily_load, which filter the same way.
-- It is non-unique because one doctor has several appointments on a day.
-- =====================================================================

CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

-- The seed table is tiny, so PostgreSQL may prefer a sequential scan.
-- This forces the planner to show index usage for demonstration only.
SET enable_seqscan = off;

EXPLAIN
SELECT appointment_id, patient_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;

RESET enable_seqscan;

-- =====================================================================
-- (g) Scheduled job
-- pr_refresh_clinic_summary counts each of the three statuses for one
-- appointment date. ON CONFLICT replaces the existing row, so reruns never
-- duplicate or double-count. A date with no appointments is stored as 0, 0, 0.
-- =====================================================================

CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day cannot be NULL';
    END IF;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count    = EXCLUDED.booked_count,
            attended_count  = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

-- Rerun test: calling it three times for the same day gives the same result.
-- Expected yesterday: booked 0, attended 2, cancelled 1
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
SELECT * FROM clinic_summary ORDER BY summary_date;
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
SELECT * FROM clinic_summary ORDER BY summary_date;   -- still one row, same counts

-- Expected today: booked 3, attended 0, cancelled 1
CALL pr_refresh_clinic_summary(CURRENT_DATE);
SELECT * FROM clinic_summary ORDER BY summary_date;

-- Cross-check against the raw appointments
SELECT appointment_day, status, COUNT(*) AS n
FROM appointments
WHERE appointment_day IN (CURRENT_DATE - 1, CURRENT_DATE)
GROUP BY appointment_day, status
ORDER BY appointment_day, status;

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
            'refresh_clinic_summary',
            '0 1 * * *',
            $job$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$job$
        );
        RAISE NOTICE 'pg_cron job refresh_clinic_summary scheduled: 0 1 * * *';
    ELSE
        RAISE NOTICE 'pg_cron is not available on this server, so the job was not scheduled. The schedule command is shown in the comment below.';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not schedule the pg_cron job: %', SQLERRM;
END
$do$;

-- The same schedule written as a plain command (for servers where pg_cron is installed):
-- SELECT cron.schedule('refresh_clinic_summary', '0 1 * * *', $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);

-- Inspect the job and its run history (uncomment where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;

-- To remove the job if needed:
-- SELECT cron.unschedule('refresh_clinic_summary');
