<?php

declare(strict_types=1);

session_start();

header('Cache-Control: no-store, no-cache, must-revalidate');
header('Pragma: no-cache');
header_remove('X-Powered-By');

require_once __DIR__ . '/../config/database.php';

// No usable ADMIN_PASS → panel disabled, never a default password.
$adminPass  = configuredSecret('ADMIN_PASS');
$loginError = '';

if ($adminPass === null) {
    unset($_SESSION['ntako_admin']);
    $loginError = 'Pannello disabilitato: imposta ADMIN_PASS in config/local.php.';
}

// ── Auth actions ──────────────────────────────────────────────────────────────
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    if (isset($_POST['logout'])) {
        session_destroy();
        header('Location: ' . strtok($_SERVER['REQUEST_URI'], '?'));
        exit;
    }
    if ($adminPass !== null) {
        if (hash_equals($adminPass, (string) ($_POST['password'] ?? ''))) {
            $_SESSION['ntako_admin'] = true;
            header('Location: ' . strtok($_SERVER['REQUEST_URI'], '?'));
            exit;
        }
        $loginError = 'Password errata.';
    }
}

// ── Login form ────────────────────────────────────────────────────────────────
if (empty($_SESSION['ntako_admin'])) {
    http_response_code($adminPass === null ? 503 : 401);
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

// ── Helpers ───────────────────────────────────────────────────────────────────
$pdo = getDbConnection();

/** Format seconds → e.g. "3h 42m" or "18m" */
$fmtTime = static function (int $s): string {
    if ($s <= 0) return '—';
    $h = intdiv($s, 3600);
    $m = intdiv($s % 3600, 60);
    return $h > 0 ? sprintf('%dh %02dm', $h, $m) : sprintf('%dm', $m);
};

/** Format unix-ms timestamp → "d/m/Y H:i" */
$fmtMs = static function (int $ms): string {
    return date('d/m/Y H:i', intdiv($ms, 1000));
};

/** Returns session stats grouped by category > task for the given time window */
function getPeriodStats(PDO $pdo, int $uid, int $fromMs, int $toMs): array
{
    $stmt = $pdo->prepare('
        SELECT
            COALESCE(c.id, 0)                              AS cat_id,
            COALESCE(c.name, "Senza categoria")            AS cat_name,
            COALESCE(c.color, "#6b7280")                   AS cat_color,
            t.id                                           AS task_id,
            t.title                                        AS task_title,
            t.is_completed,
            t.deleted_at,
            COUNT(s.id)                                    AS session_count,
            COALESCE(SUM(s.duration_seconds), 0)           AS total_seconds,
            MIN(s.started_at)                              AS first_ms,
            MAX(s.started_at)                              AS last_ms
        FROM sessions s
        JOIN tasks t   ON t.id = s.task_id
        LEFT JOIN categories c ON c.id = t.category_id
        WHERE s.user_id  = :uid
          AND s.ended_at IS NOT NULL
          AND s.started_at >= :from_ms
          AND s.started_at <  :to_ms
        GROUP BY t.id, c.id
        ORDER BY cat_name, t.title
    ');
    $stmt->execute([':uid' => $uid, ':from_ms' => $fromMs, ':to_ms' => $toMs]);
    return $stmt->fetchAll(PDO::FETCH_ASSOC);
}

/** Groups flat rows by category, calculates subtotals + grand total */
function groupByCategory(array $rows): array
{
    $cats = [];
    foreach ($rows as $r) {
        $cid = (int) $r['cat_id'];
        if (!isset($cats[$cid])) {
            $cats[$cid] = [
                'cat_name'  => $r['cat_name'],
                'cat_color' => $r['cat_color'],
                'tasks'     => [],
                'sub_sec'   => 0,
                'sub_sess'  => 0,
            ];
        }
        $cats[$cid]['tasks'][]    = $r;
        $cats[$cid]['sub_sec']   += (int) $r['total_seconds'];
        $cats[$cid]['sub_sess']  += (int) $r['session_count'];
    }
    $total_sec  = array_sum(array_column($cats, 'sub_sec'));
    $total_sess = array_sum(array_column($cats, 'sub_sess'));
    return ['cats' => $cats, 'total_sec' => $total_sec, 'total_sess' => $total_sess];
}

// ── User detail view ──────────────────────────────────────────────────────────
$userId = isset($_GET['user']) ? (int) $_GET['user'] : 0;

if ($userId > 0) {

    // Fetch user info
    $stmt = $pdo->prepare('SELECT id, email, created_at FROM users WHERE id = ?');
    $stmt->execute([$userId]);
    $user = $stmt->fetch(PDO::FETCH_ASSOC);
    if (!$user) {
        http_response_code(404);
        echo '<p style="padding:2rem;font-family:sans-serif">Utente non trovato.</p>';
        exit;
    }

    // All-time KPIs — use ? placeholders to avoid PDO named-param reuse limit
    $kpi = $pdo->prepare('
        SELECT
            (SELECT COUNT(*) FROM tasks t
             WHERE t.user_id = ? AND t.deleted_at IS NULL)                         AS tasks_active,
            (SELECT COUNT(*) FROM tasks t
             WHERE t.user_id = ? AND t.deleted_at IS NULL AND t.is_completed = 1)  AS tasks_done,
            (SELECT COUNT(*) FROM tasks t
             WHERE t.user_id = ? AND t.deleted_at IS NOT NULL)                     AS tasks_deleted,
            (SELECT COUNT(*) FROM sessions s
             WHERE s.user_id = ? AND s.ended_at IS NOT NULL)                       AS sess_total,
            (SELECT COALESCE(SUM(s.duration_seconds), 0) FROM sessions s
             WHERE s.user_id = ? AND s.ended_at IS NOT NULL)                       AS secs_total,
            (SELECT COUNT(*) FROM sessions s
             WHERE s.user_id = ? AND s.ended_at IS NULL)                           AS sess_open,
            (SELECT COUNT(*) FROM categories c
             WHERE c.user_id = ? AND c.deleted_at IS NULL)                         AS cats_active
    ');
    $kpi->execute(array_fill(0, 7, $userId));
    $k = $kpi->fetch(PDO::FETCH_ASSOC);

    // Top category all-time
    $topCat = $pdo->prepare('
        SELECT COALESCE(c.name, "Senza categoria") AS name,
               COALESCE(SUM(s.duration_seconds), 0) AS secs
        FROM sessions s
        JOIN tasks t ON t.id = s.task_id
        LEFT JOIN categories c ON c.id = t.category_id
        WHERE s.user_id = :uid AND s.ended_at IS NOT NULL
        GROUP BY c.id
        ORDER BY secs DESC
        LIMIT 1
    ');
    $topCat->execute([':uid' => $userId]);
    $topCatRow = $topCat->fetch(PDO::FETCH_ASSOC);

    // Daily sessions breakdown (last 7 days)
    $dailyBreakdown = $pdo->prepare('
        SELECT DATE(FROM_UNIXTIME(s.started_at / 1000)) AS day,
               COUNT(s.id)                              AS sessions,
               COALESCE(SUM(s.duration_seconds), 0)    AS secs
        FROM sessions s
        WHERE s.user_id = :uid
          AND s.ended_at IS NOT NULL
          AND s.started_at >= :from_ms
        GROUP BY day
        ORDER BY day DESC
    ');
    $sevenDaysAgo = (strtotime('-6 days midnight')) * 1000;
    $dailyBreakdown->execute([':uid' => $userId, ':from_ms' => $sevenDaysAgo]);
    $dailyRows = $dailyBreakdown->fetchAll(PDO::FETCH_ASSOC);

    // Period boundaries (unix ms)
    $todayStart  = strtotime('today midnight') * 1000;
    $todayEnd    = strtotime('tomorrow midnight') * 1000;
    $monthStart  = strtotime(date('Y-m-01') . ' midnight') * 1000;
    $monthEnd    = strtotime(date('Y-m-01', strtotime('+1 month')) . ' midnight') * 1000;
    $yearStart   = strtotime(date('Y') . '-01-01 midnight') * 1000;
    $yearEnd     = strtotime((date('Y') + 1) . '-01-01 midnight') * 1000;

    $statsDay   = groupByCategory(getPeriodStats($pdo, $userId, $todayStart, $todayEnd));
    $statsMonth = groupByCategory(getPeriodStats($pdo, $userId, $monthStart, $monthEnd));
    $statsYear  = groupByCategory(getPeriodStats($pdo, $userId, $yearStart, $yearEnd));

    // ── render helper ────────────────────────────────────────────────────────
    $renderPeriod = function (array $data) use ($fmtTime, $fmtMs): void {
        if ($data['total_sess'] === 0) {
            echo '<p class="empty">Nessuna sessione in questo periodo.</p>';
            return;
        }
        echo '<table class="rtable">';
        echo '<thead><tr>
                <th style="width:40%">Task / Categoria</th>
                <th>Sessioni</th>
                <th>Tempo</th>
                <th>Prima sessione</th>
                <th>Ultima sessione</th>
                <th>Stato</th>
              </tr></thead><tbody>';

        foreach ($data['cats'] as $cat) {
            $hex   = htmlspecialchars($cat['cat_color']);
            $cname = htmlspecialchars($cat['cat_name']);
            // Category header row
            echo "<tr class=\"cat-row\">
                    <td colspan=\"6\">
                      <span class=\"cat-dot\" style=\"background:{$hex}\"></span>
                      <strong>{$cname}</strong>
                    </td>
                  </tr>";
            foreach ($cat['tasks'] as $t) {
                $title   = htmlspecialchars((string) $t['task_title']);
                $done    = (int) $t['is_completed'];
                $deleted = $t['deleted_at'] !== null && $t['deleted_at'] !== '0';
                $badge   = $deleted
                    ? '<span class="badge badge-del">eliminato</span>'
                    : ($done
                        ? '<span class="badge badge-ok">completato</span>'
                        : '<span class="badge badge-run">attivo</span>');
                $first = $t['first_ms'] ? $fmtMs((int) $t['first_ms']) : '—';
                $last  = $t['last_ms']  ? $fmtMs((int) $t['last_ms'])  : '—';
                echo "<tr class=\"task-row\">
                        <td class=\"task-title\">{$title}</td>
                        <td class=\"num\">{$t['session_count']}</td>
                        <td class=\"num time\">{$fmtTime((int)$t['total_seconds'])}</td>
                        <td class=\"num dim\">{$first}</td>
                        <td class=\"num dim\">{$last}</td>
                        <td>{$badge}</td>
                      </tr>";
            }
            // Category subtotal
            echo "<tr class=\"sub-row\">
                    <td class=\"sub-lbl\">Subtotale · {$cname}</td>
                    <td class=\"num\">{$cat['sub_sess']}</td>
                    <td class=\"num time\">{$fmtTime($cat['sub_sec'])}</td>
                    <td colspan=\"3\"></td>
                  </tr>";
        }

        // Grand total
        echo "<tr class=\"total-row\">
                <td><strong>TOTALE</strong></td>
                <td class=\"num\"><strong>{$data['total_sess']}</strong></td>
                <td class=\"num time\"><strong>{$fmtTime($data['total_sec'])}</strong></td>
                <td colspan=\"3\"></td>
              </tr>";
        echo '</tbody></table>';
    };

    ?>
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NTAKO Admin — <?= htmlspecialchars((string) $user['email']) ?></title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0 }
  body { font-family: system-ui, sans-serif; background: #f1f3f5; color: #222; }

  /* top bar */
  header { background: #e84545; color: #fff; padding: .9rem 1.5rem;
           display: flex; align-items: center; justify-content: space-between; }
  header h1 { font-size: 1.15rem; font-weight: 700; letter-spacing: .02em; }
  .back { color: #fff; text-decoration: none; font-size: .88rem; font-weight: 600;
          background: rgba(255,255,255,.18); border: 1px solid rgba(255,255,255,.35);
          padding: .3rem .85rem; border-radius: 6px; }
  .back:hover { background: rgba(255,255,255,.3); }
  form.logout button { background: rgba(255,255,255,.18); border: 1px solid rgba(255,255,255,.4);
                       color: #fff; padding: .35rem .9rem; border-radius: 6px;
                       cursor: pointer; font-size: .82rem; font-weight: 600; }
  form.logout button:hover { background: rgba(255,255,255,.3); }

  /* user card */
  .ucard { margin: 1.25rem 1.5rem .5rem; background: #fff; border-radius: 10px;
           padding: 1.2rem 1.5rem; box-shadow: 0 1px 6px rgba(0,0,0,.07);
           display: flex; align-items: center; gap: 1.5rem; flex-wrap: wrap; }
  .avatar { width: 48px; height: 48px; border-radius: 50%; background: #e84545;
            display: flex; align-items: center; justify-content: center;
            font-size: 1.3rem; font-weight: 700; color: #fff; flex-shrink: 0; }
  .uinfo h2 { font-size: 1.1rem; color: #111; }
  .uinfo .reg { font-size: .8rem; color: #999; margin-top: .15rem; }

  /* KPI cards */
  .summary { display: flex; gap: .85rem; padding: .75rem 1.5rem 1rem; flex-wrap: wrap; }
  .kpi { background: #fff; border-radius: 10px; padding: .85rem 1.2rem; flex: 1; min-width: 110px;
         box-shadow: 0 1px 6px rgba(0,0,0,.07); }
  .kpi .val { font-size: 1.7rem; font-weight: 700; color: #e84545; line-height: 1; }
  .kpi .lbl { font-size: .72rem; color: #888; margin-top: .18rem; }
  .kpi.warn .val { color: #e67e22; }
  .kpi.ok   .val { color: #1e8449; }
  .kpi.blue .val { color: #2980b9; }

  /* 7-day bar chart */
  .wrap  { padding: 0 1.5rem 2rem; }
  .section-title { font-size: .82rem; font-weight: 700; text-transform: uppercase;
                   letter-spacing: .05em; color: #999; margin-bottom: .65rem; }

  .daybars { display: flex; gap: .4rem; align-items: flex-end; height: 60px;
             background: #fff; border-radius: 10px; padding: .75rem 1rem .5rem;
             box-shadow: 0 1px 6px rgba(0,0,0,.07); margin-bottom: 1.5rem; }
  .daybar-col { display: flex; flex-direction: column; align-items: center; flex: 1; gap: 2px; }
  .daybar-fill { width: 100%; background: #e84545; border-radius: 3px 3px 0 0; min-height: 2px; }
  .daybar-lbl  { font-size: .62rem; color: #aaa; white-space: nowrap; }
  .daybar-val  { font-size: .65rem; color: #555; font-weight: 600; }

  /* tabs */
  .tabs { display: flex; gap: .3rem; margin-bottom: 1rem; }
  .tab-btn { background: #fff; border: 1px solid #ddd; border-radius: 7px;
             padding: .45rem 1.1rem; font-size: .85rem; font-weight: 600; cursor: pointer;
             color: #555; transition: all .15s; }
  .tab-btn.active { background: #e84545; color: #fff; border-color: #e84545; }
  .tab-btn:hover:not(.active) { border-color: #bbb; }
  .tab-panel { display: none; }
  .tab-panel.active { display: block; }

  /* report table */
  .rtable { width: 100%; border-collapse: collapse; background: #fff;
            border-radius: 10px; overflow: hidden; box-shadow: 0 1px 6px rgba(0,0,0,.07);
            font-size: .83rem; }
  .rtable thead { background: #f8f8f8; }
  .rtable th { padding: .65rem 1rem; text-align: left; font-size: .71rem; font-weight: 700;
               text-transform: uppercase; letter-spacing: .05em; color: #777;
               border-bottom: 1px solid #eee; white-space: nowrap; }
  .rtable td { padding: .6rem 1rem; border-bottom: 1px solid #f2f2f2; vertical-align: middle; }
  .rtable tr:last-child td { border-bottom: none; }

  /* category header row */
  .cat-row td { background: #f5f5f5; font-size: .8rem; padding: .45rem 1rem; }
  .cat-dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%;
             margin-right: .45rem; vertical-align: middle; }

  /* task rows */
  .task-row:hover td { background: #fafafa; }
  .task-title { font-weight: 500; padding-left: 2rem !important; }

  /* subtotal row */
  .sub-row td { background: #fdf6f6; font-size: .78rem; color: #888;
                padding: .4rem 1rem; border-bottom: 2px solid #f0e0e0; }
  .sub-lbl { padding-left: 2rem !important; font-style: italic; }

  /* total row */
  .total-row td { background: #fff0f0; padding: .65rem 1rem; border-top: 2px solid #e84545; }

  /* misc */
  .num  { font-variant-numeric: tabular-nums; }
  .time { font-weight: 600; color: #c0392b; }
  .dim  { color: #aaa; font-size: .78rem; }
  .badge { display: inline-block; padding: .12rem .5rem; border-radius: 99px;
           font-size: .7rem; font-weight: 700; }
  .badge-ok  { background: #eafaf1; color: #1e8449; }
  .badge-run { background: #eaf4fe; color: #2471a3; }
  .badge-del { background: #f5f5f5; color: #aaa; }
  .empty { padding: 1.5rem; color: #aaa; text-align: center; font-size: .88rem;
           background: #fff; border-radius: 10px; box-shadow: 0 1px 6px rgba(0,0,0,.07); }
</style>
</head>
<body>

<header>
  <div style="display:flex;align-items:center;gap:1rem">
    <a class="back" href="<?= htmlspecialchars(strtok($_SERVER['REQUEST_URI'], '?')) ?>">← Dashboard</a>
    <h1>Statistiche utente</h1>
  </div>
  <div style="display:flex;align-items:center;gap:1.2rem">
    <span style="font-size:.8rem;opacity:.85"><?= date('d/m/Y H:i') ?></span>
    <form class="logout" method="post">
      <button type="submit" name="logout" value="1">Esci</button>
    </form>
  </div>
</header>

<!-- User card -->
<div class="ucard">
  <div class="avatar"><?= strtoupper(mb_substr((string) $user['email'], 0, 1)) ?></div>
  <div class="uinfo">
    <h2><?= htmlspecialchars((string) $user['email']) ?></h2>
    <div class="reg">Registrato il <?= date('d/m/Y', strtotime((string) $user['created_at'])) ?>
      &nbsp;·&nbsp; ID #<?= (int) $user['id'] ?></div>
  </div>
</div>

<!-- KPI cards -->
<div class="summary">
  <div class="kpi">
    <div class="val"><?= (int) $k['tasks_active'] ?></div>
    <div class="lbl">Task attivi</div>
  </div>
  <div class="kpi ok">
    <div class="val"><?= (int) $k['tasks_done'] ?></div>
    <div class="lbl">Completati</div>
  </div>
  <div class="kpi blue">
    <div class="val"><?= (int) $k['cats_active'] ?></div>
    <div class="lbl">Categorie</div>
  </div>
  <div class="kpi">
    <div class="val"><?= (int) $k['sess_total'] ?></div>
    <div class="lbl">Sessioni totali</div>
  </div>
  <div class="kpi">
    <div class="val"><?= $fmtTime((int) $k['secs_total']) ?></div>
    <div class="lbl">Tempo totale</div>
  </div>
  <?php if ($topCatRow): ?>
  <div class="kpi">
    <div class="val" style="font-size:1rem;padding-top:.3rem"><?= htmlspecialchars((string) $topCatRow['name']) ?></div>
    <div class="lbl">Categoria top · <?= $fmtTime((int) $topCatRow['secs']) ?></div>
  </div>
  <?php endif; ?>
  <?php if ((int) $k['sess_open'] > 0): ?>
  <div class="kpi warn">
    <div class="val"><?= (int) $k['sess_open'] ?></div>
    <div class="lbl">Sessioni aperte</div>
  </div>
  <?php endif; ?>
</div>

<div class="wrap">

  <!-- 7-day mini bar chart -->
  <?php if (!empty($dailyRows)):
      $maxSecs = max(array_column($dailyRows, 'secs')) ?: 1;
      // Build a map day→data for the last 7 days
      $dayMap = [];
      foreach ($dailyRows as $dr) $dayMap[$dr['day']] = $dr;
  ?>
  <div class="section-title" style="margin-bottom:.65rem">Ultimi 7 giorni</div>
  <div class="daybars">
    <?php for ($i = 6; $i >= 0; $i--):
        $d   = date('Y-m-d', strtotime("-{$i} days"));
        $dr  = $dayMap[$d] ?? null;
        $sec = $dr ? (int) $dr['secs'] : 0;
        $pct = $maxSecs > 0 ? round($sec / $maxSecs * 44) : 0;
        $lbl = date('d/m', strtotime($d));
    ?>
      <div class="daybar-col">
        <div class="daybar-val"><?= $sec > 0 ? $fmtTime($sec) : '' ?></div>
        <div class="daybar-fill" style="height:<?= $pct ?>px"></div>
        <div class="daybar-lbl"><?= $lbl ?></div>
      </div>
    <?php endfor; ?>
  </div>
  <?php endif; ?>

  <!-- Period tabs -->
  <div class="tabs">
    <button class="tab-btn active" onclick="switchTab('day',this)">
      Oggi <span style="font-weight:400;opacity:.7"><?= $statsDay['total_sec'] > 0 ? '· ' . $fmtTime($statsDay['total_sec']) : '' ?></span>
    </button>
    <button class="tab-btn" onclick="switchTab('month',this)">
      <?= date('F Y') ?> <span style="font-weight:400;opacity:.7"><?= $statsMonth['total_sec'] > 0 ? '· ' . $fmtTime($statsMonth['total_sec']) : '' ?></span>
    </button>
    <button class="tab-btn" onclick="switchTab('year',this)">
      <?= date('Y') ?> <span style="font-weight:400;opacity:.7"><?= $statsYear['total_sec'] > 0 ? '· ' . $fmtTime($statsYear['total_sec']) : '' ?></span>
    </button>
  </div>

  <div id="tab-day"   class="tab-panel active"><?php $renderPeriod($statsDay); ?></div>
  <div id="tab-month" class="tab-panel"><?php $renderPeriod($statsMonth); ?></div>
  <div id="tab-year"  class="tab-panel"><?php $renderPeriod($statsYear); ?></div>

</div><!-- .wrap -->

<script>
function switchTab(id, btn) {
  document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
  document.getElementById('tab-' + id).classList.add('active');
  btn.classList.add('active');
}
</script>
</body>
</html>
    <?php
    exit;
}

// ── Dashboard ─────────────────────────────────────────────────────────────────
/** @var list<array<string,mixed>> $users */
$users = $pdo->query('
    SELECT
        u.id,
        u.email,
        u.created_at                                                          AS registered,
        (SELECT COUNT(*) FROM tasks t
         WHERE t.user_id = u.id AND t.deleted_at IS NULL)                    AS tasks_total,
        (SELECT COUNT(*) FROM tasks t
         WHERE t.user_id = u.id AND t.deleted_at IS NULL AND t.is_completed = 1)  AS done_tasks,
        (SELECT COUNT(*) FROM sessions s
         WHERE s.user_id = u.id)                                             AS sessions_total,
        (SELECT COUNT(*) FROM sessions s
         WHERE s.user_id = u.id AND s.type = "tracking")                    AS track_sessions,
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
  .email a { font-weight: 600; color: #e84545; text-decoration: none; }
  .email a:hover { text-decoration: underline; }
  .badge { display: inline-block; padding: .15rem .55rem; border-radius: 99px;
           font-size: .72rem; font-weight: 700; }
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
      <th>Completati</th>
      <th>Sessioni</th>
      <th>Tracking</th>
      <th>Tempo totale</th>
      <th>Aperte</th>
    </tr>
  </thead>
  <tbody>
  <?php foreach ($users as $u): ?>
    <?php
      $open = (int) $u['open_sessions'];
      $secs = (int) $u['total_seconds'];
      $detailUrl = '?user=' . (int) $u['id'];
    ?>
    <tr>
      <td class="email">
        <a href="<?= $detailUrl ?>"><?= htmlspecialchars((string) $u['email']) ?></a>
      </td>
      <td class="reg"><?= date('d/m/Y', strtotime((string) $u['registered'])) ?></td>
      <td class="num"><?= (int) $u['tasks_total'] ?></td>
      <td>
        <?php $done = (int) $u['done_tasks']; $tot = (int) $u['tasks_total']; ?>
        <span class="badge <?= $done > 0 ? 'badge-ok' : '' ?>"><?= $done ?></span>
        <span class="dim">/ <?= $tot ?></span>
      </td>
      <td class="num"><?= (int) $u['sessions_total'] ?></td>
      <td class="num"><?= (int) $u['track_sessions'] ?></td>
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
