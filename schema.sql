-- =============================================================================
-- SMILE DENTAL CLINIC — RELATIONAL DATABASE SCHEMA (PostgreSQL)
-- -----------------------------------------------------------------------------
-- Purpose: link patient bookings (front end) to dentist availability and to
-- the staff dashboard (Confirm / Reschedule / Cancel) already built in
-- index.html. Designed to be consumed by a Node.js backend (pg, Sequelize,
-- Prisma, Knex — any of them can point straight at these tables).
--
-- Written in PostgreSQL syntax. To use MySQL instead: replace SERIAL with
-- INT AUTO_INCREMENT, TIMESTAMPTZ with DATETIME, and drop the CHECK
-- constraints' "believe it or not" quirks are minimal — the rest is portable.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. DENTISTS / STAFF
-- One row per staff account (dentist, hygienist, or admin) — this is what
-- the "Staff Login" screen authenticates against.
-- -----------------------------------------------------------------------------
CREATE TABLE dentists (
  dentist_id     SERIAL PRIMARY KEY,
  first_name     VARCHAR(80)  NOT NULL,
  last_name      VARCHAR(80)  NOT NULL,
  email          VARCHAR(150) NOT NULL UNIQUE,
  password_hash  VARCHAR(255) NOT NULL,        -- store a bcrypt/argon2 hash, never plain text
  role           VARCHAR(20)  NOT NULL DEFAULT 'dentist'
                 CHECK (role IN ('dentist', 'hygienist', 'admin')),
  is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- 2. PATIENTS
-- One row per patient. Matches the fields already collected in the
-- booking flow's "patient info" step (name, phone, email, note).
-- -----------------------------------------------------------------------------
CREATE TABLE patients (
  patient_id   SERIAL PRIMARY KEY,
  first_name   VARCHAR(80)  NOT NULL,
  last_name    VARCHAR(80)  NOT NULL,
  phone        VARCHAR(30)  NOT NULL,
  email        VARCHAR(150) NOT NULL UNIQUE,
  notes        TEXT,                            -- "Nota para el consultorio (opcional)"
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- 3. SERVICES
-- The service catalog already shown in the "select service" step
-- (General Cleaning, Dental Exam, Teeth Whitening, Emergency Visit...).
-- -----------------------------------------------------------------------------
CREATE TABLE services (
  service_id        SERIAL PRIMARY KEY,
  name               VARCHAR(100)   NOT NULL,
  duration_minutes   INT            NOT NULL CHECK (duration_minutes > 0),
  price              NUMERIC(10,2)  NOT NULL CHECK (price >= 0),
  is_active          BOOLEAN        NOT NULL DEFAULT TRUE
);

-- -----------------------------------------------------------------------------
-- 4. DENTIST AVAILABILITY ("horarios del dentista")
-- Each row is one bookable time slot for one dentist. A patient's
-- appointment always points at exactly one of these rows.
-- -----------------------------------------------------------------------------
CREATE TABLE dentist_availability (
  availability_id  SERIAL PRIMARY KEY,
  dentist_id       INT   NOT NULL REFERENCES dentists(dentist_id) ON DELETE CASCADE,
  slot_date        DATE  NOT NULL,
  start_time       TIME  NOT NULL,
  end_time         TIME  NOT NULL,
  is_booked        BOOLEAN NOT NULL DEFAULT FALSE,   -- kept in sync by the trigger below
  CHECK (end_time > start_time),
  UNIQUE (dentist_id, slot_date, start_time)          -- a dentist can't have two slots at once
);

CREATE INDEX idx_availability_lookup
  ON dentist_availability (dentist_id, slot_date, is_booked);

-- -----------------------------------------------------------------------------
-- 5. APPOINTMENTS ("citas")
-- The row that ties everything together: a patient books one service in
-- one dentist's available slot. Note there's no separate dentist_id column
-- here — the dentist is reached through availability_id, avoiding storing
-- the same fact twice (kept normalized to 3NF).
-- -----------------------------------------------------------------------------
CREATE TABLE appointments (
  appointment_id   SERIAL PRIMARY KEY,
  patient_id       INT NOT NULL REFERENCES patients(patient_id)              ON DELETE CASCADE,
  availability_id  INT NOT NULL UNIQUE REFERENCES dentist_availability(availability_id) ON DELETE RESTRICT,
  service_id       INT NOT NULL REFERENCES services(service_id)              ON DELETE RESTRICT,
  status           VARCHAR(20) NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'confirmed', 'cancelled', 'completed')),
  notes            TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_appointments_patient ON appointments (patient_id);
CREATE INDEX idx_appointments_status  ON appointments (status);

-- -----------------------------------------------------------------------------
-- 6. KEEP is_booked IN SYNC AUTOMATICALLY
-- Booking a slot marks it unavailable; cancelling an appointment frees it
-- again. This trigger means the front end never has to update both tables
-- itself — one INSERT/UPDATE on "appointments" is enough.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_availability_on_appointment_change()
RETURNS TRIGGER AS $$
BEGIN
  IF (TG_OP = 'INSERT') THEN
    UPDATE dentist_availability SET is_booked = TRUE WHERE availability_id = NEW.availability_id;
  ELSIF (TG_OP = 'UPDATE' AND NEW.status = 'cancelled' AND OLD.status <> 'cancelled') THEN
    UPDATE dentist_availability SET is_booked = FALSE WHERE availability_id = NEW.availability_id;
  ELSIF (TG_OP = 'UPDATE' AND OLD.status = 'cancelled' AND NEW.status <> 'cancelled') THEN
    UPDATE dentist_availability SET is_booked = TRUE WHERE availability_id = NEW.availability_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sync_availability
AFTER INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION sync_availability_on_appointment_change();

-- =============================================================================
-- EXAMPLE QUERIES a Node.js backend would run
-- =============================================================================

-- Free slots for a given dentist and date (powers the "Available Times" step):
-- SELECT availability_id, start_time, end_time
-- FROM dentist_availability
-- WHERE dentist_id = $1 AND slot_date = $2 AND is_booked = FALSE
-- ORDER BY start_time;

-- Create a new appointment (powers POST /api/book):
-- INSERT INTO appointments (patient_id, availability_id, service_id, notes)
-- VALUES ($1, $2, $3, $4)
-- RETURNING appointment_id;

-- Today's appointments for the staff dashboard, with dentist + patient + service:
-- SELECT a.appointment_id, a.status, av.slot_date, av.start_time,
--        p.first_name || ' ' || p.last_name AS patient_name,
--        d.first_name || ' ' || d.last_name AS dentist_name,
--        s.name AS service_name
-- FROM appointments a
-- JOIN dentist_availability av ON av.availability_id = a.availability_id
-- JOIN dentists  d ON d.dentist_id  = av.dentist_id
-- JOIN patients  p ON p.patient_id  = a.patient_id
-- JOIN services  s ON s.service_id  = a.service_id
-- WHERE av.slot_date = CURRENT_DATE
-- ORDER BY av.start_time;

-- Cancel an appointment (powers the dashboard's "Cancel" button):
-- UPDATE appointments SET status = 'cancelled' WHERE appointment_id = $1;
-- (the trigger above automatically frees the linked availability slot)
