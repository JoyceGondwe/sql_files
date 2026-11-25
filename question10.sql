-- Question 10: Scholarship Application Assessment

-- (a) Database and seed data
CREATE TABLE students (
    student_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE applications (
    application_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    age_at_application INT NOT NULL CHECK (age_at_application > 0),
    monthly_income NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark NUMERIC(5,2) NOT NULL CHECK (average_mark >= 0 AND average_mark <= 100),
    submitted_on DATE NOT NULL DEFAULT CURRENT_DATE,
    status VARCHAR(12) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status VARCHAR(12) NOT NULL,
    new_status VARCHAR(12) NOT NULL,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO students (student_number, full_name) VALUES
    ('SCH-001', 'Faith Mumba'),
    ('SCH-002', 'Owen Banda'),
    ('SCH-003', 'Naomi Tembo');

-- 6 PENDING applications covering qualifying, non-qualifying, and boundary cases
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 21, 2500.00, 82.50, DATE '2026-11-10', 'PENDING'), -- qualifies
    (1, 18, 3000.00, 70.00, DATE '2026-11-12', 'PENDING'), -- exact lower/upper boundary -> qualifies
    (2, 26, 2000.00, 85.00, DATE '2026-11-14', 'PENDING'), -- over age 25 -> rejected
    (2, 20, 3500.00, 78.00, DATE '2026-11-15', 'PENDING'), -- income > 3000 -> rejected
    (3, 25, 3000.00, 69.99, DATE '2026-11-18', 'PENDING'), -- mark < 70 boundary -> rejected
    (3, 22,    0.00, 70.00, DATE '2026-11-20', 'PENDING'); -- zero income & mark 70 -> qualifies

-- (b) Function: `fn_scholarship_eligible`
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age INT,
    p_income NUMERIC,
    p_mark NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Inputs cannot be NULL (age=%, income=%, mark=%)', p_age, p_income, p_mark;
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, received: %', p_age;
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Monthly income cannot be negative, received: %', p_income;
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Average mark must be between 0 and 100, received: %', p_mark;
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000)
       AND (p_mark >= 70);
END;
$$;

-- (c)
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age INT;
    v_income NUMERIC(12,2);
    v_mark NUMERIC(5,2);
    v_status VARCHAR(12);
    v_eligible BOOLEAN;
    v_new_status VARCHAR(12);
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
      INTO v_age, v_income, v_mark, v_status
      FROM applications
     WHERE application_id = p_application_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % is already assessed with status %', p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);
    v_new_status := CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END;

    UPDATE applications
       SET status = v_new_status
     WHERE application_id = p_application_id;
END;
$$;


-- (d)
CREATE OR REPLACE FUNCTION trg_fn_applications_status_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, clock_timestamp());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_after_update_status
AFTER UPDATE OF status ON applications
FOR EACH ROW
EXECUTE FUNCTION trg_fn_applications_status_audit();

-- (e)
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
  FROM applications a
  JOIN students s ON s.student_id = a.student_id
 WHERE a.status = 'APPROVED';


-- (f)
CREATE INDEX idx_applications_status_submitted_on ON applications (status, submitted_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT application_id, student_id, average_mark, submitted_on
  FROM applications
 WHERE status = 'APPROVED'
   AND submitted_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';

/*
  Justification: Filtering by equality on status followed by a submitted_on date range aligns
  with (status, submitted_on), avoiding full scans when querying applications by decision status
  over a submission window.
*/


-- (g)
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

SELECT cron.schedule(
    'weekly_scholarship_assessment',
    '0 8 * * 1',
    $$CALL pr_assess_pending();$$
);



























































