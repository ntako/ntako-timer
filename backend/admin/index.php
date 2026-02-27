<?php

declare(strict_types=1);

session_start();

header('Cache-Control: no-store, no-cache, must-revalidate');
header('Pragma: no-cache');
header_remove('X-Powered-By');

require_once __DIR__ . '/../config/database.php';

$adminPass = getenv('ADMIN_PASS') ?: 'admin_change_me';
$loginError = '';

// ── Auth actions ──────────────────────────────────────────────────────────────
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    if (isset($_POST['logout'])) {
        session_destroy();
        header('Location: ' . strtok($_SERVER['REQUEST_URI'], '?'));
        exit;
    }
    if (hash_equals($adminPass, (string) ($_POST['password'] ?? ''))) {
        $_SESSION['ntako_admin'] = true;
        header('Location: ' . strtok($_SERVER['REQUEST_URI'], '?'));
        exit;
    }
    $loginError = 'Password errata.';
}

// ── Login form ────────────────────────────────────────────────────────────────
if (empty($_SESSION['ntako_admin'])) {
    http_response_code(401);
    ?>
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NTAKO Admin — Accesso</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0 }
  body { font-family: system-ui, sans-serif; background: #f1f3f5; display: flex;
         align-items: center; justify-content: center; min-height: 100vh; }
  .card { background: #fff; border-radius: 12px; padding: 2.5rem 2rem;
          box-shadow: 0 4px 24px rgba(0,0,0,.10); width: 100%; max-width: 340px; }
  h1 { font-size: 1.4rem; margin-bottom: 0.25rem; color: #111; }
  .sub { font-size: .85rem; color: #888; margin-bottom: 1.75rem; }
  label { font-size: .8rem; font-weight: 600; color: #555; display: block; margin-bottom: .35rem; }
  input[type=password] { width: 100%; padding: .65rem .85rem; border: 1px solid #ddd;
                         border-radius: 7px; font-size: 1rem; outline: none; }
  input[type=password]:focus { border-color: #e84545; box-shadow: 0 0 0 3px rgba(232,69,69,.12); }
  button { margin-top: 1.1rem; width: 100%; background: #e84545; color: #fff; border: none;
           border-radius: 7px; padding: .7rem; font-size: 1rem; font-weight: 600; cursor: pointer; }
  button:hover { background: #c73535; }
  .err { margin-top: .85rem; color: #c0392b; font-size: .85rem; text-align: center; }
</style>
</head>
<body>
<div class="card">
  <h1>NTAKO Timer</h1>
  <p class="sub">Pannello di amministrazione</p>
  <form method="post">
    <label for="pw">Password admin</label>
    <input type="password" id="pw" name="password" autofocus autocomplete="current-password">
    <button type="submit">Accedi</button>
    <?php if ($loginError !== '') echo '<p class="err">' . htmlspecialchars($loginError) . '</p>'; ?>
  </form>
</div>
</body>
</html>
    <?php
    exit;
}

// ── Dashboard ─────────────────────────────────────────────────────────────────
$pdo = getDbConnection();

/** @var list<array<string,mixed>> $users */
$users = $pdo->query('
    SELECT
        u.id,
        u.email,
        u.created_at                                                          AS registered,
        (SELECT COUNT(*) FROM tasks t
         WHERE t.user_id = u.id AND t.deleted_at IS NULL)                    AS tasks_total,
        (SELECT COUNT(*) FROM tasks t
         WHERE t.user_id = u.id AND t.deleted_at IS NULL AND t.type = "pomodoro") AS pomo_tasks,
        (SELECT COUNT(*) FROM tasks t
         WHERE t.user_id = u.id AND t.deleted_at IS NULL AND t.type = "tracker")  AS track_tasks,
        (SELECT COUNT(*) FROM tasks t
         WHERE t.user_id = u.id AND t.deleted_at IS NULL AND t.is_completed = 1)  AS done_tasks,
        (SELECT COUNT(*) FROM sessions s
         WHERE s.user_id = u.id)                                             AS sessions_total,
        (SELECT COUNT(*) FROM sessions s
         WHERE s.user_id = u.id AND s.type = "work")                        AS work_sessions,
        (SELECT COUNT(*) FROM sessions s
         WHERE s.user_id = u.id AND s.type = "tracking")                    AS track_sessions,
        (SELECT COUNT(*) FROM sessions s
         WHERE s.user_id = u.id AND s.type IN ("short_break","long_break")) AS break_sessions,
        (SELECT COALESCE(SUM(s.duration_seconds), 0) FROM sessions s
         WHERE s.user_id = u.id AND s.ended_at IS NOT NULL)                 AS total_seconds,
        (SELECT COUNT(*) FROM sessions s
         WHERE s.user_id = u.id AND s.ended_at IS NULL)                     AS open_sessions
    FROM users u
    ORDER BY u.created_at DESC
')->fetchAll(PDO::FETCH_ASSOC);

$totalUsers    = count($users);
$totalTasks    = (int) array_sum(array_column($users, 'tasks_total'));
$totalSessions = (int) array_sum(array_column($users, 'sessions_total'));
$totalOpen     = (int) array_sum(array_column($users, 'open_sessions'));

/** Format seconds into hh:mm */
$fmtTime = static function (int $s): string {
    $h = intdiv($s, 3600);
    $m = intdiv($s % 3600, 60);
    return sprintf('%dh %02dm', $h, $m);
};

?>
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NTAKO Admin</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0 }
  body { font-family: system-ui, sans-serif; background: #f1f3f5; color: #222; }

  /* ── Top bar ── */
  header { background: #e84545; color: #fff; padding: .9rem 1.5rem;
           display: flex; align-items: center; justify-content: space-between; }
  header h1 { font-size: 1.15rem; font-weight: 700; letter-spacing: .02em; }
  header .meta { font-size: .8rem; opacity: .85; }
  form.logout button { background: rgba(255,255,255,.18); border: 1px solid rgba(255,255,255,.4);
                       color: #fff; padding: .35rem .9rem; border-radius: 6px;
                       cursor: pointer; font-size: .82rem; font-weight: 600; }
  form.logout button:hover { background: rgba(255,255,255,.3); }

  /* ── Summary cards ── */
  .summary { display: flex; gap: 1rem; padding: 1.25rem 1.5rem; flex-wrap: wrap; }
  .kpi { background: #fff; border-radius: 10px; padding: 1rem 1.4rem; flex: 1; min-width: 130px;
         box-shadow: 0 1px 6px rgba(0,0,0,.07); }
  .kpi .val { font-size: 2rem; font-weight: 700; color: #e84545; line-height: 1; }
  .kpi .lbl { font-size: .75rem; color: #888; margin-top: .2rem; }
  .kpi.warn .val { color: #e67e22; }

  /* ── Table ── */
  .wrap { padding: 0 1.5rem 2rem; overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; background: #fff;
          border-radius: 10px; overflow: hidden; box-shadow: 0 1px 6px rgba(0,0,0,.07); font-size: .85rem; }
  thead { background: #f8f8f8; }
  th { padding: .75rem 1rem; text-align: left; font-size: .73rem; font-weight: 700;
       text-transform: uppercase; letter-spacing: .05em; color: #777; border-bottom: 1px solid #eee; white-space: nowrap; }
  td { padding: .75rem 1rem; border-bottom: 1px solid #f2f2f2; vertical-align: middle; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: #fafafa; }
  .email { font-weight: 600; color: #111; }
  .badge { display: inline-block; padding: .15rem .55rem; border-radius: 99px;
           font-size: .72rem; font-weight: 700; }
  .badge-pomo  { background: #fde8e8; color: #c0392b; }
  .badge-track { background: #e8f4fd; color: #2980b9; }
  .badge-open  { background: #fef3cd; color: #d68910; }
  .badge-ok    { background: #eafaf1; color: #1e8449; }
  .num { font-variant-numeric: tabular-nums; }
  .dim { color: #aaa; font-size: .78rem; }
  .reg { font-size: .78rem; color: #999; }
</style>
</head>
<body>

<header>
  <h1>NTAKO Timer &mdash; Admin</h1>
  <div style="display:flex;align-items:center;gap:1.2rem">
    <span class="meta"><?= date('d/m/Y H:i') ?></span>
    <form class="logout" method="post">
      <button type="submit" name="logout" value="1">Esci</button>
    </form>
  </div>
</header>

<div class="summary">
  <div class="kpi">
    <div class="val"><?= $totalUsers ?></div>
    <div class="lbl">Utenti registrati</div>
  </div>
  <div class="kpi">
    <div class="val"><?= $totalTasks ?></div>
    <div class="lbl">Task totali</div>
  </div>
  <div class="kpi">
    <div class="val"><?= $totalSessions ?></div>
    <div class="lbl">Sessioni totali</div>
  </div>
  <div class="kpi <?= $totalOpen > 0 ? 'warn' : '' ?>">
    <div class="val"><?= $totalOpen ?></div>
    <div class="lbl">Sessioni aperte</div>
  </div>
</div>

<div class="wrap">
<?php if (empty($users)): ?>
  <p style="padding:2rem;color:#999;text-align:center">Nessun utente registrato.</p>
<?php else: ?>
<table>
  <thead>
    <tr>
      <th>Utente</th>
      <th>Registrato</th>
      <th>Task</th>
      <th>Pomodoro</th>
      <th>Tracker</th>
      <th>Completati</th>
      <th>Sessioni</th>
      <th>Work</th>
      <th>Tracking</th>
      <th>Pause</th>
      <th>Tempo totale</th>
      <th>Aperte</th>
    </tr>
  </thead>
  <tbody>
  <?php foreach ($users as $u): ?>
    <?php
      $open = (int) $u['open_sessions'];
      $secs = (int) $u['total_seconds'];
    ?>
    <tr>
      <td class="email"><?= htmlspecialchars((string) $u['email']) ?></td>
      <td class="reg"><?= date('d/m/Y', strtotime((string) $u['registered'])) ?></td>
      <td class="num"><?= (int) $u['tasks_total'] ?></td>
      <td><span class="badge badge-pomo"><?= (int) $u['pomo_tasks'] ?></span></td>
      <td><span class="badge badge-track"><?= (int) $u['track_tasks'] ?></span></td>
      <td>
        <?php $done = (int) $u['done_tasks']; $tot = (int) $u['tasks_total']; ?>
        <span class="badge <?= $done > 0 ? 'badge-ok' : '' ?>"><?= $done ?></span>
        <span class="dim">/ <?= $tot ?></span>
      </td>
      <td class="num"><?= (int) $u['sessions_total'] ?></td>
      <td class="num"><?= (int) $u['work_sessions'] ?></td>
      <td class="num"><?= (int) $u['track_sessions'] ?></td>
      <td class="num"><?= (int) $u['break_sessions'] ?></td>
      <td class="num"><?= $secs > 0 ? $fmtTime($secs) : '<span class="dim">—</span>' ?></td>
      <td>
        <?php if ($open > 0): ?>
          <span class="badge badge-open">⚠ <?= $open ?></span>
        <?php else: ?>
          <span class="dim">—</span>
        <?php endif; ?>
      </td>
    </tr>
  <?php endforeach; ?>
  </tbody>
</table>
<?php endif; ?>
</div>

</body>
</html>
