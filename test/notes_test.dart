import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:transcripts/job.dart';
import 'package:transcripts/library.dart';
import 'package:transcripts/notes.dart';
import 'package:transcripts/prompts.dart';
import 'package:transcripts/settings.dart';
import 'package:transcripts/srt.dart';
import 'package:transcripts/text_generator.dart';
import 'package:transcripts/text_jobs.dart';

const _srt =
    '1\n00:00:00,000 --> 00:00:10,000\nSpeaker 1: one\n\n'
    '2\n00:00:10,000 --> 00:00:20,000\nSpeaker 2: two\n\n'
    '3\n00:00:30,000 --> 00:00:40,000\nSpeaker 1: three\n';

void main() {
  late Directory root;
  late Library library;
  late File recording;

  File sidecar(String name, String content) {
    return File(p.join(root.path, '.a', name))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('notes_test');
    library = Library(root);
    recording = File(p.join(root.path, 'a.mp3'))..writeAsStringSync('x');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('notes are stored sorted and the file goes away when empty', () {
    expect(readNotes(library, recording), isEmpty);
    writeNotes(library, recording, const [
      Note(id: 'b', time: 25, text: 'later'),
      Note(id: 'a', time: 5.5, text: 'earlier', image: 'pic.jpg'),
    ]);
    final notes = readNotes(library, recording);
    expect(notes.map((n) => n.id), ['a', 'b']);
    expect(notes.first.time, 5.5);
    expect(notes.first.image, 'pic.jpg');
    expect(notes.last.image, isNull);

    writeNotes(library, recording, const []);
    expect(library.sidecarFile(recording, Sidecar.notes).existsSync(), isFalse);

    sidecar('notes.json', 'not json');
    expect(readNotes(library, recording), isEmpty);
  });

  test('a picture name that is not a plain file name is dropped', () {
    Note note(String image) =>
        Note.fromJson({'id': 'n', 'time': 1, 'text': '', 'image': image});
    expect(note('n.jpg').image, 'n.jpg');
    for (final bad in ['../../x', 'a/b.jpg', '.hidden', '/abs.jpg', '..']) {
      expect(note(bad).image, isNull, reason: bad);
    }
  });

  test('transcriptRows puts each note after the cue it falls in', () {
    final cues = parseSrt(_srt);
    const before = Note(id: '0', time: 0, text: 'at the very start');
    const inFirst = Note(id: '1', time: 4, text: 'during one');
    const inGap = Note(id: '2', time: 25, text: 'between two and three');
    const after = Note(id: '3', time: 99, text: 'after the end');
    expect(transcriptRows(cues, const [after, inGap, inFirst, before]), [
      0,
      before,
      inFirst,
      1,
      inGap,
      2,
      after,
    ]);
    expect(transcriptRows(cues, const []), [0, 1, 2]);
    expect(transcriptRows(const [], const [inFirst]), [inFirst]);
  });

  test('the summary input carries notes in place', () {
    sidecar('translation.srt', _srt);
    sidecar('speakers.json', '{"1": "Host"}');
    writeNotes(library, recording, const [
      Note(id: 'a', time: 12, text: 'They mean the\nnew office.'),
      Note(id: 'b', time: 75, text: '  '),
    ]);
    expect(
      translatedTranscriptText(library, recording),
      'Host: one\nSpeaker 2: two\n'
      '[Note at 0:12: They mean the new office.]\nHost: three',
    );
    expect(hasTextNotes(library, recording), isTrue);
    expect(
      speakerLines(library, recording, Sidecar.translation),
      'Host: one\nSpeaker 2: two\nHost: three',
    );
  });

  test('prompts explain notes only when there are some', () {
    expect(summaryPromptFor(notes: false), summaryPrompt);
    final withNotes = summaryPromptFor(notes: true);
    expect(withNotes, contains('"Note at"'));
    expect(
      withNotes,
      endsWith(
        'not attribute them to a speaker.\n\n'
        'Transcript follows.\n',
      ),
    );
    expect(
      withNotes.replaceFirst(RegExp(r'Lines in square[^\n]*\n\n'), ''),
      summaryPrompt,
    );
    expect(folderFlatPromptFor(notes: false), folderFlatPrompt);
    expect(
      folderFlatPromptFor(notes: true),
      endsWith('Translations follow.\n'),
    );
  });

  test(
    'a summary of a recording with notes sends them and the explanation',
    () async {
      sidecar('translation.srt', _srt);
      writeNotes(library, recording, const [
        Note(id: 'a', time: 12, text: 'Context.'),
      ]);
      late List<dynamic> parts;
      final job = SummaryJob(
        library: library,
        recording: recording,
        generator: const TextGenerator(
          provider: TextProvider.gemini,
          apiKey: 'key',
          model: 'm',
        ),
        clientFactory: () => MockClient((req) async {
          parts = (jsonDecode(req.body) as Map)['contents'][0]['parts'] as List;
          return http.Response(
            'data: {"candidates": [{"content": {"parts": [{"text": "ok"}]}}]}\n\n',
            200,
          );
        }),
      );
      await job.run();

      expect(job.state, JobState.done, reason: job.error);
      expect(
        parts[0]['text'],
        withBackground(summaryPromptFor(notes: true), title: 'a'),
      );
      expect(parts[1]['text'], contains('[Note at 0:12: Context.]'));
    },
  );

  group('pictures', () {
    late File source;

    setUp(() {
      source = File(p.join(root.path, 'picked.jpg'))
        ..writeAsBytesSync([1, 2, 3]);
    });

    test('are stored in the sidecar and removed with the note', () {
      const note = Note(id: 'n1', time: 3, text: '');
      final name = storeNoteImage(library, recording, source, note.id);
      expect(name, 'n1.jpg');
      final withPicture = note.withImage(name);
      final stored = noteImage(library, recording, withPicture)!;
      expect(stored.path, p.join(root.path, '.a', 'notes', 'n1.jpg'));
      expect(stored.readAsBytesSync(), [1, 2, 3]);
      expect(noteImage(library, recording, note), isNull);

      removeNoteImage(library, recording, withPicture);
      expect(noteImage(library, recording, withPicture), isNull);
    });

    test('are numbered in the summary input and named by note lines', () {
      sidecar('translation.srt', _srt);
      writeNotes(library, recording, [
        const Note(id: 'a', time: 2, text: 'Plain note'),
        Note(
          id: 'b',
          time: 12,
          text: 'The whiteboard',
        ).withImage(storeNoteImage(library, recording, source, 'b')),
        const Note(
          id: 'c',
          time: 35,
          text: '',
        ).withImage(storeNoteImage(library, recording, source, 'c')),
        const Note(id: 'd', time: 36, text: 'Lost picture', image: 'gone.jpg'),
      ]);

      final input = summaryInput(library, recording)!;
      expect(
        input.text,
        'Speaker 1: one\n'
        '[Note at 0:02: Plain note]\n'
        'Speaker 2: two\n'
        '[Note at 0:12, with Picture 1: The whiteboard]\n'
        'Speaker 1: three\n'
        '[Picture 2 at 0:35]\n'
        '[Note at 0:36: Lost picture]',
      );
      expect(input.images.map((i) => i.label), ['Picture 1:', 'Picture 2:']);
      expect(input.images.first.mimeType, 'image/jpeg');
      expect(input.images.first.bytes, [1, 2, 3]);
      expect(input.hasNotes, isTrue);

      expect(
        translatedTranscriptText(library, recording),
        isNot(contains('Picture')),
      );
    });

    test('the summary prompt explains pictures when some are sent', () {
      final prompt = summaryPromptFor(notes: true, pictures: true);
      expect(prompt, contains('"Note at"'));
      expect(prompt, contains('Pictures follow the transcript'));
      expect(prompt, endsWith('Transcript follows.\n'));
      expect(summaryPromptFor(notes: true), isNot(contains('Pictures follow')));
    });

    Future<Map<String, dynamic>> requestBody(TextProvider provider) async {
      sidecar('translation.srt', _srt);
      writeNotes(library, recording, [
        const Note(
          id: 'b',
          time: 12,
          text: 'Board',
        ).withImage(storeNoteImage(library, recording, source, 'b')),
      ]);
      late Map<String, dynamic> body;
      final job = SummaryJob(
        library: library,
        recording: recording,
        generator: TextGenerator(provider: provider, apiKey: 'k', model: 'm'),
        clientFactory: () => MockClient((req) async {
          if (req.method == 'GET') {
            return http.Response('{"max_tokens": 9000}', 200);
          }
          body = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(
            provider == TextProvider.gemini
                ? 'data: {"candidates": [{"content": {"parts": [{"text": "ok"}]}}]}\n\n'
                : 'data: {"type": "content_block_delta", "delta": '
                      '{"type": "text_delta", "text": "ok"}}\n\n',
            200,
          );
        }),
      );
      await job.run();
      expect(job.state, JobState.done, reason: job.error);
      return body;
    }

    test('go to Gemini as inline data after the transcript', () async {
      final body = await requestBody(TextProvider.gemini);
      final parts = body['contents'][0]['parts'] as List;
      expect(
        parts[0]['text'],
        withBackground(
          summaryPromptFor(notes: true, pictures: true),
          title: 'a',
        ),
      );
      expect(parts[1]['text'], contains('with Picture 1: Board'));
      expect(parts[2], {'text': 'Picture 1:'});
      expect(parts[3], {
        'inline_data': {'mime_type': 'image/jpeg', 'data': 'AQID'},
      });
    });

    test('go to Claude as image blocks after the transcript', () async {
      final body = await requestBody(TextProvider.anthropic);
      expect(
        body['system'],
        withBackground(
          summaryPromptFor(notes: true, pictures: true),
          title: 'a',
        ),
      );
      final content = body['messages'][0]['content'] as List;
      expect(content[0]['type'], 'text');
      expect(content[0]['text'], contains('with Picture 1: Board'));
      expect(content[1], {'type': 'text', 'text': 'Picture 1:'});
      expect(content[2], {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': 'image/jpeg',
          'data': 'AQID',
        },
      });
    });
  });
}
