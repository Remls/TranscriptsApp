import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'languages.dart';
import 'library.dart';
import 'srt.dart';
import 'trash.dart';

const _trashDir = '.trash';
const _macResourceDir = '__MACOSX';
const _ignoredNames = {'.DS_Store', '.gitkeep'};

/// A top-level folder that a zip of a whole library folder wraps its entries
/// in.
const _wrapperDir = 'audios';

/// Deflate level for text sidecars. Media is stored without compression.
const _textLevel = 6;

enum RestoreMode { merge, replace }

class RestoreResult {
  const RestoreResult({
    required this.added,
    required this.skipped,
    required this.repaired,
    this.languages,
  });

  /// Files written to the library.
  final int added;

  /// Files left out because the library already had them.
  final int skipped;

  /// Restored SRT files whose timestamps or speaker lines were repaired.
  final int repaired;

  /// The zip's language list file, which is merged rather than restored.
  final String? languages;
}

/// A backup that cannot be read, with a message for the user.
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reports [done] of [total] through [onProgress], once per whole percent.
class _Progress {
  _Progress(this.total, this.onProgress);

  final int total;
  final void Function(double fraction) onProgress;
  int _done = 0;
  int _lastPercent = -1;

  void add(int amount) {
    _done += amount;
    final percent = total == 0 ? 100 : (_done * 100 ~/ total).clamp(0, 100);
    if (percent == _lastPercent) return;
    _lastPercent = percent;
    onProgress(percent / 100);
  }
}

/// Writes [filePaths] into a zip at [zipPath]. Entry names are the paths
/// relative to [basePath], with forward slashes. Media is stored, text is
/// deflated. [languages] becomes the zip's language list file.
void createArchive(
  String basePath,
  List<String> filePaths,
  String zipPath,
  void Function(double fraction) onProgress, {
  String? languages,
}) {
  final files = [for (final path in filePaths) File(path)]
    ..sort((a, b) => a.path.compareTo(b.path));
  final library = Library(Directory(basePath));
  final progress = _Progress(
    files.fold(0, (sum, f) => sum + f.lengthSync()),
    onProgress,
  );
  final encoder = ZipFileEncoder()..create(zipPath);
  try {
    for (final f in files) {
      final name = p.split(p.relative(f.path, from: basePath)).join('/');
      encoder.addFileSync(
        f,
        name,
        library.isMediaName(name) ? ZipFileEncoder.store : _textLevel,
      );
      progress.add(f.lengthSync());
    }
    if (languages != null) {
      encoder.addArchiveFile(ArchiveFile.string(languageListFile, languages));
    }
  } finally {
    encoder.closeSync();
  }
  onProgress(1);
}

/// The file names of playback copies inside a sidecar folder.
final _playbackCopies = {
  Sidecar.playbackVideo.fileName,
  Sidecar.playbackSound.fileName,
};

/// Whether [path] is a playback copy, or one being made, in a sidecar
/// folder.
bool _isPlaybackCopy(String path) {
  final name = p.basename(path);
  return p.basename(p.dirname(path)).startsWith('.') &&
      (_playbackCopies.contains(name) || name.startsWith('.partial-'));
}

/// Every file under [dir], minus the ignored names and playback copies.
List<String> _filesUnder(Directory dir) {
  if (!dir.existsSync()) return [];
  return [
    for (final f in dir.listSync(recursive: true).whereType<File>())
      if (!_ignoredNames.contains(p.basename(f.path)) &&
          !_isPlaybackCopy(f.path))
        f.path,
  ];
}

/// Writes every library file except the trash into a zip at [zipPath].
void createBackup(
  String rootPath,
  String zipPath,
  void Function(double fraction) onProgress,
) {
  final root = Directory(rootPath)..createSync(recursive: true);
  final files = [
    for (final path in _filesUnder(root))
      if (p.split(p.relative(path, from: root.path)).first != _trashDir) path,
  ];
  createArchive(root.path, files, zipPath, onProgress);
}

/// [recording] and every file in its sidecar folder.
List<String> recordingArchiveFiles(Library library, File recording) {
  return [recording.path, ..._filesUnder(library.sidecarDir(recording))];
}

/// Every file in [folder], including its sidecars and folder summaries.
List<String> folderArchiveFiles(Directory folder) => _filesUnder(folder);

/// Writes [recordingPath] and its sidecar folder into a zip at [zipPath], laid
/// out as a loose recording of a backup.
void createRecordingZip(
  String rootPath,
  String recordingPath,
  String zipPath,
  void Function(double fraction) onProgress, {
  String? languages,
}) {
  final recording = File(recordingPath);
  createArchive(
    recording.parent.path,
    recordingArchiveFiles(Library(Directory(rootPath)), recording),
    zipPath,
    onProgress,
    languages: languages,
  );
}

/// Writes the folder at [folderPath] into a zip at [zipPath], with every entry
/// under the folder's name.
void createFolderZip(
  String folderPath,
  String zipPath,
  void Function(double fraction) onProgress, {
  String? languages,
}) {
  final folder = Directory(folderPath);
  createArchive(
    folder.parent.path,
    folderArchiveFiles(folder),
    zipPath,
    onProgress,
    languages: languages,
  );
}

/// The path parts an archive entry is restored to, or null when the entry is
/// not library content or would land outside the library.
List<String>? _entryParts(String name) {
  final parts = name
      .split(RegExp(r'[/\\]'))
      .where((s) => s.isNotEmpty)
      .toList();
  if (parts.isEmpty || parts.contains('..') || parts.contains('.')) return null;
  if (parts.first == _macResourceDir || parts.first == _trashDir) return null;
  if (_ignoredNames.contains(parts.last)) return null;
  return parts;
}

/// Moves every folder and loose recording in [library] to its trash.
void _trashEverything(Library library) {
  final trash = Trash(library);
  for (final section in library.scan()) {
    final folder = section.folder;
    if (folder != null) {
      trash.trashFolder(folder);
    } else {
      for (final recording in section.recordings) {
        trash.trashRecording(recording.file);
      }
    }
  }
}

/// Normalizes timestamps, repairs backward cues and splits inline speakers in
/// [srt]. The original is kept next to it as `.srt.bak`. Returns whether the
/// file changed.
bool repairSrtFile(File srt) {
  final original = srt.readAsStringSync();
  final repaired = splitInlineSpeakers(
    fixBackwardTimestamps(normalizeSrtTimestamps(original)),
  );
  if (repaired == original) return false;
  final backup = File('${srt.path}.bak');
  if (!backup.existsSync()) backup.writeAsStringSync(original);
  srt.writeAsStringSync(repaired);
  return true;
}

/// Opens the zip at [zipPath] and passes its restorable entries to [use].
T _withEntries<T>(
  String zipPath,
  T Function(List<(ArchiveFile, List<String>)> entries) use,
) {
  final input = InputFileStream(zipPath);
  try {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } catch (_) {
      throw const BackupException('This file is not a zip backup');
    }
    final entries = <(ArchiveFile, List<String>)>[];
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final parts = _entryParts(entry.name);
      if (parts != null) entries.add((entry, parts));
    }
    if (entries.isEmpty) {
      throw const BackupException('This backup has no files to restore');
    }
    return use(entries);
  } finally {
    input.closeSync();
  }
}

bool _isLanguageList(List<String> parts) =>
    parts.length == 1 && parts.first == languageListFile;

bool _isWrapped(List<(ArchiveFile, List<String>)> entries) => entries.every(
  (e) =>
      _isLanguageList(e.$2) || (e.$2.length > 1 && e.$2.first == _wrapperDir),
);

/// Whether every file in the zip at [zipPath] is inside one top-level folder
/// named `audios`. Such a zip is either a zip of the whole library folder or a
/// shared folder of that name.
bool hasWrapperFolder(String zipPath) => _withEntries(zipPath, _isWrapped);

/// Extracts the backup at [zipPath] into the library at [rootPath]. In merge
/// mode, files the library already has are kept. In replace mode, the current
/// folders and recordings are moved to the trash first. With [unwrap], a
/// top-level `audios` folder holding every file is dropped from the paths.
RestoreResult restoreBackup(
  String zipPath,
  String rootPath,
  RestoreMode mode,
  void Function(double fraction) onProgress, {
  required bool unwrap,
}) {
  return _withEntries(zipPath, (entries) {
    final wrapped = unwrap && _isWrapped(entries);

    final root = Directory(rootPath)..createSync(recursive: true);
    if (mode == RestoreMode.replace) _trashEverything(Library(root));

    final progress = _Progress(
      entries.fold(0, (sum, e) => sum + e.$1.size),
      onProgress,
    );
    var added = 0;
    var skipped = 0;
    var repaired = 0;
    String? languages;
    for (final (entry, parts) in entries) {
      final placed = wrapped && !_isLanguageList(parts)
          ? parts.skip(1).toList()
          : parts;
      if (placed.first == _trashDir || placed.first == _macResourceDir) {
        progress.add(entry.size);
        continue;
      }
      if (_isLanguageList(placed)) {
        languages = utf8.decode(entry.content, allowMalformed: true);
        progress.add(entry.size);
        continue;
      }
      final target = File(p.joinAll([root.path, ...placed]));
      if (target.existsSync()) {
        skipped++;
      } else {
        target.parent.createSync(recursive: true);
        final output = OutputFileStream(target.path);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
        added++;
        if (p.extension(target.path) == '.srt' && repairSrtFile(target)) {
          repaired++;
        }
      }
      progress.add(entry.size);
    }
    onProgress(1);
    return RestoreResult(
      added: added,
      skipped: skipped,
      repaired: repaired,
      languages: languages,
    );
  });
}

/// Runs [task] on another isolate, delivering its progress to [onProgress].
Future<T> runWithProgress<T>(
  T Function(void Function(double fraction) report) task,
  void Function(double fraction) onProgress,
) async {
  final port = ReceivePort();
  port.listen((message) {
    if (message is double) onProgress(message);
  });
  final send = port.sendPort;
  try {
    return await Isolate.run(() => task(send.send));
  } finally {
    port.close();
  }
}

Future<void> createBackupInBackground(
  String rootPath,
  String zipPath,
  void Function(double fraction) onProgress,
) {
  return runWithProgress(
    (report) => createBackup(rootPath, zipPath, report),
    onProgress,
  );
}

Future<void> createRecordingZipInBackground(
  String rootPath,
  String recordingPath,
  String zipPath,
  void Function(double fraction) onProgress, {
  String? languages,
}) {
  return runWithProgress(
    (report) => createRecordingZip(
      rootPath,
      recordingPath,
      zipPath,
      report,
      languages: languages,
    ),
    onProgress,
  );
}

Future<void> createFolderZipInBackground(
  String folderPath,
  String zipPath,
  void Function(double fraction) onProgress, {
  String? languages,
}) {
  return runWithProgress(
    (report) =>
        createFolderZip(folderPath, zipPath, report, languages: languages),
    onProgress,
  );
}

Future<RestoreResult> restoreBackupInBackground(
  String zipPath,
  String rootPath,
  RestoreMode mode,
  void Function(double fraction) onProgress, {
  required bool unwrap,
}) {
  return runWithProgress(
    (report) => restoreBackup(zipPath, rootPath, mode, report, unwrap: unwrap),
    onProgress,
  );
}

Future<bool> hasWrapperFolderInBackground(String zipPath) {
  return Isolate.run(() => hasWrapperFolder(zipPath));
}

/// The file name for a backup made at [now].
String backupFileName(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'transcripts-backup-${now.year}-${two(now.month)}-${two(now.day)}.zip';
}
