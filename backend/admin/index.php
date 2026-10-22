<?php

declare(strict_types=1);

session_start();

header('Cache-Control: no-store, no-cache, must-revalidate');
header('Pragma: no-cache');
header_remove('X-Powered-By');

require_once __DIR__ . '/../config/database.php';
require_once __DIR__ . '/export.php';
require_once __DIR__ . '/import.php';
require_once __DIR__ . '/report.php';

// Dates on this page (filters, buckets, CSV) are in this timezone.
if (!@date_default_timezone_set((string) (getenv('APP_TIMEZONE') ?: 'Europe/Rome'))) {
    date_default_timezone_set('Europe/Rome');
}

// Token for the state-changing forms of a logged-in admin (import).
$_SESSION['csrf'] ??= bin2hex(random_bytes(16));
$csrf  = (string) $_SESSION['csrf'];
$flash = $_SESSION['flash'] ?? null;
unset($_SESSION['flash']);

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
    if ($adminPass !== null && isset($_POST['password'])) {
        if (hash_equals($adminPass, (string) $_POST['password'])) {
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
    // Rounded to the minute, like the charts and the app's history.
    $min = (int) round($s / 60);
    $h   = intdiv($min, 60);
    $m   = $min % 60;
    return $h > 0 ? sprintf('%dh %02dm', $h, $m) : sprintf('%dm', $m);
};

/** Format unix-ms timestamp → "d/m/Y H:i" */
$fmtMs = static function (int $ms): string {
    return date('d/m/Y H:i', intdiv($ms, 1000));
};

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

    // Import a JSON backup into this user's data (POST → redirect → GET).
    if ($_SERVER['REQUEST_METHOD'] === 'POST' && ($_POST['action'] ?? '') === 'import') {
        $upload = $_FILES['backup'] ?? null;
        $error  = (int) ($upload['error'] ?? UPLOAD_ERR_NO_FILE);
        if (!hash_equals($csrf, (string) ($_POST['csrf'] ?? ''))) {
            $result = ['ok' => false, 'msg' => 'Sessione scaduta: ricarica la pagina e riprova.'];
        } elseif ($error !== UPLOAD_ERR_OK) {
            $result = ['ok' => false, 'msg' => match ($error) {
                UPLOAD_ERR_INI_SIZE, UPLOAD_ERR_FORM_SIZE => 'File troppo grande per il server (upload_max_filesize).',
                UPLOAD_ERR_NO_FILE                        => 'Nessun file selezionato.',
                default                                   => 'Caricamento del file non riuscito.',
            }];
        } else {
            try {
                $counts = importBackup($pdo, $userId, (string) file_get_contents($upload['tmp_name']));
                $line = static fn (string $label, array $c): string =>
                    "$label: {$c['added']} nuove, {$c['updated']} aggiornate, {$c['unchanged']} già presenti";
                $result = ['ok' => true, 'msg' => implode("\n", [
                    'Importazione completata. I dispositivi ricevono i dati al prossimo sync.',
                    $line('Categorie', $counts['categories']),
                    $line('Task', $counts['tasks']),
                    $line('Sessioni', $counts['sessions']),
                ])];
            } catch (BackupImportError $e) {
                $result = ['ok' => false, 'msg' => $e->getMessage()];
            } catch (Throwable $e) {
                error_log('admin import failed for user ' . $userId . ': ' . $e);
                $result = ['ok' => false, 'msg' => 'Importazione non riuscita: dettagli nel log del server.'];
            }
        }
        $_SESSION['flash'] = $result;
        header('Location: ' . strtok($_SERVER['REQUEST_URI'], '?') . '?user=' . $userId);
        exit;
    }

    // Downloads: same formats as the app's backup / CSV export.
    $export = (string) ($_GET['export'] ?? '');
    if ($export === 'json' || $export === 'csv') {
        $fileName = sprintf('ntako_utente%d_%s.%s', $userId, date('Ymd_Hi'), $export);
        header('Content-Disposition: attachment; filename="' . $fileName . '"');
        if ($export === 'json') {
            header('Content-Type: application/json; charset=utf-8');
            echo json_encode(
                exportBackup($pdo, $userId),
                JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES
            );
        } else {
            header('Content-Type: text/csv; charset=utf-8');
            echo exportSessionsCsv($pdo, $userId);
        }
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

    // Filtered report for the charts and the list.
    $filters  = reportFilters($_GET, $pdo, $userId);
    $report   = buildReport($pdo, $userId, $filters);
    $listData = groupByCategory($report['rows']);

    $stmt = $pdo->prepare('SELECT id, name, deleted_at FROM categories WHERE user_id = ? ORDER BY name');
    $stmt->execute([$userId]);
    $catOptions = $stmt->fetchAll(PDO::FETCH_ASSOC);

    $taskSql = 'SELECT id, title, deleted_at FROM tasks WHERE user_id = ?';
    $taskArgs = [$userId];
    if ($filters['cat'] === 'none') {
        $taskSql .= ' AND category_id IS NULL';
    } elseif ($filters['cat'] !== '') {
        $taskSql .= ' AND category_id = ?';
        $taskArgs[] = (int) $filters['cat'];
    }
    $stmt = $pdo->prepare($taskSql . ' ORDER BY title');
    $stmt->execute($taskArgs);
    $taskOptions = $stmt->fetchAll(PDO::FETCH_ASSOC);

    $fmtDay = static fn (DateTimeImmutable $d): string =>
        $d->format('j') . ' ' . REPORT_MONTHS[(int) $d->format('n') - 1] . ' ' . $d->format('Y');
    $lastDay   = $filters['to']->modify('-1 day');
    $rangeText = $filters['from'] == $lastDay
        ? $fmtDay($lastDay)
        : $fmtDay($filters['from']) . ' – ' . $fmtDay($lastDay);
    $groupText = ['day' => 'giorno', 'week' => 'settimana', 'month' => 'mese'][$filters['group']];

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

  /* flash message */
  .flash { margin: 1rem 1.5rem 0; padding: .75rem 1rem; border-radius: 8px; font-size: .85rem;
           line-height: 1.5; }
  .flash.ok  { background: #eafaf1; color: #1e8449; }
  .flash.err { background: #fdecea; color: #a93226; }

  /* import */
  .import { position: relative; }
  .import summary { list-style: none; cursor: pointer; }
  .import summary::-webkit-details-marker { display: none; }
  .import-form { position: absolute; right: 0; top: calc(100% + .4rem); z-index: 5; width: 320px;
                 background: #fff; border-radius: 10px; padding: 1rem;
                 box-shadow: 0 6px 24px rgba(0,0,0,.15); display: grid; gap: .6rem; }
  .import-form button { background: #e84545; color: #fff; border: none; border-radius: 7px;
                        padding: .5rem; font-weight: 600; cursor: pointer; }
  .import-form .hint { font-size: .75rem; color: #888; line-height: 1.4; }

  /* filters: one row above everything they scope */
  .filters { display: flex; flex-wrap: wrap; align-items: flex-end; gap: .6rem .9rem;
             background: #fff; border-radius: 10px; padding: .8rem 1rem; margin-bottom: .5rem;
             box-shadow: 0 1px 6px rgba(0,0,0,.07); }
  .filters label { display: grid; gap: .2rem; font-size: .7rem; font-weight: 700; color: #888;
                   text-transform: uppercase; letter-spacing: .04em; }
  .filters select, .filters input { font: inherit; font-size: .85rem; text-transform: none;
                   letter-spacing: 0; font-weight: 400; color: #222; padding: .4rem .5rem;
                   border: 1px solid #ddd; border-radius: 6px; background: #fff; min-width: 9rem; }
  .filters .custom-range { display: flex; gap: .6rem; }
  .filters .custom-range[hidden] { display: none; }
  .filters .apply { background: #e84545; color: #fff; border: none; border-radius: 7px;
                    padding: .5rem 1rem; font-weight: 600; cursor: pointer; }
  .range-text { font-size: .8rem; color: #888; margin: .2rem 0 .9rem; }

  .period-kpis { padding: 0 0 1rem; }
  .view-toggle { display: flex; gap: .3rem; margin-bottom: .8rem; }

  /* charts */
  .chart-card { background: #fff; border-radius: 10px; padding: 1rem 1rem .75rem;
                box-shadow: 0 1px 6px rgba(0,0,0,.07); margin-bottom: 1rem; }
  .chart-title { font-size: .8rem; font-weight: 700; color: #555; margin-bottom: .6rem; }
  .chart-box { position: relative; }
  .chart-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 0 1rem;
                align-items: start; }
  .chart-fallback { font-size: .8rem; color: #888; }
  .exports { margin-left: auto; display: flex; gap: .5rem; flex-wrap: wrap; }
  .export { padding: .45rem .8rem; border: 1px solid #e84545; border-radius: 7px;
            color: #e84545; font-size: .8rem; font-weight: 600; text-decoration: none; }
  .export:hover { background: #e84545; color: #fff; }
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

<?php if ($flash): ?>
<div class="flash <?= $flash['ok'] ? 'ok' : 'err' ?>"><?= nl2br(htmlspecialchars((string) $flash['msg'])) ?></div>
<?php endif; ?>

<!-- User card -->
<div class="ucard">
  <div class="avatar"><?= strtoupper(mb_substr((string) $user['email'], 0, 1)) ?></div>
  <div class="uinfo">
    <h2><?= htmlspecialchars((string) $user['email']) ?></h2>
    <div class="reg">Registrato il <?= date('d/m/Y', strtotime((string) $user['created_at'])) ?>
      &nbsp;·&nbsp; ID #<?= (int) $user['id'] ?></div>
  </div>
  <div class="exports">
    <a class="export" href="?user=<?= (int) $user['id'] ?>&amp;export=json"
       title="Backup completo, importabile nell'app">⬇ Backup JSON</a>
    <a class="export" href="?user=<?= (int) $user['id'] ?>&amp;export=csv"
       title="Sessioni completate, per Excel o Fogli">⬇ Sessioni CSV</a>
    <details class="import">
      <summary class="export">⬆ Importa backup</summary>
      <?php $confirmText = json_encode(
          'Importare il backup nei dati di ' . $user['email'] . '? I dati vengono uniti: niente viene cancellato.',
          JSON_HEX_TAG | JSON_HEX_APOS | JSON_HEX_QUOT | JSON_HEX_AMP | JSON_UNESCAPED_UNICODE
      ); ?>
      <form class="import-form" method="post" enctype="multipart/form-data"
            onsubmit="return confirm(<?= htmlspecialchars((string) $confirmText, ENT_QUOTES) ?>)">
        <input type="hidden" name="action" value="import">
        <input type="hidden" name="csrf" value="<?= htmlspecialchars($csrf) ?>">
        <input type="file" name="backup" accept=".json,application/json" required>
        <button type="submit">Importa</button>
        <p class="hint">Backup JSON dell'app o di questo pannello. Unisce i dati senza
          cancellare nulla; i dispositivi dell'utente li ricevono al prossimo sync.</p>
      </form>
    </details>
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

  <!-- Filters: one row, scoping everything below -->
  <form class="filters" id="filters" method="get">
    <input type="hidden" name="user" value="<?= (int) $userId ?>">
    <label>Periodo
      <select name="period">
        <?php foreach (REPORT_PERIODS as $value => $label): ?>
          <option value="<?= $value ?>" <?= $filters['period'] === $value ? 'selected' : '' ?>><?= htmlspecialchars($label) ?></option>
        <?php endforeach; ?>
      </select>
    </label>
    <span class="custom-range" <?= $filters['period'] === 'custom' ? '' : 'hidden' ?>>
      <label>Dal <input type="date" name="from" value="<?= $filters['from']->format('Y-m-d') ?>"></label>
      <label>Al <input type="date" name="to" value="<?= $lastDay->format('Y-m-d') ?>"></label>
    </span>
    <label>Categoria
      <select name="cat">
        <option value="">Tutte</option>
        <option value="none" <?= $filters['cat'] === 'none' ? 'selected' : '' ?>>Senza categoria</option>
        <?php foreach ($catOptions as $c): ?>
          <option value="<?= (int) $c['id'] ?>" <?= $filters['cat'] === (string) $c['id'] ? 'selected' : '' ?>>
            <?= htmlspecialchars((string) $c['name']) ?><?= $c['deleted_at'] !== null ? ' (eliminata)' : '' ?></option>
        <?php endforeach; ?>
      </select>
    </label>
    <label>Task
      <select name="task">
        <option value="0">Tutti</option>
        <?php foreach ($taskOptions as $t): ?>
          <option value="<?= (int) $t['id'] ?>" <?= $filters['task'] === (int) $t['id'] ? 'selected' : '' ?>>
            <?= htmlspecialchars((string) $t['title'] !== '' ? (string) $t['title'] : '(senza titolo)') ?><?= $t['deleted_at'] !== null ? ' (eliminato)' : '' ?></option>
        <?php endforeach; ?>
      </select>
    </label>
    <label>Raggruppa per
      <select name="group">
        <?php foreach (REPORT_GROUPS as $value => $label): ?>
          <option value="<?= $value ?>" <?= $filters['groupChoice'] === $value ? 'selected' : '' ?>><?= $label ?></option>
        <?php endforeach; ?>
      </select>
    </label>
    <button type="submit" class="apply">Applica</button>
  </form>
  <p class="range-text"><?= htmlspecialchars($rangeText) ?> · raggruppato per <?= $groupText ?></p>

  <!-- Period totals -->
  <div class="summary period-kpis">
    <div class="kpi">
      <div class="val"><?= $report['total_seconds'] > 0 ? $fmtTime($report['total_seconds']) : '0m' ?></div>
      <div class="lbl">Tempo nel periodo</div>
    </div>
    <div class="kpi">
      <div class="val"><?= (int) $report['sessions'] ?></div>
      <div class="lbl">Sessioni</div>
    </div>
    <div class="kpi">
      <div class="val"><?= (int) $report['active_days'] ?></div>
      <div class="lbl">Giorni con attività</div>
    </div>
    <div class="kpi">
      <div class="val"><?= $report['active_days'] > 0 ? $fmtTime(intdiv($report['total_seconds'], $report['active_days'])) : '—' ?></div>
      <div class="lbl">Media per giorno attivo</div>
    </div>
  </div>

  <div class="view-toggle">
    <button type="button" class="tab-btn active" data-view="chart">Grafici</button>
    <button type="button" class="tab-btn" data-view="list">Lista</button>
  </div>

  <div id="view-chart" class="tab-panel active">
    <?php if ($report['sessions'] === 0): ?>
      <p class="empty">Nessuna sessione con questi filtri.</p>
    <?php else: ?>
      <div class="chart-card">
        <div class="chart-title">Ore per <?= $groupText ?>, per categoria</div>
        <div class="chart-box" style="height:300px">
          <canvas id="chart-time" role="img" aria-label="Ore per <?= $groupText ?> suddivise per categoria; i valori sono nella vista Lista"></canvas>
        </div>
      </div>
      <div class="chart-grid">
        <div class="chart-card">
          <div class="chart-title">Per categoria</div>
          <div class="chart-box" style="height:<?= count($report['chart']['categories']) * 32 + 16 ?>px">
            <canvas id="chart-cats" role="img" aria-label="Ore per categoria"></canvas>
          </div>
        </div>
        <div class="chart-card">
          <div class="chart-title">Task principali</div>
          <div class="chart-box" style="height:<?= count($report['chart']['tasks']) * 32 + 16 ?>px">
            <canvas id="chart-tasks" role="img" aria-label="Ore per task"></canvas>
          </div>
        </div>
      </div>
      <p class="chart-fallback" id="chart-fallback" hidden>Grafici non disponibili (libreria non raggiungibile): usa la vista Lista.</p>
    <?php endif; ?>
  </div>

  <div id="view-list" class="tab-panel"><?php $renderPeriod($listData); ?></div>

</div><!-- .wrap -->

<script type="application/json" id="report-data"><?= json_encode(
    $report['chart'],
    JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT | JSON_UNESCAPED_UNICODE
) ?></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js"></script>
<script>
(function () {
  // Filters: a select applies at once; custom dates wait for "Applica".
  const form = document.getElementById('filters');
  const range = form.querySelector('.custom-range');
  form.period.addEventListener('change', () => {
    if (form.period.value === 'custom') { range.hidden = false; return; }
    form.submit();
  });
  form.cat.addEventListener('change', () => { form.task.value = '0'; form.submit(); });
  form.task.addEventListener('change', () => form.submit());
  form.group.addEventListener('change', () => form.submit());

  // Chart / list toggle, remembered in this browser.
  const show = (view) => {
    document.querySelectorAll('[data-view]').forEach(b => b.classList.toggle('active', b.dataset.view === view));
    document.getElementById('view-chart').classList.toggle('active', view === 'chart');
    document.getElementById('view-list').classList.toggle('active', view === 'list');
    try { localStorage.setItem('ntako-admin-view', view); } catch (e) {}
  };
  document.querySelectorAll('[data-view]').forEach(b => b.addEventListener('click', () => show(b.dataset.view)));
  let saved = null;
  try { saved = localStorage.getItem('ntako-admin-view'); } catch (e) {}
  if (saved === 'list') show('list');

  const data = JSON.parse(document.getElementById('report-data').textContent);
  if (!data.categories.length) return;
  if (typeof Chart === 'undefined') {
    document.getElementById('chart-fallback').hidden = false;
    return;
  }

  const fmt = (secs) => {
    const min = Math.round(secs / 60), h = Math.floor(min / 60), m = min % 60;
    return h > 0 ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m`;
  };
  const ink = '#555', grid = '#eee', surface = '#fff';
  Chart.defaults.font.family = 'system-ui, sans-serif';
  Chart.defaults.color = '#999';

  // Hours per bucket, stacked by category (category color = its identity in the app).
  // Only the top non-empty segment of a column gets the rounded data-end;
  // a 2px surface-colored top border separates the stacked segments.
  const topSeries = data.labels.map((_, i) => {
    for (let c = data.categories.length - 1; c >= 0; c--) if (data.categories[c].buckets[i] > 0) return c;
    return -1;
  });
  new Chart(document.getElementById('chart-time'), {
    type: 'bar',
    data: {
      labels: data.labels,
      datasets: data.categories.map((c, ci) => ({
        label: c.name,
        data: c.buckets.map(s => s / 3600),
        backgroundColor: c.color,
        borderColor: surface,
        borderWidth: { top: 2, right: 0, bottom: 0, left: 0 },
        borderSkipped: false,
        borderRadius: ctx => topSeries[ctx.dataIndex] === ci ? { topLeft: 4, topRight: 4 } : 0,
        maxBarThickness: 24,
      })),
    },
    options: {
      maintainAspectRatio: false,
      interaction: { mode: 'index', intersect: false },
      scales: {
        x: { stacked: true, grid: { display: false }, ticks: { maxRotation: 0, autoSkip: true } },
        y: { stacked: true, beginAtZero: true, grid: { color: grid }, border: { display: false },
             ticks: { callback: v => v + ' h' } },
      },
      plugins: {
        legend: { position: 'top', align: 'start', labels: { boxWidth: 12, boxHeight: 12, color: ink } },
        tooltip: {
          filter: item => item.raw > 0,
          itemSort: (a, b) => b.raw - a.raw,
          callbacks: {
            label: item => ` ${fmt(item.raw * 3600)}  ${item.dataset.label}`,
            footer: items => 'Totale ' + fmt(items.reduce((sum, i) => sum + i.raw * 3600, 0)),
          },
        },
      },
    },
  });

  // Horizontal bars with the value at the tip.
  const valueLabels = {
    id: 'valueLabels',
    afterDatasetsDraw(chart) {
      const { ctx } = chart;
      ctx.save();
      ctx.fillStyle = ink;
      ctx.font = '12px system-ui, sans-serif';
      ctx.textBaseline = 'middle';
      chart.getDatasetMeta(0).data.forEach((bar, i) =>
        ctx.fillText(fmt(chart.data.datasets[0].data[i] * 3600), bar.x + 6, bar.y));
      ctx.restore();
    },
  };
  const shorten = (label) => label.length > 30 ? label.slice(0, 29) + '…' : label;
  const hbar = (id, items, title) => new Chart(document.getElementById(id), {
    type: 'bar',
    plugins: [valueLabels],
    data: {
      labels: items.map(i => i.name),
      datasets: [{
        data: items.map(i => i.seconds / 3600),
        backgroundColor: items.map(i => i.color),
        borderRadius: 4,
        borderSkipped: 'start',
        maxBarThickness: 20,
      }],
    },
    options: {
      indexAxis: 'y',
      maintainAspectRatio: false,
      layout: { padding: { right: 64 } },
      scales: {
        x: { display: false, beginAtZero: true },
        y: { grid: { display: false }, border: { display: false },
             ticks: { color: ink, callback(v) { return shorten(this.getLabelForValue(v)); } } },
      },
      plugins: {
        legend: { display: false },
        tooltip: { callbacks: { title, label: item => ' ' + fmt(item.raw * 3600) } },
      },
    },
  });
  hbar('chart-cats', [...data.categories].sort((a, b) => b.seconds - a.seconds),
       items => items[0].label);
  hbar('chart-tasks', data.tasks, items => {
    const t = data.tasks[items[0].dataIndex];
    return t.category ? `${t.name} · ${t.category}` : t.name;
  });
})();
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
