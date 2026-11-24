import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:transcripts/backup.dart';
import 'package:transcripts/library.dart';
import 'package:transcripts/trash.dart';

void main() {
  late Directory tmp;
  late Directory source;
  late Directory target;
  late String zipPath;

  File touch(Directory root, String rel, [String content = 'x']) {
    return File(p.joinAll([root.path, ...rel.split('/')]))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  String? read(Directory root, String rel) {
    final f = File(p.joinAll([root.path, ...rel.split('/')]));
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  /// A zip holding [entries], mapping entry names to their text.
  void writeZip(Map<String, String> entries) {
    final staging = Directory(p.join(tmp.path, 'staging'))..createSync();
    final encoder = ZipFileEncoder()..create(zipPath);
    var n = 0;
    for (final MapEntry(key: name, value: content) in entries.entries) {
      final f = File(p.join(staging.path, '${n++}'))
        ..writeAsStringSync(content);
      encoder.addFileSync(f, name);
    }
    encoder.closeSync();
  }

  RestoreResult restore([
    RestoreMode mode = RestoreMode.merge,
    bool unwrap = true,
  ]) {
    return restoreBackup(zipPath, target.path, mode, (_) {}, unwrap: unwrap);
  }

  List<String> zipEntries() {
    final input = InputFileStream(zipPath);
    try {
      return [
        for (final e in ZipDecoder().decodeStream(input))
          if (e.isFile) e.name,
      ]..sort();
    } finally {
      input.closeSync();
    }
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('backup_test');
    source = Directory(p.join(tmp.path, 'source'))..createSync();
    target = Directory(p.join(tmp.path, 'target'))..createSync();
    zipPath = p.join(tmp.path, 'backup.zip');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('a backup restores to an identical library, without the trash', () {
    final big = Uint8List(3 * 1024 * 1024);
    for (var i = 0; i < big.length; i++) {
      big[i] = (i * 31 + i ~/ 7) & 0xff;
    }
    File(p.join(source.path, 'set', 'long.mp3'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(big);
    touch(
      source,
      'set/.long/transcript.srt',
      '1\n00:00:01,000 --> 00:00:02,000\nދިވެހި\n',
    );
    touch(source, 'set/.long/speakers.json', '{"1": "Name"}');
    touch(source, 'set/.summary-flat.md', 'flat');
    touch(source, 'loose.m4a', 'loose audio');
    touch(source, '.loose/lang', 'ja\n');
    touch(source, '.trash/1-0/old.mp3', 'trashed');
    touch(source, '.DS_Store', 'junk');

    final fractions = <double>[];
    createBackup(source.path, zipPath, fractions.add);
    expect(fractions.last, 1);
    expect(File(zipPath).lengthSync(), greaterThan(big.length));

    final result = restore();
    expect(result.added, 6);
    expect(result.skipped, 0);
    expect(result.repaired, 0);
    expect(File(p.join(target.path, 'set', 'long.mp3')).readAsBytesSync(), big);
    expect(
      read(target, 'set/.long/transcript.srt'),
      '1\n00:00:01,000 --> 00:00:02,000\nދިވެހި\n',
    );
    expect(read(target, 'set/.long/speakers.json'), '{"1": "Name"}');
    expect(read(target, 'set/.summary-flat.md'), 'flat');
    expect(read(target, 'loose.m4a'), 'loose audio');
    expect(read(target, '.loose/lang'), 'ja\n');
    expect(Directory(p.join(target.path, '.trash')).existsSync(), isFalse);
    expect(read(target, '.DS_Store'), isNull);
  });

  test('merge keeps files the library already has', () {
    touch(source, 'set/a.mp3', 'backup audio');
    touch(source, 'set/.a/summary.md', 'backup summary');
    createBackup(source.path, zipPath, (_) {});
    touch(target, 'set/a.mp3', 'current audio');
    touch(target, 'other.mp3', 'untouched');

    final result = restore();
    expect(result.added, 1);
    expect(result.skipped, 1);
    expect(read(target, 'set/a.mp3'), 'current audio');
    expect(read(target, 'set/.a/summary.md'), 'backup summary');
    expect(read(target, 'other.mp3'), 'untouched');
  });

  test('replace moves the current library to the trash first', () {
    touch(source, 'set/a.mp3', 'backup audio');
    createBackup(source.path, zipPath, (_) {});
    touch(target, 'set/a.mp3', 'current audio');
    touch(target, 'old/b.mp3');
    touch(target, 'loose.mp3');
    touch(target, '.loose/lang', 'en\n');

    final result = restore(RestoreMode.replace);
    expect(result.added, 1);
    expect(result.skipped, 0);
    expect(read(target, 'set/a.mp3'), 'backup audio');
    expect(Library(target).scan().map((s) => s.title), ['set']);
    final trashed = Trash(Library(target)).items();
    expect(trashed.map((i) => i.name).toSet(), {'set', 'old', 'loose'});
  });

  test('a zip of a whole audios folder is unwrapped on request', () {
    writeZip({
      'audios/set/a.mp3': 'audio',
      'audios/set/.a/lang': 'ko\n',
      'audios/.gitkeep': '',
      '__MACOSX/audios/set/._a.mp3': 'resource fork',
      'audios/set/.DS_Store': 'junk',
    });
    final result = restore();
    expect(result.added, 2);
    expect(read(target, 'set/a.mp3'), 'audio');
    expect(read(target, 'set/.a/lang'), 'ko\n');
    expect(Directory(p.join(target.path, 'audios')).existsSync(), isFalse);
    expect(Directory(p.join(target.path, '__MACOSX')).existsSync(), isFalse);
  });

  test('a zip of a whole audios folder can be kept as a folder', () {
    writeZip({'audios/a.mp3': 'audio', 'audios/.a/lang': 'ko\n'});
    expect(hasWrapperFolder(zipPath), isTrue);
    final result = restore(RestoreMode.merge, false);
    expect(result.added, 2);
    expect(read(target, 'audios/a.mp3'), 'audio');
    expect(read(target, 'audios/.a/lang'), 'ko\n');
  });

  test('a zip with files beside the audios folder has no wrapper', () {
    writeZip({'audios/a.mp3': 'audio', 'b.mp3': 'other'});
    expect(hasWrapperFolder(zipPath), isFalse);
    restore();
    expect(read(target, 'audios/a.mp3'), 'audio');
    expect(read(target, 'b.mp3'), 'other');
  });

  test('a recording zip holds the recording and its sidecars', () {
    final library = Library(source);
    final recording = touch(source, 'set/talk.mp4', 'video');
    touch(source, 'set/.talk/transcript.srt', 'srt');
    touch(source, 'set/.talk/notes.json', '[]');
    touch(source, 'set/.talk/notes/n1.jpg', 'picture');
    touch(source, 'set/.talk/.DS_Store', 'junk');
    touch(source, 'set/other.mp3', 'not included');
    touch(source, 'set/.other/lang', 'en\n');
    touch(source, 'set/.summary-flat.md', 'not included');

    expect(recordingArchiveFiles(library, recording).length, 4);
    createRecordingZip(source.path, recording.path, zipPath, (_) {});
    expect(zipEntries(), [
      '.talk/notes.json',
      '.talk/notes/n1.jpg',
      '.talk/transcript.srt',
      'talk.mp4',
    ]);

    final result = restore();
    expect(result.added, 4);
    expect(read(target, 'talk.mp4'), 'video');
    expect(read(target, '.talk/notes/n1.jpg'), 'picture');
    expect(Library(target).scan().single.recordings.single.name, 'talk');
  });

  test('a folder zip merges in as that folder', () {
    final folder = Directory(p.join(source.path, 'set'));
    touch(source, 'set/a.mp3', 'a');
    touch(source, 'set/.a/transcript.srt', 'srt');
    touch(source, 'set/b.m4a', 'b');
    touch(source, 'set/.summary-hier.md', 'hier');
    touch(source, 'set/.DS_Store', 'junk');
    touch(source, 'elsewhere.mp3', 'not included');

    createFolderZip(folder.path, zipPath, (_) {});
    final entries = zipEntries();
    expect(entries, [
      'set/.a/transcript.srt',
      'set/.summary-hier.md',
      'set/a.mp3',
      'set/b.m4a',
    ]);
    expect(hasWrapperFolder(zipPath), isFalse);

    touch(target, 'kept/c.mp3', 'c');
    touch(target, 'loose.mp3', 'loose');
    final result = restore();
    expect(result.added, 4);
    expect(read(target, 'set/.summary-hier.md'), 'hier');
    expect(read(target, 'set/.a/transcript.srt'), 'srt');
    expect(read(target, 'kept/c.mp3'), 'c');
    expect(read(target, 'loose.mp3'), 'loose');
  });

  test('zips carry a language list that is merged, not restored', () {
    final recording = touch(source, 'talk.mp3', 'audio');
    touch(source, '.talk/lang', 'ta\n');
    const list = '[{"code": "ta", "name": "Tamil", "script": "Tamil"}]';
    createRecordingZip(
      source.path,
      recording.path,
      zipPath,
      (_) {},
      languages: list,
    );
    expect(zipEntries(), ['.languages.json', '.talk/lang', 'talk.mp3']);

    touch(target, '.languages.json', 'local list');
    final result = restore();
    expect(result.added, 2);
    expect(result.languages, list);
    expect(read(target, '.languages.json'), 'local list');
  });

  test('a language list beside an audios folder keeps it a wrapper', () {
    writeZip({'.languages.json': '[]', 'audios/a.mp3': 'audio'});
    expect(hasWrapperFolder(zipPath), isTrue);
    expect(restore().languages, '[]');
    expect(read(target, 'a.mp3'), 'audio');
  });

  test('playback copies stay out of backups and recording zips', () {
    touch(source, 'set/a.wma', 'audio');
    touch(source, 'set/.a/transcript.srt', 'srt');
    touch(source, 'set/.a/playback.m4a', 'copy');
    touch(source, 'set/.a/playback.mkv', 'copy');
    touch(source, 'set/playback.mkv', 'a recording with that name');
    createBackup(source.path, zipPath, (_) {});
    expect(zipEntries(), [
      'set/.a/transcript.srt',
      'set/a.wma',
      'set/playback.mkv',
    ]);
  });

  test('entries that point outside the library are ignored', () {
    writeZip({
      '../escape.mp3': 'bad',
      'set/../../up.mp3': 'bad',
      'ok.mp3': 'good',
    });
    final result = restore();
    expect(result.added, 1);
    expect(read(target, 'ok.mp3'), 'good');
    expect(File(p.join(tmp.path, 'escape.mp3')).existsSync(), isFalse);
    expect(File(p.join(tmp.path, 'up.mp3')).existsSync(), isFalse);
  });

  test('a wrapped zip cannot place files in the trash', () {
    writeZip({
      'audios/.trash/1-0/origin': '../..',
      'audios/.trash/1-0/x.mp3': 'planted',
      'audios/__MACOSX/._x.mp3': 'fork',
      'audios/ok.mp3': 'good',
    });
    final result = restore();
    expect(result.added, 1);
    expect(Directory(p.join(target.path, '.trash')).existsSync(), isFalse);
    expect(Directory(p.join(target.path, '__MACOSX')).existsSync(), isFalse);
  });

  test('restored transcripts get the timestamp and speaker repairs', () {
    const broken =
        '1\n00:05,000 --> 00:03,000\nSpeaker 1: a Speaker 2: b\n\n'
        '2\n00:00:20,000 --> 00:00:21,000\nc\n';
    writeZip({
      'a.mp3': 'audio',
      '.a/transcript.srt': broken,
      '.a/translation.srt': '1\n00:00:01,000 --> 00:00:02,000\nfine\n',
    });
    final result = restore();
    expect(result.repaired, 1);
    expect(
      read(target, '.a/transcript.srt'),
      '1\n00:00:05,000 --> 00:00:10,000\nSpeaker 1: a\nSpeaker 2: b\n\n'
      '2\n00:00:20,000 --> 00:00:21,000\nc\n',
    );
    expect(read(target, '.a/transcript.srt.bak'), broken);
    expect(read(target, '.a/translation.srt.bak'), isNull);
  });

  test('rejects files that are not usable backups', () {
    File(zipPath).writeAsStringSync('not a zip at all');
    expect(restore, throwsA(isA<BackupException>()));

    writeZip({'__MACOSX/x': 'only junk'});
    expect(restore, throwsA(isA<BackupException>()));
  });

  test('runWithProgress returns the result and relays progress', () async {
    touch(source, 'a.mp3', 'audio');
    final src = source.path;
    final zip = zipPath;
    final fractions = <double>[];
    await runWithProgress(
      (report) => createBackup(src, zip, report),
      fractions.add,
    );
    await pumpEventQueue();
    expect(File(zipPath).existsSync(), isTrue);
    expect(fractions.last, 1);
  });

  test('backupFileName carries the date', () {
    expect(
      backupFileName(DateTime(2026, 3, 7)),
      'transcripts-backup-2026-03-07.zip',
    );
  });
}
