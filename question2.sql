-- Question 2: University Fee Payments

-- (a) Database and seed data
CREATE TABLE students (
    student_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name VARCHAR(120) NOT NULL,
    fee_due NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id INT NOT NULL REFERENCES payments(payment_id),
    student_id INT NOT NULL REFERENCES students(student_id),
    amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    logged_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INT NOT NULL CHECK (payment_count >= 0),
    total_amount NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0)
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('STU-2026-001', 'Mwamba Banda', 5000.00),
    ('STU-2026-002', 'Chanda Phiri', 8000.00),
    ('STU-2026-003', 'Mutale Zulu',  6500.00);

-- (b) Function: `fn_fee_balance`
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(12,2);
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due
      INTO v_fee_due
      FROM students
     WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0.00)
      INTO v_paid
      FROM payments
     WHERE student_id = p_student_id;

    RETURN v_fee_due - v_paid;
END;
$$;

-- (c)
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INT,
    p_amount NUMERIC(12,2),
    p_paid_on DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(12,2);
    v_paid NUMERIC(12,2);
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive, received: %', p_amount;
    END IF;

    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'paid_on cannot be NULL';
    END IF;

    SELECT fee_due
      INTO v_fee_due
      FROM students
     WHERE student_id = p_student_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0.00)
      INTO v_paid
      FROM payments
     WHERE student_id = p_student_id;

    v_balance := v_fee_due - v_paid;

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment %.2f exceeds outstanding balance %.2f for student %',
            p_amount, v_balance, p_student_id;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- (d)
CREATE OR REPLACE FUNCTION trg_fn_payments_after_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, clock_timestamp());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_after_insert
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payments_after_insert();

-- Six payments across students 1 and 2; student 3 remains with zero payments
CALL pr_receive_payment(1, 1500.00, DATE '2026-11-24');
CALL pr_receive_payment(1, 1000.00, DATE '2026-11-24');
CALL pr_receive_payment(1,  500.00, DATE '2026-11-24');
CALL pr_receive_payment(2, 3000.00, DATE '2026-11-24');
CALL pr_receive_payment(2, 2000.00, DATE '2026-11-24');
CALL pr_receive_payment(2, 1000.00, DATE '2026-11-24');

-- (e)
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0.00) AS outstanding_balance
  FROM students s
  LEFT JOIN payments p ON p.student_id = s.student_id
 GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0.00) > 0;

-- (f)
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT payment_id, amount, paid_on
  FROM payments
 WHERE student_id = 1
   AND paid_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';

/*
  Justification: Filtering by a single student_id and a paid_on date 
  range aligns directly with (student_id, paid_on), enabling fast range 
  lookups per student.
*/


-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INT;
    v_total NUMERIC(12,2);
BEGIN
    SELECT COUNT(*), COALESCE(SUM(amount), 0.00)
      INTO v_count, v_total
      FROM payments
     WHERE paid_on = p_day;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    VALUES (p_day, v_count, v_total)
    ON CONFLICT (collection_date)
    DO UPDATE SET payment_count = EXCLUDED.payment_count,
                  total_amount = EXCLUDED.total_amount;
END;
$$;

SELECT cron.schedule(
    'refresh_daily_collections',
    '0 1 * * *',
    $$CALL pr_refresh_collections((CURRENT_DATE - INTERVAL '1 day')::date);$$
);










