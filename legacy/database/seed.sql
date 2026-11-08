-- =====================================================================
-- CTMS seed data
-- Coordinates anchored on University of Kashmir, Hazratbal (North Campus
-- reference) with routes toward Sopore / Baramulla / Srinagar city.
-- Passwords (bcrypt, cost 12):
--   admin@ctms.uok.edu.in    / Admin@123
--   driver1@ctms.uok.edu.in  / Driver@123   (also driver2, driver3)
--   student1@ctms.uok.edu.in / Student@123  (also student2)
-- =====================================================================
USE ctms;
SET FOREIGN_KEY_CHECKS = 0;

TRUNCATE TABLE audit_logs;
TRUNCATE TABLE sessions;
TRUNCATE TABLE notifications;
TRUNCATE TABLE announcements;
TRUNCATE TABLE favorites;
TRUNCATE TABLE bus_locations;
TRUNCATE TABLE route_stops;
TRUNCATE TABLE stops;
TRUNCATE TABLE drivers;
TRUNCATE TABLE buses;
TRUNCATE TABLE routes;
TRUNCATE TABLE admins;
TRUNCATE TABLE students;
TRUNCATE TABLE users;

-- ------------------------------ USERS --------------------------------
INSERT INTO users (id, email, password_hash, full_name, phone, role) VALUES
(1,'admin@ctms.uok.edu.in','$2b$12$7mTPZWbIGY8ITHmCaCeflu0jlp6oLKkousC8k4Yyn2PDXsaoCYAwu','Transport Admin','+910000000001','admin'),
(2,'driver1@ctms.uok.edu.in','$2b$12$PflWy0L5CZ8mLPTZSzhoi.bHZOC4WSIMhduPAU1PLTFfzC48y1tH2','Bashir Ahmad','+910000000002','driver'),
(3,'driver2@ctms.uok.edu.in','$2b$12$PflWy0L5CZ8mLPTZSzhoi.bHZOC4WSIMhduPAU1PLTFfzC48y1tH2','Ghulam Nabi','+910000000003','driver'),
(4,'driver3@ctms.uok.edu.in','$2b$12$PflWy0L5CZ8mLPTZSzhoi.bHZOC4WSIMhduPAU1PLTFfzC48y1tH2','Mohammad Yousuf','+910000000004','driver'),
(5,'student1@ctms.uok.edu.in','$2b$12$oVYzrlvZJxDXgsZ6.yKJL.rj6WLl3p0gcPtUAruvg0r7r21RUAmlS','Aisha Jan','+910000000005','student'),
(6,'student2@ctms.uok.edu.in','$2b$12$oVYzrlvZJxDXgsZ6.yKJL.rj6WLl3p0gcPtUAruvg0r7r21RUAmlS','Umar Farooq','+910000000006','student');

INSERT INTO admins (user_id, level) VALUES (1,'superadmin');

INSERT INTO students (user_id, enrollment_no, department, semester) VALUES
(5,'UOK-CS-2023-014','Computer Science',6),
(6,'UOK-EE-2023-031','Electronics',6);

-- ------------------------------ ROUTES -------------------------------
-- path = ordered [lat,lng] polyline along the corridor
INSERT INTO routes (id, code, name, description, path, distance_km) VALUES
(1,'R1','Hazratbal — Sopore','North campus to Sopore town via Bandipora road',
 JSON_ARRAY(JSON_ARRAY(34.1280,74.8370),JSON_ARRAY(34.1700,74.8000),JSON_ARRAY(34.2200,74.7400),JSON_ARRAY(34.2870,74.4690)),
 27.50),
(2,'R2','Hazratbal — Baramulla','North campus to Baramulla via Pattan',
 JSON_ARRAY(JSON_ARRAY(34.1280,74.8370),JSON_ARRAY(34.1600,74.7600),JSON_ARRAY(34.1750,74.5400),JSON_ARRAY(34.1980,74.3640)),
 31.20),
(3,'R3','Hazratbal — Srinagar City (Lal Chowk)','Campus to city centre via Foreshore',
 JSON_ARRAY(JSON_ARRAY(34.1280,74.8370),JSON_ARRAY(34.1050,74.8200),JSON_ARRAY(34.0830,74.8090),JSON_ARRAY(34.0740,74.8150)),
 8.40);

-- ------------------------------ STOPS --------------------------------
INSERT INTO stops (id, name, latitude, longitude) VALUES
(1,'University Main Gate (Hazratbal)',34.1280000,74.8370000),
(2,'Naseem Bagh',34.1330000,74.8420000),
(3,'Nigeen',34.1170000,74.8260000),
(4,'Pattan',34.1750000,74.5400000),
(5,'Baramulla Bus Stand',34.1980000,74.3640000),
(6,'Sangrama',34.2200000,74.7400000),
(7,'Sopore Chowk',34.2870000,74.4690000),
(8,'Foreshore Road',34.1050000,74.8200000),
(9,'Dalgate',34.0830000,74.8090000),
(10,'Lal Chowk',34.0740000,74.8150000);

-- --------------------------- ROUTE_STOPS -----------------------------
INSERT INTO route_stops (route_id, stop_id, stop_order, eta_offset_min) VALUES
(1,1,1,0),(1,6,2,20),(1,7,3,40),
(2,1,1,0),(2,4,2,25),(2,5,3,45),
(3,1,1,0),(3,8,2,8),(3,9,3,15),(3,10,4,22);

-- ------------------------------ BUSES --------------------------------
INSERT INTO buses (id, reg_no, label, capacity, route_id, status, occupancy) VALUES
(1,'JK01-AB-1234','Bus 1 — Sopore',45,1,'on_time','available'),
(2,'JK01-CD-5678','Bus 2 — Baramulla',45,2,'on_time','moderate'),
(3,'JK01-EF-9012','Bus 3 — Lal Chowk',40,3,'idle','available');

-- ----------------------------- DRIVERS -------------------------------
INSERT INTO drivers (user_id, license_no, assigned_bus_id) VALUES
(2,'JK-DL-2019-1102',1),
(3,'JK-DL-2018-4471',2),
(4,'JK-DL-2020-8853',3);

-- -------------------- INITIAL BUS LOCATIONS --------------------------
INSERT INTO bus_locations (bus_id, latitude, longitude, speed_kmh, heading) VALUES
(1,34.1700000,74.8000000,38.5,300),
(2,34.1600000,74.7600000,42.0,280),
(3,34.1280000,74.8370000,0.0,0);

-- ----------------------------- FAVORITES -----------------------------
INSERT INTO favorites (user_id, bus_id) VALUES (5,1),(6,2);

-- --------------------------- ANNOUNCEMENTS ---------------------------
INSERT INTO announcements (title, body, severity, audience, created_by) VALUES
('Winter timings in effect','Buses depart 30 minutes earlier from 1 Dec. Plan accordingly.','info','all',1),
('R2 minor delay','Baramulla route delayed ~10 min due to Pattan roadworks.','warning','students',1);

-- --------------------------- NOTIFICATIONS ---------------------------
INSERT INTO notifications (user_id, type, title, body) VALUES
(5,'announcement','Winter timings in effect','Buses depart 30 minutes earlier from 1 Dec.'),
(6,'status','Bus 2 is moderately full','Seats filling up on the Baramulla route.');

SET FOREIGN_KEY_CHECKS = 1;
