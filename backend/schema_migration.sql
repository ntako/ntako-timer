-- NTAKO_TIMER — Migration script for existing databases
-- Run this on databases created with the original schema.sql
-- Safe to run multiple times (uses IF NOT EXISTS / IF EXISTS guards).

-- 1. Create categories table
CREATE TABLE IF NOT EXISTS categories (
  id         INT PRIMARY KEY AUTO_INCREMENT,
  user_id    INT NOT NULL,
  client_id  VARCHAR(36) NOT NULL,
  name       VARCHAR(100) NOT NULL,
  color      VARCHAR(7) NOT NULL DEFAULT '#6366f1',
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  deleted_at BIGINT DEFAULT NULL,
  CONSTRAINT fk_categories_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  UNIQUE KEY uq_user_client_cat (user_id, client_id)
);

-- 2. Add category_id column to tasks (if not present)
ALTER TABLE tasks
  ADD COLUMN IF NOT EXISTS category_id INT DEFAULT NULL AFTER client_id,
  ADD COLUMN IF NOT EXISTS type VARCHAR(20) NOT NULL DEFAULT 'pomodoro' AFTER description;

-- 3. Add FK constraint for category_id (skip if already exists)
ALTER TABLE tasks
  ADD CONSTRAINT fk_tasks_category FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE SET NULL;

-- 4. Rename pomodoro_sessions → sessions (skip if sessions already exists)
RENAME TABLE pomodoro_sessions TO sessions;

-- 5. Remove pomodoro columns from tasks (if present)
ALTER TABLE tasks
  DROP COLUMN IF EXISTS pomodoro_goal,
  DROP COLUMN IF EXISTS pomodoros_done;

-- 6. Update type default to 'tracker'
ALTER TABLE tasks MODIFY COLUMN type VARCHAR(20) NOT NULL DEFAULT 'tracker';
