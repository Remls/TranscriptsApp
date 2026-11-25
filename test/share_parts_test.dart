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

  SharePayload build(ShareKind kind, {String? lang, ShareFormat? format}) =>
      buildSharePayload(
        library,
        recording,
        (kind: kind, lang: lang, format: format),
        temp,
        languageName: (code) =>
            const {'en': 'English', 'ja': 'Japanese', 'dv': 'Dhivehi'}[code]!,
      );

  setUp(() {
    root = Directory.systemTemp.createTempSync('share_test');
    temp = Directory(p.join(root.path, 'out'));
    library = Library(Directory(p.join(root.path, 'lib')));
    recording = touch('lib/set/My talk.m4a', 'audio');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('only existing pieces are offered, with their languages', () {
    expect(availableShareKinds(library, recording), [
      ShareKind.recording,
      ShareKind.everything,
    ]);

    touch('lib/set/.My talk/transcript.srt', _srt);
    touch('lib/set/.My talk/summary.ja.md', 'summary');
    expect(availableShareKinds(library, recording), [
      ShareKind.recording,
      ShareKind.transcript,
      ShareKind.summary,
      ShareKind.everything,
    ]);

    touch('lib/set/.My talk/translation.ja.srt', _srt);
    touch('lib/set/.My talk/translation.srt', _srt);
    expect(availableShareKinds(library, recording), ShareKind.values);
    expect(shareLangs(library, recording, ShareKind.translation), ['en', 'ja']);
    expect(shareLangs(library, recording, ShareKind.summary), ['ja']);
    expect(formatsFor(ShareKind.summary), [
      ShareFormat.text,
      ShareFormat.plain,
    ]);
    expect(formatsFor(ShareKind.recording), isEmpty);
  });

  test('the recording is shared as the file itself', () {
    final payload = build(ShareKind.recording);
    expect(payload.file!.path, recording.path);
    expect(payload.mimeType, 'audio/mp4');
    expect(temp.existsSync(), isFalse);

    recording = touch('lib/clip.MKV');
    expect(build(ShareKind.recording).mimeType, 'video/x-matroska');
  });

  test('subtitle files are named with their language code', () {
    touch('lib/set/.My talk/transcript.srt', _srt);
    touch('lib/set/.My talk/translation.srt', 'translated');
    touch('lib/set/.My talk/translation.ja.srt', 'ja');

    final transcript = build(ShareKind.transcript, format: ShareFormat.srt);
    expect(p.basename(transcript.file!.path), 'My talk.dv.srt');
    expect(transcript.file!.readAsStringSync(), _srt);
    expect(transcript.mimeType, 'application/x-subrip');

    final english = build(
      ShareKind.translation,
      lang: 'en',
      format: ShareFormat.srt,
    );
    expect(p.basename(english.file!.path), 'My talk.en.srt');
    expect(english.file!.readAsStringSync(), 'translated');

    final japanese = build(
      ShareKind.translation,
      lang: 'ja',
      format: ShareFormat.srt,
    );
    expect(p.basename(japanese.file!.path), 'My talk.ja.srt');
    expect(japanese.file!.readAsStringSync(), 'ja');
  });

  test('text files carry speaker names and manual changes', () {
    touch('lib/set/.My talk/transcript.srt', _srt);
    touch('lib/set/.My talk/translation.ja.srt', _srt);
    touch('lib/set/.My talk/speakers.json', '{"1": "Host"}');
    touch('lib/set/.My talk/speaker-overrides.json', '{"1:0": "1"}');

    final transcript = build(ShareKind.transcript, format: ShareFormat.text);
    expect(p.basename(transcript.file!.path), 'My talk.txt');
    expect(transcript.file!.readAsStringSync(), 'Host: one\nHost: two\n');
    expect(transcript.mimeType, 'text/plain');

    final translation = build(
      ShareKind.translation,
      lang: 'ja',
      format: ShareFormat.text,
    );
    expect(p.basename(translation.file!.path), 'My talk (Japanese).txt');

    final plain = build(ShareKind.transcript, format: ShareFormat.plain);
    expect(plain.text, 'Host: one\nHost: two');
    expect(plain.file, isNull);
    expect(
      build(ShareKind.translation, lang: 'ja', format: ShareFormat.plain).text,
      'Host: one\nHost: two',
    );
  });

  test('a summary is shared as text in its language', () {
    touch('lib/set/.My talk/summary.md', '- a point\n');
    final payload = build(
      ShareKind.summary,
      lang: 'en',
      format: ShareFormat.plain,
    );
    expect(payload.text, '- a point');
    expect(payload.file, isNull);

    final file = build(ShareKind.summary, lang: 'en', format: ShareFormat.text);
    expect(p.basename(file.file!.path), 'My talk (English summary).txt');
    expect(file.file!.readAsStringSync(), '- a point\n');
    expect(file.mimeType, 'text/plain');
  });
}
