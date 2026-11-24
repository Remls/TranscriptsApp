import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'backup.dart';
import 'job_panel.dart';
import 'library.dart';
import 'session.dart';
import 'share_parts.dart';

const _groupIcons = {
  'Transcript': Icons.subject,
  'Translation': Icons.translate,
  'Summary': Icons.summarize_outlined,
};

const _zipMimeType = 'application/zip';

void _showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), persist: false));
}

/// Sends [text] to another app through the system share sheet.
Future<void> shareText(String text, {String? subject}) {
  return SharePlus.instance.share(ShareParams(text: text, subject: subject));
}

/// An emptied folder in the cache for files on their way out.
Future<Directory> _shareOutDir() async {
  final dir = Directory(
    p.join((await getTemporaryDirectory()).path, 'share_out'),
  );
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  return dir..createSync(recursive: true);
}

/// Builds a zip named [fileName] with [build] behind a progress dialog, then
/// sends it to another app.
Future<void> _shareZip(
  BuildContext context,
  String fileName,
  Future<void> Function(String zipPath, void Function(double) report) build,
) async {
  final zip = File(p.join((await _shareOutDir()).path, fileName));
  if (!context.mounted) return;
  try {
    await runWithProgressDialog(
      context,
      'Making $fileName',
      (report) => build(zip.path, report),
    );
  } on Exception catch (e) {
    if (context.mounted) _showMessage(context, 'Could not make the zip: $e');
    return;
  }
  await SharePlus.instance.share(
    ShareParams(files: [XFile(zip.path, mimeType: _zipMimeType)]),
  );
}

/// Lets the user pick a part of [recording] and sends it to another app
/// through the system share sheet.
Future<void> showShareSheet(
  BuildContext context,
  Session session,
  Recording recording,
) async {
  final library = session.library;
  final parts = availableShareParts(library, recording.file);
  final part = await showModalBottomSheet<SharePart>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: .min,
          children: [
            ListTile(
              title: Text(
                'Share ${recording.name}',
                maxLines: 1,
                overflow: .ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final (i, part) in parts.indexed) ...[
              if (part.group != null &&
                  (i == 0 || parts[i - 1].group != part.group))
                ListTile(
                  dense: true,
                  leading: Icon(_groupIcons[part.group]),
                  title: Text(
                    part.group!,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ListTile(
                contentPadding: part.group == null
                    ? null
                    : const EdgeInsetsDirectional.only(start: 72, end: 24),
                leading: switch (part) {
                  SharePart.recording => Icon(
                    recording.isVideo
                        ? Icons.videocam_outlined
                        : Icons.graphic_eq,
                  ),
                  SharePart.everything => const Icon(Icons.folder_zip_outlined),
                  _ => null,
                },
                title: Text(part.label),
                onTap: () => Navigator.pop(context, part),
              ),
            ],
          ],
        ),
      ),
    ),
  );
  if (part == null || !context.mounted) return;

  if (part == SharePart.everything) {
    if (session.recordingBusy(recording.relPath)) {
      _showMessage(context, 'Wait for the running job to finish');
      return;
    }
    await _shareZip(
      context,
      '${recording.name}.zip',
      (zipPath, report) => createRecordingZipInBackground(
        library.root.path,
        recording.file.path,
        zipPath,
        report,
        languages: session.languages.jsonFor([recording.lang]),
      ),
    );
    return;
  }

  final payload = buildSharePayload(
    library,
    recording.file,
    part,
    await _shareOutDir(),
  );
  final file = payload.file;
  await SharePlus.instance.share(
    file == null
        ? ShareParams(text: payload.text, subject: recording.name)
        : ShareParams(files: [XFile(file.path, mimeType: payload.mimeType)]),
  );
}

/// Sends [folder] and everything in it to another app as one zip.
Future<void> shareFolderZip(
  BuildContext context,
  Session session,
  Directory folder,
) async {
  if (session.folderBusy(folder)) {
    _showMessage(context, 'Wait for the running job to finish');
    return;
  }
  await _shareZip(
    context,
    '${p.basename(folder.path)}.zip',
    (zipPath, report) => createFolderZipInBackground(
      folder.path,
      zipPath,
      report,
      languages: session.languages.jsonFor([
        for (final r in session.library.recordingsIn(folder)) r.lang,
      ]),
    ),
  );
}
