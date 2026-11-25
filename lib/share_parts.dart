import 'dart:io';

import 'package:path/path.dart' as p;

import 'library.dart';
import 'text_jobs.dart';

/// A piece of a recording that can be sent to another app.
enum ShareKind { recording, transcript, translation, summary, everything }

/// How a transcript, translation or summary is sent.
enum ShareFormat {
  srt('As subtitle file (.srt)'),
  text('As text file (.txt)'),
  plain('As plain text');

  const ShareFormat(this.label);

  final String label;
}

/// What to send: a piece, in [lang] for a translation or summary, as
/// [format] for anything but the recording or the zip.
typedef ShareChoice = ({ShareKind kind, String? lang, ShareFormat? format});

/// The formats [kind] can be sent as.
List<ShareFormat> formatsFor(ShareKind kind) => switch (kind) {
  ShareKind.transcript || ShareKind.translation => ShareFormat.values,
  ShareKind.summary => const [ShareFormat.text, ShareFormat.plain],
  _ => const [],
};

/// What a share hands to the system: a file, or plain text.
class SharePayload {
  const SharePayload.file(File this.file, String this.mimeType) : text = null;
  const SharePayload.text(String this.text) : file = null, mimeType = null;

  final File? file;
  final String? mimeType;
  final String? text;
}

const _mediaMimeTypes = {
  '.mp3': 'audio/mpeg',
  '.m4a': 'audio/mp4',
  '.ogg': 'audio/ogg',
  '.opus': 'audio/ogg',
  '.wav': 'audio/wav',
  '.flac': 'audio/flac',
  '.aac': 'audio/aac',
  '.m4b': 'audio/mp4',
  '.amr': 'audio/amr',
  '.wma': 'audio/x-ms-wma',
  '.mp4': 'video/mp4',
  '.3gp': 'video/3gpp',
  '.wmv': 'video/x-ms-wmv',
  '.ts': 'video/mp2t',
  '.mts': 'video/mp2t',
  '.m4v': 'video/mp4',
  '.webm': 'video/webm',
  '.mov': 'video/quicktime',
  '.mkv': 'video/x-matroska',
  '.avi': 'video/x-msvideo',
};

const _srtMimeType = 'application/x-subrip';

/// The pieces of [recording] that exist, in menu order.
List<ShareKind> availableShareKinds(Library library, File recording) => [
  ShareKind.recording,
  if (library.sidecarFile(recording, Sidecar.transcriptSrt).existsSync())
    ShareKind.transcript,
  if (library.translationLangs(recording).isNotEmpty) ShareKind.translation,
  if (library.summaryLangs(recording).isNotEmpty) ShareKind.summary,
  ShareKind.everything,
];

/// The languages [recording] has [kind] in, English first.
List<String> shareLangs(Library library, File recording, ShareKind kind) =>
    switch (kind) {
      ShareKind.translation => library.translationLangs(recording),
      ShareKind.summary => library.summaryLangs(recording),
      _ => const [],
    };

/// Prepares [choice] of [recording] for sharing. Files are written into
/// [tempDir], named after the recording: subtitle files as
/// `<name>.<language code>.srt`, which video players read as the subtitles'
/// language, and text files with the language's name from [languageName].
/// Text files and plain text carry speaker names and manual speaker changes.
/// [ShareKind.everything] is a zip built in the background and is not
/// handled here.
SharePayload buildSharePayload(
  Library library,
  File recording,
  ShareChoice choice,
  Directory tempDir, {
  required String Function(String code) languageName,
}) {
  final name = p.basenameWithoutExtension(recording.path);
  File temp(String fileName, String content) {
    tempDir.createSync(recursive: true);
    return File(p.join(tempDir.path, fileName))..writeAsStringSync(content);
  }

  final kind = choice.kind;
  if (kind == ShareKind.recording) {
    return SharePayload.file(
      recording,
      _mediaMimeTypes[p.extension(recording.path).toLowerCase()] ??
          'application/octet-stream',
    );
  }
  if (kind == ShareKind.everything) {
    throw UnsupportedError(
      'The zip of a recording is built by createRecordingZip',
    );
  }
  final format = choice.format!;
  if (kind == ShareKind.summary) {
    final lang = choice.lang!;
    final summary = library
        .summaryFile(recording, lang)
        .readAsStringSync()
        .trim();
    return format == ShareFormat.plain
        ? SharePayload.text(summary)
        : SharePayload.file(
            temp('$name (${languageName(lang)} summary).txt', '$summary\n'),
            'text/plain',
          );
  }
  final transcript = kind == ShareKind.transcript;
  final lang = transcript ? library.langOf(recording) : choice.lang!;
  final srt = transcript
      ? library.sidecarFile(recording, Sidecar.transcriptSrt)
      : library.translationFile(recording, lang);
  return switch (format) {
    ShareFormat.srt => SharePayload.file(
      temp('$name.$lang.srt', srt.readAsStringSync()),
      _srtMimeType,
    ),
    ShareFormat.text => SharePayload.file(
      temp(
        transcript ? '$name.txt' : '$name (${languageName(lang)}).txt',
        '${speakerLines(library, recording, srt)}\n',
      ),
      'text/plain',
    ),
    ShareFormat.plain => SharePayload.text(
      speakerLines(library, recording, srt)!,
    ),
  };
}
