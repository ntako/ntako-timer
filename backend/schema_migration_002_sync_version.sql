-- NTAKO_TIMER — Migration 002: per-user sync versions for incremental pull
-- Run ONCE on databases created before this change (not idempotent).
-- Compatible with MySQL 5.7+ / MariaDB.

ALTER TABLE users
  ADD COLUMN sync_seq BIGINT NOT NULL DEFAULT 0 AFTER password_hash;

ALTER TABLE categories
  ADD COLUMN version BIGINT NOT NULL DEFAULT 0,
  ADD KEY idx_categories_user_version (user_id, version);

ALTER TABLE tasks
  ADD COLUMN version BIGINT NOT NULL DEFAULT 0,
  ADD KEY idx_tasks_user_version (user_id, version);

ALTER TABLE sessions
  ADD COLUMN version BIGINT NOT NULL DEFAULT 0,
  ADD KEY idx_sessions_user_version (user_id, version);

-- Existing rows: the pull cursor only needs versions to be unique within a
-- table for a given user, which the auto-increment id already guarantees.
UPDATE categories SET version = id;
UPDATE tasks      SET version = id;
UPDATE sessions   SET version = id;

-- New versions must continue above the highest one each user already has.
UPDATE users u SET sync_seq = GREATEST(
  COALESCE((SELECT MAX(version) FROM categories WHERE user_id = u.id), 0),
  COALESCE((SELECT MAX(version) FROM tasks      WHERE user_id = u.id), 0),
  COALESCE((SELECT MAX(version) FROM sessions   WHERE user_id = u.id), 0)
);
