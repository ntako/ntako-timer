import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../auth/auth_notifier.dart';
import '../sync/sync_service.dart';
import 'backup_service.dart';

/// Settings entries for JSON backup / restore and CSV export.
class BackupSection extends ConsumerWidget {
  const BackupSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.download),
          title: const Text('Esporta backup'),
          subtitle: const Text('Tutti i dati in un file JSON reimportabile'),
          onTap: () => _export(context, ref, csv: false),
        ),
        ListTile(
          leading: const Icon(Icons.table_chart_outlined),
          title: const Text('Esporta sessioni (CSV)'),
          subtitle: const Text('Per Excel o Fogli Google'),
          onTap: () => _export(context, ref, csv: true),
        ),
        ListTile(
          leading: const Icon(Icons.upload),
          title: const Text('Importa backup'),
          subtitle: const Text(
            'Unisce un backup JSON ai dati attuali, senza cancellare nulla',
          ),
          onTap: () => _import(context, ref),
        ),
      ],
    );
  }

  Future<void> _export(
    BuildContext context,
    WidgetRef ref, {
    required bool csv,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final backup = ref.read(backupServiceProvider);
      final content = csv
          ? await backup.exportSessionsCsv()
          : await backup.exportJson();
      final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
      final path = await FilePicker.saveFile(
        fileName: csv
            ? 'ntako_sessioni_$stamp.csv'
            : 'ntako_backup_$stamp.json',
        bytes: utf8.encode(content),
      );
      // On the web the browser downloads the file and no path comes back.
      if (path == null && !kIsWeb) return;
      messenger.showSnackBar(const SnackBar(content: Text('File esportato')));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Errore esportazione: $e')),
      );
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      final bytes = picked?.files.single.bytes;
      if (bytes == null) return;

      final String source;
      try {
        source = utf8.decode(bytes);
      } on FormatException {
        throw const BackupFormatException('Il file non è un testo UTF-8.');
      }

      final result = await ref.read(backupServiceProvider).importJson(source);

      final loggedIn =
          ref.read(authNotifierProvider).valueOrNull?.status ==
          AuthStatus.authenticated;
      if (loggedIn && result.changedAnything) {
        ref.read(syncServiceProvider).sync().ignore();
      }

      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(_summary(result)),
        ),
      );
    } on BackupFormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Errore importazione: $e')),
      );
    }
  }

  static String _summary(ImportResult r) {
    if (!r.changedAnything) return 'Nessuna novità: i dati erano già presenti.';
    String line(String label, ImportCounts c) =>
        '$label: ${c.added} nuovi, ${c.updated} aggiornati';
    return [
      'Importazione completata',
      line('Categorie', r.categories),
      line('Task', r.tasks),
      line('Sessioni', r.sessions),
    ].join('\n');
  }
}
