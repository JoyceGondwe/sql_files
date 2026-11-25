-- Question 7: Water Meter Readings and Billing

-- (a) Database and seed data
CREATE TABLE customers (
    customer_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE readings (
    reading_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id INT NOT NULL REFERENCES customers(customer_id),
    reading_month DATE NOT NULL CHECK (reading_month = DATE_TRUNC('month', reading_month)::date),
    previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading NUMERIC(12,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_readings_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reading_id INT NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0.00 CHECK (amount_paid >= 0 AND amount_paid <= charge),
    due_on DATE NOT NULL
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due NUMERIC(12,2) NOT NULL CHECK (total_due >= 0)
);

INSERT INTO customers (full_name) VALUES
    ('Lusaka Water Estates'),
    ('Kabwe Holdings Ltd'),
    ('Ndola Residence Co');


-- (b)
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_tier1 NUMERIC(12,2);
    v_tier2 NUMERIC(12,2);
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption units must be non-negative, received: %', p_units;
    END IF;

    IF p_units = 0 THEN
        RETURN 0.00;
    END IF;

    v_tier1 := LEAST(p_units, 10) * 5.00;
    v_tier2 := GREATEST(p_units - 10, 0) * 8.00;

    RETURN ROUND(v_tier1 + v_tier2, 2);
END;
$$;


-- (c)
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev NUMERIC(12,2);
    v_curr NUMERIC(12,2);
    v_units NUMERIC(12,2);
    v_charge NUMERIC(12,2);
    v_bill_exists BOOLEAN;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'p_due_on cannot be NULL';
    END IF;

    SELECT previous_reading, current_reading
      INTO v_prev, v_curr
      FROM readings
     WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM bills WHERE reading_id = p_reading_id
    ) INTO v_bill_exists;

    IF v_bill_exists THEN
        RAISE EXCEPTION 'A bill already exists for reading_id %', p_reading_id;
    END IF;

    v_units := v_curr - v_prev;
    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0.00, p_due_on);
END;
$$;


-- (d)
CREATE OR REPLACE FUNCTION trg_fn_readings_check_order()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%.2f) cannot be less than previous_reading (%.2f)',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_before_ins_upd_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_readings_check_order();

-- 6 readings covering 0, exactly 10, and above 10 units
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-10-01', 100.00, 100.00), -- 0 units
    (1, DATE '2026-11-01', 100.00, 110.00), -- 10 units (K50.00)
    (2, DATE '2026-10-01',  50.00,  65.00), -- 15 units (10*5 + 5*8 = K90.00)
    (2, DATE '2026-11-01',  65.00,  65.00), -- 0 units
    (3, DATE '2026-10-01',  20.00,  30.00), -- 10 units (K50.00)
    (3, DATE '2026-11-01',  30.00,  52.00); -- 22 units (10*5 + 12*8 = K146.00)



-- (e)
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name,
       b.due_on,
       (b.charge - b.amount_paid) AS outstanding_amount
  FROM bills b
  JOIN readings r ON r.reading_id = b.reading_id
  JOIN customers c ON c.customer_id = r.customer_id
 WHERE b.due_on < CURRENT_DATE
   AND b.amount_paid < b.charge


-- (f)
CREATE INDEX idx_bills_due_on_unpaid ON bills (due_on) WHERE amount_paid < charge;

EXPLAIN (ANALYZE, BUFFERS)
SELECT bill_id, reading_id, charge, amount_paid, due_on
  FROM bills
 WHERE due_on < CURRENT_DATE
   AND amount_paid < charge;

/*
  Justification: A partial index on due_on for rows where amount_paid < charge filters
  directly to unpaid bills and enables fast date range / cutoff scans on due_on.
*/

-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_due NUMERIC(12,2);
BEGIN
    SELECT COALESCE(SUM(charge - amount_paid), 0.00)
      INTO v_total_due
      FROM bills
     WHERE amount_paid < charge;

    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    VALUES (CURRENT_DATE, v_total_due)
    ON CONFLICT (snapshot_date)
    DO UPDATE SET total_due = EXCLUDED.total_due;
END;
$$;

SELECT cron.schedule(
    'refresh_receivables_snapshot',
    '30 0 * * *',
    $$CALL pr_refresh_receivables();$$
);



































	