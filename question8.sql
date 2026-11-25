-- Question 8: Transport Fleet Maintenance

-- (a) Database and seed data
CREATE TABLE vehicles (
    vehicle_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registration VARCHAR(25) NOT NULL UNIQUE,
    current_odometer NUMERIC(12,2) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(12,2) NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_vehicles_service_le_current CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id INT NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on DATE NOT NULL DEFAULT CURRENT_DATE,
    start_odometer NUMERIC(12,2) NOT NULL CHECK (start_odometer >= 0),
    end_odometer NUMERIC(12,2) NOT NULL CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(12,2) NOT NULL CHECK (km_since_service >= 0),
    flagged_on DATE NOT NULL DEFAULT CURRENT_DATE
);

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ALC 101 ZM', 5200.00, 0.00),     -- already >= 5000 km since service
    ('BLC 202 ZM', 14200.00, 10000.00),-- 4200 km since service; trips will push >= 5000
    ('CLC 303 ZM', 8100.00, 8000.00);  -- 100 km since service


-- (b)
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr NUMERIC(12,2);
    v_last NUMERIC(12,2);
BEGIN
    SELECT current_odometer, last_service_odometer
      INTO v_curr, v_last
      FROM vehicles
     WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_curr - v_last) >= 5000.00;
END;
$$;

-- (c)
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INT,
    p_trip_on DATE,
    p_start NUMERIC(12,2),
    p_end NUMERIC(12,2)
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_trip_on IS NULL THEN
        RAISE EXCEPTION 'p_trip_on cannot be NULL';
    END IF;

    IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'Invalid odometer range: start=%, end=%', p_start, p_end;
    END IF;

    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;


-- (d)
CREATE OR REPLACE FUNCTION trg_fn_trips_before_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr_odo NUMERIC(12,2);
BEGIN
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'end_odometer (%.2f) must be greater than start_odometer (%.2f)',
            NEW.end_odometer, NEW.start_odometer;
    END IF;

    SELECT current_odometer
      INTO v_curr_odo
      FROM vehicles
     WHERE vehicle_id = NEW.vehicle_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_curr_odo THEN
        RAISE EXCEPTION 'start_odometer (%.2f) must match current_odometer (%.2f)',
            NEW.start_odometer, v_curr_odo;
    END IF;

    UPDATE vehicles
       SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_before_insert
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trips_before_insert();

-- 6 trips recorded via pr_record_trip
CALL pr_record_trip(1, DATE '2026-11-20',  5200.00,  5500.00);
CALL pr_record_trip(1, DATE '2026-11-22',  5500.00,  5750.00);
CALL pr_record_trip(2, DATE '2026-11-21', 14200.00, 14800.00);
CALL pr_record_trip(2, DATE '2026-11-23', 14800.00, 15200.00);
CALL pr_record_trip(3, DATE '2026-11-22',  8100.00,  8350.00);
CALL pr_record_trip(3, DATE '2026-11-24',  8350.00,  8500.00);


-- (e)
CREATE OR REPLACE VIEW v_service_due AS
SELECT vehicle_id,
       registration,
       (current_odometer - last_service_odometer) AS km_since_service
  FROM vehicles
 WHERE (current_odometer - last_service_odometer) >= 5000.00;


-- (f)
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT trip_id, trip_on, start_odometer, end_odometer
  FROM trips
 WHERE vehicle_id = 2
   AND trip_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';

/*
  Justification: Filtering by vehicle_id and a trip_on date range aligns directly with
  (vehicle_id, trip_on), allowing an index range scan on just that vehicle's trips within 
  the requested period.
*/


-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM service_alerts sa
     WHERE NOT EXISTS (
         SELECT 1
           FROM vehicles v
          WHERE v.vehicle_id = sa.vehicle_id
            AND (v.current_odometer - v.last_service_odometer) >= 5000.00
     );

    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT v.vehicle_id,
           (v.current_odometer - v.last_service_odometer),
           CURRENT_DATE
      FROM vehicles v
     WHERE (v.current_odometer - v.last_service_odometer) >= 5000.00
    ON CONFLICT (vehicle_id)
    DO UPDATE SET km_since_service = EXCLUDED.km_since_service,
                  flagged_on = EXCLUDED.flagged_on;
END;
$$;

SELECT cron.schedule(
    'weekly_service_alerts',
    '0 6 * * 1',
    $$CALL pr_refresh_service_alerts();$$
);










































	