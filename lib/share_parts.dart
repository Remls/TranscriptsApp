import 'dart:io';

import 'package:path/path.dart' as p;

import 'library.dart';
import 'text_jobs.dart';

/// A piece of a recording that can be sent to another app.
enum SharePart {
  recording(null, 'Recording'),
  transcriptSrt('Transcript', 'As subtitle file (.srt)'),
  transcriptText('Transcript', 'As text file (.txt)'),
  transcriptPlain('Transcript', 'As plain text'),
  translationSrt('Translation', 'As subtitle file (.srt)'),
  translationText('Translation', 'As text file (.txt)'),
  translationPlain('Translation', 'As plain text'),
  summaryText('Summary', 'As text file (.txt)'),
  summaryPlain('Summary', 'As plain text'),
  everything(null, 'Everything (.zip)');

  const SharePart(this.group, this.label);

  /// The heading the option sits under, or null for one on its own.
  final String? group;
  final String label;
}

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

/// The parts of [recording] that exist, in menu order.
List<SharePart> availableShareParts(Library library, File recording) {
  bool has(Sidecar key) => library.sidecarFile(recording, key).existsSync();
  return [
    SharePart.recording,
    if (has(Sidecar.transcriptSrt)) ...[
      SharePart.transcriptSrt,
      SharePart.transcriptText,
      SharePart.transcriptPlain,
    ],
    if (has(Sidecar.translation)) ...[
      SharePart.translationSrt,
      SharePart.translationText,
      SharePart.translationPlain,
    ],
    if (has(Sidecar.summary)) ...[
      SharePart.summaryText,
      SharePart.summaryPlain,
    ],
    SharePart.everything,
  ];
}

/// Prepares [part] of [recording] for sharing. Transcript and translation
/// files are written into [tempDir], named after the recording. Text files
/// and plain text carry speaker names and manual speaker changes. [SharePart.everything] is
/// a zip built in the background and is not handled here.
SharePayload buildSharePayload(
  Library library,
  File recording,
  SharePart part,
  Directory tempDir,
) {
  final name = p.basenameWithoutExtension(recording.path);
  File temp(String fileName, String content) {
    tempDir.createSync(recursive: true);
    return File(p.join(tempDir.path, fileName))..writeAsStringSync(content);
  }

  SharePayload srt(Sidecar key, String suffix) => SharePayload.file(
    temp(
      '$name$suffix.srt',
      library.sidecarFile(recording, key).readAsStringSync(),
    ),
    _srtMimeType,
  );
  SharePayload text(Sidecar key, String suffix) => SharePayload.file(
    temp('$name$suffix.txt', '${speakerLines(library, recording, key)}\n'),
    'text/plain',
  );
  String summary() =>
      library.sidecarFile(recording, Sidecar.summary).readAsStringSync().trim();

  return switch (part) {
    SharePart.recording => SharePayload.file(
      recording,
      _mediaMimeTypes[p.extension(recording.path).toLowerCase()] ??
          'application/octet-stream',
    ),
    SharePart.transcriptSrt => srt(Sidecar.transcriptSrt, ''),
    SharePart.transcriptText => text(Sidecar.transcriptSrt, ''),
    SharePart.translationSrt => srt(Sidecar.translation, ' (English)'),
    SharePart.translationText => text(Sidecar.translation, ' (English)'),
    SharePart.transcriptPlain => SharePayload.text(
      speakerLines(library, recording, Sidecar.transcriptSrt)!,
    ),
    SharePart.translationPlain => SharePayload.text(
      speakerLines(library, recording, Sidecar.translation)!,
    ),
    SharePart.summaryText => SharePayload.file(
      temp('$name (summary).txt', '${summary()}\n'),
      'text/plain',
    ),
    SharePart.summaryPlain => SharePayload.text(summary()),
    SharePart.everything => throw UnsupportedError(
      'The zip of a recording is built by createRecordingZip',
    ),
  };
}
