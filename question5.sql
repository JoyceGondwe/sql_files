-- Question 5: Hostel Room Allocation

-- (a) Database and seed data
CREATE TABLE students (
    student_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE rooms (
    room_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_number VARCHAR(20) NOT NULL UNIQUE,
    capacity INT NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    room_id INT NOT NULL REFERENCES rooms(room_id),
    allocated_on DATE NOT NULL,
    released_on DATE NULL,
    status VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_allocations_status_dates CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED' AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INT NOT NULL REFERENCES rooms(room_id),
    occupied_beds INT NOT NULL CHECK (occupied_beds >= 0),
    free_beds INT NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
    ('STU-101', 'Dalitso Ngoma'),
    ('STU-102', 'Musonda Kapansa'),
    ('STU-103', 'Tisa Mwanza'),
    ('STU-104', 'Chisomo Nyirenda');

INSERT INTO rooms (room_number, capacity) VALUES
    ('R-101', 2), -- will be full (2 active)
    ('R-102', 3), -- will be partly occupied (1 active, 1 ended)
    ('R-103', 2); -- empty (no active allocations)

INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
    (1, 1, DATE '2026-10-01', NULL,              'ACTIVE'),
    (2, 1, DATE '2026-10-02', NULL,              'ACTIVE'),
    (3, 2, DATE '2026-10-03', NULL,              'ACTIVE'),
    (4, 2, DATE '2026-09-01', DATE '2026-09-30', 'ENDED');


-- (b) Function: `fn_free_beds`
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INT;
    v_active_cnt INT;
BEGIN
    SELECT capacity
      INTO v_capacity
      FROM rooms
     WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*)
      INTO v_active_cnt
      FROM allocations
     WHERE room_id = p_room_id
       AND status = 'ACTIVE';

    RETURN v_capacity - COALESCE(v_active_cnt, 0);
END;
$$;

-- (c)
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id INT,
    p_room_id INT,
    p_allocated_on DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INT;
    v_active_room_beds INT;
    v_has_active BOOLEAN;
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'allocated_on cannot be NULL';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT capacity
      INTO v_capacity
      FROM rooms
     WHERE room_id = p_room_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT EXISTS (
        SELECT 1
          FROM allocations
         WHERE student_id = p_student_id
           AND status = 'ACTIVE'
    ) INTO v_has_active;

    IF v_has_active THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE room allocation', p_student_id;
    END IF;

    SELECT COUNT(*)
      INTO v_active_room_beds
      FROM allocations
     WHERE room_id = p_room_id
       AND status = 'ACTIVE';

    IF v_active_room_beds >= v_capacity THEN
        RAISE EXCEPTION 'Room % is at full capacity (%)', p_room_id, v_capacity;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;


-- (d)
CREATE OR REPLACE FUNCTION trg_fn_allocations_enforce_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INT;
    v_room_active_cnt INT;
    v_student_active_cnt INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT capacity
          INTO v_capacity
          FROM rooms
         WHERE room_id = NEW.room_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
        END IF;

        SELECT COUNT(*)
          INTO v_room_active_cnt
          FROM allocations
         WHERE room_id = NEW.room_id
           AND status = 'ACTIVE'
           AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id);

        IF v_room_active_cnt + 1 > v_capacity THEN
            RAISE EXCEPTION 'Room % capacity (%) exceeded', NEW.room_id, v_capacity;
        END IF;

        SELECT COUNT(*)
          INTO v_student_active_cnt
          FROM allocations
         WHERE student_id = NEW.student_id
           AND status = 'ACTIVE'
           AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id);

        IF v_student_active_cnt >= 1 THEN
            RAISE EXCEPTION 'Student % already has another ACTIVE allocation', NEW.student_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_before_ins_upd_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocations_enforce_rules();


-- (e)
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS free_beds
  FROM rooms r
  LEFT JOIN allocations a ON a.room_id = r.room_id
 GROUP BY r.room_id, r.room_number, r.capacity;


-- (f)
CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';

EXPLAIN (ANALYZE, BUFFERS)
SELECT allocation_id, student_id, allocated_on
  FROM allocations
 WHERE room_id = 2
   AND status = 'ACTIVE';


/*
  Justification: Partial index on room_id where status = 'ACTIVE' excludes historical
  ENDED rows and directly serves active room bed lookups.
*/



-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE,
           r.room_id,
           COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS occupied_beds,
           r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS free_beds
      FROM rooms r
      LEFT JOIN allocations a ON a.room_id = r.room_id
     GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id)
    DO UPDATE SET occupied_beds = EXCLUDED.occupied_beds,
                  free_beds = EXCLUDED.free_beds;
END;
$$;

SELECT cron.schedule(
    'refresh_daily_occupancy',
    '55 23 * * *',
    $$CALL pr_refresh_occupancy();$$
);



















































