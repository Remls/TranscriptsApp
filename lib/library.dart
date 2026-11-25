import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'languages.dart';

const audioExts = {
  '.mp3',
  '.m4a',
  '.m4b',
  '.ogg',
  '.opus',
  '.wav',
  '.flac',
  '.aac',
  '.amr',
  '.wma',
};
const videoExts = {
  '.mp4',
  '.mov',
  '.mkv',
  '.webm',
  '.avi',
  '.m4v',
  '.3gp',
  '.wmv',
  '.ts',
  '.mts',
};

/// The files kept in a recording's sidecar folder.
enum Sidecar {
  transcriptSrt('transcript.srt'),
  transcriptTxt('transcript.txt'),
  lang('lang'),
  furigana('furigana.srt'),
  speakers('speakers.json'),
  overrides('speaker-overrides.json'),
  notes('notes.json'),
  context('context.txt'),
  audio('audio.mp3'),
  playbackVideo('playback.mkv'),
  playbackSound('playback.m4a');

  const Sidecar(this.fileName);

  final String fileName;
}

class Recording {
  const Recording({
    required this.file,
    required this.relPath,
    required this.lang,
    required this.hasTranscript,
    required this.translations,
    required this.summaries,
  });

  final File file;

  /// Path relative to the library root, with forward slashes.
  final String relPath;
  final String lang;
  final bool hasTranscript;

  /// The languages the recording is translated into, English first.
  final List<String> translations;

  /// The languages the recording is summarized in, English first.
  final List<String> summaries;

  bool get hasTranslation => translations.isNotEmpty;

  /// Every language the recording has text in.
  Set<String> get languages => {lang, ...translations, ...summaries};
  bool get hasSummary => summaries.isNotEmpty;

  String get name => p.basenameWithoutExtension(file.path);
  bool get isVideo => videoExts.contains(p.extension(file.path).toLowerCase());
}

class LibrarySection {
  const LibrarySection(this.title, this.recordings, {this.folder});

  final String title;
  final List<Recording> recordings;

  /// The folder's directory, or null for the section of loose files.
  final Directory? folder;
}

const looseSectionTitle = 'Other';

/// A library change that cannot be made, with a message for the user.
class LibraryException implements Exception {
  const LibraryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The on-disk library: recordings at the root or one folder deep, each with a
/// hidden sidecar folder `.<basename>/` next to it.
class Library {
  Library(this.root);

  final Directory root;

  Directory sidecarDir(File recording) {
    return Directory(
      p.join(
        recording.parent.path,
        '.${p.basenameWithoutExtension(recording.path)}',
      ),
    );
  }

  /// The cached summary of a whole folder, for mode "flat" or "hier".
  File folderSummaryFile(Directory folder, String mode) {
    return File(p.join(folder.path, '.summary-$mode.md'));
  }

  File sidecarFile(File recording, Sidecar key) {
    return File(p.join(sidecarDir(recording).path, key.fileName));
  }

  /// [recording]'s translation into [lang]: `translation.srt` for English,
  /// else `translation.<lang>.srt`.
  File translationFile(File recording, String lang) =>
      _langFile(recording, 'translation', '.srt', lang);

  /// [recording]'s summary in [lang]: `summary.md` for English, else
  /// `summary.<lang>.md`.
  File summaryFile(File recording, String lang) =>
      _langFile(recording, 'summary', '.md', lang);

  /// The languages [recording] has a translation in, English first, then by
  /// code.
  List<String> translationLangs(File recording) =>
      _langsOf(recording, 'translation', '.srt');

  /// The languages [recording] has a summary in, English first, then by code.
  List<String> summaryLangs(File recording) =>
      _langsOf(recording, 'summary', '.md');

  File _langFile(File recording, String stem, String ext, String lang) => File(
    p.join(
      sidecarDir(recording).path,
      lang == englishLang ? '$stem$ext' : '$stem.$lang$ext',
    ),
  );

  List<String> _langsOf(File recording, String stem, String ext) {
    final dir = sidecarDir(recording);
    if (!dir.existsSync()) return const [];
    final name = RegExp(
      '^${RegExp.escape(stem)}(?:\\.([a-z]{2,}))?${RegExp.escape(ext)}\$',
    );
    final langs = <String>{};
    for (final f in dir.listSync().whereType<File>()) {
      final m = name.firstMatch(p.basename(f.path));
      if (m != null) langs.add(m[1] ?? englishLang);
    }
    return langs.toList()..sort((a, b) {
      if (a == englishLang) return -1;
      if (b == englishLang) return 1;
      return a.compareTo(b);
    });
  }

  /// The audio to upload for transcription: the extracted sidecar audio
  /// once it exists, else the recording itself.
  File transcriptionAudio(File recording) {
    final extracted = sidecarFile(recording, Sidecar.audio);
    return extracted.existsSync() ? extracted : recording;
  }

  String langOf(File recording) {
    final f = sidecarFile(recording, Sidecar.lang);
    if (f.existsSync()) {
      final code = f.readAsStringSync().trim();
      if (isValidLangCode(code)) return code;
    }
    return defaultLang;
  }

  /// The user's note about [recording] for the model, or empty when none.
  String contextOf(File recording) {
    final f = sidecarFile(recording, Sidecar.context);
    return f.existsSync() ? f.readAsStringSync().trim() : '';
  }

  /// Saves [text] as the note about [recording], or removes the note when
  /// [text] is blank.
  void writeContext(File recording, String text) {
    final f = sidecarFile(recording, Sidecar.context);
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      if (f.existsSync()) f.deleteSync();
      return;
    }
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('$trimmed\n');
  }

  /// A sidecar JSON object of string values, or empty when absent or invalid.
  Map<String, String> readStringMap(File recording, Sidecar key) {
    final f = sidecarFile(recording, key);
    if (!f.existsSync()) return {};
    try {
      final d = jsonDecode(f.readAsStringSync());
      if (d is Map) return d.map((k, v) => MapEntry('$k', '$v'));
    } on FormatException {
      // Falls through to empty.
    }
    return {};
  }

  File? recordingAt(String relPath) {
    final f = File(p.joinAll([root.path, ...relPath.split('/')]));
    return f.existsSync() && _isMedia(f) ? f : null;
  }

  Recording describe(File file) {
    return Recording(
      file: file,
      relPath: p.split(p.relative(file.path, from: root.path)).join('/'),
      lang: langOf(file),
      hasTranscript: sidecarFile(file, Sidecar.transcriptSrt).existsSync(),
      translations: translationLangs(file),
      summaries: summaryLangs(file),
    );
  }

  /// Folders sorted by name, followed by the loose files when there are any.
  List<LibrarySection> scan() {
    root.createSync(recursive: true);
    final sections = <LibrarySection>[];
    final top = _sorted(root);
    for (final dir in top.whereType<Directory>()) {
      if (p.basename(dir.path).startsWith('.')) continue;
      sections.add(
        LibrarySection(p.basename(dir.path), recordingsIn(dir), folder: dir),
      );
    }
    final loose = [
      for (final f in top.whereType<File>())
        if (_isMedia(f)) describe(f),
    ];
    if (loose.isNotEmpty) {
      sections.add(LibrarySection(looseSectionTitle, loose));
    }
    return sections;
  }

  /// The recordings directly inside [dir], sorted by path.
  List<Recording> recordingsIn(Directory dir) {
    return [
      for (final f in _sorted(dir).whereType<File>())
        if (_isMedia(f)) describe(f),
    ];
  }

  /// The top-level folders, sorted by name.
  List<Directory> folders() {
    root.createSync(recursive: true);
    return [
      for (final dir in _sorted(root).whereType<Directory>())
        if (!p.basename(dir.path).startsWith('.')) dir,
    ];
  }

  /// A trimmed file or folder name, rejected when it is empty, hidden, or
  /// contains a path separator.
  String checkName(String raw) {
    final name = raw.trim();
    if (name.isEmpty) throw const LibraryException('Enter a name');
    if (name.startsWith('.')) {
      throw const LibraryException('A name cannot start with a dot');
    }
    if (name.contains('/') || name.contains('\\')) {
      throw const LibraryException('A name cannot contain a slash');
    }
    return name;
  }

  /// Whether [dir] already holds a recording named [stem], with any
  /// extension, or its sidecar folder.
  bool stemTaken(Directory dir, String stem) {
    if (Directory(p.join(dir.path, '.$stem')).existsSync()) return true;
    if (!dir.existsSync()) return false;
    return dir.listSync().whereType<File>().any(
      (f) => _isMedia(f) && p.basenameWithoutExtension(f.path) == stem,
    );
  }

  /// [stem], or the first of "stem (2)", "stem (3)" and so on that is free
  /// in [dir].
  String freeStem(Directory dir, String stem) {
    if (!stemTaken(dir, stem)) return stem;
    for (var n = 2; ; n++) {
      final candidate = '$stem ($n)';
      if (!stemTaken(dir, candidate)) return candidate;
    }
  }

  Directory createFolder(String rawName) {
    final dir = Directory(p.join(root.path, checkName(rawName)));
    if (dir.existsSync()) {
      throw const LibraryException('A folder with that name already exists');
    }
    return dir..createSync(recursive: true);
  }

  Directory renameFolder(Directory folder, String rawName) {
    final target = p.join(root.path, checkName(rawName));
    if (target == folder.path) return folder;
    if (Directory(target).existsSync()) {
      throw const LibraryException('A folder with that name already exists');
    }
    return folder.renameSync(target);
  }

  /// Copies [source] into [folder] (the root when null) under a free name.
  /// Returns the new recording.
  Future<File> importFile(
    File source,
    Directory? folder, {
    String? name,
  }) async {
    final fileName = name ?? p.basename(source.path);
    final ext = p.extension(fileName);
    if (!_isMediaExtension(ext)) {
      throw LibraryException('$fileName is not an audio or video file');
    }
    final dir = folder ?? root;
    dir.createSync(recursive: true);
    final stem = freeStem(dir, checkName(p.basenameWithoutExtension(fileName)));
    return source.copy(p.join(dir.path, '$stem$ext'));
  }

  /// Moves [recording] and its sidecar folder to [dir] under [stem].
  File _relocate(File recording, Directory dir, String stem) {
    final sidecar = sidecarDir(recording);
    final target = File(
      p.join(dir.path, '$stem${p.extension(recording.path)}'),
    );
    dir.createSync(recursive: true);
    recording.renameSync(target.path);
    if (sidecar.existsSync()) sidecar.renameSync(sidecarDir(target).path);
    return target;
  }

  File renameRecording(File recording, String rawStem) {
    final stem = checkName(rawStem);
    if (stem == p.basenameWithoutExtension(recording.path)) return recording;
    if (stemTaken(recording.parent, stem)) {
      throw const LibraryException(
        'A recording with that name already exists here',
      );
    }
    return _relocate(recording, recording.parent, stem);
  }

  /// Moves [recording] to [folder], or to the root when null.
  File moveRecording(File recording, Directory? folder) {
    final dir = folder ?? root;
    if (dir.path == recording.parent.path) return recording;
    final stem = p.basenameWithoutExtension(recording.path);
    if (stemTaken(dir, stem)) {
      throw const LibraryException(
        'A recording with that name already exists there',
      );
    }
    return _relocate(recording, dir, stem);
  }

  /// Moves [recording] and its sidecar folder to [dir], renaming it when the
  /// name is taken there.
  File relocateFreely(File recording, Directory dir) {
    final stem = p.basenameWithoutExtension(recording.path);
    return _relocate(recording, dir, freeStem(dir, stem));
  }

  List<FileSystemEntity> _sorted(Directory dir) {
    return dir.listSync()..sort((a, b) => a.path.compareTo(b.path));
  }

  /// Whether a file called [name] can be a recording.
  bool isMediaName(String name) => _isMediaExtension(p.extension(name));

  bool _isMediaExtension(String ext) {
    final lower = ext.toLowerCase();
    return audioExts.contains(lower) || videoExts.contains(lower);
  }

  bool _isMedia(File f) {
    if (p.basename(f.path).startsWith('.')) return false;
    return _isMediaExtension(p.extension(f.path));
  }
}
