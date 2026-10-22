-- NTAKO_TIMER — Migration 003: tables to utf8mb4
-- Run ONCE on databases whose tables were created with the server default
-- charset (latin1 on MySQL 5.7). Safe to re-run: converting a table that is
-- already utf8mb4 changes nothing.
--
-- Why: latin1 cannot store characters such as "→" or emoji. A single task
-- containing one makes every sync push fail with
-- "1366 Incorrect string value", since a push is all or nothing.
--
-- ROW_FORMAT=DYNAMIC keeps the utf8mb4 index on users.email (255 chars ×
-- 4 bytes) within InnoDB's key length limit on older row formats.

ALTER TABLE users
  ROW_FORMAT=DYNAMIC,
  CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

ALTER TABLE categories
  ROW_FORMAT=DYNAMIC,
  CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

ALTER TABLE tasks
  ROW_FORMAT=DYNAMIC,
  CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

ALTER TABLE sessions
  ROW_FORMAT=DYNAMIC,
  CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
