import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:transcripts/job.dart';
import 'package:transcripts/languages.dart';
import 'package:transcripts/library.dart';
import 'package:transcripts/prompts.dart';
import 'package:transcripts/settings.dart';
import 'package:transcripts/text_generator.dart';
import 'package:transcripts/text_jobs.dart';

import 'languages_fixture.dart';

const _gemini = TextGenerator(
  provider: TextProvider.gemini,
  apiKey: 'key',
  model: 'model-x',
);

const _srt =
    '1\n00:00:01,000 --> 00:00:02,000\nSpeaker 1: one\n\n'
    '2\n00:00:03,000 --> 00:00:04,000\nSpeaker 2: two\nplain\n';

http.Response _geminiText(String text) {
  final event = {
    'candidates': [
      {
        'content': {
          'parts': [
            {'text': text},
          ],
        },
      },
    ],
  };
  return http.Response.bytes(
    utf8.encode('data: ${jsonEncode(event)}\n\n'),
    200,
  );
}

/// The prompt and input text of a Gemini generate request.
(String, String?) _parts(http.Request req) {
  final parts = (jsonDecode(req.body) as Map)['contents'][0]['parts'] as List;
  return (
    parts[0]['text'] as String,
    parts.length > 1 ? parts[1]['text'] as String? : null,
  );
}

void main() {
  late Directory root;
  late Library library;

  File touch(String rel, [String content = '']) {
    return File(p.joinAll([root.path, ...rel.split('/')]))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  String read(String rel) {
    return File(p.joinAll([root.path, ...rel.split('/')])).readAsStringSync();
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('text_jobs_test');
    library = Library(root);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('prompts match the fixtures', () {
    String fixture(String name) =>
        File('test/fixtures/$name.txt').readAsStringSync();
    for (final lang in ['dv', 'ja']) {
      expect(
        buildTranslationPrompt(shipped(lang), shipped('en')),
        fixture('translation_prompt_$lang'),
        reason: lang,
      );
    }
    expect(
      buildTranslationPrompt(shipped('en'), shipped('ja')),
      fixture('translation_prompt_en_ja'),
    );
    expect(
      buildTranslationPrompt(shipped('ja'), shipped('dv')),
      fixture('translation_prompt_ja_dv'),
    );
    expect(
      withBackground(
        '<prompt>\n',
        title: 'Title',
        note: ' Line one.\nLine two. ',
      ),
      fixture('background_prompt'),
    );
    expect(
      withBackground('<prompt>\n', title: 'Title', note: '  '),
      fixture('background_prompt_no_note'),
    );
    expect(summaryPrompt, fixture('summary_prompt'));
    expect(buildSummaryPrompt(shipped('en')), summaryPrompt);
    expect(buildSummaryPrompt(shipped('dv')), fixture('summary_prompt_dv'));
    expect(folderFlatPrompt, fixture('folder_flat_prompt'));
    expect(folderHierPrompt, fixture('folder_hier_prompt'));
  });

  group('translatedTranscriptText', () {
    test('applies overrides and names to the translation', () {
      final rec = touch('a.mp3');
      touch('.a/translation.srt', _srt);
      touch('.a/speakers.json', '{"3": "Host"}');
      touch('.a/speaker-overrides.json', '{"0:0": "3"}');
      expect(
        translatedTranscriptText(library, rec),
        'Host: one\nSpeaker 2: two\nplain',
      );
    });

    test('reads the transcript itself for an English recording', () {
      final rec = touch('a.mp3');
      touch('.a/transcript.srt', _srt);
      expect(translatedTranscriptText(library, rec), isNull);
      touch('.a/lang', 'en\n');
      expect(
        translatedTranscriptText(library, rec),
        'Speaker 1: one\nSpeaker 2: two\nplain',
      );
    });
  });

  test('translation sends the transcript and stores the result', () async {
    final rec = touch('a.mp3');
    touch('.a/transcript.srt', _srt);
    touch('.a/lang', 'ja\n');
    late (String, String?) sent;
    final job = TranslationJob(
      library: library,
      recording: rec,
      generator: _gemini,
      languages: LanguageList(root),
      clientFactory: () => MockClient((req) async {
        sent = _parts(req);
        return _geminiText('```srt\ntranslated\n```');
      }),
    );
    await job.run();

    expect(job.state, JobState.done);
    expect(sent, (
      withBackground(
        buildTranslationPrompt(shipped('ja'), shipped('en')),
        title: 'a',
      ),
      _srt,
    ));
    expect(read('.a/translation.srt'), 'translated\n');
  });

  test('a Japanese translation keeps its readings apart', () async {
    final rec = touch('a.mp3');
    touch('.a/transcript.srt', _srt);
    touch('.a/lang', 'en\n');
    late (String, String?) sent;
    final job = TranslationJob(
      library: library,
      recording: rec,
      generator: _gemini,
      languages: LanguageList(root),
      to: 'ja',
      clientFactory: () => MockClient((req) async {
        sent = _parts(req);
        return _geminiText(
          '```srt\n1\n00:00:01,000 --> 00:00:02,000\n｜東京《とうきょう》へ\n```',
        );
      }),
    );
    await job.run();

    expect(job.state, JobState.done, reason: job.error);
    expect(
      sent.$1,
      withBackground(
        buildTranslationPrompt(shipped('en'), shipped('ja')),
        title: 'a',
      ),
    );
    expect(
      read('.a/translation.ja.srt'),
      '1\n00:00:01,000 --> 00:00:02,000\n東京へ\n',
    );
    expect(
      read('.a/furigana.ja.srt'),
      '1\n00:00:01,000 --> 00:00:02,000\n｜東京《とうきょう》へ\n',
    );
    expect(
      File(p.join(root.path, '.a', 'translation.srt')).existsSync(),
      isFalse,
    );
  });

  test('translation sends the saved context note', () async {
    final rec = touch('a.mp3');
    touch('.a/transcript.srt', _srt);
    touch('.a/lang', 'ja\n');
    library.writeContext(rec, 'Two speakers.');
    late (String, String?) sent;
    final job = TranslationJob(
      library: library,
      recording: rec,
      generator: _gemini,
      languages: LanguageList(root),
      clientFactory: () => MockClient((req) async {
        sent = _parts(req);
        return _geminiText('translated');
      }),
    );
    await job.run();

    expect(
      sent.$1,
      withBackground(
        buildTranslationPrompt(shipped('ja'), shipped('en')),
        title: 'a',
        note: 'Two speakers.',
      ),
    );
  });

  test('a summary in a new language translates first', () async {
    final rec = touch('a.mp3');
    touch('.a/transcript.srt', _srt);
    touch('.a/lang', 'ja\n');
    final prompts = <String>[];
    final job = SummaryJob(
      library: library,
      recording: rec,
      generator: _gemini,
      languages: LanguageList(root),
      lang: 'dv',
      clientFactory: () => MockClient((req) async {
        prompts.add(_parts(req).$1);
        return _geminiText(prompts.length == 1 ? _srt : '- ނުކުތާ');
      }),
    );
    await job.run();

    expect(job.state, JobState.done, reason: job.error);
    expect(prompts, [
      withBackground(
        buildTranslationPrompt(shipped('ja'), shipped('dv')),
        title: 'a',
      ),
      withBackground(buildSummaryPrompt(shipped('dv')), title: 'a'),
    ]);
    expect(read('.a/translation.dv.srt'), isNotEmpty);
    expect(read('.a/summary.dv.md'), '- ނުކުތާ\n');
  });

  test(
    'a summary in the recording\'s own language reads the transcript',
    () async {
      final rec = touch('a.mp3');
      touch('.a/transcript.srt', _srt);
      touch('.a/lang', 'ja\n');
      late (String, String?) sent;
      final job = SummaryJob(
        library: library,
        recording: rec,
        generator: _gemini,
        languages: LanguageList(root),
        lang: 'ja',
        clientFactory: () => MockClient((req) async {
          sent = _parts(req);
          return _geminiText('- 要点');
        }),
      );
      await job.run();

      expect(job.state, JobState.done, reason: job.error);
      expect(sent, (
        withBackground(buildSummaryPrompt(shipped('ja')), title: 'a'),
        'Speaker 1: one\nSpeaker 2: two\nplain',
      ));
      expect(read('.a/summary.ja.md'), '- 要点\n');
      expect(
        File(p.join(root.path, '.a', 'translation.ja.srt')).existsSync(),
        isFalse,
      );
    },
  );

  test('summary sends the named transcript and stores markdown', () async {
    final rec = touch('a.mp3');
    touch('.a/translation.srt', _srt);
    late (String, String?) sent;
    final job = SummaryJob(
      library: library,
      recording: rec,
      generator: _gemini,
      languages: LanguageList(root),
      clientFactory: () => MockClient((req) async {
        sent = _parts(req);
        return _geminiText('  - a point\n');
      }),
    );
    await job.run();

    expect(job.state, JobState.done);
    expect(sent, (
      withBackground(summaryPrompt, title: 'a'),
      'Speaker 1: one\nSpeaker 2: two\nplain',
    ));
    expect(read('.a/summary.md'), '- a point\n');
  });

  test('a Claude generator calls the Anthropic API', () async {
    final rec = touch('a.mp3');
    touch('.a/translation.srt', _srt);
    final urls = <String>[];
    final job = SummaryJob(
      library: library,
      recording: rec,
      generator: const TextGenerator(
        provider: TextProvider.anthropic,
        apiKey: 'key',
        model: 'claude-x',
      ),
      languages: LanguageList(root),
      clientFactory: () => MockClient((req) async {
        urls.add('${req.url.host}${req.url.path}');
        if (req.method == 'GET') {
          return http.Response('{"max_tokens": 9000}', 200);
        }
        final event = {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'from claude'},
        };
        return http.Response('data: ${jsonEncode(event)}\n\n', 200);
      }),
    );
    await job.run();

    expect(job.state, JobState.done);
    expect(urls, [
      'api.anthropic.com/v1/models/claude-x',
      'api.anthropic.com/v1/messages',
    ]);
    expect(read('.a/summary.md'), 'from claude\n');
  });

  group('folder summary', () {
    late Directory folder;
    late List<String> prompts;
    late List<String?> inputs;

    FolderSummaryJob job(FolderSummaryMode mode) {
      return FolderSummaryJob(
        library: library,
        folder: folder,
        mode: mode,
        language: shipped('dv'),
        languages: LanguageList(root),
        generator: _gemini,
        geminiKey: '',
        geminiModel: '',
        clientFactory: () => MockClient((req) async {
          final (prompt, input) = _parts(req);
          prompts.add(prompt);
          inputs.add(input);
          if (prompt.contains('You are translating')) {
            return _geminiText(_srt.replaceAll('one', 'uno'));
          }
          return _geminiText('output ${prompts.length}');
        }),
      );
    }

    setUp(() {
      touch('set/a.mp3');
      touch('set/.a/transcript.srt', _srt);
      touch('set/b.mp3');
      touch('set/.b/transcript.srt', _srt);
      touch('set/.b/lang', 'en\n');
      folder = Directory(p.join(root.path, 'set'));
      prompts = [];
      inputs = [];
    });

    test('flat mode translates, then summarizes the transcripts', () async {
      final j = job(FolderSummaryMode.flat);
      await j.run();

      expect(j.state, JobState.done, reason: j.error);
      expect(prompts, [
        withBackground(
          buildTranslationPrompt(shipped('dv'), shipped('en')),
          title: 'a',
        ),
        folderFlatPrompt,
      ]);
      expect(read('set/.a/translation.srt'), _srt.replaceAll('one', 'uno'));
      expect(
        inputs.last,
        '## a\n\nSpeaker 1: uno\nSpeaker 2: two\nplain\n\n'
        '## b\n\nSpeaker 1: one\nSpeaker 2: two\nplain',
      );
      expect(read('set/.summary-flat.md'), 'output 2\n');
      expect(
        File(p.join(folder.path, '.b', 'translation.srt')).existsSync(),
        isFalse,
      );
    });

    test('hierarchical mode summarizes each recording first', () async {
      touch('set/.a/translation.srt', _srt);
      touch('set/.a/summary.md', 'existing summary\n');
      final j = job(FolderSummaryMode.hierarchical);
      await j.run();

      expect(j.state, JobState.done, reason: j.error);
      expect(prompts, [
        withBackground(summaryPrompt, title: 'b'),
        folderHierPrompt,
      ]);
      expect(read('set/.b/summary.md'), 'output 1\n');
      expect(inputs.last, '## a\n\nexisting summary\n\n## b\n\noutput 1');
      expect(read('set/.summary-hier.md'), 'output 2\n');
    });

    test('an untranscribed recording needs Gemini settings', () async {
      touch('set/c.mp3');
      final j = job(FolderSummaryMode.flat);
      await j.run();

      expect(j.state, JobState.failed);
      expect(j.error, contains('Gemini API key'));
      expect(prompts, isEmpty);
    });

    test('an empty folder fails', () async {
      folder = Directory(p.join(root.path, 'empty'))..createSync();
      final j = job(FolderSummaryMode.flat);
      await j.run();

      expect(j.error, 'no audio in folder');
    });
  });
}
