-- =====================================================================
-- Campus Transport Management System (CTMS)
-- University of Kashmir, North Campus
-- MySQL 8.0 normalized schema
-- =====================================================================
-- Engine: InnoDB (FK support, row-level locking, transactions)
-- Charset: utf8mb4 (full unicode incl. emoji in announcements)
-- =====================================================================

SET NAMES utf8mb4;
SET time_zone = '+00:00';
SET FOREIGN_KEY_CHECKS = 0;

CREATE DATABASE IF NOT EXISTS ctms
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;
USE ctms;

-- ---------------------------------------------------------------------
-- users : single identity table, role discriminator + profile tables
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS users;
CREATE TABLE users (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  email           VARCHAR(190)    NOT NULL,
  password_hash   VARCHAR(255)    NOT NULL,
  full_name       VARCHAR(150)    NOT NULL,
  phone           VARCHAR(20)     NULL,
  role            ENUM('student','driver','admin') NOT NULL DEFAULT 'student',
  is_active       TINYINT(1)      NOT NULL DEFAULT 1,
  failed_attempts INT UNSIGNED    NOT NULL DEFAULT 0,
  locked_until    DATETIME        NULL,
  last_login_at   DATETIME        NULL,
  created_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_users_email (email),
  KEY idx_users_role (role),
  KEY idx_users_active (is_active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- students
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS students;
CREATE TABLE students (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id      BIGINT UNSIGNED NOT NULL,
  enrollment_no VARCHAR(40)    NOT NULL,
  department   VARCHAR(120)    NULL,
  semester     TINYINT UNSIGNED NULL,
  created_at   DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_students_user (user_id),
  UNIQUE KEY uq_students_enrollment (enrollment_no),
  CONSTRAINT fk_students_user FOREIGN KEY (user_id)
    REFERENCES users (id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- routes
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS routes;
CREATE TABLE routes (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  code        VARCHAR(20)     NOT NULL,
  name        VARCHAR(150)    NOT NULL,
  description VARCHAR(255)    NULL,
  -- polyline: ordered JSON array of [lat,lng] for drawing the path
  path        JSON            NULL,
  distance_km DECIMAL(6,2)    NULL,
  is_active   TINYINT(1)      NOT NULL DEFAULT 1,
  created_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_routes_code (code),
  KEY idx_routes_active (is_active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- stops
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS stops;
CREATE TABLE stops (
  id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  name      VARCHAR(150)    NOT NULL,
  latitude  DECIMAL(10,7)   NOT NULL,
  longitude DECIMAL(10,7)   NOT NULL,
  created_at DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_stops_geo (latitude, longitude)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- route_stops : ordered M:N between routes and stops
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS route_stops;
CREATE TABLE route_stops (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  route_id      BIGINT UNSIGNED NOT NULL,
  stop_id       BIGINT UNSIGNED NOT NULL,
  stop_order    INT UNSIGNED    NOT NULL,
  eta_offset_min INT UNSIGNED   NOT NULL DEFAULT 0, -- mins from route start
  PRIMARY KEY (id),
  UNIQUE KEY uq_route_stop_order (route_id, stop_order),
  UNIQUE KEY uq_route_stop (route_id, stop_id),
  KEY idx_rs_stop (stop_id),
  CONSTRAINT fk_rs_route FOREIGN KEY (route_id)
    REFERENCES routes (id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_rs_stop FOREIGN KEY (stop_id)
    REFERENCES stops (id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- buses
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS buses;
CREATE TABLE buses (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  reg_no        VARCHAR(30)     NOT NULL,
  label         VARCHAR(80)     NOT NULL,           -- e.g. "Bus 4 - Sopore"
  capacity      INT UNSIGNED    NOT NULL DEFAULT 40,
  route_id      BIGINT UNSIGNED NULL,
  status        ENUM('idle','on_time','delayed','breakdown','completed')
                  NOT NULL DEFAULT 'idle',
  occupancy     ENUM('available','moderate','full') NOT NULL DEFAULT 'available',
  is_active     TINYINT(1)      NOT NULL DEFAULT 1,
  created_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_buses_reg (reg_no),
  KEY idx_buses_route (route_id),
  KEY idx_buses_status (status),
  CONSTRAINT fk_buses_route FOREIGN KEY (route_id)
    REFERENCES routes (id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- drivers : profile + bus assignment (1:1 active assignment)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS drivers;
CREATE TABLE drivers (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id       BIGINT UNSIGNED NOT NULL,
  license_no    VARCHAR(40)     NOT NULL,
  assigned_bus_id BIGINT UNSIGNED NULL,
  created_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_drivers_user (user_id),
  UNIQUE KEY uq_drivers_license (license_no),
  UNIQUE KEY uq_drivers_bus (assigned_bus_id), -- one driver per bus
  CONSTRAINT fk_drivers_user FOREIGN KEY (user_id)
    REFERENCES users (id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_drivers_bus FOREIGN KEY (assigned_bus_id)
    REFERENCES buses (id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- admins
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS admins;
CREATE TABLE admins (
  id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id   BIGINT UNSIGNED NOT NULL,
  level     ENUM('admin','superadmin') NOT NULL DEFAULT 'admin',
  created_at DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_admins_user (user_id),
  CONSTRAINT fk_admins_user FOREIGN KEY (user_id)
    REFERENCES users (id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- bus_locations : append-only GPS breadcrumb trail (time-series)
-- latest row per bus = current position
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS bus_locations;
CREATE TABLE bus_locations (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  bus_id     BIGINT UNSIGNED NOT NULL,
  latitude   DECIMAL(10,7)   NOT NULL,
  longitude  DECIMAL(10,7)   NOT NULL,
  speed_kmh  DECIMAL(6,2)    NULL,
  heading    DECIMAL(6,2)    NULL,        -- bearing 0-360
  recorded_at DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_loc_bus_time (bus_id, recorded_at),
  CONSTRAINT fk_loc_bus FOREIGN KEY (bus_id)
    REFERENCES buses (id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- favorites : students' favourite buses
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS favorites;
CREATE TABLE favorites (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id    BIGINT UNSIGNED NOT NULL,
  bus_id     BIGINT UNSIGNED NOT NULL,
  created_at DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_fav (user_id, bus_id),
  KEY idx_fav_bus (bus_id),
  CONSTRAINT fk_fav_user FOREIGN KEY (user_id)
    REFERENCES users (id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_fav_bus FOREIGN KEY (bus_id)
    REFERENCES buses (id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- announcements : broadcast by admins
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS announcements;
CREATE TABLE announcements (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  title       VARCHAR(180)    NOT NULL,
  body        TEXT            NOT NULL,
  severity    ENUM('info','warning','critical') NOT NULL DEFAULT 'info',
  audience    ENUM('all','students','drivers') NOT NULL DEFAULT 'all',
  created_by  BIGINT UNSIGNED NULL,
  created_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_ann_audience (audience),
  KEY idx_ann_created (created_at),
  CONSTRAINT fk_ann_creator FOREIGN KEY (created_by)
    REFERENCES users (id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- notifications : per-user inbox
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS notifications;
CREATE TABLE notifications (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id    BIGINT UNSIGNED NOT NULL,
  type       VARCHAR(50)     NOT NULL,      -- arrival, status, announcement
  title      VARCHAR(180)    NOT NULL,
  body       VARCHAR(500)    NULL,
  is_read    TINYINT(1)      NOT NULL DEFAULT 0,
  created_at DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_notif_user_read (user_id, is_read),
  CONSTRAINT fk_notif_user FOREIGN KEY (user_id)
    REFERENCES users (id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- sessions : refresh-token store (rotation + revocation)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS sessions;
CREATE TABLE sessions (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id       BIGINT UNSIGNED NOT NULL,
  token_hash    CHAR(64)        NOT NULL,   -- sha256 of refresh token
  user_agent    VARCHAR(255)    NULL,
  ip_address    VARCHAR(45)     NULL,
  expires_at    DATETIME        NOT NULL,
  revoked_at    DATETIME        NULL,
  created_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_sessions_token (token_hash),
  KEY idx_sessions_user (user_id),
  CONSTRAINT fk_sessions_user FOREIGN KEY (user_id)
    REFERENCES users (id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- audit_logs : security / admin action trail
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS audit_logs;
CREATE TABLE audit_logs (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id    BIGINT UNSIGNED NULL,
  action     VARCHAR(80)     NOT NULL,    -- login, create_bus, delete_user...
  entity     VARCHAR(60)     NULL,
  entity_id  BIGINT UNSIGNED NULL,
  meta       JSON            NULL,
  ip_address VARCHAR(45)     NULL,
  created_at DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_audit_user (user_id),
  KEY idx_audit_action (action),
  KEY idx_audit_created (created_at),
  CONSTRAINT fk_audit_user FOREIGN KEY (user_id)
    REFERENCES users (id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

SET FOREIGN_KEY_CHECKS = 1;
