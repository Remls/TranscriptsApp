import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:transcripts/gemini.dart';

const _base = 'https://gemini.test';

GeminiClient _client(MockClientHandler handler) {
  return GeminiClient(
    apiKey: 'test-key',
    client: MockClient(handler),
    baseUrl: _base,
  );
}

http.Response _jsonResponse(Object body, [int status = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

String _sse(List<Object> events) {
  return events.map((e) => 'data: ${jsonEncode(e)}\n\n').join();
}

Map<String, Object> _textEvent(List<Map<String, Object>> parts) {
  return {
    'candidates': [
      {
        'content': {'parts': parts},
      },
    ],
  };
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('gemini_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('upload starts a resumable session, then sends the bytes', () async {
    final file = File('${tmp.path}/a.mp3')..writeAsBytesSync([1, 2, 3, 4, 5]);
    final requests = <http.Request>[];
    final progress = <double>[];
    final gemini = _client((req) async {
      requests.add(req);
      if (req.url.path == '/upload/v1beta/files') {
        return http.Response(
          '{}',
          200,
          headers: {'x-goog-upload-url': '$_base/session/1'},
        );
      }
      return _jsonResponse({
        'file': {
          'name': 'files/abc',
          'uri': '$_base/v1beta/files/abc',
          'mimeType': 'audio/mpeg',
          'state': 'PROCESSING',
        },
      });
    });

    final uploaded = await gemini.upload(
      file,
      'audio/mpeg',
      onProgress: progress.add,
    );

    expect(requests[0].headers['x-goog-api-key'], 'test-key');
    expect(requests[0].headers['X-Goog-Upload-Command'], 'start');
    expect(requests[0].headers['X-Goog-Upload-Header-Content-Length'], '5');
    expect(
      requests[0].headers['X-Goog-Upload-Header-Content-Type'],
      'audio/mpeg',
    );
    expect(requests[1].url.toString(), '$_base/session/1');
    expect(requests[1].headers['X-Goog-Upload-Command'], 'upload, finalize');
    expect(requests[1].bodyBytes, [1, 2, 3, 4, 5]);
    expect(progress.last, 1.0);
    expect(uploaded.name, 'files/abc');
    expect(uploaded.state, 'PROCESSING');
  });

  test('upload reports the API error message', () async {
    final file = File('${tmp.path}/a.mp3')..writeAsBytesSync([1]);
    final gemini = _client(
      (req) async => _jsonResponse({
        'error': {'message': 'API key not valid'},
      }, 400),
    );
    expect(
      () => gemini.upload(file, 'audio/mpeg'),
      throwsA(
        isA<GeminiException>().having(
          (e) => e.message,
          'message',
          'API key not valid',
        ),
      ),
    );
  });

  test('waitUntilActive polls until the file is ready', () async {
    var polls = 0;
    final gemini = _client((req) async {
      polls++;
      return _jsonResponse({
        'name': 'files/abc',
        'uri': 'u',
        'mimeType': 'audio/mpeg',
        'state': polls < 3 ? 'PROCESSING' : 'ACTIVE',
      });
    });
    final ready = await gemini.waitUntilActive(
      const GeminiFile(
        name: 'files/abc',
        uri: 'u',
        mimeType: 'audio/mpeg',
        state: 'PROCESSING',
      ),
      interval: Duration.zero,
    );
    expect(ready.state, 'ACTIVE');
    expect(polls, 3);
  });

  test('waitUntilActive fails on any other final state', () async {
    final gemini = _client((req) async => _jsonResponse({}));
    expect(
      () => gemini.waitUntilActive(
        const GeminiFile(name: 'f', uri: 'u', mimeType: 'm', state: 'FAILED'),
      ),
      throwsA(isA<GeminiException>()),
    );
  });

  test('generateStream yields text parts and skips thoughts', () async {
    late http.Request sent;
    final gemini = _client((req) async {
      sent = req;
      return http.Response.bytes(
        utf8.encode(
          _sse([
            _textEvent([
              {'text': 'thinking', 'thought': true},
              {'text': '1\n00:00:01,000 --> '},
            ]),
            {'candidates': <Object>[]},
            _textEvent([
              {'text': '00:00:02,000\nދިވެހި\n'},
            ]),
          ]),
        ),
        200,
      );
    });

    final chunks = await gemini
        .generateStream(
          model: 'model-x',
          prompt: 'the prompt',
          file: const GeminiFile(
            name: 'files/abc',
            uri: 'file-uri',
            mimeType: 'audio/mpeg',
            state: 'ACTIVE',
          ),
        )
        .toList();

    expect(chunks.join(), '1\n00:00:01,000 --> 00:00:02,000\nދިވެހި\n');
    expect(sent.url.path, '/v1beta/models/model-x:streamGenerateContent');
    expect(sent.url.queryParameters, {'alt': 'sse'});
    final parts =
        (jsonDecode(sent.body) as Map)['contents'][0]['parts'] as List;
    expect(parts[0], {'text': 'the prompt'});
    expect(parts[1], {
      'file_data': {'mime_type': 'audio/mpeg', 'file_uri': 'file-uri'},
    });
  });

  test('generateStream fails on an error status or a blocked prompt', () async {
    final denied = _client(
      (req) async => _jsonResponse({
        'error': {'message': 'quota exceeded'},
      }, 429),
    );
    expect(
      denied.generateStream(model: 'm', prompt: 'p').toList(),
      throwsA(
        isA<GeminiException>().having(
          (e) => e.message,
          'message',
          'quota exceeded',
        ),
      ),
    );

    final blocked = _client(
      (req) async => http.Response(
        _sse([
          {
            'promptFeedback': {'blockReason': 'SAFETY'},
          },
        ]),
        200,
      ),
    );
    expect(
      blocked.generateStream(model: 'm', prompt: 'p').toList(),
      throwsA(isA<GeminiException>()),
    );
  });

  test('listModels keeps the models that generate content', () async {
    final gemini = _client(
      (req) async => _jsonResponse({
        'models': [
          {
            'name': 'models/zeta',
            'supportedGenerationMethods': ['generateContent'],
          },
          {
            'name': 'models/embedder',
            'supportedGenerationMethods': ['embedContent'],
          },
          {
            'name': 'models/alpha',
            'supportedGenerationMethods': ['generateContent', 'countTokens'],
          },
        ],
      }),
    );
    expect(await gemini.listModels(), ['alpha', 'zeta']);
  });
}
