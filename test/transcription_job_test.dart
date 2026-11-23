import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:transcripts/job.dart';
import 'package:transcripts/library.dart';
import 'package:transcripts/prompts.dart';
import 'package:transcripts/transcription_job.dart';

import 'languages_fixture.dart';

const _fileJson = {
  'name': 'files/abc',
  'uri': 'file-uri',
  'mimeType': 'audio/mpeg',
  'state': 'ACTIVE',
};

http.Response _json(Object body, [int status = 200]) {
  return http.Response(jsonEncode(body), status);
}

http.Response _sse(String text) {
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

void main() {
  late Directory root;
  late Library library;
  late Recording recording;
  late List<String> calls;

  setUp(() {
    root = Directory.systemTemp.createTempSync('job_test');
    library = Library(root);
    final file = File(p.join(root.path, 'folder', 'talk.mp3'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    recording = library.describe(file);
    calls = [];
  });

  tearDown(() => root.deleteSync(recursive: true));

  TranscriptionJob job(
    FutureOr<http.Response> Function(http.Request) generate, {
    String lang = 'ja',
  }) {
    return TranscriptionJob(
      library: library,
      recording: recording,
      language: shipped(lang),
      apiKey: 'key',
      model: 'model-x',
      pollInterval: Duration.zero,
      clientFactory: () => MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        if (req.url.path == '/upload/v1beta/files') {
          return http.Response(
            '{}',
            200,
            headers: {'x-goog-upload-url': 'https://gemini.test/session'},
          );
        }
        if (req.url.path == '/session') return _json({'file': _fileJson});
        if (req.method == 'DELETE') return _json({});
        return generate(req);
      }),
    );
  }

  String sidecar(Sidecar key) {
    return library.sidecarFile(recording.file, key).readAsStringSync();
  }

  test('writes the cleaned transcript, plain text and language', () async {
    late String prompt;
    final j = job((req) {
      prompt = (jsonDecode(req.body) as Map)['contents'][0]['parts'][0]['text'];
      return _sse(
        '```srt\n1\n00:05,000 --> 00:03,000\n'
        'Speaker 1: one Speaker 2: two\n```',
      );
    });
    await j.run();
    await pumpEventQueue();

    expect(j.state, JobState.done);
    expect(prompt, buildTranscriptionPrompt(shipped('ja')));
    expect(
      sidecar(Sidecar.transcriptSrt),
      '1\n00:00:05,000 --> 00:00:10,000\nSpeaker 1: one\nSpeaker 2: two\n',
    );
    expect(sidecar(Sidecar.transcriptTxt), 'Speaker 1: one\nSpeaker 2: two\n');
    expect(sidecar(Sidecar.lang), 'ja\n');
    expect(calls.last, 'DELETE /v1beta/files/abc');
  });

  test('fails on an empty response and writes nothing', () async {
    final j = job((req) => _sse('  '));
    await j.run();

    expect(j.state, JobState.failed);
    expect(j.error, 'empty response from Gemini');
    expect(library.sidecarDir(recording.file).existsSync(), isFalse);
  });

  test('reports an API failure', () async {
    final j = job(
      (req) => _json({
        'error': {'message': 'model not found'},
      }, 404),
    );
    await j.run();

    expect(j.state, JobState.failed);
    expect(j.error, 'model not found');
  });

  test('cancel ends the run without writing', () async {
    final generating = Completer<void>();
    final release = Completer<http.Response>();
    final j = job((req) {
      generating.complete();
      return release.future;
    });
    final run = j.run();
    await generating.future;
    j.cancel();
    release.completeError(http.ClientException('connection closed'));
    await run;

    expect(j.state, JobState.cancelled);
    expect(library.sidecarDir(recording.file).existsSync(), isFalse);
  });
}
