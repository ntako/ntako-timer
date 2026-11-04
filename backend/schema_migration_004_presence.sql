-- Workadoro — Migration 004: presence detection (places, stays, settings)
-- Run ONCE on databases created before this change. Safe to re-run: every
-- table is created only if missing.
-- Compatible with MySQL 5.7+ / MariaDB.
-- ── Presence detection ("badge") ─────────────────────────────────────────────
-- Platform-wide settings, one row per name. Presence uses:
--   presence_policy  off | admin | user   (see lib/Presence.php)
--   presence_mode    gps | wifi | gps_and_wifi | gps_or_wifi
CREATE TABLE IF NOT EXISTS app_settings (
  name  VARCHAR(64) PRIMARY KEY,
  value TEXT NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Per-user override of the platform presence settings (NULL = inherit).
CREATE TABLE IF NOT EXISTS user_presence (
  user_id INT PRIMARY KEY,
  policy  VARCHAR(10) DEFAULT NULL,
  mode    VARCHAR(20) DEFAULT NULL,
  CONSTRAINT fk_user_presence_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Places a device can detect. user_id NULL = platform place, seen by every
-- user and edited only by the admin.
CREATE TABLE IF NOT EXISTS places (
  id         INT PRIMARY KEY AUTO_INCREMENT,
  user_id    INT DEFAULT NULL,
  client_id  VARCHAR(36) NOT NULL,
  name       VARCHAR(100) NOT NULL,
  latitude   DOUBLE DEFAULT NULL,
  longitude  DOUBLE DEFAULT NULL,
  radius_m   INT NOT NULL DEFAULT 100 COMMENT 'includes the expected GPS error',
  wifi       TEXT COMMENT 'JSON list: SSIDs and/or BSSIDs (aa:bb:cc:dd:ee:ff)',
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  deleted_at BIGINT DEFAULT NULL,
  KEY idx_places_user (user_id),
  CONSTRAINT fk_places_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  UNIQUE KEY uq_places_client (client_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Stays in a place, as recorded by a device. exited_at NULL = still inside
-- (or the device stopped reporting: last_seen_at is the last detection).
CREATE TABLE IF NOT EXISTS presences (
  id           INT PRIMARY KEY AUTO_INCREMENT,
  user_id      INT NOT NULL,
  client_id    VARCHAR(36) NOT NULL,
  place_id     INT DEFAULT NULL,
  place_name   VARCHAR(100) NOT NULL DEFAULT '' COMMENT 'name at entry, kept if the place is deleted',
  device       VARCHAR(50) NOT NULL DEFAULT '',
  method       VARCHAR(10) NOT NULL DEFAULT '' COMMENT 'gps | wifi | gps+wifi',
  entered_at   BIGINT NOT NULL,
  exited_at    BIGINT DEFAULT NULL,
  last_seen_at BIGINT NOT NULL,
  created_at   BIGINT NOT NULL,
  KEY idx_presences_user_entered (user_id, entered_at),
  CONSTRAINT fk_presences_user  FOREIGN KEY (user_id)  REFERENCES users(id)  ON DELETE CASCADE,
  CONSTRAINT fk_presences_place FOREIGN KEY (place_id) REFERENCES places(id) ON DELETE SET NULL,
  UNIQUE KEY uq_user_client_presence (user_id, client_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
