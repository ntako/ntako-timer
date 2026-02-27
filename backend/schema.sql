-- NTAKO_TIMER Database Schema
-- Compatible with MySQL 5.7+ and MySQL 8.0

CREATE TABLE IF NOT EXISTS users (
  id            INT PRIMARY KEY AUTO_INCREMENT,
  email         VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

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

CREATE TABLE IF NOT EXISTS tasks (
  id           INT PRIMARY KEY AUTO_INCREMENT,
  user_id      INT NOT NULL,
  client_id    VARCHAR(36) NOT NULL,
  category_id  INT DEFAULT NULL,
  title        VARCHAR(255) NOT NULL,
  description  TEXT,
  type         VARCHAR(20) NOT NULL DEFAULT 'pomodoro' COMMENT 'pomodoro | tracker',
  pomodoro_goal  INT DEFAULT 4,
  pomodoros_done INT DEFAULT 0,
  is_completed TINYINT(1) DEFAULT 0,
  created_at   BIGINT NOT NULL,
  updated_at   BIGINT NOT NULL,
  deleted_at   BIGINT DEFAULT NULL,
  CONSTRAINT fk_tasks_user     FOREIGN KEY (user_id)     REFERENCES users(id)      ON DELETE CASCADE,
  CONSTRAINT fk_tasks_category FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE SET NULL,
  UNIQUE KEY uq_user_client_task (user_id, client_id)
);

CREATE TABLE IF NOT EXISTS sessions (
  id               INT PRIMARY KEY AUTO_INCREMENT,
  user_id          INT NOT NULL,
  task_id          INT DEFAULT NULL,
  client_id        VARCHAR(36) NOT NULL,
  type             VARCHAR(20) NOT NULL COMMENT 'work | short_break | long_break | tracking',
  started_at       BIGINT NOT NULL,
  ended_at         BIGINT DEFAULT NULL,
  duration_seconds INT NOT NULL,
  is_completed     TINYINT(1) DEFAULT 0,
  created_at       BIGINT NOT NULL,
  CONSTRAINT fk_sessions_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  CONSTRAINT fk_sessions_task FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL,
  UNIQUE KEY uq_user_client_session (user_id, client_id)
);
