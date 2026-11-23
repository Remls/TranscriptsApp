import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:transcripts/library.dart';
import 'package:transcripts/trash.dart';

void main() {
  late Directory root;
  late Directory outside;
  late Library library;
  late Trash trash;

  String at(String rel) => p.joinAll([root.path, ...rel.split('/')]);

  File touch(String rel, [String content = 'x']) {
    return File(at(rel))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  bool exists(String rel) =>
      File(at(rel)).existsSync() || Directory(at(rel)).existsSync();

  Matcher failsWith(String part) => throwsA(
    isA<LibraryException>().having((e) => e.message, 'message', contains(part)),
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('library_ops_test');
    outside = Directory.systemTemp.createTempSync('library_ops_src');
    library = Library(root);
    trash = Trash(library);
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    outside.deleteSync(recursive: true);
  });

  test('checkName trims and rejects unusable names', () {
    expect(library.checkName('  name '), 'name');
    expect(() => library.checkName('  '), failsWith('Enter a name'));
    expect(() => library.checkName('.hidden'), failsWith('dot'));
    expect(() => library.checkName('a/b'), failsWith('slash'));
  });

  test('folders can be created, listed and renamed', () {
    library.createFolder(' b ');
    final a = library.createFolder('a');
    touch('.trash/x/y');
    expect(library.folders().map((d) => p.basename(d.path)), ['a', 'b']);
    expect(() => library.createFolder('a'), failsWith('already exists'));

    touch('a/rec.mp3');
    touch('a/.rec/transcript.srt');
    expect(() => library.renameFolder(a, 'b'), failsWith('already exists'));
    library.renameFolder(a, 'c');
    expect(exists('a'), isFalse);
    expect(exists('c/rec.mp3'), isTrue);
    expect(exists('c/.rec/transcript.srt'), isTrue);
  });

  group('importFile', () {
    test('copies into the folder and keeps the source', () async {
      final source = File(p.join(outside.path, 'talk.m4a'))
        ..writeAsStringSync('audio');
      final folder = library.createFolder('set');
      final imported = await library.importFile(source, folder);
      expect(imported.path, at('set/talk.m4a'));
      expect(imported.readAsStringSync(), 'audio');
      expect(source.existsSync(), isTrue);
    });

    test('picks a free name when the stem is taken', () async {
      touch('talk.mp3');
      touch('.talk (2)/lang');
      final source = File(p.join(outside.path, 'cached'))
        ..writeAsStringSync('audio');
      final imported = await library.importFile(source, null, name: 'talk.m4a');
      expect(imported.path, at('talk (3).m4a'));
    });

    test('rejects files that are not audio or video', () {
      final source = File(p.join(outside.path, 'notes.txt'))
        ..writeAsStringSync('text');
      expect(library.importFile(source, null), failsWith('not an audio'));
    });
  });

  test('renameRecording moves the sidecar folder with the file', () {
    final rec = touch('set/old.mp3');
    touch('set/.old/transcript.srt');
    touch('set/taken.m4a');

    expect(
      () => library.renameRecording(rec, 'taken'),
      failsWith('already exists'),
    );
    expect(library.renameRecording(rec, 'old').path, rec.path);
    final renamed = library.renameRecording(rec, ' new ');
    expect(renamed.path, at('set/new.mp3'));
    expect(exists('set/old.mp3'), isFalse);
    expect(exists('set/.old'), isFalse);
    expect(exists('set/.new/transcript.srt'), isTrue);
  });

  test('moveRecording moves between folders and the root', () {
    final rec = touch('a/rec.mp3');
    touch('a/.rec/summary.md');
    final b = library.createFolder('b');
    touch('b/other.mp3');

    final moved = library.moveRecording(rec, b);
    expect(moved.path, at('b/rec.mp3'));
    expect(exists('b/.rec/summary.md'), isTrue);
    expect(exists('a/rec.mp3'), isFalse);

    final loose = library.moveRecording(moved, null);
    expect(loose.path, at('rec.mp3'));
    expect(exists('.rec/summary.md'), isTrue);

    touch('b/rec.wav');
    expect(() => library.moveRecording(loose, b), failsWith('already exists'));
  });

  group('trash', () {
    test('holds a recording with its sidecars and restores it', () {
      final rec = touch('set/rec.mp3', '12345');
      touch('set/.rec/transcript.srt', '123');
      trash.trashRecording(rec);

      expect(exists('set/rec.mp3'), isFalse);
      expect(exists('set/.rec'), isFalse);
      expect(library.scan().single.recordings, isEmpty);
      final item = trash.items().single;
      expect(item.name, 'rec');
      expect(item.isFolder, isFalse);
      expect(item.origin, 'set');
      expect(item.bytes, 8 + 'set'.length);
      expect(trash.totalBytes(), item.bytes);

      final restored = trash.restore(item);
      expect(restored.path, at('set/rec.mp3'));
      expect(exists('set/.rec/transcript.srt'), isTrue);
      expect(trash.items(), isEmpty);
    });

    test('restores under a free name, recreating a missing folder', () {
      trash.trashRecording(touch('rec.mp3'));
      touch('rec.mp3');
      expect(trash.restore(trash.items().single).path, at('rec (2).mp3'));

      final inFolder = touch('gone/a.mp3');
      trash.trashRecording(inFolder);
      Directory(at('gone')).deleteSync(recursive: true);
      expect(trash.restore(trash.items().single).path, at('gone/a.mp3'));
    });

    test('an origin outside the library restores to the root', () {
      trash.trashRecording(touch('set/rec.mp3'));
      final slot = Directory(at('.trash')).listSync().single as Directory;
      File(p.join(slot.path, 'origin')).writeAsStringSync('../../elsewhere');
      expect(trash.items().single.origin, '');
      expect(trash.restore(trash.items().single).path, at('rec.mp3'));
    });

    test('holds a whole folder and restores it', () {
      touch('set/rec.mp3');
      touch('set/.rec/lang');
      touch('set/.summary-flat.md');
      trash.trashFolder(Directory(at('set')));

      expect(exists('set'), isFalse);
      final item = trash.items().single;
      expect(item.name, 'set');
      expect(item.isFolder, isTrue);

      library.createFolder('set');
      expect(trash.restore(item).path, at('set (2)'));
      expect(exists('set (2)/.rec/lang'), isTrue);
      expect(exists('set (2)/.summary-flat.md'), isTrue);
    });

    test('deletes one item or everything for good', () {
      trash.trashRecording(touch('a.mp3'));
      trash.trashRecording(touch('b.mp3'));
      expect(trash.items(), hasLength(2));

      trash.deletePermanently(trash.items().firstWhere((i) => i.name == 'a'));
      expect(trash.items().single.name, 'b');

      trash.empty();
      expect(trash.items(), isEmpty);
      expect(trash.totalBytes(), 0);
    });
  });
}
