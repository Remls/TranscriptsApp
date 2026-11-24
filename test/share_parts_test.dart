import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:transcripts/library.dart';
import 'package:transcripts/share_parts.dart';

const _srt =
    '1\n00:00:01,000 --> 00:00:02,000\nSpeaker 1: one\n\n'
    '2\n00:00:03,000 --> 00:00:04,000\nSpeaker 2: two\n';

void main() {
  late Directory root;
  late Directory temp;
  late Library library;
  late File recording;

  File touch(String rel, [String content = 'x']) {
    return File(p.joinAll([root.path, ...rel.split('/')]))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  SharePayload build(SharePart part) =>
      buildSharePayload(library, recording, part, temp);

  setUp(() {
    root = Directory.systemTemp.createTempSync('share_test');
    temp = Directory(p.join(root.path, 'out'));
    library = Library(Directory(p.join(root.path, 'lib')));
    recording = touch('lib/set/My talk.m4a', 'audio');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('only existing parts are offered', () {
    expect(availableShareParts(library, recording), [
      SharePart.recording,
      SharePart.everything,
    ]);

    touch('lib/set/.My talk/transcript.srt', _srt);
    touch('lib/set/.My talk/summary.md', 'summary');
    expect(availableShareParts(library, recording), [
      SharePart.recording,
      SharePart.transcriptSrt,
      SharePart.transcriptText,
      SharePart.transcriptPlain,
      SharePart.summaryText,
      SharePart.summaryPlain,
      SharePart.everything,
    ]);

    touch('lib/set/.My talk/translation.srt', _srt);
    expect(availableShareParts(library, recording), SharePart.values);
  });

  test('the recording is shared as the file itself', () {
    final payload = build(SharePart.recording);
    expect(payload.file!.path, recording.path);
    expect(payload.mimeType, 'audio/mp4');
    expect(temp.existsSync(), isFalse);

    recording = touch('lib/clip.MKV');
    expect(build(SharePart.recording).mimeType, 'video/x-matroska');
  });

  test('subtitle files are copies named after the recording', () {
    touch('lib/set/.My talk/transcript.srt', _srt);
    touch('lib/set/.My talk/translation.srt', 'translated');

    final transcript = build(SharePart.transcriptSrt);
    expect(p.basename(transcript.file!.path), 'My talk.srt');
    expect(transcript.file!.readAsStringSync(), _srt);
    expect(transcript.mimeType, 'application/x-subrip');

    final translation = build(SharePart.translationSrt);
    expect(p.basename(translation.file!.path), 'My talk (English).srt');
    expect(translation.file!.readAsStringSync(), 'translated');
  });

  test('text files carry speaker names and manual changes', () {
    touch('lib/set/.My talk/transcript.srt', _srt);
    touch('lib/set/.My talk/translation.srt', _srt);
    touch('lib/set/.My talk/speakers.json', '{"1": "Host"}');
    touch('lib/set/.My talk/speaker-overrides.json', '{"1:0": "1"}');

    final transcript = build(SharePart.transcriptText);
    expect(p.basename(transcript.file!.path), 'My talk.txt');
    expect(transcript.file!.readAsStringSync(), 'Host: one\nHost: two\n');
    expect(transcript.mimeType, 'text/plain');

    final translation = build(SharePart.translationText);
    expect(p.basename(translation.file!.path), 'My talk (English).txt');

    final plain = build(SharePart.transcriptPlain);
    expect(plain.text, 'Host: one\nHost: two');
    expect(plain.file, isNull);
    expect(build(SharePart.translationPlain).text, 'Host: one\nHost: two');
  });

  test('the summary is shared as text', () {
    touch('lib/set/.My talk/summary.md', '- a point\n');
    final payload = build(SharePart.summaryPlain);
    expect(payload.text, '- a point');
    expect(payload.file, isNull);

    final file = build(SharePart.summaryText);
    expect(p.basename(file.file!.path), 'My talk (summary).txt');
    expect(file.file!.readAsStringSync(), '- a point\n');
    expect(file.mimeType, 'text/plain');
  });
}
