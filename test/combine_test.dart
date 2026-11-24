import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:transcripts/combine.dart';
import 'package:transcripts/job.dart';
import 'package:transcripts/library.dart';
import 'package:transcripts/notes.dart';
import 'package:transcripts/trash.dart';

import 'fake_media_tools.dart';

String _srt(List<String> lines, {int step = 2}) {
  final out = StringBuffer();
  for (final (i, line) in lines.indexed) {
    String ts(int s) => '00:00:${s.toString().padLeft(2, '0')},000';
    if (i > 0) out.writeln();
    out.writeln(i + 1);
    out.writeln('${ts(i * step)} --> ${ts(i * step + step)}');
    out.writeln(line);
  }
  return out.toString();
}

void main() {
  late Directory root;
  late Library library;
  late FakeMediaTools media;

  String at(String rel) => p.joinAll([root.path, ...rel.split('/')]);

  File touch(String rel, [String content = 'x']) {
    return File(at(rel))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  String? read(String rel) =>
      File(at(rel)).existsSync() ? File(at(rel)).readAsStringSync() : null;

  /// A part whose audio is [seconds] characters long.
  CombinePart part(
    String rel,
    int seconds, {
    List<String>? transcript,
    List<String>? translation,
    List<String>? furigana,
    String? lang,
    String? names,
    String? overrides,
    bool summary = false,
  }) {
    final file = touch(rel, p.basenameWithoutExtension(rel)[0] * seconds);
    final dir = p.posix.join(
      p.posix.dirname(rel),
      '.${p.basenameWithoutExtension(rel)}',
    );
    if (transcript != null) touch('$dir/transcript.srt', _srt(transcript));
    if (translation != null) touch('$dir/translation.srt', _srt(translation));
    if (furigana != null) touch('$dir/furigana.srt', _srt(furigana));
    if (lang != null) touch('$dir/lang', '$lang\n');
    if (names != null) touch('$dir/speakers.json', names);
    if (overrides != null) touch('$dir/speaker-overrides.json', overrides);
    if (summary) touch('$dir/summary.md', 'summary');
    return CombinePart.load(library, file, seconds.toDouble());
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('combine_test');
    library = Library(root);
    media = FakeMediaTools();
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('compareForCombining orders family pieces by number', () {
    final files = [
      for (final n in ['b.mp3', 'a_10.mp3', 'a_2.mp3', 'a.mp3', 'a_1.mp3'])
        File(n),
    ]..sort(compareForCombining);
    expect(files.map((f) => f.path), [
      'a.mp3',
      'a_1.mp3',
      'a_2.mp3',
      'a_10.mp3',
      'b.mp3',
    ]);
  });

  group('combineProblems', () {
    test('needs two recordings of one format', () {
      final a = part('a.mp3', 4);
      expect(combineProblems([a]).single, contains('at least two'));
      expect(
        combineProblems([a, part('b.m4a', 4)]).single,
        contains('different formats'),
      );
      expect(combineProblems([a, part('c.mp3', 4)]), isEmpty);
    });

    test('needs transcripts on all parts or none', () {
      final a = part('a.mp3', 4, transcript: ['x']);
      final b = part('b.mp3', 4);
      final problem = combineProblems([a, b]).single;
      expect(problem, contains('no transcript: b'));
    });

    test('needs one language', () {
      final a = part('a.mp3', 4, transcript: ['x'], lang: 'ja');
      final b = part('b.mp3', 4, transcript: ['x']);
      expect(combineProblems([a, b]).single, contains('different languages'));
    });
  });

  test('defaultCombinedName uses the family base when there is one', () {
    expect(
      defaultCombinedName([part('talk_1.mp3', 1), part('talk_2.mp3', 1)]),
      'talk',
    );
    expect(
      defaultCombinedName([part('one.mp3', 1), part('two.mp3', 1)]),
      'one (combined)',
    );
  });

  group('defaultSpeakerMapping', () {
    test('keeps numbers when nothing is named', () {
      final parts = [
        part('a.mp3', 4, transcript: ['Speaker 1: x', 'Speaker 2: y']),
        part('b.mp3', 4, transcript: ['Speaker 2: x', 'Speaker 3: y']),
      ];
      expect(defaultSpeakerMapping(parts), [
        {'1': '1', '2': '2'},
        {'2': '2', '3': '3'},
      ]);
    });

    test('matches the same name across different numbers', () {
      final parts = [
        part(
          'a.mp3',
          4,
          transcript: ['Speaker 1: x', 'Speaker 2: y'],
          names: '{"1": "Host", "2": "Guest"}',
        ),
        part(
          'b.mp3',
          4,
          transcript: ['Speaker 1: x', 'Speaker 2: y'],
          names: '{"1": "guest ", "2": "Host"}',
        ),
      ];
      final mapping = defaultSpeakerMapping(parts);
      expect(mapping[1], {'1': '2', '2': '1'});
      expect(combinedSpeakerNames(parts, mapping), {'1': 'Host', '2': 'Guest'});
    });

    test('two speakers of one part never share a combined speaker', () {
      final parts = [
        part(
          'a.mp3',
          4,
          transcript: ['Speaker 1: x', 'Speaker 2: y'],
          names: '{"1": "Host"}',
        ),
        part(
          'b.mp3',
          4,
          transcript: ['Speaker 1: x', 'Speaker 2: y'],
          names: '{"2": "Host"}',
        ),
        part(
          'c.mp3',
          4,
          transcript: ['Speaker 1: x', 'Speaker 2: y', 'Speaker 3: z'],
          names: '{"3": "Host"}',
        ),
      ];
      final mapping = defaultSpeakerMapping(parts);
      expect(mapping[1], {'1': '2', '2': '1'});
      expect(mapping[2], {'1': '2', '2': '3', '3': '1'});
      for (final map in mapping) {
        expect(map.values.toSet().length, map.length);
      }
    });

    test('a different name on a taken number becomes a new speaker', () {
      final parts = [
        part('a.mp3', 4, transcript: ['Speaker 1: x'], names: '{"1": "Host"}'),
        part('b.mp3', 4, transcript: ['Speaker 1: x'], names: '{"1": "Other"}'),
        part('c.mp3', 4, transcript: ['Speaker 1: x', 'Speaker 2: y']),
      ];
      final mapping = defaultSpeakerMapping(parts);
      expect(mapping[1], {'1': '2'});
      expect(mapping[2], {'1': '1', '2': '2'});
      expect(combinedSpeakerNames(parts, mapping), {'1': 'Host', '2': 'Other'});
    });

    test('uses manual speaker changes when listing a part\'s speakers', () {
      final parts = [
        part('a.mp3', 4, transcript: ['Speaker 1: x']),
        part(
          'b.mp3',
          4,
          transcript: ['Speaker 1: x', 'Speaker 1: y'],
          overrides: '{"1:0": "5"}',
        ),
      ];
      expect(defaultSpeakerMapping(parts)[1], {'1': '1', '5': '5'});
      expect(parts[1].sampleLine('5'), 'y');
    });
  });

  test('mergeCues shifts timestamps and renumbers speakers', () {
    final parts = [
      part('a.mp3', 10, transcript: ['Speaker 1: a1', 'plain']),
      part(
        'b.mp3',
        7,
        transcript: ['Speaker 1: b1', 'Speaker 2: b2'],
        overrides: '{"1:0": "1"}',
      ),
      part('c.mp3', 5, transcript: ['Speaker 3: c1']),
    ];
    final merged = mergeCues(parts, [
      {'1': '1'},
      {'1': '2', '2': '9'},
      {'3': '1'},
    ]);
    expect(merged.map((c) => c.start), [0, 2, 10, 12, 17]);
    expect(merged.map((c) => c.end), [2, 4, 12, 14, 19]);
    expect(merged.map((c) => c.items.single.speaker), [
      '1',
      null,
      '2',
      '2',
      '1',
    ]);
    expect(partOffsets(parts), [0, 10, 17]);
  });

  test('readings are merged only when every piece has them', () {
    final parts = [
      part('a.mp3', 10, transcript: ['x'], furigana: ['｜一《いち》']),
      part('b.mp3', 5, transcript: ['y'], furigana: ['｜二《に》']),
    ];
    expect(mergesFurigana(parts), isTrue);
    final merged = mergeCues(parts, [{}, {}], from: (p) => p.furigana);
    expect(merged.map((c) => c.items.single.text), ['｜一《いち》', '｜二《に》']);
    expect(merged.map((c) => c.start), [0, 10]);

    expect(
      mergesFurigana([
        ...parts,
        part('c.mp3', 3, transcript: ['z']),
      ]),
      isFalse,
    );
  });

  test('describeCombination states what happens to each piece', () {
    final parts = [
      part(
        'talk_1.mp3',
        75,
        transcript: ['Speaker 1: a'],
        translation: ['Speaker 1: a'],
        names: '{"1": "Host"}',
        summary: true,
      ),
      part(
        'talk_2.mp3',
        30,
        transcript: ['Speaker 2: b'],
        names: '{"2": "Host"}',
        overrides: '{"0:0": "2"}',
      ),
    ];
    final lines = describeCombination(
      parts,
      defaultSpeakerMapping(parts),
      'talk',
    );
    expect(lines, [
      'Joins 2 recordings into "talk.mp3", 1:45 long, in this order: '
          'talk_1 (starts at 0:00), talk_2 (starts at 1:15).',
      "The transcripts are merged into one, with each part's timestamps "
          'shifted to where it starts.',
      'The translation is left out, because talk_2 has none. Translate the '
          'combined recording afterwards.',
      'Host is Host in talk_1, Host in talk_2.',
      'Manual speaker changes are kept.',
      'Summaries are not carried over (1 of the recordings has one). '
          'Generate a new one afterwards.',
      'The 2 originals move to the trash with everything attached to them. '
          'You can restore them from there.',
    ]);

    final bare = [part('x.mp3', 5), part('y.mp3', 5)];
    expect(describeCombination(bare, defaultSpeakerMapping(bare), 'xy'), [
      'Joins 2 recordings into "xy.mp3", 0:10 long, in this order: '
          'x (starts at 0:00), y (starts at 0:05).',
      'None of the recordings has a transcript, so only the audio is joined.',
      'The 2 originals move to the trash with everything attached to them. '
          'You can restore them from there.',
    ]);
  });

  group('CombineJob', () {
    CombineJob job(List<CombinePart> parts, String name) {
      return CombineJob(
        library: library,
        parts: parts,
        mapping: defaultSpeakerMapping(parts),
        outputStem: name,
        media: media,
      );
    }

    test(
      'joins the audio and merges transcript, translation and names',
      () async {
        final parts = [
          part(
            'set/talk_1.mp3',
            6,
            transcript: ['Speaker 1: one', 'Speaker 2: two'],
            translation: ['Speaker 1: uno', 'Speaker 2: dos'],
            lang: 'ja',
            names: '{"1": "Host"}',
            summary: true,
          ),
          part(
            'set/talk_2.mp3',
            4,
            transcript: ['Speaker 2: three'],
            translation: ['Speaker 2: tres'],
            lang: 'ja',
            names: '{"2": "Host"}',
          ),
        ];
        touch('set/other.mp3');
        final j = job(parts, 'talk');
        await j.run();

        expect(j.state, JobState.done, reason: j.error);
        expect(j.result!.path, at('set/talk.mp3'));
        expect(read('set/talk.mp3'), 'tttttttttt');
        expect(
          read('set/.talk/transcript.srt'),
          '1\n00:00:00,000 --> 00:00:02,000\nSpeaker 1: one\n\n'
          '2\n00:00:02,000 --> 00:00:04,000\nSpeaker 2: two\n\n'
          '3\n00:00:06,000 --> 00:00:08,000\nSpeaker 1: three\n',
        );
        expect(
          read('set/.talk/transcript.txt'),
          'Speaker 1: one\nSpeaker 2: two\nSpeaker 1: three\n',
        );
        expect(read('set/.talk/translation.srt'), contains('Speaker 1: tres'));
        expect(read('set/.talk/lang'), 'ja\n');
        expect(library.readStringMap(j.result!, Sidecar.speakers), {
          '1': 'Host',
        });
        expect(read('set/.talk/summary.md'), isNull);
        expect(read('set/.talk/speaker-overrides.json'), isNull);

        expect(
          Directory(at('set'))
              .listSync()
              .map((e) => p.basename(e.path))
              .toSet(),
          {'talk.mp3', '.talk', 'other.mp3'},
        );
        expect(Trash(library).items().map((i) => i.name).toSet(), {
          'talk_1',
          'talk_2',
        });
      },
    );

    test('notes move to their times in the combined recording', () async {
      final a = part('a.mp3', 10, transcript: ['x']);
      final b = part('b.mp3', 5, transcript: ['y']);
      writeNotes(library, a.file, const [Note(id: 'n1', time: 4, text: 'one')]);
      writeNotes(library, b.file, const [
        Note(id: 'n2', time: 1.5, text: 'two'),
      ]);
      final parts = [
        CombinePart.load(library, a.file, 10),
        CombinePart.load(library, b.file, 5),
      ];
      expect(
        describeCombination(parts, defaultSpeakerMapping(parts), 'ab'),
        contains('Your 2 notes are kept, moved to their new times.'),
      );
      final j = job(parts, 'ab');
      await j.run();

      expect(j.state, JobState.done, reason: j.error);
      final notes = readNotes(library, j.result!);
      expect(notes.map((n) => (n.id, n.time, n.text)), [
        ('n1', 4.0, 'one'),
        ('n2', 11.5, 'two'),
      ]);
    });

    test('notes keep their pictures', () async {
      final a = part('a.mp3', 10);
      final b = part('b.mp3', 5);
      final picture = touch('pic.jpg', 'PIXELS');
      writeNotes(library, b.file, [
        const Note(
          id: 'n2',
          time: 1,
          text: '',
        ).withImage(storeNoteImage(library, b.file, picture, 'n2')),
      ]);
      final parts = [
        CombinePart.load(library, a.file, 10),
        CombinePart.load(library, b.file, 5),
      ];
      final j = job(parts, 'a');
      await j.run();

      expect(j.state, JobState.done, reason: j.error);
      final note = readNotes(library, j.result!).single;
      expect(note.time, 11);
      expect(noteImage(library, j.result!, note)!.readAsStringSync(), 'PIXELS');
      expect(
        root
            .listSync()
            .map((e) => p.basename(e.path))
            .where((n) => n.contains('tmp')),
        isEmpty,
      );
    });

    test('leaves out the translation when a part lacks one', () async {
      final parts = [
        part('a.mp3', 4, transcript: ['x'], translation: ['x']),
        part('b.mp3', 4, transcript: ['y']),
      ];
      expect(partsMissingTranslation(parts), ['b']);
      final j = job(parts, 'ab');
      await j.run();

      expect(j.state, JobState.done, reason: j.error);
      expect(read('.ab/transcript.srt'), isNotNull);
      expect(read('.ab/translation.srt'), isNull);
    });

    test('joins recordings that have no transcripts', () async {
      final j = job([part('a.mp3', 3), part('b.mp3', 2)], 'ab');
      await j.run();

      expect(j.state, JobState.done, reason: j.error);
      expect(read('ab.mp3'), 'aaabb');
      expect(Directory(at('.ab')).existsSync(), isFalse);
    });

    test('joins the audio extracted from videos', () async {
      final a = part('a.mp4', 3, transcript: ['x']);
      final b = part('b.mp4', 2, transcript: ['y']);
      touch('.a/audio.mp3', 'AAA');
      touch('.b/audio.mp3', 'BB');
      final parts = [
        CombinePart.load(library, a.file, 3),
        CombinePart.load(library, b.file, 2),
      ];
      final j = job(parts, 'ab');
      await j.run();

      expect(j.state, JobState.done, reason: j.error);
      expect(read('ab.mp4'), 'aaabb');
      expect(read('.ab/audio.mp3'), 'AAABB');
    });

    test('refuses a name another recording has', () async {
      touch('taken.mp3');
      final j = job([part('a.mp3', 3), part('b.mp3', 2)], 'taken');
      await j.run();

      expect(j.state, JobState.failed);
      expect(j.error, contains('already exists'));
      expect(read('a.mp3'), 'aaa');
      expect(Trash(library).items(), isEmpty);
    });

    test('a failed join leaves everything in place', () async {
      media.failOn = 'concat';
      final j = job([part('a.mp3', 3), part('b.mp3', 2)], 'ab');
      await j.run();

      expect(j.state, JobState.failed);
      expect(root.listSync().map((e) => p.basename(e.path)).toSet(), {
        'a.mp3',
        'b.mp3',
      });
    });
  });
}
