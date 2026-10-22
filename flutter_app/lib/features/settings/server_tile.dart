import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/network/api_client.dart';
import '../../core/providers.dart';
import '../auth/auth_notifier.dart';
import '../sync/sync_service.dart';

/// Settings entry showing the backend address, with a dialog to change it.
class ServerTile extends ConsumerStatefulWidget {
  const ServerTile({super.key});

  @override
  ConsumerState<ServerTile> createState() => _ServerTileState();
}

class _ServerTileState extends ConsumerState<ServerTile> {
  late Future<String> _current;

  @override
  void initState() {
    super.initState();
    _current = ref.read(apiClientProvider).effectiveBaseUrl;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _current,
      builder: (context, snap) => ListTile(
        leading: const Icon(Icons.dns_outlined),
        title: const Text('Server'),
        subtitle: Text(snap.data ?? '…'),
        trailing: const Icon(Icons.edit_outlined),
        onTap: snap.hasData ? () => _edit(snap.data!) : null,
      ),
    );
  }

  Future<void> _edit(String current) async {
    final chosen = await showDialog<_Choice>(
      context: context,
      builder: (_) => _ServerDialog(current: current),
    );
    if (chosen == null || !mounted) return;

    final api = ref.read(apiClientProvider);
    final newUrl = chosen.useDefault ? ApiClient.defaultBaseUrl : chosen.url!;
    if (newUrl == api.baseUrl) return;

    final db = ref.read(appDatabaseProvider);
    if (chosen.useDefault) {
      await db.settingsDao.deleteValue(ApiClient.baseUrlSettingsKey);
    } else {
      await db.settingsDao.setValue(ApiClient.baseUrlSettingsKey, newUrl);
    }
    api.setBaseUrl(chosen.useDefault ? null : newUrl);

    // Token and sync position belong to the previous server.
    final auth = ref.read(authNotifierProvider.notifier);
    final wasLoggedIn =
        ref.read(authNotifierProvider).valueOrNull?.status ==
        AuthStatus.authenticated;
    await ref.read(syncServiceProvider).resetCursor();
    if (wasLoggedIn) await auth.logout();

    if (!mounted) return;
    setState(() => _current = Future.value(newUrl));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          wasLoggedIn ? 'Server cambiato: accedi di nuovo' : 'Server salvato',
        ),
      ),
    );
  }
}

class _Choice {
  final String? url;
  final bool useDefault;

  const _Choice.url(this.url) : useDefault = false;
  const _Choice.useDefault() : url = null, useDefault = true;
}

class _ServerDialog extends StatefulWidget {
  final String current;

  const _ServerDialog({required this.current});

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  late final _ctrl = TextEditingController(text: widget.current);
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _checkAndSave() async {
    final url = ApiClient.normalizeBaseUrl(_ctrl.text);
    if (url == null) {
      setState(() => _error = 'Inserisci un indirizzo http:// o https://');
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    final problem = await ApiClient.checkServer(url);
    if (!mounted) return;
    if (problem != null) {
      setState(() {
        _checking = false;
        _error = problem;
      });
      return;
    }
    Navigator.of(context).pop(_Choice.url(url));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Server'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ctrl,
            enabled: !_checking,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Indirizzo del backend',
              hintText: 'https://tuodominio.it/backend/api',
              border: const OutlineInputBorder(),
              errorText: _error,
              errorMaxLines: 4,
            ),
            onSubmitted: (_) => _checkAndSave(),
          ),
          const SizedBox(height: 12),
          Text(
            'Predefinito: ${ApiClient.defaultBaseUrl}\n'
            'Cambiando server verrai disconnesso.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _checking
              ? null
              : () => Navigator.of(context).pop(const _Choice.useDefault()),
          child: const Text('Predefinito'),
        ),
        TextButton(
          onPressed: _checking ? null : () => Navigator.of(context).pop(),
          child: const Text('Annulla'),
        ),
        FilledButton(
          onPressed: _checking ? null : _checkAndSave,
          child: _checking
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Prova e salva'),
        ),
      ],
    );
  }
}
