<?php

declare(strict_types=1);

/**
 * Admin panel: presence detection settings, places and stays report.
 * Platform scope on the dashboard ($userId null), user scope on a user page.
 */

require_once __DIR__ . '/../lib/Presence.php';

const PRESENCE_ACTIONS = ['presence_settings', 'place_save', 'place_delete'];

/**
 * Applies a presence form. Returns the flash message.
 *
 * @param array<string,mixed> $post
 * @return array{ok:bool,msg:string}
 */
function handlePresencePost(PDO $pdo, ?int $userId, array $post): array
{
    try {
        switch ($post['action'] ?? '') {
            case 'presence_settings':
                if ($userId === null) {
                    Presence::savePlatformSettings($pdo, (string) ($post['policy'] ?? ''), (string) ($post['mode'] ?? ''));
                } else {
                    Presence::saveUserOverride($pdo, $userId, (string) ($post['policy'] ?? ''), (string) ($post['mode'] ?? ''));
                }
                return ['ok' => true, 'msg' => 'Impostazioni presenze salvate. I dispositivi le ricevono al prossimo aggiornamento.'];

            case 'place_save':
                $clientId = (string) ($post['client_id'] ?? '');
                Presence::adminSavePlace($pdo, $userId, $clientId !== '' ? $clientId : null, $post);
                return ['ok' => true, 'msg' => 'Luogo salvato.'];

            case 'place_delete':
                Presence::adminDeletePlace($pdo, $userId, (string) ($post['client_id'] ?? ''));
                return ['ok' => true, 'msg' => 'Luogo eliminato.'];
        }
    } catch (InvalidArgumentException $e) {
        return ['ok' => false, 'msg' => $e->getMessage()];
    }
    return ['ok' => false, 'msg' => 'Azione sconosciuta.'];
}

/** <option>s for $choices, with an optional "inherit" first option. */
function presenceOptions(array $choices, ?string $selected, ?string $inheritLabel = null): string
{
    $html = $inheritLabel !== null
        ? '<option value=""' . ($selected === null ? ' selected' : '') . '>' . htmlspecialchars($inheritLabel) . '</option>'
        : '';
    foreach ($choices as $value => $label) {
        $html .= '<option value="' . $value . '"' . ($selected === $value ? ' selected' : '') . '>'
            . htmlspecialchars($label) . '</option>';
    }
    return $html;
}

function renderPresenceSettings(PDO $pdo, ?int $userId, string $csrf): void
{
    $platform = Presence::platformSettings($pdo);
    if ($userId === null) {
        $policy = $platform['policy'];
        $mode   = $platform['mode'];
        $inheritPolicy = $inheritMode = null;
    } else {
        ['policy' => $policy, 'mode' => $mode] = Presence::userOverride($pdo, $userId);
        $inheritPolicy = 'Come la piattaforma (' . Presence::POLICIES[$platform['policy']] . ')';
        $inheritMode   = 'Come la piattaforma (' . Presence::MODES[$platform['mode']] . ')';
    }
    ?>
  <form class="presence-settings" method="post">
    <input type="hidden" name="action" value="presence_settings">
    <input type="hidden" name="csrf" value="<?= htmlspecialchars($csrf) ?>">
    <label>Rilevamento
      <select name="policy"><?= presenceOptions(Presence::POLICIES, $policy, $inheritPolicy) ?></select>
    </label>
    <label>Modalità
      <select name="mode"><?= presenceOptions(Presence::MODES, $mode, $inheritMode) ?></select>
    </label>
    <button type="submit" class="apply">Salva</button>
    <p class="hint">
      <b>Gestito dall'amministratore</b>: modalità e luoghi si impostano qui, le app rilevano soltanto.
      <b>Gestito dall'utente</b>: ogni dispositivo sceglie la modalità (quella indicata qui è il suggerimento)
      e l'utente crea i propri luoghi. I luoghi della piattaforma valgono per tutti in entrambi i casi.
    </p>
  </form>
    <?php
}

/** Places table plus the add/edit form (one form, filled by "Modifica"). */
function renderPlaces(PDO $pdo, ?int $userId, string $csrf): void
{
    $places = Presence::adminPlaces($pdo, $userId);
    $fmtPos = static fn (array $p): string => $p['latitude'] !== null
        ? sprintf('%.5f, %.5f · %d m', $p['latitude'], $p['longitude'], $p['radius_m'])
        : '—';
    ?>
  <?php if ($places === []): ?>
    <p class="empty">Nessun luogo<?= $userId === null ? ' della piattaforma' : " dell'utente" ?>.</p>
  <?php else: ?>
  <table class="rtable places">
    <thead><tr><th>Luogo</th><th>Posizione · raggio</th><th>Reti Wi-Fi</th><th></th></tr></thead>
    <tbody>
    <?php foreach ($places as $p): ?>
      <tr>
        <td><strong><?= htmlspecialchars((string) $p['name']) ?></strong></td>
        <td class="num">
          <?php if ($p['latitude'] !== null): ?>
            <a href="https://www.openstreetmap.org/?mlat=<?= $p['latitude'] ?>&amp;mlon=<?= $p['longitude'] ?>#map=17/<?= $p['latitude'] ?>/<?= $p['longitude'] ?>"
               target="_blank" rel="noopener"><?= $fmtPos($p) ?></a>
          <?php else: ?>—<?php endif; ?>
        </td>
        <td class="dim"><?= $p['wifi'] ? htmlspecialchars(implode(', ', $p['wifi'])) : '—' ?></td>
        <td class="actions">
          <button type="button" class="link" data-edit-place="<?= htmlspecialchars((string) json_encode([
              'client_id' => $p['client_id'], 'name' => $p['name'],
              'latitude' => $p['latitude'], 'longitude' => $p['longitude'],
              'radius_m' => (int) $p['radius_m'], 'wifi' => implode("\n", $p['wifi']),
          ], JSON_UNESCAPED_UNICODE)) ?>">Modifica</button>
          <form method="post" onsubmit="return confirm('Eliminare questo luogo? Le presenze già registrate restano.')">
            <input type="hidden" name="action" value="place_delete">
            <input type="hidden" name="csrf" value="<?= htmlspecialchars($csrf) ?>">
            <input type="hidden" name="client_id" value="<?= htmlspecialchars((string) $p['client_id']) ?>">
            <button type="submit" class="link danger">Elimina</button>
          </form>
        </td>
      </tr>
    <?php endforeach; ?>
    </tbody>
  </table>
  <?php endif; ?>

  <form class="place-form" id="place-form" method="post">
    <input type="hidden" name="action" value="place_save">
    <input type="hidden" name="csrf" value="<?= htmlspecialchars($csrf) ?>">
    <input type="hidden" name="client_id" value="">
    <div class="place-title" data-new="Nuovo luogo" data-edit="Modifica luogo">Nuovo luogo</div>
    <div class="place-grid">
      <div class="place-fields">
        <label>Nome <input name="name" required maxlength="100" placeholder="Es. Ufficio Milano"></label>
        <div class="row">
          <label>Latitudine <input name="latitude" inputmode="decimal" placeholder="45.46421"></label>
          <label>Longitudine <input name="longitude" inputmode="decimal" placeholder="9.18999"></label>
        </div>
        <label>Raggio (metri)
          <input name="radius_m" type="number" min="<?= Presence::MIN_RADIUS ?>" max="<?= Presence::MAX_RADIUS ?>" value="100" required>
        </label>
        <label>Reti Wi-Fi <span class="opt">una per riga: nome (SSID) o indirizzo dell'access point (BSSID)</span>
          <textarea name="wifi" rows="3" placeholder="Ufficio-WiFi&#10;a4:2b:b0:12:34:56"></textarea>
        </label>
        <p class="hint">Serve una posizione, una rete o entrambe. Il raggio deve comprendere lo scarto del GPS:
          all'interno di un edificio 50–100 m è un buon punto di partenza. Puoi incollare
          "lat, lon" (ad es. da Google Maps) nel campo latitudine, oppure cliccare sulla mappa.</p>
        <div class="row">
          <button type="submit" class="apply">Salva luogo</button>
          <button type="button" class="link" data-place-reset>Annulla</button>
        </div>
      </div>
      <div class="place-map" id="place-map" aria-label="Mappa: clic per impostare la posizione"></div>
    </div>
  </form>
    <?php
}

/** Place colors by slot (Presence::placeSlots): the categorical palette, 0 = neutral. */
const PRESENCE_COLORS = ['#9ca3af', '#2a78d6', '#eb6834', '#1baf7a', '#eda100',
                         '#e87ba4', '#008300', '#6250d6', '#e34948'];

/** The timeline chart shows one row per day: only for short ranges. */
const PRESENCE_TIMELINE_DAYS = 31;

/**
 * Stays in the filtered range, aggregated for list and charts. Stays of
 * several devices in the same place are merged first (time is not counted
 * twice), then split at midnight: each day gets the time spent in it.
 *
 * @param array<string,mixed> $f result of reportFilters()
 * @param string $place '' = all, otherwise a place key (see Presence::stays)
 * @return array<string,mixed>
 */
function buildPresenceReport(PDO $pdo, int $userId, array $f, string $place): array
{
    $fromMs = $f['from']->getTimestamp() * 1000;
    $toMs   = $f['to']->getTimestamp() * 1000;
    $now    = (int) (microtime(true) * 1000);
    $tz     = new DateTimeZone(date_default_timezone_get());

    $buckets = [];
    $dayList = [];
    for ($d = $f['from']; $d < $f['to']; $d = $d->modify('+1 day')) {
        $b = reportBucket($d, $f['group']);
        $buckets[$b['key']] ??= $b['label'];
        $dayList[] = $d->format('Y-m-d');
    }
    $bucketIndex = array_flip(array_keys($buckets));

    $byPlace = [];   // key → name, slot, intervals
    $raw     = [];
    foreach (Presence::stays($pdo, $userId, $fromMs, $toMs) as $r) {
        if ($place !== '' && $r['place'] !== $place) {
            continue;
        }
        $open = $r['exited_at'] === null && $now - $r['last_seen_at'] < Presence::STALE_MS;
        $end  = $r['exited_at'] ?? ($open ? $now : $r['last_seen_at']);
        $raw[] = $r + ['end' => $end, 'open' => $open, 'color' => PRESENCE_COLORS[$r['slot']]];

        $start = max($r['entered_at'], $fromMs);
        $clip  = min($end, $toMs);
        if ($clip > $start) {
            $byPlace[$r['place']] ??= ['name' => $r['place_name'], 'slot' => $r['slot'], 'iv' => []];
            $byPlace[$r['place']]['iv'][] = [$start, $clip, $open && $clip === $end];
        }
    }

    $places = [];
    $daily  = [];   // Y-m-d → place key → first, last, seconds, open
    $bars   = [];   // timeline: [day, place key, from hour, to hour]
    foreach ($byPlace as $key => $p) {
        $series = [
            'key' => $key, 'name' => $p['name'], 'color' => PRESENCE_COLORS[$p['slot']],
            'seconds' => 0, 'buckets' => array_fill(0, count($buckets), 0), 'days' => 0,
            'avg_in' => null, 'avg_out' => null,
        ];
        foreach (Presence::mergeIntervals($p['iv']) as [$start, $end, $open]) {
            $cur = $start;
            while ($cur < $end) {
                $day   = (new DateTimeImmutable('@' . intdiv($cur, 1000)))->setTimezone($tz)->setTime(0, 0);
                $dayMs = $day->getTimestamp() * 1000;
                $slice = min($end, $day->modify('+1 day')->getTimestamp() * 1000);
                $secs  = intdiv($slice - $cur, 1000);
                $date  = $day->format('Y-m-d');

                $e = &$daily[$date][$key];
                $e ??= ['name' => $p['name'], 'color' => $series['color'], 'first' => $cur,
                        'last' => $slice, 'seconds' => 0, 'open' => false];
                $e['last']     = max($e['last'], $slice);
                $e['seconds'] += $secs;
                $e['open']     = $e['open'] || ($open && $slice === $end);
                unset($e);

                $series['seconds'] += $secs;
                $i = $bucketIndex[reportBucket($day, $f['group'])['key']] ?? null;
                if ($i !== null) {
                    $series['buckets'][$i] += $secs;
                }
                $bars[] = [$date, $key, round(($cur - $dayMs) / 3_600_000, 3), round(($slice - $dayMs) / 3_600_000, 3)];
                $cur = $slice;
            }
        }
        // Typical entry and exit: averages of each day's first entry and last exit.
        $ins = $outs = [];
        foreach ($daily as $date => $entries) {
            if (isset($entries[$key])) {
                $midnight = (new DateTimeImmutable($date, $tz))->getTimestamp() * 1000;
                $ins[]  = ($entries[$key]['first'] - $midnight) / 60000;
                if (!$entries[$key]['open']) {
                    $outs[] = ($entries[$key]['last'] - $midnight) / 60000;
                }
            }
        }
        $series['days']    = count($ins);
        $series['avg_in']  = $ins ? (int) round(array_sum($ins) / count($ins)) : null;
        $series['avg_out'] = $outs ? (int) round(array_sum($outs) / count($outs)) : null;
        $places[$key] = $series;
    }

    // Stable order by name: a place keeps its place whatever the filter.
    uasort($places, static fn ($a, $b) => strcasecmp($a['name'], $b['name']));
    krsort($daily);
    $days = [];
    foreach ($daily as $date => $entries) {
        uasort($entries, static fn ($a, $b) => $a['first'] <=> $b['first']);
        $days[] = ['date' => $date, 'seconds' => array_sum(array_column($entries, 'seconds')),
                   'entries' => array_values($entries)];
    }
    $total = array_sum(array_column($places, 'seconds'));

    return [
        'total'    => $total,
        'days'     => $days,
        'stays'    => array_reverse($raw),
        'places'   => array_values($places),
        'chart'    => [
            'labels'   => array_values($buckets),
            'places'   => array_values(array_map(static fn ($p) => [
                'key' => $p['key'], 'name' => $p['name'], 'color' => $p['color'],
                'seconds' => $p['seconds'], 'buckets' => $p['buckets'],
            ], $places)),
            'timeline' => count($dayList) <= PRESENCE_TIMELINE_DAYS && $bars !== []
                ? ['days' => array_map(static function (string $d): string {
                       $day = new DateTimeImmutable($d);
                       return $day->format('j') . ' ' . REPORT_MONTHS[(int) $day->format('n') - 1];
                   }, $dayList), 'dates' => $dayList, 'bars' => $bars]
                : null,
        ],
    ];
}

/**
 * Places offered by the report filter: the user's and the platform's,
 * deleted ones included (their stays still count).
 *
 * @return array<string,string> place key → label
 */
function presencePlaceOptions(PDO $pdo, int $userId): array
{
    $stmt = $pdo->prepare('
        SELECT client_id, name, user_id, deleted_at FROM places
        WHERE user_id IS NULL OR user_id = ? ORDER BY name
    ');
    $stmt->execute([$userId]);
    $options = [];
    foreach ($stmt->fetchAll() as $p) {
        $options[(string) $p['client_id']] = $p['name']
            . ($p['user_id'] === null ? ' (comune)' : '')
            . ($p['deleted_at'] !== null ? ' (eliminato)' : '');
    }
    return $options;
}

/** "08:55" from minutes after midnight. */
function presenceClock(?int $minutes): string
{
    return $minutes === null ? '—' : sprintf('%02d:%02d', intdiv($minutes, 60), $minutes % 60);
}

/**
 * The "Presenze" tab of a user page: filters, totals, charts or list.
 *
 * @param array<string,mixed> $get query string
 */
function renderPresenceReport(PDO $pdo, int $userId, array $get, callable $fmtTime): void
{
    $filters = reportFilters($get, $pdo, $userId);
    if ($filters['period'] === 'all') {
        // From the first stay, not the first timer session.
        $first = Presence::firstStayMs($pdo, $userId);
        if ($first !== null) {
            $filters['from'] = (new DateTimeImmutable('@' . intdiv($first, 1000)))
                ->setTimezone(new DateTimeZone(date_default_timezone_get()))->setTime(0, 0);
            $days = (int) $filters['from']->diff($filters['to'])->days;
            if ($filters['groupChoice'] === 'auto') {
                $filters['group'] = $days <= 45 ? 'day' : ($days <= 190 ? 'week' : 'month');
            }
        }
    }
    $options = presencePlaceOptions($pdo, $userId);
    $place   = (string) ($get['place'] ?? '');
    if ($place !== '' && !array_key_exists($place, $options) && !str_starts_with($place, 'n:')) {
        $place = '';
    }
    $r = buildPresenceReport($pdo, $userId, $filters, $place);

    $lastDay   = $filters['to']->modify('-1 day');
    $fmtDay    = static fn (DateTimeImmutable $d): string =>
        $d->format('j') . ' ' . REPORT_MONTHS[(int) $d->format('n') - 1] . ' ' . $d->format('Y');
    $rangeText = $filters['from'] == $lastDay ? $fmtDay($lastDay) : $fmtDay($filters['from']) . ' – ' . $fmtDay($lastDay);
    $groupText = ['day' => 'giorno', 'week' => 'settimana', 'month' => 'mese'][$filters['group']];
    $activeDays = count($r['days']);
    $hm  = static fn (int $ms): string => date('H:i', intdiv($ms, 1000));
    $dmy = static fn (int $ms): string => date('d/m/Y H:i', intdiv($ms, 1000));
    $methods = ['gps' => 'GPS', 'wifi' => 'Wi-Fi', 'gps+wifi' => 'GPS + Wi-Fi'];
    $devices = ['android' => 'Android', 'iOS' => 'iPhone', 'linux' => 'Linux', 'windows' => 'Windows',
                'macOS' => 'Mac', 'web' => 'Browser'];
    ?>
  <form class="filters" id="presence-filters" method="get">
    <input type="hidden" name="user" value="<?= $userId ?>">
    <input type="hidden" name="tab" value="presence">
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
    <label>Luogo
      <select name="place">
        <option value="">Tutti</option>
        <?php foreach ($options as $key => $label): ?>
          <option value="<?= htmlspecialchars($key) ?>" <?= $place === $key ? 'selected' : '' ?>><?= htmlspecialchars($label) ?></option>
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

  <div class="summary period-kpis">
    <div class="kpi"><div class="val"><?= $r['total'] > 0 ? $fmtTime($r['total']) : '0m' ?></div><div class="lbl">Tempo nei luoghi</div></div>
    <div class="kpi"><div class="val"><?= $activeDays ?></div><div class="lbl">Giorni con presenza</div></div>
    <div class="kpi"><div class="val"><?= $activeDays > 0 ? $fmtTime(intdiv($r['total'], $activeDays)) : '—' ?></div><div class="lbl">Media per giorno</div></div>
    <div class="kpi"><div class="val"><?= count($r['stays']) ?></div><div class="lbl">Permanenze registrate</div></div>
  </div>

  <div class="view-toggle">
    <button type="button" class="tab-btn active" data-pview="chart">Grafici</button>
    <button type="button" class="tab-btn" data-pview="list">Elenco</button>
  </div>

  <?php if ($r['stays'] === []): ?>
    <p class="empty">Nessuna presenza con questi filtri.</p>
  <?php else: ?>
  <div id="pview-chart" class="tab-panel active">
    <div class="chart-card">
      <div class="chart-title">Ore per <?= $groupText ?>, per luogo</div>
      <div class="chart-box" style="height:300px">
        <canvas id="pchart-time" role="img" aria-label="Ore di presenza per <?= $groupText ?> suddivise per luogo; i valori sono nella vista Elenco"></canvas>
      </div>
    </div>
    <div class="chart-grid">
      <div class="chart-card">
        <div class="chart-title">Per luogo</div>
        <div class="chart-box" style="height:<?= count($r['places']) * 32 + 16 ?>px">
          <canvas id="pchart-places" role="img" aria-label="Ore per luogo"></canvas>
        </div>
      </div>
      <div class="chart-card">
        <div class="chart-title">Orari tipici</div>
        <table class="rtable compact">
          <thead><tr><th>Luogo</th><th>Giorni</th><th>Entrata media</th><th>Uscita media</th><th>Media/giorno</th></tr></thead>
          <tbody>
          <?php foreach ($r['places'] as $p): ?>
            <tr>
              <td><span class="cat-dot" style="background:<?= $p['color'] ?>"></span><?= htmlspecialchars($p['name']) ?></td>
              <td class="num"><?= $p['days'] ?></td>
              <td class="num"><?= presenceClock($p['avg_in']) ?></td>
              <td class="num"><?= presenceClock($p['avg_out']) ?></td>
              <td class="num time"><?= $p['days'] > 0 ? $fmtTime(intdiv($p['seconds'], $p['days'])) : '—' ?></td>
            </tr>
          <?php endforeach; ?>
          </tbody>
        </table>
      </div>
    </div>
    <?php if ($r['chart']['timeline'] !== null): ?>
    <div class="chart-card">
      <div class="chart-title">Orari di presenza, giorno per giorno</div>
      <div class="chart-box" style="height:<?= count($r['chart']['timeline']['days']) * 22 + 60 ?>px">
        <canvas id="pchart-timeline" role="img" aria-label="Fasce orarie di presenza per giorno e luogo; gli orari sono nella vista Elenco"></canvas>
      </div>
    </div>
    <?php endif; ?>
    <p class="chart-fallback" id="pchart-fallback" hidden>Grafici non disponibili (libreria non raggiungibile): usa la vista Elenco.</p>
  </div>

  <div id="pview-list" class="tab-panel">
    <div class="section-title">Per giorno</div>
    <table class="rtable">
      <thead><tr><th>Giorno</th><th>Luogo</th><th>Prima entrata</th><th>Ultima uscita</th><th>Permanenza</th></tr></thead>
      <tbody>
      <?php foreach ($r['days'] as $d): ?>
        <?php $day = DateTimeImmutable::createFromFormat('!Y-m-d', $d['date']); ?>
        <tr class="cat-row">
          <td colspan="4"><strong><?= ucfirst(['lun', 'mar', 'mer', 'gio', 'ven', 'sab', 'dom'][(int) $day->format('N') - 1]) . ' ' . $fmtDay($day) ?></strong></td>
          <td class="num time"><strong><?= $fmtTime($d['seconds']) ?></strong></td>
        </tr>
        <?php foreach ($d['entries'] as $e): ?>
        <tr class="task-row">
          <td></td>
          <td><span class="cat-dot" style="background:<?= $e['color'] ?>"></span><?= htmlspecialchars($e['name']) ?></td>
          <td class="num"><?= $hm($e['first']) ?></td>
          <td class="num"><?= $e['open'] ? '<span class="badge badge-run">presente</span>' : $hm($e['last']) ?></td>
          <td class="num time"><?= $fmtTime($e['seconds']) ?></td>
        </tr>
        <?php endforeach; ?>
      <?php endforeach; ?>
      </tbody>
    </table>

    <div class="section-title" style="margin-top:1.25rem">Permanenze registrate</div>
    <table class="rtable">
      <thead><tr><th>Luogo</th><th>Entrata</th><th>Uscita</th><th>Durata</th><th>Dispositivo</th><th>Rilevato con</th></tr></thead>
      <tbody>
      <?php foreach ($r['stays'] as $s): ?>
        <tr>
          <td><span class="cat-dot" style="background:<?= $s['color'] ?>"></span><?= htmlspecialchars($s['place_name']) ?></td>
          <td class="num"><?= $dmy($s['entered_at']) ?></td>
          <td class="num"><?= $s['open'] ? '<span class="badge badge-run">in corso</span>'
              : ($s['exited_at'] === null ? $dmy($s['end']) . ' <span class="dim" title="Il dispositivo ha smesso di rispondere: uscita all\'ultimo rilevamento">*</span>' : $dmy($s['end'])) ?></td>
          <td class="num time"><?= $fmtTime(intdiv($s['end'] - $s['entered_at'], 1000)) ?></td>
          <td class="dim"><?= htmlspecialchars($devices[$s['device']] ?? ($s['device'] !== '' ? $s['device'] : '—')) ?></td>
          <td class="dim"><?= $methods[$s['method']] ?? '—' ?></td>
        </tr>
      <?php endforeach; ?>
      </tbody>
    </table>
  </div>
  <?php endif; ?>
  <p class="hint">Le permanenze di più dispositivi nello stesso luogo sono unite, così il tempo non è contato due volte;
    una permanenza a cavallo della mezzanotte è divisa tra i due giorni. Un dispositivo che smette di rispondere
    per più di <?= intdiv(Presence::STALE_MS, 60000) ?> minuti viene considerato uscito all'ultimo rilevamento (*).</p>

  <script type="application/json" id="presence-data"><?= json_encode(
      $r['chart'],
      JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT | JSON_UNESCAPED_UNICODE
  ) ?></script>
    <?php
}

/** Charts of the "Presenze" tab; needs Chart.js loaded first. */
function presenceReportScript(): void
{
    ?>
<script>
(function () {
  const form = document.getElementById('presence-filters');
  if (!form) return;
  const range = form.querySelector('.custom-range');
  form.period.addEventListener('change', () => {
    if (form.period.value === 'custom') { range.hidden = false; return; }
    form.submit();
  });
  form.place.addEventListener('change', () => form.submit());
  form.group.addEventListener('change', () => form.submit());

  const show = (view) => {
    document.querySelectorAll('[data-pview]').forEach(b => b.classList.toggle('active', b.dataset.pview === view));
    document.getElementById('pview-chart')?.classList.toggle('active', view === 'chart');
    document.getElementById('pview-list')?.classList.toggle('active', view === 'list');
    try { localStorage.setItem('workadoro-admin-pview', view); } catch (e) {}
  };
  document.querySelectorAll('[data-pview]').forEach(b => b.addEventListener('click', () => show(b.dataset.pview)));
  let saved = null;
  try { saved = localStorage.getItem('workadoro-admin-pview'); } catch (e) {}
  if (saved === 'list') show('list');

  const data = JSON.parse(document.getElementById('presence-data').textContent);
  if (!data.places.length) return;
  if (typeof Chart === 'undefined') {
    document.getElementById('pchart-fallback').hidden = false;
    return;
  }
  const fmt = (secs) => {
    const min = Math.round(secs / 60), h = Math.floor(min / 60), m = min % 60;
    return h > 0 ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m`;
  };
  const clock = (hours) => {
    const min = Math.round(hours * 60);
    return `${String(Math.floor(min / 60)).padStart(2, '0')}:${String(min % 60).padStart(2, '0')}`;
  };
  const ink = '#555', grid = '#eee', surface = '#fff';
  Chart.defaults.font.family = 'system-ui, sans-serif';
  Chart.defaults.color = '#999';
  const legend = { position: 'top', align: 'start', labels: { boxWidth: 12, boxHeight: 12, color: ink } };

  // Hours per bucket, stacked by place; only the top segment gets the rounded end.
  const topSeries = data.labels.map((_, i) => {
    for (let c = data.places.length - 1; c >= 0; c--) if (data.places[c].buckets[i] > 0) return c;
    return -1;
  });
  new Chart(document.getElementById('pchart-time'), {
    type: 'bar',
    data: {
      labels: data.labels,
      datasets: data.places.map((p, pi) => ({
        label: p.name,
        data: p.buckets.map(s => s / 3600),
        backgroundColor: p.color,
        borderColor: surface,
        borderWidth: { top: 2, right: 0, bottom: 0, left: 0 },
        borderSkipped: false,
        borderRadius: ctx => topSeries[ctx.dataIndex] === pi ? { topLeft: 4, topRight: 4 } : 0,
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
        legend: data.places.length > 1 ? legend : { display: false },
        tooltip: {
          filter: item => item.raw > 0,
          itemSort: (a, b) => b.raw - a.raw,
          callbacks: {
            label: item => ` ${fmt(item.raw * 3600)}  ${item.dataset.label}`,
            footer: items => items.length > 1 ? 'Totale ' + fmt(items.reduce((s, i) => s + i.raw * 3600, 0)) : '',
          },
        },
      },
    },
  });

  // Hours per place, value at the tip.
  const sorted = [...data.places].sort((a, b) => b.seconds - a.seconds);
  new Chart(document.getElementById('pchart-places'), {
    type: 'bar',
    plugins: [{
      id: 'valueLabels',
      afterDatasetsDraw(chart) {
        const { ctx } = chart;
        ctx.save();
        ctx.fillStyle = ink;
        ctx.font = '12px system-ui, sans-serif';
        ctx.textBaseline = 'middle';
        chart.getDatasetMeta(0).data.forEach((bar, i) => ctx.fillText(fmt(sorted[i].seconds), bar.x + 6, bar.y));
        ctx.restore();
      },
    }],
    data: {
      labels: sorted.map(p => p.name),
      datasets: [{ data: sorted.map(p => p.seconds / 3600), backgroundColor: sorted.map(p => p.color),
                   borderRadius: 4, borderSkipped: 'start', maxBarThickness: 20 }],
    },
    options: {
      indexAxis: 'y',
      maintainAspectRatio: false,
      layout: { padding: { right: 64 } },
      scales: { x: { display: false, beginAtZero: true },
                y: { grid: { display: false }, border: { display: false }, ticks: { color: ink } } },
      plugins: { legend: { display: false }, tooltip: { callbacks: { label: item => ' ' + fmt(sorted[item.dataIndex].seconds) } } },
    },
  });

  // Timeline: one row per day, the hours spent in each place.
  const tl = data.timeline;
  if (!tl) return;
  const dayIndex = Object.fromEntries(tl.dates.map((d, i) => [d, i]));
  new Chart(document.getElementById('pchart-timeline'), {
    type: 'bar',
    data: {
      labels: tl.days,
      datasets: data.places.map(p => ({
        label: p.name,
        data: tl.bars.filter(b => b[1] === p.key).map(b => ({ y: tl.days[dayIndex[b[0]]], x: [b[2], b[3]] })),
        backgroundColor: p.color,
        borderColor: surface,
        borderWidth: 1,
        borderRadius: 3,
        borderSkipped: false,
        grouped: false,
        barPercentage: 0.7,
        categoryPercentage: 1,
      })),
    },
    options: {
      indexAxis: 'y',
      maintainAspectRatio: false,
      scales: {
        x: { min: 0, max: 24, grid: { color: grid }, border: { display: false },
             ticks: { stepSize: 2, callback: v => String(v).padStart(2, '0') + ':00' } },
        y: { grid: { display: false }, border: { display: false }, ticks: { color: ink, autoSkip: false } },
      },
      plugins: {
        legend: data.places.length > 1 ? legend : { display: false },
        tooltip: { callbacks: {
          label: item => ` ${item.dataset.label}: ${clock(item.raw.x[0])} – ${clock(item.raw.x[1])}`
                         + ` (${fmt((item.raw.x[1] - item.raw.x[0]) * 3600)})`,
        } },
      },
    },
  });
})();
</script>
    <?php
}

function presenceStyles(): void
{
    ?>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css">
<style>
  .presence { margin-top: 1.75rem; }
  .presence .section-title { margin-top: 1.25rem; }
  .presence-settings, .place-form { background: #fff; border-radius: 10px; padding: .9rem 1rem;
         box-shadow: 0 1px 6px rgba(0,0,0,.07); margin-bottom: 1rem; }
  .presence-settings { display: flex; flex-wrap: wrap; gap: .6rem .9rem; align-items: flex-end; }
  .presence label, .place-form label { display: grid; gap: .2rem; font-size: .7rem; font-weight: 700; color: #888;
         text-transform: uppercase; letter-spacing: .04em; }
  .presence select, .presence input, .presence textarea { font: inherit; font-size: .85rem; color: #222;
         padding: .4rem .5rem; border: 1px solid #ddd; border-radius: 6px; background: #fff;
         text-transform: none; letter-spacing: 0; font-weight: 400; min-width: 0; width: 100%; }
  .presence-settings select { min-width: 14rem; }
  .presence .apply { background: #e84545; color: #fff; border: none; border-radius: 7px;
         padding: .5rem 1rem; font-weight: 600; cursor: pointer; }
  .presence .hint { flex-basis: 100%; font-size: .75rem; color: #888; line-height: 1.45; margin-top: .3rem; }
  .presence .opt { text-transform: none; letter-spacing: 0; font-weight: 400; }
  .presence .link { background: none; border: none; color: #2471a3; font: inherit; font-size: .8rem;
         font-weight: 600; cursor: pointer; padding: .2rem .3rem; }
  .presence .link.danger { color: #c0392b; }
  .places { margin-bottom: 1rem; }
  .places .actions { white-space: nowrap; text-align: right; }
  .places .actions form { display: inline; }
  .place-title { font-weight: 700; font-size: .9rem; margin-bottom: .6rem; }
  .place-grid { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.2fr); gap: 1rem; }
  .place-fields { display: grid; gap: .6rem; align-content: start; }
  .place-fields .row { display: flex; gap: .6rem; align-items: flex-end; }
  .place-fields .row > label { flex: 1; }
  .place-map { min-height: 300px; border-radius: 8px; background: #eef1f3; }
  .rtable.compact th, .rtable.compact td { padding: .45rem .6rem; }
  .page-tabs { display: flex; gap: .3rem; margin: .25rem 0 1rem; }
  .page-tabs a { text-decoration: none; }
  @media (max-width: 760px) { .place-grid { grid-template-columns: 1fr; } }
</style>
    <?php
}

/** Map and form behaviour; the form also works without it. */
function presenceScript(): void
{
    ?>
<script src="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js"></script>
<script>
(function () {
  const form = document.getElementById('place-form');
  if (!form) return;
  const title = form.querySelector('.place-title');
  const f = form.elements;

  // "45.46, 9.19" pasted into latitude fills both fields.
  f.latitude.addEventListener('input', () => {
    const m = f.latitude.value.match(/^\s*(-?\d+(?:\.\d+)?)\s*[,;\s]\s*(-?\d+(?:\.\d+)?)\s*$/);
    if (m) { f.latitude.value = m[1]; f.longitude.value = m[2]; }
    sync();
  });
  f.longitude.addEventListener('input', sync);
  f.radius_m.addEventListener('input', sync);

  const fill = (p) => {
    f.client_id.value = p.client_id || '';
    f.name.value = p.name || '';
    f.latitude.value = p.latitude ?? '';
    f.longitude.value = p.longitude ?? '';
    f.radius_m.value = p.radius_m || 100;
    f.wifi.value = p.wifi || '';
    title.textContent = p.client_id ? title.dataset.edit : title.dataset.new;
    sync(true);
  };
  document.querySelectorAll('[data-edit-place]').forEach(b => b.addEventListener('click', () => {
    fill(JSON.parse(b.dataset.editPlace));
    form.scrollIntoView({ behavior: 'smooth', block: 'start' });
    f.name.focus();
  }));
  form.querySelector('[data-place-reset]').addEventListener('click', () => fill({}));

  let map = null, marker = null, circle = null;
  function sync(recenter) {
    if (!map) return;
    const lat = parseFloat(f.latitude.value), lon = parseFloat(f.longitude.value);
    const r = parseInt(f.radius_m.value, 10) || 100;
    if (isNaN(lat) || isNaN(lon)) {
      if (marker) { marker.remove(); circle.remove(); marker = circle = null; }
      return;
    }
    const pos = [lat, lon];
    if (!marker) {
      marker = L.circleMarker(pos, { radius: 5, color: '#e84545', fillOpacity: 1 }).addTo(map);
      circle = L.circle(pos, { radius: r, color: '#e84545', weight: 2, fillOpacity: .12 }).addTo(map);
    } else {
      marker.setLatLng(pos); circle.setLatLng(pos); circle.setRadius(r);
    }
    if (recenter) map.fitBounds(circle.getBounds(), { maxZoom: 17 });
  }

  if (typeof L === 'undefined') {
    document.getElementById('place-map').textContent = 'Mappa non disponibile: inserisci le coordinate a mano.';
    return;
  }
  map = L.map('place-map').setView([42.5, 12.5], 5);
  L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
  }).addTo(map);
  map.on('click', (e) => {
    f.latitude.value = e.latlng.lat.toFixed(6);
    f.longitude.value = e.latlng.lng.toFixed(6);
    sync();
  });
  sync(true);
})();
</script>
    <?php
}
