-- Question 3: Library Returns and Overdue Fines

-- (a) Database and seed data
CREATE TABLE books (
    book_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    book_id INT NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(120) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL,
    returned_on DATE NULL,
    fine_amount NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (fine_amount >= 0),
    CONSTRAINT chk_loans_due_after_borrow CHECK (due_on >= borrowed_on),
    CONSTRAINT chk_loans_return_after_borrow CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL CHECK (overdue_count >= 0),
    total_fine NUMERIC(12,2) NOT NULL CHECK (total_fine >= 0)
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Clean Code'),
    ('Designing Data-Intensive Applications');

-- 6 loans: includes open overdue, on-time (returned on due_on), and returned loans
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
    (1, 'Thandiwe Moyo',  DATE '2026-11-01', DATE '2026-11-10', NULL,              0.00), -- open overdue
    (2, 'Kondwani Banda', DATE '2026-11-05', DATE '2026-11-15', DATE '2026-11-15', 0.00), -- on-time return
    (3, 'Chileshe Nkandu',DATE '2026-11-01', DATE '2026-11-08', DATE '2026-11-11', 6.00), -- returned late (3 days * K2)
    (1, 'Bwalya Tembo',   DATE '2026-11-20', DATE '2026-11-30', NULL,              0.00), -- open, not yet due
    (2, 'Luyando Mulenga',DATE '2026-11-02', DATE '2026-11-12', DATE '2026-11-10', 0.00), -- returned early
    (3, 'Mapalo Phiri',   DATE '2026-11-03', DATE '2026-11-13', NULL,              0.00); -- open overdue


-- (b) Function: `fn_loan_fine`
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on DATE;
    v_returned_on DATE;
    v_effective_date DATE;
    v_overdue_days INT;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of cannot be NULL';
    END IF;

    SELECT due_on, returned_on
      INTO v_due_on, v_returned_on
      FROM loans
     WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    v_effective_date := CASE
        WHEN v_returned_on IS NOT NULL AND v_returned_on < p_as_of THEN v_returned_on
        ELSE p_as_of
    END;

    v_overdue_days := GREATEST(0, (v_effective_date - v_due_on));
    RETURN (v_overdue_days * 2)::NUMERIC(10,2);
END;
$$;

-- (c)
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_returned_on DATE;
    v_fine NUMERIC(10,2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'p_returned_on cannot be NULL';
    END IF;

    SELECT borrowed_on, returned_on
      INTO v_borrowed_on, v_returned_on
      FROM loans
     WHERE loan_id = p_loan_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    IF v_returned_on IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % has already been returned on %', p_loan_id, v_returned_on;
    END IF;

    IF p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date % cannot be before borrowed_on %', p_returned_on, v_borrowed_on;
    END IF;

    UPDATE loans
       SET returned_on = p_returned_on
     WHERE loan_id = p_loan_id;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
       SET fine_amount = v_fine
     WHERE loan_id = p_loan_id;
END;
$$;


-- (d)
CREATE OR REPLACE FUNCTION trg_fn_loans_return_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, clock_timestamp());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_after_update_return
AFTER UPDATE OF returned_on ON loans
FOR EACH ROW
EXECUTE FUNCTION trg_fn_loans_return_audit();

-- (e)
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
  FROM loans l
  JOIN books b ON b.book_id = l.book_id
 WHERE l.returned_on IS NULL
   AND l.due_on < CURRENT_DATE;

-- (f)
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;

EXPLAIN (ANALYZE, BUFFERS)
SELECT loan_id, borrower_name, due_on
  FROM loans
 WHERE book_id = 1
   AND returned_on IS NULL;

/*
  Justification: A partial B-tree index on book_id WHERE returned_on IS NULL 
  stays compact by indexing only active unreturned loans and directly satisfies 
  book_id = ... AND returned_on IS NULL.
*/


-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INT;
    v_total NUMERIC(12,2);
BEGIN
    SELECT COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0.00)
      INTO v_count, v_total
      FROM loans
     WHERE returned_on IS NULL
       AND due_on < p_as_of;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    VALUES (p_as_of, v_count, v_total)
    ON CONFLICT (snapshot_date)
    DO UPDATE SET overdue_count = EXCLUDED.overdue_count,
                  total_fine = EXCLUDED.total_fine;
END;
$$;

SELECT cron.schedule(
    'refresh_overdue_loans',
    '10 0 * * *',
    $$CALL pr_refresh_overdue(CURRENT_DATE);$$
);


























