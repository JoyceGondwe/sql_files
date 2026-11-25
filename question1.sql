-- (a)
CREATE TABLE medicines (
    medicine_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_name VARCHAR(120) NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty INT NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    old_qty INT NOT NULL CHECK (old_qty >= 0),
    new_qty INT NOT NULL CHECK (new_qty >= 0),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty INT NOT NULL CHECK (total_qty >= 0),
    total_amount NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0)
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Amoxicillin 500mg', 25.00, 120),
    ('Paracetamol 500mg', 10.00, 14),
    ('Ibuprofen 400mg', 15.00, 50);


-- (b)
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive, received: %', p_quantity;
    END IF;

    SELECT unit_price
      INTO v_price
      FROM medicines
     WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN ROUND(v_price * p_quantity, 2);
END;
$$;

-- (c)
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INT,
    p_quantity INT,
    p_sold_on DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INT;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive, received: %', p_quantity;
    END IF;

    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'sold_on cannot be NULL';
    END IF;

    SELECT unit_price, stock_qty
      INTO v_price, v_stock
      FROM medicines
     WHERE medicine_id = p_medicine_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine_id %: available %, requested %',
            p_medicine_id, v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
       SET stock_qty = stock_qty - p_quantity
     WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d)
CREATE OR REPLACE FUNCTION trg_fn_medicines_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, clock_timestamp());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_after_update_stock
AFTER UPDATE OF stock_qty ON medicines
FOR EACH ROW
EXECUTE FUNCTION trg_fn_medicines_stock_audit();

-- Seed six valid sales using pr_record_sale (completing part (a))
CALL pr_record_sale(1, 10, DATE '2026-11-24');
CALL pr_record_sale(2, 6,  DATE '2026-11-24');
CALL pr_record_sale(3, 15, DATE '2026-11-24');
CALL pr_record_sale(1, 5,  DATE '2026-11-24');
CALL pr_record_sale(2, 3,  DATE '2026-11-24');
CALL pr_record_sale(3, 8,  DATE '2026-11-24');

-- (e)
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id,
       medicine_name,
       unit_price,
       stock_qty
  FROM medicines
 WHERE stock_qty < 10;

SELECT * FROM v_low_stock;

-- (f)
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT sale_id, quantity, unit_price, sold_on
  FROM sales
 WHERE medicine_id = 1
   AND sold_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';

/* 
   Justification: Equality filtering on medicine_id followed 
   by a range scan on sold_on matches the leading column order (medicine_id, sold_on) 
   of a B-tree composite index, avoiding a full table scan and sort.
*/


-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_qty INT;
    v_total_amount NUMERIC(12,2);
BEGIN
    SELECT COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0.00)
      INTO v_total_qty, v_total_amount
      FROM sales
     WHERE sold_on = p_day;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    VALUES (p_day, v_total_qty, v_total_amount)
    ON CONFLICT (sales_date)
    DO UPDATE SET total_qty = EXCLUDED.total_qty,
                  total_amount = EXCLUDED.total_amount;
END;
$$;

SELECT cron.schedule(
    'refresh_daily_sales',
    '15 0 * * *',
    $$CALL pr_refresh_sales((CURRENT_DATE - INTERVAL '1 day')::date);$$
);






































