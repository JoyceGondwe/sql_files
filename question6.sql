-- Question 6: Monthly Payroll Processing

-- (a) Database and seed data
CREATE TABLE employees (
    employee_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    pay_month DATE NOT NULL CHECK (pay_month = DATE_TRUNC('month', pay_month)::date),
    gross_pay NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT uq_payroll_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    old_salary NUMERIC(12,2) NOT NULL CHECK (old_salary >= 0),
    new_salary NUMERIC(12,2) NOT NULL CHECK (new_salary >= 0),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Dr. Joseph Mumba', 12000.00, 2500.00, 1500.00, TRUE),
    ('Prof. Mary Banda',  18000.00, 4000.00, 2500.00, TRUE),
    ('Mr. David Phiri',    9000.00, 1000.00,  800.00, FALSE);


-- (b)
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic NUMERIC(12,2);
    v_allow NUMERIC(12,2);
    v_ded NUMERIC(12,2);
    v_net NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction
      INTO v_basic, v_allow, v_ded
      FROM employees
     WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := (v_basic + v_allow) - v_ded;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Computed net pay is negative (%.2f) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;


-- (c)
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
    v_gross NUMERIC(12,2);
    v_net NUMERIC(12,2);
    v_exists BOOLEAN;
BEGIN
    IF p_month IS NULL OR p_month <> DATE_TRUNC('month', p_month)::date THEN
        RAISE EXCEPTION 'p_month must be the first day of a month, received: %', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance
          FROM employees
         WHERE active = TRUE
    LOOP
        v_gross := rec.basic_salary + rec.allowance;
        v_net := fn_net_pay(rec.employee_id);

        SELECT EXISTS (
            SELECT 1
              FROM payroll
             WHERE employee_id = rec.employee_id
               AND pay_month = p_month
        ) INTO v_exists;

        IF NOT v_exists THEN
            INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
            VALUES (rec.employee_id, p_month, v_gross, v_net);
        END IF;
    END LOOP;
END;
$$;


-- (d)
CREATE OR REPLACE FUNCTION trg_fn_employees_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, clock_timestamp());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_after_update_salary
AFTER UPDATE OF basic_salary ON employees
FOR EACH ROW
EXECUTE FUNCTION trg_fn_employees_salary_audit();

-- Process two payroll months (completing seed data in (a))
CALL pr_process_payroll(DATE '2026-10-01');
CALL pr_process_payroll(DATE '2026-11-01');



-- (e)
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT p.payroll_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay,
       e.active AS currently_active
  FROM payroll p
  JOIN employees e ON e.employee_id = p.employee_id;


-- (f)
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

EXPLAIN (ANALYZE, BUFFERS)
SELECT payroll_id, employee_id, gross_pay, net_pay
  FROM payroll
 WHERE pay_month = DATE '2026-11-01';

/*
  Justification: uq_payroll_employee_month leads with employee_id, 
  so filtering solely by pay_month across all employees cannot use that 
  index efficiently as a prefix; idx_payroll_pay_month supports direct monthly report lookups.
*/


-- (g)
SELECT cron.schedule(
    'monthly_payroll_processing',
    '0 2 1 * *',
    $$CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::date);$$
);

-- Inspect scheduled jobs
SELECT jobid, jobname, schedule, command, active
  FROM cron.job
 WHERE jobname = 'monthly_payroll_processing';

-- Inspect run history
SELECT runid, jobid, status, return_message, start_time, end_time
  FROM cron.job_run_details
 ORDER BY start_time DESC
 LIMIT 20;






















	