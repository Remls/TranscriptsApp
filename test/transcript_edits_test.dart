import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:transcripts/library.dart';
import 'package:transcripts/srt.dart';
import 'package:transcripts/transcript_edits.dart';

const _srt =
    '1\n00:00:01,500 --> 00:00:04,000\nSpeaker 1: one\nSpeaker 2: two\n\n'
    '2\n01:02:03,004 --> 01:02:05,000\nplain line\n\n'
    '3\n01:02:06,000 --> 01:02:07,000\nSpeaker 1: three\n';

void main() {
  late Directory root;
  late Library library;
  late File recording;
  late TranscriptEditor editor;

  File sidecar(Sidecar key) => library.sidecarFile(recording, key);
  File translation([String lang = 'en']) =>
      library.translationFile(recording, lang);

  setUp(() {
    root = Directory.systemTemp.createTempSync('edits_test');
    library = Library(root);
    recording = File(p.join(root.path, 'a.mp3'))..writeAsStringSync('x');
    sidecar(Sidecar.transcriptSrt)
      ..createSync(recursive: true)
      ..writeAsStringSync(_srt);
    editor = TranscriptEditor(library, recording);
  });

  tearDown(() => root.deleteSync(recursive: true));

  Map<String, String> overrides() =>
      library.readStringMap(recording, Sidecar.overrides);

  Map<String, int> counts() => speakerLineCounts(parseSrt(_srt), overrides());

  test('formatSrt round-trips a parsed transcript', () {
    expect(formatSrt(parseSrt(_srt)), _srt);
    expect(formatSrt(const []), '');
  });

  test('setText rewrites one line and the plain-text copy', () {
    editor.setText(0, 1, '  fixed\n text ');
    expect(
      sidecar(Sidecar.transcriptSrt).readAsStringSync(),
      _srt.replaceFirst('Speaker 2: two', 'Speaker 2: fixed text'),
    );
    expect(
      sidecar(Sidecar.transcriptTxt).readAsStringSync(),
      'Speaker 1: one\nSpeaker 2: fixed text\nplain line\nSpeaker 1: three\n',
    );

    editor.setText(1, 0, 'still plain');
    expect(
      parseSrt(
        sidecar(Sidecar.transcriptSrt).readAsStringSync(),
      )[1].items.single.speaker,
      isNull,
    );
    expect(() => editor.setText(0, 0, '  '), throwsA(isA<LibraryException>()));
  });

  test('setText on a translation leaves the transcript files alone', () {
    translation().writeAsStringSync(_srt);
    editor.setText(2, 0, 'tres', translation: 'en');
    expect(translation().readAsStringSync(), contains('Speaker 1: tres'));
    expect(sidecar(Sidecar.transcriptSrt).readAsStringSync(), _srt);
    expect(sidecar(Sidecar.transcriptTxt).existsSync(), isFalse);
  });

  test('speaker names are stored and removed', () {
    editor.setSpeakerName('1', '  Host ');
    editor.setSpeakerName('2', 'Guest');
    expect(library.readStringMap(recording, Sidecar.speakers), {
      '1': 'Host',
      '2': 'Guest',
    });
    editor.setSpeakerName('1', '');
    expect(library.readStringMap(recording, Sidecar.speakers), {'2': 'Guest'});
    editor.setSpeakerName('2', ' ');
    expect(sidecar(Sidecar.speakers).existsSync(), isFalse);
  });

  test('a line can be given to another speaker and back', () {
    editor.setLineSpeaker(0, 1, '1');
    editor.setLineSpeaker(1, 0, '3');
    expect(overrides(), {'0:1': '1', '1:0': '3'});
    expect(counts(), {'1': 3, '3': 1});

    editor.setLineSpeaker(0, 1, '2');
    expect(overrides(), {'1:0': '3'});
  });

  test('swap exchanges every line of two speakers', () {
    editor.setLineSpeaker(1, 0, '2');
    editor.swapSpeakers('1', '2');
    expect(overrides(), {'0:0': '2', '0:1': '1', '1:0': '1', '2:0': '2'});
    expect(counts(), {'1': 2, '2': 2});

    editor.swapSpeakers('1', '2');
    expect(overrides(), {'1:0': '2'});
  });

  test('merge gives one speaker all the lines of another', () {
    editor.mergeSpeakers('2', '1');
    expect(overrides(), {'0:1': '1'});
    expect(counts(), {'1': 3});
  });

  test('a remap can start partway through and run to the end', () {
    editor.remapSpeakers({'1': '3'}, fromCue: 0, fromItem: 1);
    expect(overrides(), {'2:0': '3'});
    expect(counts(), {'1': 1, '2': 1, '3': 1});

    editor.resetSpeakerChanges();
    editor.remapSpeakers({'1': '2', '2': '1'}, fromCue: 0, fromItem: 1);
    expect(overrides(), {'0:1': '1', '2:0': '2'});

    editor.resetSpeakerChanges();
    editor.remapSpeakers({'1': '2'}, fromCue: 2);
    expect(overrides(), {'2:0': '2'});
  });

  test('reset drops every manual change', () {
    editor.mergeSpeakers('2', '1');
    editor.resetSpeakerChanges();
    expect(sidecar(Sidecar.overrides).existsSync(), isFalse);
    expect(counts(), {'1': 2, '2': 1});
  });

  test('speaker helpers', () {
    expect(nextSpeakerId(['1', '3', '2']), '4');
    expect(nextSpeakerId(const []), '1');
    final cues = parseSrt(_srt);
    expect(effectiveSpeaker(cues, {'1:0': '9'}, 1, 0), '9');
    expect(effectiveSpeaker(cues, const {}, 1, 0), isNull);
    expect(speakerLineCounts(cues, {'0:0': '10'}).keys, ['1', '2', '10']);
  });

  test('deleting lines updates every file and moves speaker changes', () {
    translation().writeAsStringSync(
      '1\n00:00:01,500 --> 00:00:04,000\nSpeaker 1: uno\nSpeaker 2: dos\n\n'
      '2\n01:02:03,004 --> 01:02:05,000\nplano\n\n'
      '3\n01:02:06,000 --> 01:02:07,000\nSpeaker 1: tres\n',
    );
    translation('ja').writeAsStringSync(
      '1\n00:00:01,500 --> 00:00:04,000\nSpeaker 1: いち\nSpeaker 2: に\n\n'
      '2\n01:02:03,004 --> 01:02:05,000\nふつう\n\n'
      '3\n01:02:06,000 --> 01:02:07,000\nSpeaker 1: さん\n',
    );
    editor.setLineSpeaker(0, 1, '3');
    editor.setLineSpeaker(2, 0, '2');

    editor.deleteLines([(0, 0), (1, 0)]);

    List<String> lines(File file) => [
      for (final cue in parseSrt(file.readAsStringSync()))
        for (final item in cue.items) item.text,
    ];
    expect(lines(sidecar(Sidecar.transcriptSrt)), ['two', 'three']);
    expect(lines(translation()), ['dos', 'tres']);
    expect(lines(translation('ja')), ['に', 'さん']);
    expect(sidecar(Sidecar.transcriptTxt).readAsStringSync(), contains('two'));
    expect(
      sidecar(Sidecar.transcriptTxt).readAsStringSync(),
      isNot(contains('one')),
    );
    expect(overrides(), {'0:0': '3', '1:0': '2'});
  });

  test('deleting lines works without a translation', () {
    editor.deleteLines([(2, 0)]);
    expect(
      parseSrt(sidecar(Sidecar.transcriptSrt).readAsStringSync()).length,
      2,
    );
    expect(translation().existsSync(), isFalse);
  });

  test('several lines can be given to one speaker at once', () {
    editor.setLinesSpeaker([(0, 0), (0, 1), (1, 0)], '2');
    expect(overrides(), {'0:0': '2', '1:0': '2'});
  });

  test('edits and deletes keep the readings aligned', () {
    sidecar(Sidecar.furigana).writeAsStringSync(
      '1\n00:00:01,500 --> 00:00:04,000\nSpeaker 1: ｜一《いち》\nSpeaker 2: ｜二《に》\n\n'
      '2\n01:02:03,004 --> 01:02:05,000\n｜平《たいら》\n\n'
      '3\n01:02:06,000 --> 01:02:07,000\nSpeaker 1: ｜三《さん》\n',
    );
    List<String> lines() => [
      for (final cue in parseSrt(sidecar(Sidecar.furigana).readAsStringSync()))
        for (final item in cue.items) item.text,
    ];

    editor.setText(0, 1, 'changed');
    expect(lines(), ['｜一《いち》', 'changed', '｜平《たいら》', '｜三《さん》']);

    editor.deleteLines([(1, 0)]);
    expect(lines(), ['｜一《いち》', 'changed', '｜三《さん》']);
  });
}
