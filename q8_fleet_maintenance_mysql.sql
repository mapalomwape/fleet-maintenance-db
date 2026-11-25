-- Question 8: Transport Fleet Maintenance (MySQL 8.0.16+)
-- CHECK constraints are only enforced from 8.0.16, so use 8.0.16 or later.

DROP DATABASE IF EXISTS fleet_db;
CREATE DATABASE fleet_db;
USE fleet_db;

-- =====================================================================
-- (a) DATABASE
-- =====================================================================
CREATE TABLE vehicles (
    vehicle_id            INT AUTO_INCREMENT PRIMARY KEY,
    registration          VARCHAR(20) NOT NULL,
    current_odometer      INT NOT NULL,
    last_service_odometer INT NOT NULL,
    CONSTRAINT uq_vehicle_reg UNIQUE (registration),
    CONSTRAINT ck_veh_current CHECK (current_odometer >= 0),
    CONSTRAINT ck_veh_service CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_veh_order   CHECK (last_service_odometer <= current_odometer)
) ENGINE=InnoDB;

CREATE TABLE trips (
    trip_id        INT AUTO_INCREMENT PRIMARY KEY,
    vehicle_id     INT  NOT NULL,
    trip_on        DATE NOT NULL,
    start_odometer INT  NOT NULL,
    end_odometer   INT  NOT NULL,
    CONSTRAINT fk_trip_vehicle FOREIGN KEY (vehicle_id)
        REFERENCES vehicles(vehicle_id),
    CONSTRAINT ck_trip_start CHECK (start_odometer >= 0),
    CONSTRAINT ck_trip_end   CHECK (end_odometer > start_odometer)
) ENGINE=InnoDB;

CREATE TABLE service_alerts (
    vehicle_id      INT PRIMARY KEY,
    km_since_service INT  NOT NULL,
    flagged_on      DATE NOT NULL,
    CONSTRAINT fk_alert_vehicle FOREIGN KEY (vehicle_id)
        REFERENCES vehicles(vehicle_id),
    CONSTRAINT ck_alert_km CHECK (km_since_service >= 0)
) ENGINE=InnoDB;

DELIMITER $$

-- =====================================================================
-- (b) FUNCTION fn_service_due : TRUE when km since service >= 5000
-- =====================================================================
CREATE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN
READS SQL DATA
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_km    INT;

    SELECT COUNT(*) INTO v_count
    FROM vehicles WHERE vehicle_id = p_vehicle_id;

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Unknown vehicle';
    END IF;

    SELECT current_odometer - last_service_odometer
      INTO v_km
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    RETURN v_km >= 5000;
END$$

-- =====================================================================
-- (c) PROCEDURE pr_record_trip
-- Only inserts the trip. It does NOT touch vehicles.current_odometer;
-- the BEFORE INSERT trigger does that.
-- =====================================================================
CREATE PROCEDURE pr_record_trip(
    IN p_vehicle_id INT,
    IN p_trip_on    DATE,
    IN p_start      INT,
    IN p_end        INT
)
BEGIN
    DECLARE v_count INT DEFAULT 0;

    IF p_vehicle_id IS NULL OR p_trip_on IS NULL
       OR p_start IS NULL OR p_end IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'All trip parameters are required';
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Unknown vehicle';
    END IF;

    IF p_end <= p_start THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'end_odometer must be greater than start_odometer';
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END$$

-- =====================================================================
-- (d) TRIGGER (BEFORE INSERT, row level)
-- 1. locks the vehicle row (FOR UPDATE) so two concurrent trips cannot
--    both start from the same odometer value
-- 2. start must equal the vehicle's current odometer
-- 3. mileage must be valid (end > start, non-negative)
-- 4. sets current_odometer to the trip end, once per inserted row.
-- If the INSERT later fails, InnoDB rolls back the whole statement, so
-- the odometer update is undone as well.
-- =====================================================================
CREATE TRIGGER trg_trips_bi
BEFORE INSERT ON trips
FOR EACH ROW
BEGIN
    DECLARE v_current INT;
    DECLARE v_count   INT DEFAULT 0;

    SELECT COUNT(*) INTO v_count
    FROM vehicles WHERE vehicle_id = NEW.vehicle_id;
    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Unknown vehicle';
    END IF;

    SELECT current_odometer INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NEW.start_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Invalid mileage: end must be greater than start';
    END IF;

    IF NEW.start_odometer <> v_current THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'start_odometer must equal the vehicle current odometer';
    END IF;

    UPDATE vehicles
       SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;
END$$

-- =====================================================================
-- (g) PROCEDURE pr_refresh_service_alerts
-- 1. remove alerts for vehicles that are no longer due
-- 2. insert an alert for each due vehicle, or update km_since_service
--    if one already exists (flagged_on keeps the original flag date)
-- Done in one transaction, so a failure leaves alerts unchanged.
-- =====================================================================
CREATE PROCEDURE pr_refresh_service_alerts()
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    DELETE sa
    FROM service_alerts sa
    JOIN vehicles v ON v.vehicle_id = sa.vehicle_id
    WHERE v.current_odometer - v.last_service_odometer < 5000;

    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT v.vehicle_id,
           v.current_odometer - v.last_service_odometer,
           CURRENT_DATE
    FROM vehicles v
    WHERE v.current_odometer - v.last_service_odometer >= 5000
    ON DUPLICATE KEY UPDATE
        km_since_service = v.current_odometer - v.last_service_odometer;

    COMMIT;
END$$

DELIMITER ;

-- =====================================================================
-- SEED DATA (trips are added AFTER the trigger exists, via the procedure)
-- V1: 8000 km since service (due)
-- V2: 4000 km since service (not due)
-- V3: exactly 5000 km since service (due, boundary case)
-- =====================================================================
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
 ('ABC 1234', 10000,  2000),
 ('BCD 2345', 12000,  8000),
 ('CDE 3456', 15000, 10000);

CALL pr_record_trip(1, '2026-10-01', 10000, 10300);
CALL pr_record_trip(1, '2026-10-08', 10300, 10650);
CALL pr_record_trip(2, '2026-10-02', 12000, 12300);
CALL pr_record_trip(2, '2026-10-09', 12300, 12800);   -- 4800 km: still not due
CALL pr_record_trip(3, '2026-10-03', 15000, 15250);
CALL pr_record_trip(3, '2026-10-10', 15250, 15500);

-- =====================================================================
-- (e) VIEW
-- =====================================================================
CREATE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

-- =====================================================================
-- (f) INDEX
-- Query: one vehicle's trips within a date range.
-- Composite (vehicle_id, trip_on): the equality column comes first, then
-- the range column. MySQL seeks directly to the vehicle's entries and
-- reads only the dates in the range, already sorted by trip_on, so no
-- filesort. The foreign key's automatic single-column index on
-- vehicle_id becomes redundant because this index also starts with
-- vehicle_id (MySQL drops the implicit one automatically).
-- =====================================================================
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);

EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN '2026-10-01' AND '2026-10-31'
ORDER BY trip_on;
-- Expected: key = idx_trips_vehicle_date, type = range, no "Using filesort".
-- On a tiny table the optimizer may choose a full scan; to show the plan
-- it would use on a large table:
EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips FORCE INDEX (idx_trips_vehicle_date)
WHERE vehicle_id = 1
  AND trip_on BETWEEN '2026-10-01' AND '2026-10-31'
ORDER BY trip_on;

-- =====================================================================
-- (g) SCHEDULED JOB: every Monday at 06:00 (MySQL Event Scheduler)
-- 2026-11-30 is a Monday; EVERY 1 WEEK keeps it on Mondays.
-- =====================================================================
SET GLOBAL event_scheduler = ON;   -- needs SUPER / SYSTEM_VARIABLES_ADMIN

CREATE EVENT ev_weekly_service_alerts
ON SCHEDULE EVERY 1 WEEK
STARTS '2026-11-30 06:00:00'
DO CALL pr_refresh_service_alerts();

-- Inspect the job
SHOW EVENTS FROM fleet_db;
SELECT event_name, status, interval_value, interval_field, starts, last_executed
FROM information_schema.EVENTS
WHERE event_schema = 'fleet_db' AND event_name = 'ev_weekly_service_alerts';

-- =====================================================================
-- TEST SCRIPT
-- =====================================================================
SELECT * FROM vehicles;   -- V1 10650, V2 12800, V3 15500
SELECT * FROM trips;

-- Function
SELECT fn_service_due(1) AS v1,   -- 1 (8650 km)
       fn_service_due(2) AS v2,   -- 0 (4800 km)
       fn_service_due(3) AS v3;   -- 1 (5500 km)
-- SELECT fn_service_due(99);      -- ERROR: Unknown vehicle

-- Procedure / trigger rejections (nothing stored, odometer unchanged)
-- CALL pr_record_trip(99, '2026-11-01', 0, 10);        -- ERROR: unknown vehicle
-- CALL pr_record_trip(1, '2026-11-01', 10650, 10650);  -- ERROR: end not > start
-- CALL pr_record_trip(1, '2026-11-01', 10000, 10100);  -- ERROR: start <> current
-- INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
-- VALUES (1, '2026-11-01', 10000, 10100);               -- direct SQL also rejected
SELECT COUNT(*) FROM trips;                             -- still 6

-- A valid trip moves the odometer exactly once
CALL pr_record_trip(2, '2026-11-02', 12800, 13000);     -- V2 now 13000 -> 5000 km, due
SELECT current_odometer FROM vehicles WHERE vehicle_id = 2;   -- 13000

-- View
SELECT * FROM v_service_due;   -- V1, V2, V3

-- Alerts
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;  -- 3 alerts

-- Service vehicle 1: no longer due, so its alert is removed on refresh
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 1;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;  -- vehicles 2 and 3 only
