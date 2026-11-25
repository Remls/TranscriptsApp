import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transcripts/combine.dart';
import 'package:transcripts/notes.dart';
import 'package:transcripts/srt.dart';
import 'package:transcripts/durations.dart';
import 'package:transcripts/job.dart';
import 'package:transcripts/library.dart';
import 'package:transcripts/rechunk.dart';
import 'package:transcripts/transcription_job.dart';
import 'package:transcripts/trash.dart';

import 'fake_media_tools.dart';

import 'languages_fixture.dart';

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

  setUp(() {
    root = Directory.systemTemp.createTempSync('media_test');
    library = Library(root);
    media = FakeMediaTools();
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('familyBase strips a numeric suffix', () {
    expect(familyBase('talk'), 'talk');
    expect(familyBase('talk_12'), 'talk');
    expect(familyBase('talk_a'), 'talk_a');
    expect(familyBase('2026_05_01'), '2026_05');
  });

  test('familyMembers finds same-extension siblings in order', () {
    touch('set/talk_10.mp3');
    touch('set/talk_2.mp3');
    final first = touch('set/talk.mp3');
    touch('set/talk_3.m4a');
    touch('set/talker.mp3');
    touch('set/.talk/transcript.srt');
    expect(familyMembers(first).map((f) => p.basename(f.path)), [
      'talk.mp3',
      'talk_2.mp3',
      'talk_10.mp3',
    ]);
    expect(familyMembers(File(at('set/talk_2.mp3'))).length, 3);
  });

  test('planChunkCount merges a short tail into the last chunk', () {
    expect(planChunkCount(1800, 900, 1200), 2);
    expect(planChunkCount(2000, 900, 1200), 2);
    expect(planChunkCount(2200, 900, 1200), 3);
    expect(planChunkCount(1300, 900, 1200), 2);
    expect(planChunkCount(1201, 900, 1200), 2);
  });

  test('splitProblem explains why nothing can be split', () {
    expect(splitProblem(1800, 900, 1200), isNull);
    expect(splitProblem(1800, 0, 1200), contains('target'));
    expect(splitProblem(1800, 1200, 1200), contains('target'));
    expect(splitProblem(600, 900, 1200), contains('not above the max (20:00)'));
  });

  group('describeSplit', () {
    SplitCarry carryOf(List<File> files) => SplitCarry.of([
      for (final f in files) CombinePart.load(library, f, 100),
    ]);

    test('states the join, the chunks and the trash', () {
      final bare = carryOf([touch('talk.mp3'), touch('talk_2.mp3')]);
      expect(
        describeSplit(
          [('talk', 1500.0), ('talk_2', 700.0)],
          'talk',
          '.mp3',
          900,
          1200,
          carry: bare,
          languageName: _name,
        ),
        [
          'Joins 2 recordings first, 36:40 in total: talk (25:00), '
              'talk_2 (11:40).',
          'Cuts that into 3 chunks: talk_1.mp3 (15:00), talk_2.mp3 (15:00), '
              'talk_3.mp3 (6:40).',
          'The 2 originals move to the trash. You can restore them from there.',
        ],
      );
      expect(
        describeSplit(
          [('day', 5430.0)],
          'day',
          '.mp3',
          60,
          120,
          carry: carryOf([touch('day.mp3')]),
          languageName: _name,
        ).first,
        'Cuts "day.mp3" into 90 chunks, day_1.mp3 to day_90.mp3. Each is 1:00 '
        'long and the last is 1:30.',
      );
    });

    test('states what is carried into the chunks', () {
      final rec = touch('long.m4a');
      touch('.long/transcript.srt', '1\n00:00:01,000 --> 00:00:02,000\nx\n');
      touch('.long/translation.srt', '1\n00:00:01,000 --> 00:00:02,000\ny\n');
      touch('.long/summary.md', 'summary');
      writeNotes(library, rec, const [
        Note(id: 'a', time: 1, text: 'one'),
        Note(id: 'b', time: 2, text: 'two'),
      ]);
      expect(
        describeSplit(
          [('long', 2900.0)],
          'long',
          '.m4a',
          900,
          1200,
          carry: carryOf([rec]),
          languageName: _name,
        ),
        [
          'Cuts "long.m4a" into 3 chunks: long_1.m4a (15:00), '
              'long_2.m4a (15:00), long_3.m4a (18:20).',
          'The transcript, the English translation and your 2 notes are cut at the '
              'same points and kept with the chunks. A line that runs across '
              'a cut stays in the chunk where it starts.',
          'Summaries are not carried over (1 of the recordings has one). '
              'Generate new ones afterwards.',
          'The original moves to the trash. You can restore it from there.',
        ],
      );
    });

    test('words a single carried item correctly', () {
      final rec = touch('n.mp3');
      writeNotes(library, rec, const [Note(id: 'a', time: 1, text: 'one')]);
      final lines = describeSplit(
        [('n', 2900.0)],
        'n',
        '.mp3',
        900,
        1200,
        carry: carryOf([rec]),
        languageName: _name,
      );
      expect(lines[1], startsWith('Your 1 note is cut at the same points'));
    });

    test('a family with mixed transcripts is a problem', () {
      touch('.talk/transcript.srt', '1\n00:00:01,000 --> 00:00:02,000\nx\n');
      final carry = carryOf([touch('talk.mp3'), touch('talk_2.mp3')]);
      expect(carry.problems.single, contains('no transcript: talk_2'));
    });
  });

  test('cuesBetween and notesBetween take a stretch and rebase its times', () {
    final cues = [
      Cue(0, 5, const [CueItem('1', 'a')]),
      Cue(8, 12, const [CueItem('2', 'b')]),
      Cue(10, 11, const [CueItem('1', 'c')]),
      Cue(25, 26, const [CueItem('1', 'd')]),
    ];
    final middle = cuesBetween(cues, 8, 20);
    expect(middle.map((c) => (c.start, c.end, c.items.single.text)), [
      (0.0, 4.0, 'b'),
      (2.0, 3.0, 'c'),
    ]);
    expect(cuesBetween(cues, 20, null).single.start, 5);
    expect(cuesBetween(cues, 12, 20), isEmpty);

    const notes = [
      Note(id: 'a', time: 3, text: 'x'),
      Note(id: 'b', time: 10, text: 'y'),
    ];
    expect(notesBetween(notes, 10, null).single.time, 0);
    expect(notesBetween(notes, 0, 10).single.id, 'a');
  });

  group('rechunk', () {
    RechunkJob job(File recording, {double target = 10, double max = 15}) {
      return RechunkJob(
        library: library,
        recording: recording,
        targetSeconds: target,
        maxSeconds: max,
        media: media,
      );
    }

    test('joins the family, cuts chunks and trashes the originals', () async {
      final a = touch('set/talk.mp3', 'a' * 12);
      touch('set/talk_2.mp3', 'b' * 12);
      touch('set/.talk/summary.md', 'old');
      touch('set/other.mp3', 'zzz');

      final j = job(a);
      await j.run();

      expect(j.state, JobState.done, reason: j.error);
      expect(media.calls.where((c) => !c.startsWith('duration')), [
        'concat talk.mp3+talk_2.mp3',
        'split 0.0 10.0',
        'split 10.0 end',
      ]);
      expect(read('set/talk_1.mp3'), 'a' * 10);
      expect(read('set/talk_2.mp3'), 'aa${'b' * 12}');
      expect(read('set/talk.mp3'), isNull);
      expect(Directory(at('set/.talk')).existsSync(), isFalse);
      expect(read('set/other.mp3'), 'zzz');
      expect(j.chunks.map((f) => p.basename(f.path)), [
        'talk_1.mp3',
        'talk_2.mp3',
      ]);
      expect(
        Directory(at('set')).listSync().map((e) => p.basename(e.path)).toSet(),
        {'talk_1.mp3', 'talk_2.mp3', 'other.mp3'},
      );
      final trashed = Trash(library).items();
      expect(trashed.map((i) => i.name).toSet(), {'talk', 'talk_2'});
    });

    test(
      'transcript, translation, names and notes follow the chunks',
      () async {
        String srt(List<(int, String)> lines) => [
          for (final (i, (start, text)) in lines.indexed)
            '${i + 1}\n00:00:${start.toString().padLeft(2, '0')},000 --> '
                '00:00:${(start + 2).toString().padLeft(2, '0')},000\n$text\n',
        ].join('\n');

        final a = touch('set/talk.mp3', 'a' * 12);
        touch('set/talk_2.mp3', 'b' * 12);
        touch(
          'set/.talk/transcript.srt',
          srt([(1, 'Speaker 1: a1'), (9, 'Speaker 2: a2')]),
        );
        touch(
          'set/.talk/translation.srt',
          srt([(1, 'Speaker 1: A1'), (9, 'Speaker 2: A2')]),
        );
        touch('set/.talk/speakers.json', '{"1": "Host"}');
        touch('set/.talk/lang', 'ja\n');
        touch('set/.talk/summary.md', 'old summary');
        touch(
          'set/.talk_2/transcript.srt',
          srt([(0, 'Speaker 2: b1'), (10, 'Speaker 2: b2')]),
        );
        touch(
          'set/.talk_2/translation.srt',
          srt([(0, 'Speaker 2: B1'), (10, 'Speaker 2: B2')]),
        );
        touch(
          'set/.talk/translation.ja.srt',
          srt([(1, 'Speaker 1: ア1'), (9, 'Speaker 2: ア2')]),
        );
        touch(
          'set/.talk_2/translation.ja.srt',
          srt([(0, 'Speaker 2: ビ1'), (10, 'Speaker 2: ビ2')]),
        );
        library.writeContext(a, 'A boat trip.');
        touch('set/.talk_2/speakers.json', '{"2": "Host"}');
        touch('set/.talk_2/lang', 'ja\n');
        writeNotes(library, a, const [Note(id: 'n1', time: 4, text: 'early')]);
        writeNotes(library, File(at('set/talk_2.mp3')), const [
          Note(id: 'n2', time: 11, text: 'late'),
        ]);

        final j = job(a);
        await j.run();

        expect(j.state, JobState.done, reason: j.error);
        // Joined, the lines start at 1, 9, 12 and 22 seconds. The chunks cover
        // 0 to 10 and 10 to 24.
        expect(
          read('set/.talk_1/transcript.srt'),
          srt([(1, 'Speaker 1: a1'), (9, 'Speaker 2: a2')]),
        );
        expect(
          read('set/.talk_2/transcript.srt'),
          srt([(2, 'Speaker 1: b1'), (12, 'Speaker 1: b2')]),
        );
        expect(read('set/.talk_2/translation.srt'), contains('Speaker 1: B2'));
        expect(
          read('set/.talk_1/translation.ja.srt'),
          contains('Speaker 2: ア2'),
        );
        expect(
          read('set/.talk_2/translation.ja.srt'),
          contains('Speaker 1: ビ2'),
        );
        expect(
          read('set/.talk_1/transcript.txt'),
          'Speaker 1: a1\nSpeaker 2: a2\n',
        );
        expect(read('set/.talk_2/lang'), 'ja\n');
        for (final chunk in j.chunks) {
          expect(library.readStringMap(chunk, Sidecar.speakers), {'1': 'Host'});
          expect(library.summaryFile(chunk, 'en').existsSync(), isFalse);
          expect(library.contextOf(chunk), 'A boat trip.');
        }
        expect(readNotes(library, j.chunks[0]).map((n) => (n.id, n.time)), [
          ('n1', 4.0),
        ]);
        expect(readNotes(library, j.chunks[1]).map((n) => (n.id, n.time)), [
          ('n2', 13.0),
        ]);
      },
    );

    test('a note\'s picture goes to the chunk the note falls in', () async {
      final rec = touch('long.mp3', 'a' * 31);
      final picture = touch('pic.jpg', 'PIXELS');
      writeNotes(library, rec, [
        const Note(
          id: 'n1',
          time: 14,
          text: 'second chunk',
        ).withImage(storeNoteImage(library, rec, picture, 'n1')),
      ]);
      final j = job(rec);
      await j.run();

      expect(j.state, JobState.done, reason: j.error);
      expect(readNotes(library, j.chunks[0]), isEmpty);
      final note = readNotes(library, j.chunks[1]).single;
      expect(note.time, 4);
      expect(
        noteImage(library, j.chunks[1], note)!.readAsStringSync(),
        'PIXELS',
      );
      expect(
        root
            .listSync()
            .map((e) => p.basename(e.path))
            .where((n) => n.contains('tmp')),
        isEmpty,
      );
    });

    test('a video keeps its extracted audio, cut the same way', () async {
      final v = touch('clip.mp4', 'v' * 31);
      touch('.clip/audio.mp3', 'A' * 31);
      final j = job(v);
      await j.run();

      expect(j.state, JobState.done, reason: j.error);
      expect(read('clip_1.mp4'), 'v' * 10);
      expect(read('.clip_1/audio.mp3'), 'A' * 10);
      expect(read('.clip_3/audio.mp3'), 'A' * 11);
      expect(
        root
            .listSync()
            .map((e) => p.basename(e.path))
            .where((n) => n.contains('tmp')),
        isEmpty,
      );
    });

    test('a family with only some transcripts is refused', () async {
      final a = touch('set/talk.mp3', 'a' * 12);
      touch('set/talk_2.mp3', 'b' * 12);
      touch(
        'set/.talk/transcript.srt',
        '1\n00:00:01,000 --> 00:00:02,000\nx\n',
      );
      final j = job(a);
      await j.run();

      expect(j.state, JobState.failed);
      expect(j.error, contains('no transcript: talk_2'));
      expect(read('set/talk.mp3'), 'a' * 12);
    });

    test('a single long file is cut without joining', () async {
      final a = touch('long.mp3', 'a' * 31);
      final j = job(a);
      await j.run();

      expect(j.state, JobState.done, reason: j.error);
      expect(media.calls.any((c) => c.startsWith('concat')), isFalse);
      expect(read('long_1.mp3'), 'a' * 10);
      expect(read('long_2.mp3'), 'a' * 10);
      expect(read('long_3.mp3'), 'a' * 11);
    });

    test('refuses when the total is not above the max', () async {
      final a = touch('short.mp3', 'a' * 15);
      final j = job(a);
      await j.run();

      expect(j.state, JobState.failed);
      expect(j.error, contains('not above the max'));
      expect(read('short.mp3'), 'a' * 15);
    });

    test('a failed cut leaves the originals and no temp files', () async {
      final a = touch('set/talk.mp3', 'a' * 12);
      touch('set/talk_2.mp3', 'b' * 12);
      media.failOn = 'split 10.0';
      final j = job(a);
      await j.run();

      expect(j.state, JobState.failed);
      expect(
        Directory(at('set')).listSync().map((e) => p.basename(e.path)).toSet(),
        {'talk.mp3', 'talk_2.mp3'},
      );
      expect(Trash(library).items(), isEmpty);
    });

    test('cancel reaches the media tools', () {
      final j = job(touch('a.mp3'))..cancel();
      expect(media.cancelled, isTrue);
      expect(j.state, JobState.running);
    });
  });

  test('transcribing a video extracts its audio into the sidecar', () async {
    final video = touch('clip.mp4', 'frames');
    final uploaded = <List<int>>[];
    final job = TranscriptionJob(
      library: library,
      recording: library.describe(video),
      language: shipped('en'),
      apiKey: 'key',
      model: 'model-x',
      media: media,
      pollInterval: Duration.zero,
      clientFactory: () => MockClient((req) async {
        if (req.url.path == '/upload/v1beta/files') {
          return http.Response(
            '{}',
            200,
            headers: {'x-goog-upload-url': 'https://gemini.test/session'},
          );
        }
        if (req.url.path == '/session') {
          uploaded.add(req.bodyBytes);
          return http.Response(
            '{"file": {"name": "files/a", "uri": "u", '
            '"mimeType": "audio/mpeg", "state": "ACTIVE"}}',
            200,
          );
        }
        if (req.method == 'DELETE') return http.Response('{}', 200);
        return http.Response(
          'data: {"candidates": [{"content": {"parts": [{"text": '
          '"1\\n00:00:01,000 --> 00:00:02,000\\nhello"}]}}]}\n\n',
          200,
        );
      }),
    );
    await job.run();

    expect(job.state, JobState.done, reason: job.error);
    expect(media.calls, ['extract clip.mp4']);
    expect(read('.clip/audio.mp3'), 'audio of frames');
    expect(String.fromCharCodes(uploaded.single), 'audio of frames');
    expect(read('.clip/.audio.tmp.mp3'), isNull);
    expect(read('.clip/transcript.srt'), contains('hello'));
    expect(read('clip.mp4'), 'frames');
  });

  test(
    'durations are probed once and remembered until the file changes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final file = touch('a.mp3', 'x' * 42);
      final recording = library.describe(file);

      final cache = DurationCache(prefs, media);
      var notified = 0;
      cache.addListener(() => notified++);
      expect(cache.of(recording), isNull);
      await cache.probe([recording]);
      expect(cache.of(recording), 42);
      expect(notified, 1);
      await cache.probe([recording]);
      expect(media.calls, ['duration a.mp3']);

      final reloaded = DurationCache(prefs, media);
      expect(reloaded.of(recording), 42);

      file.writeAsStringSync('x' * 7);
      expect(reloaded.of(recording), isNull);
      await reloaded.probe([recording]);
      expect(reloaded.of(recording), 7);
    },
  );
}

String _name(String code) =>
    const {'en': 'English', 'ja': 'Japanese'}[code] ?? code;
