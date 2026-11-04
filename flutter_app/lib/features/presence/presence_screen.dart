import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/database/app_database.dart';
import '../history/history_report.dart';
import 'presence_controller.dart';
import 'presence_engine.dart';
import 'presence_logic.dart';
import 'presence_report.dart';
import 'presence_sensors.dart';

/// Presence detection ("badge"): turn it on for this device, see where you
/// are, manage your places (when the admin allows it) and recent stays.
class PresenceScreen extends ConsumerWidget {
  const PresenceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(presenceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Presenze'),
        actions: [
          if (s.loggedIn)
            IconButton(
              tooltip: 'Aggiorna impostazioni e luoghi',
              icon: const Icon(Icons.refresh),
              onPressed: () => _refresh(context, ref),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!s.loggedIn)
            _Notice(
              icon: Icons.login,
              text:
                  'Impostazioni e luoghi del rilevamento presenze arrivano dal '
                  'server: accedi per usarlo.',
              action: TextButton(
                onPressed: () => context.go('/login'),
                child: const Text('Accedi'),
              ),
            )
          else if (s.config.policy == PresencePolicy.off)
            const _Notice(
              icon: Icons.location_off_outlined,
              text:
                  'Il rilevamento presenze non è attivo per il tuo account: '
                  'lo abilita l\'amministratore del server.',
            )
          else ...[
            const _StatusCard(),
            const _BackgroundWarnings(),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.insights_outlined),
                title: const Text('Report presenze'),
                subtitle: const Text(
                  'Grafici ed elenco delle permanenze, di tutti i dispositivi',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/presence/report'),
              ),
            ),
            const SizedBox(height: 8),
            const _ModeTile(),
            const _IntervalTile(),
            const SizedBox(height: 16),
            _Header(
              'Luoghi',
              trailing: s.config.canEdit
                  ? TextButton.icon(
                      onPressed: () => _editPlace(context),
                      icon: const Icon(Icons.add),
                      label: const Text('Aggiungi'),
                    )
                  : null,
            ),
            if (!s.config.canEdit)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'I luoghi sono gestiti dall\'amministratore.',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            if (s.config.places.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Nessun luogo da rilevare.'),
              ),
            for (final p in s.config.places) _PlaceTile(p),
            const SizedBox(height: 16),
            const _Header('Ultime presenze su questo dispositivo'),
            const _History(),
            const SizedBox(height: 8),
            const _Diagnostics(),
          ],
        ],
      ),
    );
  }

  static Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(presenceProvider.notifier).refreshConfig();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(PresenceController.errorMessage(e))),
        );
      }
    }
  }
}

Future<void> _editPlace(BuildContext context, [Place? place]) => showDialog(
  context: context,
  builder: (_) => Dialog.fullscreen(child: _PlaceEditor(place)),
);

class _StatusCard extends ConsumerWidget {
  const _StatusCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(presenceProvider);
    final scheme = Theme.of(context).colorScheme;
    final open = (ref.watch(recentPresencesProvider).valueOrNull ?? const [])
        .where((p) => p.exitedAt == null)
        .toList();

    final String subtitle;
    if (s.problem != null) {
      subtitle = s.problem!;
    } else if (!s.enabled) {
      subtitle = s.config.policy == PresencePolicy.admin
          ? 'L\'amministratore ha attivato il rilevamento: accendilo per '
                'registrare entrate e uscite.'
          : 'Spento';
    } else if (s.config.places.isEmpty) {
      subtitle = 'Nessun luogo da rilevare.';
    } else {
      subtitle = s.running ? 'Attivo' : 'Avvio…';
    }

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            title: const Text('Rileva su questo dispositivo'),
            subtitle: Text(
              subtitle,
              style: s.problem != null ? TextStyle(color: scheme.error) : null,
            ),
            value: s.enabled,
            onChanged: (v) => ref.read(presenceProvider.notifier).setEnabled(v),
          ),
          if (s.running) ...[
            const Divider(height: 1),
            ListTile(
              leading: Icon(
                open.isEmpty
                    ? Icons.wrong_location_outlined
                    : Icons.where_to_vote,
                color: open.isEmpty ? null : scheme.primary,
              ),
              title: Text(
                open.isEmpty
                    ? 'Non sei in nessuno dei luoghi'
                    : open
                          .map(
                            (p) => '${p.placeName} dalle ${_time(p.enteredAt)}',
                          )
                          .join('\n'),
              ),
              subtitle: s.last == null ? null : Text(_describe(s.last!)),
            ),
          ],
          if (s.problem != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: TextButton(
                onPressed: () =>
                    ref.read(presenceProvider.notifier).setEnabled(true),
                child: const Text('Riprova'),
              ),
            ),
        ],
      ),
    );
  }

  static String _describe(LastCheck c) {
    final parts = ['Ultimo controllo ${_time(c.atMs)}'];
    if (c.problem != null) return '${parts.first} · ${c.problem}';
    if (c.wifiRead) {
      final w = c.wifi;
      parts.add(
        w == null
            ? 'Wi-Fi non leggibile'
            : w.connected
            ? 'Wi-Fi ${w.ssid ?? w.bssid}'
            : 'Wi-Fi non connesso',
      );
    }
    if (c.gpsRead) {
      final a = c.gpsAccuracyM;
      parts.add(a == null ? 'GPS non disponibile' : 'GPS ±${a.round()} m');
    }
    return parts.join(' · ');
  }
}

/// Android settings that stop detection from running in the background.
class _BackgroundWarnings extends ConsumerWidget {
  const _BackgroundWarnings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(presenceProvider);
    if (!s.enabled) return const SizedBox.shrink();
    final controller = ref.read(presenceProvider.notifier);
    return Column(
      children: [
        if (s.batteryOptimized)
          _Warning(
            icon: Icons.battery_alert_outlined,
            text:
                'Ottimizzazione batteria attiva: Android può sospendere il '
                'rilevamento quando non usi il telefono, e le entrate e '
                'uscite vengono perse.',
            action: 'Disattiva',
            onPressed: controller.requestBatteryExemption,
          ),
        if (s.needsBackgroundLocation)
          _Warning(
            icon: Icons.restart_alt,
            text:
                'Posizione consentita solo durante l\'uso: dopo un riavvio '
                'del telefono il rilevamento riparte solo aprendo l\'app. '
                'In Autorizzazioni → Posizione scegli "Consenti sempre".',
            action: 'Impostazioni',
            onPressed: controller.openAppSettings,
          ),
      ],
    );
  }
}

class _Warning extends StatelessWidget {
  final IconData icon;
  final String text;
  final String action;
  final VoidCallback onPressed;

  const _Warning({
    required this.icon,
    required this.text,
    required this.action,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: scheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
              ],
            ),
            TextButton(onPressed: onPressed, child: Text(action)),
          ],
        ),
      ),
    );
  }
}

/// The detection log: checks, entries, exits, pauses, service restarts.
class _Diagnostics extends ConsumerWidget {
  const _Diagnostics();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(presenceLogProvider).valueOrNull ?? const [];
    final theme = Theme.of(context);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      leading: const Icon(Icons.bug_report_outlined),
      title: const Text('Diagnostica'),
      subtitle: const Text(
        'Avvii, pause, entrate e uscite di questo dispositivo',
      ),
      onExpansionChanged: (open) {
        if (open) ref.invalidate(presenceLogProvider);
      },
      children: [
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('Nessun evento registrato.'),
          ),
        for (final e in entries.take(100))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 92,
                  child: Text(
                    DateFormat(
                      'd/M HH:mm',
                    ).format(DateTime.fromMillisecondsSinceEpoch(e.atMs)),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  child: Text(e.message, style: theme.textTheme.bodySmall),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ModeTile extends ConsumerWidget {
  const _ModeTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(presenceProvider);
    if (s.config.policy != PresencePolicy.user) {
      return ListTile(
        leading: const Icon(Icons.tune),
        title: const Text('Modalità'),
        subtitle: Text('${s.mode.label} · impostata dall\'amministratore'),
      );
    }
    return ListTile(
      leading: const Icon(Icons.tune),
      title: const Text('Modalità su questo dispositivo'),
      subtitle: DropdownButton<TrackingMode>(
        value: s.mode,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        items: [
          for (final m in TrackingMode.values)
            DropdownMenuItem(value: m, child: Text(m.label)),
        ],
        onChanged: (m) {
          if (m != null) ref.read(presenceProvider.notifier).setMode(m);
        },
      ),
    );
  }
}

/// How often this device checks where it is: battery against promptness.
class _IntervalTile extends ConsumerWidget {
  const _IntervalTile();

  static String _label(int minutes) =>
      minutes == 1 ? 'Ogni minuto' : 'Ogni $minutes minuti';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(presenceProvider);
    final exitMinutes = exitGraceFor(s.intervalMinutes) ~/ 60000;
    return ListTile(
      leading: const Icon(Icons.schedule),
      title: const Text('Frequenza dei controlli'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButton<int>(
            value: s.intervalMinutes,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final m in checkIntervals)
                DropdownMenuItem(value: m, child: Text(_label(m))),
            ],
            onChanged: (m) {
              if (m != null) ref.read(presenceProvider.notifier).setInterval(m);
            },
          ),
          Text(
            'Controlli più radi consumano meno batteria. Entrata rilevata '
            'entro ${s.intervalMinutes == 1 ? 'un minuto' : '${s.intervalMinutes} minuti'}, '
            'uscita confermata dopo $exitMinutes minuti fuori dal luogo.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _PlaceTile extends ConsumerWidget {
  final Place place;

  const _PlaceTile(this.place);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final details = [
      if (place.hasPosition)
        '${place.latitude!.toStringAsFixed(5)}, '
            '${place.longitude!.toStringAsFixed(5)} · ${place.radiusM} m',
      if (place.hasWifi) 'Wi-Fi: ${place.wifi.join(', ')}',
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      // Same color as in the report.
      leading: Icon(
        place.platform ? Icons.business : Icons.place_outlined,
        color: placeColor(
          place.slot,
          dark: Theme.of(context).brightness == Brightness.dark,
        ),
      ),
      title: Text(place.name),
      subtitle: Text(details.join('\n')),
      trailing: place.platform
          ? const Tooltip(
              message: 'Luogo comune a tutti gli utenti',
              child: Chip(label: Text('Comune')),
            )
          : place.editable
          ? PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'edit') {
                  await _editPlace(context, place);
                } else {
                  await _delete(context, ref);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Modifica')),
                PopupMenuItem(value: 'delete', child: Text('Elimina')),
              ],
            )
          : null,
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Eliminare "${place.name}"?'),
        content: const Text('Le presenze già registrate restano.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(presenceProvider.notifier).deletePlace(place.id);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(PresenceController.errorMessage(e))),
        );
      }
    }
  }
}

class _History extends ConsumerWidget {
  const _History();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(recentPresencesProvider).valueOrNull ?? const [];
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('Nessuna presenza registrata.'),
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    return Column(
      children: [
        for (final p in rows.take(5))
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(p.placeName),
            subtitle: Text(_span(p)),
            trailing: Text(
              formatHours(((p.exitedAt ?? now) - p.enteredAt) ~/ 1000),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
      ],
    );
  }

  static String _span(Presence p) {
    final day = DateFormat(
      'EEE d MMM',
      'it',
    ).format(DateTime.fromMillisecondsSinceEpoch(p.enteredAt));
    final end = p.exitedAt == null ? 'in corso' : _time(p.exitedAt!);
    return '$day · ${_time(p.enteredAt)} – $end';
  }
}

String _time(int ms) =>
    DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(ms));

class _Header extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const _Header(this.title, {this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;

  const _Notice({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 12),
                Expanded(child: Text(text)),
              ],
            ),
            if (action != null)
              Align(alignment: Alignment.centerRight, child: action),
          ],
        ),
      ),
    );
  }
}

// ── Place editor ─────────────────────────────────────────────────────────────

class _PlaceEditor extends ConsumerStatefulWidget {
  final Place? place;

  const _PlaceEditor(this.place);

  @override
  ConsumerState<_PlaceEditor> createState() => _PlaceEditorState();
}

class _PlaceEditorState extends ConsumerState<_PlaceEditor> {
  late final _name = TextEditingController(text: widget.place?.name);
  late final _lat = TextEditingController(
    text: widget.place?.latitude?.toString(),
  );
  late final _lon = TextEditingController(
    text: widget.place?.longitude?.toString(),
  );
  final _network = TextEditingController();
  late int _radius = widget.place?.radiusM ?? 100;
  late final List<String> _wifi = [...?widget.place?.wifi];

  String? _hint;
  WifiInfo? _current;
  bool _locating = false;
  bool _saving = false;

  static const _maxRadius = 1000;

  @override
  void dispose() {
    _name.dispose();
    _lat.dispose();
    _lon.dispose();
    _network.dispose();
    super.dispose();
  }

  Future<void> _useCurrentPosition() async {
    setState(() {
      _locating = true;
      _hint = null;
    });
    final problem = await PresenceSensors.ensureLocationAccess();
    final fix = problem == null ? await PresenceSensors.currentFix() : null;
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (fix == null) {
        _hint = problem ?? 'Posizione non disponibile: riprova all\'aperto.';
        return;
      }
      _lat.text = fix.latitude.toStringAsFixed(6);
      _lon.text = fix.longitude.toStringAsFixed(6);
      // The radius must cover the GPS error, at least twice this fix's.
      final suggested = ((fix.accuracyM * 2 / 10).ceil() * 10).clamp(
        50,
        _maxRadius,
      );
      if (_radius < suggested) _radius = suggested;
      _hint = 'Precisione di questa rilevazione: ±${fix.accuracyM.round()} m.';
    });
  }

  Future<void> _readCurrentNetwork() async {
    if (PresenceSensors.needsLocation(TrackingMode.wifi)) {
      final problem = await PresenceSensors.ensureLocationAccess();
      if (problem != null) {
        setState(() => _hint = problem);
        return;
      }
    }
    final wifi = await PresenceSensors.currentWifi();
    if (!mounted) return;
    setState(() {
      _current = wifi;
      if (wifi == null) {
        _hint = 'Rete Wi-Fi non leggibile su questo dispositivo.';
      } else if (!wifi.connected) {
        _hint = 'Non sei connesso a una rete Wi-Fi.';
      }
    });
  }

  void _addNetwork(String value) {
    final v = value.trim();
    if (v.isEmpty) return;
    final normalized = looksLikeBssid(v) ? normalizeBssid(v) : v;
    setState(() {
      if (!_wifi.contains(normalized)) _wifi.add(normalized);
      _network.clear();
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final lat = double.tryParse(_lat.text.trim().replaceAll(',', '.'));
    final lon = double.tryParse(_lon.text.trim().replaceAll(',', '.'));
    final hasLat = _lat.text.trim().isNotEmpty;
    final hasLon = _lon.text.trim().isNotEmpty;
    String? error;
    if (name.isEmpty) {
      error = 'Dai un nome al luogo.';
    } else if (hasLat != hasLon ||
        (hasLat && (lat == null || lat.abs() > 90)) ||
        (hasLon && (lon == null || lon.abs() > 180))) {
      error = 'Coordinate non valide.';
    } else if (!hasLat && _wifi.isEmpty) {
      error = 'Indica una posizione, almeno una rete Wi-Fi, o entrambe.';
    }
    if (error != null) {
      setState(() => _hint = error);
      return;
    }

    setState(() => _saving = true);
    try {
      await ref
          .read(presenceProvider.notifier)
          .savePlace(
            id: widget.place?.id,
            name: name,
            latitude: lat,
            longitude: lon,
            radiusM: _radius,
            wifi: _wifi,
          );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _hint = PresenceController.errorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.place == null ? 'Nuovo luogo' : 'Modifica luogo'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Salva'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Nome'),
            textCapitalization: TextCapitalization.sentences,
            maxLength: 100,
          ),
          if (_hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _hint!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const _Header('Posizione'),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _lat,
                  decoration: const InputDecoration(labelText: 'Latitudine'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _lon,
                  decoration: const InputDecoration(labelText: 'Longitudine'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _locating ? null : _useCurrentPosition,
              icon: _locating
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location),
              label: const Text('Usa la posizione attuale'),
            ),
          ),
          const SizedBox(height: 8),
          Text('Raggio: $_radius m'),
          Slider(
            value: _radius.clamp(10, _maxRadius).toDouble(),
            min: 10,
            max: _maxRadius.toDouble(),
            divisions: (_maxRadius - 10) ~/ 10,
            label: '$_radius m',
            onChanged: (v) => setState(() => _radius = v.round()),
          ),
          const Text(
            'Il raggio deve comprendere lo scarto del GPS: in un edificio '
            '50–100 m è un buon punto di partenza.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 16),
          const _Header('Reti Wi-Fi'),
          const Text(
            'Nome della rete (SSID: vale ogni access point) o indirizzo di un '
            'access point (BSSID, es. a4:2b:b0:12:34:56).',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final w in _wifi)
                InputChip(
                  label: Text(w),
                  onDeleted: () => setState(() => _wifi.remove(w)),
                ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _network,
                  decoration: const InputDecoration(labelText: 'Aggiungi rete'),
                  onSubmitted: _addNetwork,
                ),
              ),
              IconButton(
                tooltip: 'Aggiungi',
                icon: const Icon(Icons.add),
                onPressed: () => _addNetwork(_network.text),
              ),
            ],
          ),
          if (PresenceSensors.wifiSupported) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _readCurrentNetwork,
                icon: const Icon(Icons.wifi),
                label: const Text('Rete attuale'),
              ),
            ),
            if (current != null && current.connected)
              Wrap(
                spacing: 8,
                children: [
                  if (current.ssid != null)
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 16),
                      label: Text('Nome: ${current.ssid}'),
                      onPressed: () => _addNetwork(current.ssid!),
                    ),
                  if (current.bssid != null)
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 16),
                      label: Text('Access point: ${current.bssid}'),
                      onPressed: () => _addNetwork(current.bssid!),
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}
