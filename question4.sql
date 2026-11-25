-- Question 4: Clinic Appointment Scheduling

-- (a) Database and seed data
CREATE TABLE patients (
    patient_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE doctors (
    doctor_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE appointments (
    appointment_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id INT NOT NULL REFERENCES patients(patient_id),
    doctor_id INT NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time TIME NOT NULL CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00')),
    status VARCHAR(15) NOT NULL CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date DATE PRIMARY KEY,
    booked_count INT NOT NULL CHECK (booked_count >= 0),
    attended_count INT NOT NULL CHECK (attended_count >= 0),
    cancelled_count INT NOT NULL CHECK (cancelled_count >= 0)
);

INSERT INTO patients (full_name) VALUES
    ('Natasha Mwape'),
    ('Gift Sakala'),
    ('Kelvin Chanda');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Ruth Lungu'),
    ('Dr. Peter Sichone'),
    ('Dr. Grace Kabwe');

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, DATE '2026-11-25', TIME '09:00', 'BOOKED'),
    (2, 1, DATE '2026-11-25', TIME '10:00', 'ATTENDED'),
    (3, 1, DATE '2026-11-25', TIME '11:00', 'CANCELLED'),
    (1, 2, DATE '2026-11-25', TIME '09:00', 'BOOKED'),
    (2, 2, DATE '2026-11-26', TIME '12:00', 'BOOKED'),
    (3, 3, DATE '2026-11-26', TIME '10:00', 'ATTENDED');


-- (b) Function: `fn_daily_load`
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_cnt INT;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*)
      INTO v_cnt
      FROM appointments
     WHERE doctor_id = p_doctor_id
       AND appointment_day = p_day
       AND status <> 'CANCELLED';

    RETURN COALESCE(v_cnt, 0);
END;
$$;


-- (c)
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INT,
    p_doctor_id INT,
    p_day DATE,
    p_slot TIME
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment day % cannot be in the past or NULL', p_day;
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot_time: %', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;


-- (d)
CREATE OR REPLACE FUNCTION trg_fn_appointments_prevent_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_clash_exists BOOLEAN;
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        SELECT EXISTS (
            SELECT 1
              FROM appointments a
             WHERE a.doctor_id = NEW.doctor_id
               AND a.appointment_day = NEW.appointment_day
               AND a.slot_time = NEW.slot_time
               AND a.status <> 'CANCELLED'
               AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)
        ) INTO v_clash_exists;

        IF v_clash_exists THEN
            RAISE EXCEPTION 'Slot clash for doctor % on % at %',
                NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_before_ins_upd_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_appointments_prevent_clash();


-- (e)
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id,
       p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
  FROM appointments a
  JOIN patients p ON p.patient_id = a.patient_id
  JOIN doctors d ON d.doctor_id = a.doctor_id
 WHERE a.appointment_day = CURRENT_DATE
   AND a.status = 'BOOKED';


-- (f)
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);

EXPLAIN (ANALYZE, BUFFERS)
SELECT appointment_id, slot_time, status
  FROM appointments
 WHERE appointment_day = DATE '2026-11-25'
   AND doctor_id = 1;

/*
  Justification: Queries filtering on appointment_day and doctor_id 
  (such as daily doctor schedules and summary checks) benefit directly from
  (appointment_day, doctor_id) without requiring a full table scan.
*/


-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_booked INT;
    v_attended INT;
    v_cancelled INT;
BEGIN
    SELECT COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
      INTO v_booked, v_attended, v_cancelled
      FROM appointments
     WHERE appointment_day = p_day;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    VALUES (p_day, COALESCE(v_booked, 0), COALESCE(v_attended, 0), COALESCE(v_cancelled, 0))
    ON CONFLICT (summary_date)
    DO UPDATE SET booked_count = EXCLUDED.booked_count,
                  attended_count = EXCLUDED.attended_count,
                  cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

SELECT cron.schedule(
    'refresh_clinic_summary',
    '0 1 * * *',
    $$CALL pr_refresh_clinic_summary((CURRENT_DATE - INTERVAL '1 day')::date);$$
);


























































