import 'package:flutter_test/flutter_test.dart';
import 'package:transcripts/srt.dart';

void main() {
  group('parseSrt', () {
    test('reads timestamps, speakers and unlabelled lines', () {
      final cues = parseSrt(
        '1\r\n00:00:01,500 --> 00:00:04,000\r\nSpeaker 1: hello\r\n'
        'Speaker 2: hi\r\n\r\n'
        '2\n00:01:00,000 --> 00:01:02,250\nplain line\n',
      );
      expect(cues, hasLength(2));
      expect(cues[0].start, 1.5);
      expect(cues[0].end, 4.0);
      expect(cues[0].items.map((i) => i.speaker), ['1', '2']);
      expect(cues[0].items.map((i) => i.text), ['hello', 'hi']);
      expect(cues[1].start, 60.0);
      expect(cues[1].items.single.speaker, isNull);
      expect(cues[1].items.single.text, 'plain line');
    });

    test('skips blocks without a timestamp line', () {
      expect(parseSrt('just some text\n\nmore text'), isEmpty);
    });

    test('clamps a backward end to the next cue start', () {
      final cues = parseSrt(
        '1\n00:00:10,000 --> 00:00:08,000\na\n\n'
        '2\n00:00:12,000 --> 00:00:14,000\nb\n',
      );
      expect(cues[0].end, 12.0);
    });

    test('clamps a backward end to start plus five seconds', () {
      final cues = parseSrt(
        '1\n00:00:10,000 --> 00:00:08,000\na\n\n'
        '2\n00:00:30,000 --> 00:00:31,000\nb\n',
      );
      expect(cues[0].end, 15.0);
      expect(parseSrt('1\n00:00:10,000 --> 00:00:10,000\na\n')[0].end, 15.0);
    });
  });

  group('activeCueIndex', () {
    final cues = [
      Cue(0, 60, const []),
      Cue(5, 8, const []),
      Cue(8, 12, const []),
    ];

    test('prefers the shortest cue containing the time', () {
      expect(activeCueIndex(cues, 6), 1);
      expect(activeCueIndex(cues, 8), 2);
      expect(activeCueIndex(cues, 20), 0);
    });

    test('returns -1 outside every cue', () {
      expect(activeCueIndex(cues, 60), -1);
      expect(activeCueIndex(const [], 1), -1);
    });
  });

  test('formatClock', () {
    expect(formatClock(0), '0:00');
    expect(formatClock(75.9), '1:15');
    expect(formatClock(3725), '1:02:05');
    expect(formatClock(double.nan), '');
  });

  test('stripCodeFence', () {
    expect(stripCodeFence('```srt\n1\nfoo\n```\n'), '1\nfoo');
    expect(stripCodeFence('  1\nfoo  '), '1\nfoo');
    expect(stripCodeFence('```\nunterminated'), 'unterminated');
  });

  test('normalizeSrtTimestamps adds missing hours and fixes the separator', () {
    expect(
      normalizeSrtTimestamps(
        '1\n01:42,560 --> 01:48:210\nfoo\n\n'
        '2\n00:02:00,000 --> 00:02:01,000\nbar',
      ),
      '1\n00:01:42,560 --> 00:01:48,210\nfoo\n\n'
      '2\n00:02:00,000 --> 00:02:01,000\nbar',
    );
  });

  group('fixBackwardTimestamps', () {
    test('rewrites only the broken cues', () {
      expect(
        fixBackwardTimestamps(
          '1\n00:00:10,000 --> 00:00:08,000\na\n\n'
          '2\n00:00:12,000 --> 00:00:14,000\nb\n\n'
          '3\n00:00:20,000 --> 00:00:20,000\nc\n',
        ),
        '1\n00:00:10,000 --> 00:00:12,000\na\n\n'
        '2\n00:00:12,000 --> 00:00:14,000\nb\n\n'
        '3\n00:00:20,000 --> 00:00:25,000\nc\n',
      );
    });

    test('leaves text without cues untouched', () {
      expect(fixBackwardTimestamps('nothing here'), 'nothing here');
    });
  });

  test('splitInlineSpeakers puts each speaker turn on its own line', () {
    expect(
      splitInlineSpeakers(
        '1\n00:00:01,000 --> 00:00:04,000\n'
        'intro Speaker 1: foo Speaker 2: bar\n\n'
        '2\n00:00:05,000 --> 00:00:06,000\nSpeaker 1: solo',
      ),
      '1\n00:00:01,000 --> 00:00:04,000\n'
      'intro\nSpeaker 1: foo\nSpeaker 2: bar\n\n'
      '2\n00:00:05,000 --> 00:00:06,000\nSpeaker 1: solo',
    );
  });

  test('srtToPlaintext drops numbers and timestamps', () {
    expect(
      srtToPlaintext(
        '1\n00:00:01,000 --> 00:00:02,000\nSpeaker 1: a\n\n2\n'
        '00:00:03,000 --> 00:00:04,000\nb\n',
      ),
      'Speaker 1: a\nb\n',
    );
  });

  test('cleanModelSrt applies every write-path fix', () {
    expect(
      cleanModelSrt(
        '```\n1\n00:05,000 --> 00:03,000\nSpeaker 1: a Speaker 2: b\n```',
      ),
      '1\n00:00:05,000 --> 00:00:10,000\nSpeaker 1: a\nSpeaker 2: b',
    );
  });
}
