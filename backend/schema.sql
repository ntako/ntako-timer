-- NTAKO_TIMER Database Schema
-- Compatible with MySQL 5.7+ and MySQL 8.0
-- utf8mb4 explicitly: MySQL 5.7 defaults to latin1, which rejects "→", emoji…

CREATE TABLE IF NOT EXISTS users (
  id            INT PRIMARY KEY AUTO_INCREMENT,
  email         VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  sync_seq      BIGINT NOT NULL DEFAULT 0 COMMENT 'last version handed out to this user''s rows',
  created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS categories (
  id         INT PRIMARY KEY AUTO_INCREMENT,
  user_id    INT NOT NULL,
  client_id  VARCHAR(36) NOT NULL,
  name       VARCHAR(100) NOT NULL,
  color      VARCHAR(7) NOT NULL DEFAULT '#6366f1',
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  deleted_at BIGINT DEFAULT NULL,
  version    BIGINT NOT NULL DEFAULT 0 COMMENT 'per-user change counter, drives incremental pull',
  KEY idx_categories_user_version (user_id, version),
  CONSTRAINT fk_categories_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  UNIQUE KEY uq_user_client_cat (user_id, client_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS tasks (
  id           INT PRIMARY KEY AUTO_INCREMENT,
  user_id      INT NOT NULL,
  client_id    VARCHAR(36) NOT NULL,
  category_id  INT DEFAULT NULL,
  title        VARCHAR(255) NOT NULL,
  description  TEXT,
  type         VARCHAR(20) NOT NULL DEFAULT 'tracker',
  is_completed TINYINT(1) DEFAULT 0,
  created_at   BIGINT NOT NULL,
  updated_at   BIGINT NOT NULL,
  deleted_at   BIGINT DEFAULT NULL,
  version      BIGINT NOT NULL DEFAULT 0,
  KEY idx_tasks_user_version (user_id, version),
  CONSTRAINT fk_tasks_user     FOREIGN KEY (user_id)     REFERENCES users(id)      ON DELETE CASCADE,
  CONSTRAINT fk_tasks_category FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE SET NULL,
  UNIQUE KEY uq_user_client_task (user_id, client_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS sessions (
  id               INT PRIMARY KEY AUTO_INCREMENT,
  user_id          INT NOT NULL,
  task_id          INT DEFAULT NULL,
  client_id        VARCHAR(36) NOT NULL,
  type             VARCHAR(20) NOT NULL COMMENT 'tracking',
  started_at       BIGINT NOT NULL,
  ended_at         BIGINT DEFAULT NULL,
  duration_seconds INT NOT NULL,
  is_completed     TINYINT(1) DEFAULT 0,
  created_at       BIGINT NOT NULL,
  version          BIGINT NOT NULL DEFAULT 0,
  KEY idx_sessions_user_version (user_id, version),
  CONSTRAINT fk_sessions_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  CONSTRAINT fk_sessions_task FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL,
  UNIQUE KEY uq_user_client_session (user_id, client_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
