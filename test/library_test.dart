import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:transcripts/library.dart';

void main() {
  late Directory root;
  late Library library;

  File touch(String rel, [String content = '']) {
    final f = File(p.joinAll([root.path, ...rel.split('/')]));
    f.createSync(recursive: true);
    f.writeAsStringSync(content);
    return f;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('library_test');
    library = Library(root);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('sidecar paths sit in a hidden folder next to the recording', () {
    final rec = touch('meetings/first.part.mp3');
    expect(
      library.sidecarFile(rec, Sidecar.transcriptSrt).path,
      p.join(root.path, 'meetings', '.first.part', 'transcript.srt'),
    );
  });

  test('scan creates the root when missing', () {
    root.deleteSync(recursive: true);
    expect(library.scan(), isEmpty);
    expect(root.existsSync(), isTrue);
  });

  test('scan lists folders by name, then loose files', () {
    touch('b-folder/two.m4a');
    touch('b-folder/one.mp3');
    touch('b-folder/notes.txt');
    touch('b-folder/.one/transcript.srt');
    touch('a-folder/clip.MP4');
    touch('a-folder/.clip/audio.mp3');
    touch('loose.wav');
    touch('.loose/summary.md');
    touch('.trash/old.mp3');
    Directory(p.join(root.path, 'empty')).createSync();

    final sections = library.scan();
    expect(sections.map((s) => s.title), [
      'a-folder',
      'b-folder',
      'empty',
      looseSectionTitle,
    ]);
    expect(sections[0].recordings.single.isVideo, isTrue);
    expect(sections[1].recordings.map((r) => r.name), ['one', 'two']);
    expect(sections[1].recordings.map((r) => r.relPath), [
      'b-folder/one.mp3',
      'b-folder/two.m4a',
    ]);
    expect(sections[1].recordings[0].hasTranscript, isTrue);
    expect(sections[1].recordings[1].hasTranscript, isFalse);
    expect(sections[2].recordings, isEmpty);
    expect(sections[3].folder, isNull);
    expect(sections[3].recordings.single.hasSummary, isTrue);
  });

  test('scan omits the loose section when there are no loose files', () {
    touch('folder/a.mp3');
    expect(library.scan().map((s) => s.title), ['folder']);
  });

  test('langOf reads the lang sidecar and defaults to dv', () {
    final rec = touch('a.mp3');
    expect(library.langOf(rec), 'dv');
    touch('.a/lang', 'ja\n');
    expect(library.langOf(rec), 'ja');
    touch('.a/lang', 'xx\n');
    expect(library.langOf(rec), 'xx');
    touch('.a/lang', 'X1\n');
    expect(library.langOf(rec), 'dv');
  });

  test('transcription uses the extracted audio once it exists', () {
    final video = touch('talk.mp4');
    final audio = touch('song.mp3');
    expect(library.transcriptionAudio(video).path, video.path);
    final extracted = touch('.talk/audio.mp3');
    expect(library.transcriptionAudio(video).path, extracted.path);
    expect(library.transcriptionAudio(audio).path, audio.path);
  });

  test('readStringMap returns an empty map for absent or invalid JSON', () {
    final rec = touch('a.mp3');
    expect(library.readStringMap(rec, Sidecar.speakers), isEmpty);
    touch('.a/speakers.json', '{"1": "Name", "2": 3}');
    expect(library.readStringMap(rec, Sidecar.speakers), {
      '1': 'Name',
      '2': '3',
    });
    touch('.a/speakers.json', 'not json');
    expect(library.readStringMap(rec, Sidecar.speakers), isEmpty);
    touch('.a/speakers.json', '[1, 2]');
    expect(library.readStringMap(rec, Sidecar.speakers), isEmpty);
  });

  test('recordingAt resolves a relative path to an existing recording', () {
    final rec = touch('folder/a.mp3');
    expect(library.recordingAt('folder/a.mp3')!.path, rec.path);
    expect(library.recordingAt('folder/missing.mp3'), isNull);
  });

  test('the context note is saved trimmed and removed when blank', () {
    final rec = touch('a.mp3');
    final file = library.sidecarFile(rec, Sidecar.context);
    expect(library.contextOf(rec), '');

    library.writeContext(rec, '  Two speakers.\n');
    expect(file.readAsStringSync(), 'Two speakers.\n');
    expect(library.contextOf(rec), 'Two speakers.');

    library.writeContext(rec, '   ');
    expect(file.existsSync(), isFalse);
    library.writeContext(rec, '');
    expect(file.existsSync(), isFalse);
  });

  test('translations and summaries are found by language', () {
    final rec = touch('a.mp3');
    expect(library.translationLangs(rec), isEmpty);
    touch('.a/translation.ja.srt');
    touch('.a/translation.srt');
    touch('.a/translation.dv.srt');
    touch('.a/translation.x.srt');
    touch('.a/summary.ko.md');
    expect(library.translationLangs(rec), ['en', 'dv', 'ja']);
    expect(library.summaryLangs(rec), ['ko']);
    expect(
      library.translationFile(rec, 'en').path,
      p.join(root.path, '.a', 'translation.srt'),
    );
    expect(
      library.summaryFile(rec, 'ko').path,
      p.join(root.path, '.a', 'summary.ko.md'),
    );
    final described = library.describe(rec);
    expect(described.translations, ['en', 'dv', 'ja']);
    expect(described.summaries, ['ko']);
    expect(described.languages, {'dv', 'en', 'ja', 'ko'});
  });
}
