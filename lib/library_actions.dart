import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'backup_section.dart';
import 'library.dart';
import 'session.dart';
import 'trash.dart';
import 'unknown_languages.dart';

void _showMessage(BuildContext context, String text, {SnackBarAction? action}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(text), persist: false, action: action),
    );
}

/// Asks for a name. Resolves to null when cancelled.
Future<String?> promptName(
  BuildContext context, {
  required String title,
  required String action,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(action),
        ),
      ],
    ),
  );
}

/// A destination chosen in [pickFolder]: an existing folder, or the root
/// when [folder] is null.
class FolderChoice {
  const FolderChoice(this.folder);

  final Directory? folder;
}

/// Lets the user choose a folder, the root ("No folder"), or a new folder.
/// Resolves to null when cancelled.
Future<FolderChoice?> pickFolder(
  BuildContext context,
  Library library, {
  required String title,
  required String action,
  Directory? initial,
}) async {
  final folders = library.folders();
  var selected = initial?.path;
  var creating = false;
  final newName = TextEditingController();

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        Widget option(
          String label,
          IconData icon,
          bool chosen,
          VoidCallback onTap,
        ) {
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              chosen
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
            ),
            title: Text(label),
            trailing: Icon(icon, size: 18),
            onTap: () => setDialogState(onTap),
          );
        }

        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                option(
                  'No folder',
                  Icons.folder_off_outlined,
                  !creating && selected == null,
                  () {
                    creating = false;
                    selected = null;
                  },
                ),
                for (final folder in folders)
                  option(
                    p.basename(folder.path),
                    Icons.folder_outlined,
                    !creating && selected == folder.path,
                    () {
                      creating = false;
                      selected = folder.path;
                    },
                  ),
                option(
                  'New folder',
                  Icons.create_new_folder_outlined,
                  creating,
                  () => creating = true,
                ),
                if (creating)
                  TextField(
                    controller: newName,
                    autofocus: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(labelText: 'Folder name'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        );
      },
    ),
  );
  if (confirmed != true || !context.mounted) return null;
  try {
    if (creating) return FolderChoice(library.createFolder(newName.text));
    return FolderChoice(selected == null ? null : Directory(selected!));
  } on LibraryException catch (e) {
    _showMessage(context, e.message);
    return null;
  }
}

/// A file to import, with the name it should get when that differs from the
/// file's own.
typedef ImportSource = ({File file, String name});

/// Restores each zip in [given] as a backup, then copies the rest into a
/// folder the user chooses and opens the first one.
Future<void> importSources(
  BuildContext context,
  Session session,
  List<ImportSource> given,
) async {
  bool isZip(ImportSource s) => p.extension(s.name).toLowerCase() == '.zip';
  for (final zip in given.where(isZip)) {
    if (!context.mounted) return;
    await restoreZip(context, session, zip.file.path, askLanguages: false);
  }
  if (given.any(isZip) && context.mounted) {
    await askForUnknownLanguages(context, session);
  }
  final sources = [
    for (final s in given)
      if (!isZip(s)) s,
  ];
  if (sources.isEmpty || !context.mounted) return;
  final library = session.library;
  final media = [
    for (final s in sources)
      if (library.isMediaName(s.name)) s,
  ];
  if (media.isEmpty) {
    _showMessage(context, 'No audio, video or zip files to import');
    return;
  }
  final open = session.recording?.file.parent;
  final choice = await pickFolder(
    context,
    library,
    title: media.length == 1
        ? 'Import ${media.single.name}'
        : 'Import ${media.length} files',
    action: 'Import',
    initial: open == null || open.path == library.root.path ? null : open,
  );
  if (choice == null || !context.mounted) return;

  final progress = ValueNotifier(0);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 24),
            ValueListenableBuilder(
              valueListenable: progress,
              builder: (context, done, _) =>
                  Text('Importing ${done + 1} of ${media.length}'),
            ),
          ],
        ),
      ),
    ),
  );
  final imported = <File>[];
  String? failure;
  try {
    for (final (i, source) in media.indexed) {
      progress.value = i;
      imported.add(
        await library.importFile(source.file, choice.folder, name: source.name),
      );
    }
  } on LibraryException catch (e) {
    failure = e.message;
  } on FileSystemException catch (e) {
    failure = 'Import failed: ${e.osError?.message ?? e.message}';
  }
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();

  if (imported.isNotEmpty) {
    await session.open(library.describe(imported.first));
  }
  if (!context.mounted) return;
  final skipped = sources.length - media.length;
  _showMessage(
    context,
    failure ??
        'Imported ${imported.length} '
            '${imported.length == 1 ? 'file' : 'files'}'
            '${skipped > 0 ? ', skipped $skipped that are not audio or video' : ''}',
  );
}

Future<void> createFolder(BuildContext context, Session session) async {
  final name = await promptName(context, title: 'New folder', action: 'Create');
  if (name == null || !context.mounted) return;
  try {
    session.library.createFolder(name);
  } on LibraryException catch (e) {
    _showMessage(context, e.message);
  }
}

bool _blockedByJob(BuildContext context, bool busy) {
  if (busy) _showMessage(context, 'Wait for the running job to finish');
  return busy;
}

Future<void> renameRecording(
  BuildContext context,
  Session session,
  Recording recording,
) async {
  if (_blockedByJob(context, session.recordingBusy(recording.relPath))) return;
  final name = await promptName(
    context,
    title: 'Rename recording',
    action: 'Rename',
    initial: recording.name,
  );
  if (name == null || !context.mounted) return;
  try {
    final renamed = session.library.renameRecording(recording.file, name);
    if (session.recording?.relPath == recording.relPath) {
      await session.reopenAt(renamed);
    }
  } on LibraryException catch (e) {
    if (context.mounted) _showMessage(context, e.message);
  }
}

Future<void> moveRecording(
  BuildContext context,
  Session session,
  Recording recording,
) async {
  if (_blockedByJob(context, session.recordingBusy(recording.relPath))) return;
  final library = session.library;
  final current = recording.file.parent;
  final choice = await pickFolder(
    context,
    library,
    title: 'Move ${recording.name}',
    action: 'Move',
    initial: current.path == library.root.path ? null : current,
  );
  if (choice == null || !context.mounted) return;
  try {
    final moved = library.moveRecording(recording.file, choice.folder);
    if (session.recording?.relPath == recording.relPath) {
      await session.reopenAt(moved);
    }
  } on LibraryException catch (e) {
    if (context.mounted) _showMessage(context, e.message);
  }
}

/// Moves [recording] to the trash and offers to undo it.
Future<void> trashRecording(
  BuildContext context,
  Session session,
  Recording recording,
  VoidCallback onChanged,
) async {
  if (_blockedByJob(context, session.recordingBusy(recording.relPath))) return;
  if (session.recording?.relPath == recording.relPath) await session.close();
  final trash = Trash(session.library)..trashRecording(recording.file);
  if (!context.mounted) return;
  _showMessage(
    context,
    'Moved ${recording.name} to trash',
    action: SnackBarAction(
      label: 'Undo',
      onPressed: () {
        final item = trash.items().firstWhere(
          (i) => !i.isFolder && i.name == recording.name,
        );
        trash.restore(item);
        onChanged();
      },
    ),
  );
}

Future<void> renameFolder(
  BuildContext context,
  Session session,
  Directory folder,
) async {
  if (_blockedByJob(context, session.folderBusy(folder))) return;
  final name = await promptName(
    context,
    title: 'Rename folder',
    action: 'Rename',
    initial: p.basename(folder.path),
  );
  if (name == null || !context.mounted) return;
  final open = session.recording;
  final openInside = open != null && open.file.parent.path == folder.path;
  try {
    final renamed = session.library.renameFolder(folder, name);
    if (openInside) {
      await session.reopenAt(
        File(p.join(renamed.path, p.basename(open.file.path))),
      );
    }
  } on LibraryException catch (e) {
    if (context.mounted) _showMessage(context, e.message);
  }
}

/// Moves [folder] and everything in it to the trash and offers to undo it.
Future<void> trashFolder(
  BuildContext context,
  Session session,
  Directory folder,
  VoidCallback onChanged,
) async {
  if (_blockedByJob(context, session.folderBusy(folder))) return;
  if (session.recording?.file.parent.path == folder.path) await session.close();
  final name = p.basename(folder.path);
  final trash = Trash(session.library)..trashFolder(folder);
  if (!context.mounted) return;
  _showMessage(
    context,
    'Moved $name to trash',
    action: SnackBarAction(
      label: 'Undo',
      onPressed: () {
        final item = trash.items().firstWhere(
          (i) => i.isFolder && i.name == name,
        );
        trash.restore(item);
        onChanged();
      },
    ),
  );
}
