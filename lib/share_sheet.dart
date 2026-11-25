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

/// Lets the user pick a piece of [recording], its language and its format,
/// and sends it to another app through the system share sheet.
Future<void> showShareSheet(
  BuildContext context,
  Session session,
  Recording recording,
) async {
  final library = session.library;
  final choice = await showModalBottomSheet<ShareChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _ShareSheet(session: session, recording: recording),
  );
  if (choice == null || !context.mounted) return;

  if (choice.kind == ShareKind.everything) {
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
        languages: session.languages.jsonFor(recording.languages),
      ),
    );
    return;
  }

  final payload = buildSharePayload(
    library,
    recording.file,
    choice,
    await _shareOutDir(),
    languageName: (code) => session.languages.resolve(code).name,
  );
  final file = payload.file;
  await SharePlus.instance.share(
    file == null
        ? ShareParams(text: payload.text, subject: recording.name)
        : ShareParams(files: [XFile(file.path, mimeType: payload.mimeType)]),
  );
}

/// The share sheet's steps: the piece, then its language when there is more
/// than one, then its format. Pops with the [ShareChoice].
class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.session, required this.recording});

  final Session session;
  final Recording recording;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  ShareKind? _kind;
  String? _lang;

  /// Whether the language step was shown, so going back returns to it.
  bool _pickedLang = false;

  String _name(String code) => widget.session.languages.resolve(code).name;

  List<String> _langs(ShareKind kind) =>
      shareLangs(widget.session.library, widget.recording.file, kind);

  void _pickKind(ShareKind kind) {
    if (kind == ShareKind.recording || kind == ShareKind.everything) {
      Navigator.pop<ShareChoice>(context, (
        kind: kind,
        lang: null,
        format: null,
      ));
      return;
    }
    final langs = _langs(kind);
    setState(() {
      _kind = kind;
      _pickedLang = langs.length > 1;
      _lang = langs.length == 1 ? langs.single : null;
    });
  }

  void _back() => setState(() {
    if (_lang != null && _pickedLang) {
      _lang = null;
    } else {
      _kind = null;
      _lang = null;
    }
  });

  @override
  Widget build(BuildContext context) {
    final kind = _kind;
    final theme = Theme.of(context);
    final String title;
    final List<Widget> rows;
    if (kind == null) {
      title = 'Share ${widget.recording.name}';
      rows = [
        for (final k in availableShareKinds(
          widget.session.library,
          widget.recording.file,
        ))
          ListTile(
            leading: Icon(switch (k) {
              ShareKind.recording =>
                widget.recording.isVideo
                    ? Icons.videocam_outlined
                    : Icons.graphic_eq,
              ShareKind.transcript => Icons.subject,
              ShareKind.translation => Icons.translate,
              ShareKind.summary => Icons.summarize_outlined,
              ShareKind.everything => Icons.folder_zip_outlined,
            }),
            title: Text(switch (k) {
              ShareKind.recording => 'Recording',
              ShareKind.transcript => 'Transcript',
              ShareKind.translation => 'Translation',
              ShareKind.summary => 'Summary',
              ShareKind.everything => 'Everything (.zip)',
            }),
            trailing: formatsFor(k).isEmpty
                ? null
                : const Icon(Icons.chevron_right),
            onTap: () => _pickKind(k),
          ),
      ];
    } else if (_lang == null && kind != ShareKind.transcript) {
      title = kind == ShareKind.summary ? 'Summary' : 'Translation';
      rows = [
        for (final code in _langs(kind))
          ListTile(
            title: Text(_name(code)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => setState(() => _lang = code),
          ),
      ];
    } else {
      final lang = _lang;
      title = switch (kind) {
        ShareKind.transcript => 'Transcript (${_name(widget.recording.lang)})',
        ShareKind.summary => 'Summary (${_name(lang!)})',
        _ => 'Translation (${_name(lang!)})',
      };
      rows = [
        for (final format in formatsFor(kind))
          ListTile(
            title: Text(format.label),
            onTap: () => Navigator.pop<ShareChoice>(context, (
              kind: kind,
              lang: lang,
              format: format,
            )),
          ),
      ];
    }
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: .min,
          children: [
            ListTile(
              leading: kind == null
                  ? null
                  : IconButton(
                      tooltip: 'Back',
                      onPressed: _back,
                      icon: const Icon(Icons.arrow_back),
                    ),
              title: Text(
                title,
                maxLines: 1,
                overflow: .ellipsis,
                style: theme.textTheme.titleMedium,
              ),
            ),
            ...rows,
          ],
        ),
      ),
    );
  }
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
        for (final r in session.library.recordingsIn(folder)) ...r.languages,
      ]),
    ),
  );
}
