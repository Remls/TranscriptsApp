import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'backup.dart';
import 'job_panel.dart';
import 'save_file.dart';
import 'session.dart';
import 'unknown_languages.dart';

void _showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), persist: false));
}

Future<RestoreMode?> _askMode(BuildContext context) {
  return showDialog<RestoreMode>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Restore backup'),
      content: const Text(
        'Merge adds what the backup has and keeps every file already in '
        'the library.\n\n'
        'Replace moves the current folders and recordings to the trash '
        'first. They keep using storage until you empty the trash.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, RestoreMode.replace),
          child: const Text('Replace'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, RestoreMode.merge),
          child: const Text('Merge'),
        ),
      ],
    ),
  );
}

/// Asks whether a zip whose files are all inside a folder named `audios`
/// restores that folder's contents or the folder itself. Resolves to null
/// when cancelled.
Future<bool?> _askUnwrap(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Folder named audios'),
      content: const Text(
        'Everything in this zip is inside one folder named audios.\n\n'
        'Restore its contents puts the folders and recordings inside it '
        'straight into the library.\n\n'
        'Keep the folder restores it as a folder named audios.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Keep the folder'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Restore its contents'),
        ),
      ],
    ),
  );
}

/// Restores the zip at [zipPath] into the library after asking how, then
/// reports the outcome in a snackbar. With [askLanguages], then asks about
/// language codes the library uses that the language list lacks.
Future<void> restoreZip(
  BuildContext context,
  Session session,
  String zipPath, {
  bool askLanguages = true,
}) async {
  if (session.anyJobRunning) {
    _showMessage(context, 'Wait for the running job to finish');
    return;
  }
  final bool wrapped;
  try {
    wrapped = await hasWrapperFolderInBackground(zipPath);
  } on BackupException catch (e) {
    if (context.mounted) _showMessage(context, e.message);
    return;
  }
  if (!context.mounted) return;
  final unwrap = wrapped ? await _askUnwrap(context) : false;
  if (unwrap == null || !context.mounted) return;
  final mode = await _askMode(context);
  if (mode == null || !context.mounted) return;
  final open = session.recording?.file;
  if (mode == RestoreMode.replace) await session.close();
  if (!context.mounted) return;
  try {
    final result = await runWithProgressDialog(
      context,
      'Restoring backup',
      (report) => restoreBackupInBackground(
        zipPath,
        session.library.root.path,
        mode,
        report,
        unwrap: unwrap,
      ),
    );
    final languages = result.languages;
    if (languages != null) session.languages.merge(languages);
    if (open != null && open.existsSync()) await session.reopenAt(open);
    if (!context.mounted) return;
    _showMessage(
      context,
      [
        'Restored ${result.added} ${result.added == 1 ? 'file' : 'files'}',
        if (result.skipped > 0) 'kept ${result.skipped} already here',
        if (result.repaired > 0) 'repaired ${result.repaired} transcripts',
      ].join(', '),
    );
    if (askLanguages) await askForUnknownLanguages(context, session);
  } on BackupException catch (e) {
    if (context.mounted) _showMessage(context, e.message);
  } on Exception catch (e) {
    if (context.mounted) _showMessage(context, 'Restore failed: $e');
  }
}

/// The controls to save the library as a zip and to restore one.
class BackupSection extends StatelessWidget {
  const BackupSection({super.key, required this.session});

  final Session session;

  Future<void> _create(BuildContext context) async {
    final name = backupFileName(DateTime.now());
    final zip = File(p.join((await getTemporaryDirectory()).path, name));
    if (!context.mounted) return;
    try {
      await runWithProgressDialog(
        context,
        'Creating backup',
        (report) => createBackupInBackground(
          session.library.root.path,
          zip.path,
          report,
        ),
      );
      final saved = await saveFileAs(zip, name, 'application/zip');
      if (context.mounted) {
        _showMessage(context, saved ? 'Backup saved' : 'Backup not saved');
      }
    } on Exception catch (e) {
      if (context.mounted) _showMessage(context, 'Backup failed: $e');
    } finally {
      if (zip.existsSync()) zip.deleteSync();
    }
  }

  Future<void> _restore(BuildContext context) async {
    if (session.anyJobRunning) {
      _showMessage(context, 'Wait for the running job to finish');
      return;
    }
    final picked = await FilePicker.pickFile(
      onFileLoading: (status) {
        if (status == FilePickerStatus.picking && context.mounted) {
          _showMessage(context, 'Reading the backup file');
        }
      },
    );
    final path = picked?.path;
    try {
      if (path != null && context.mounted) {
        await restoreZip(context, session, path);
      }
    } finally {
      await FilePicker.clearTemporaryFiles();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: .start,
      children: [
        const Text(
          'A backup is one zip file with every recording, transcript, '
          'translation, summary and context note, and your language list. The '
          'trash, API keys and the other settings are left out.',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: () => _create(context),
              icon: const Icon(Icons.archive_outlined),
              label: const Text('Create backup'),
            ),
            OutlinedButton.icon(
              onPressed: () => _restore(context),
              icon: const Icon(Icons.unarchive_outlined),
              label: const Text('Restore from backup'),
            ),
          ],
        ),
      ],
    );
  }
}
