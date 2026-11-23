import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:transcripts/anthropic.dart';

const _base = 'https://anthropic.test';

AnthropicClient _client(MockClientHandler handler) {
  return AnthropicClient(
    apiKey: 'test-key',
    client: MockClient(handler),
    baseUrl: _base,
  );
}

http.Response _json(Object body, [int status = 200]) {
  return http.Response.bytes(utf8.encode(jsonEncode(body)), status);
}

http.Response _sse(List<Map<String, Object?>> events) {
  final body = events
      .map((e) => 'event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n')
      .join();
  return http.Response.bytes(utf8.encode(body), 200);
}

Map<String, Object?> _text(String text) => {
  'type': 'content_block_delta',
  'index': 0,
  'delta': {'type': 'text_delta', 'text': text},
};

Map<String, Object?> _stop(String reason) => {
  'type': 'message_delta',
  'delta': {'stop_reason': reason},
};

void main() {
  test('listModels returns the model ids', () async {
    late http.Request sent;
    final anthropic = _client((req) async {
      sent = req;
      return _json({
        'data': [
          {'id': 'model-b', 'display_name': 'B'},
          {'id': 'model-a', 'display_name': 'A'},
        ],
      });
    });
    expect(await anthropic.listModels(), ['model-b', 'model-a']);
    expect(sent.url.path, '/v1/models');
    expect(sent.headers['x-api-key'], 'test-key');
    expect(sent.headers['anthropic-version'], isNotEmpty);
  });

  test('generateStream sends system and input, and yields text', () async {
    late Map<String, dynamic> body;
    final anthropic = _client((req) async {
      if (req.method == 'GET') return _json({'max_tokens': 8000});
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return _sse([
        {'type': 'message_start'},
        {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'thinking_delta', 'thinking': 'hidden'},
        },
        _text('Hello '),
        _text('ދިވެހި'),
        _stop('end_turn'),
        {'type': 'message_stop'},
      ]);
    });

    final chunks = await anthropic
        .generateStream(model: 'model-x', system: 'the prompt', input: 'text')
        .toList();

    expect(chunks.join(), 'Hello ދިވެހި');
    expect(body['model'], 'model-x');
    expect(body['stream'], isTrue);
    expect(body['max_tokens'], 8000);
    expect(body['system'], 'the prompt');
    expect(body['messages'], [
      {'role': 'user', 'content': 'text'},
    ]);
  });

  test('generateStream caps max_tokens for large-output models', () async {
    late Map<String, dynamic> body;
    final anthropic = _client((req) async {
      if (req.method == 'GET') return _json({'max_tokens': 128000});
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return _sse([_text('ok'), _stop('end_turn')]);
    });
    await anthropic.generateStream(model: 'm', system: 's', input: 'i').drain();
    expect(body['max_tokens'], 64000);
  });

  test('generateStream fails on refusal, truncation and errors', () async {
    Future<void> expectFailure(
      http.Response response,
      String messagePart,
    ) async {
      final anthropic = _client((req) async {
        if (req.method == 'GET') return _json({'max_tokens': 8000});
        return response;
      });
      await expectLater(
        anthropic.generateStream(model: 'm', system: 's', input: 'i').toList(),
        throwsA(
          isA<AnthropicException>().having(
            (e) => e.message,
            'message',
            contains(messagePart),
          ),
        ),
      );
    }

    await expectFailure(_sse([_stop('refusal')]), 'declined');
    await expectFailure(_sse([_text('part'), _stop('max_tokens')]), 'cut off');
    await expectFailure(
      _sse([
        {
          'type': 'error',
          'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
        },
      ]),
      'Overloaded',
    );
    await expectFailure(
      _json({
        'type': 'error',
        'error': {
          'type': 'authentication_error',
          'message': 'invalid x-api-key',
        },
      }, 401),
      'invalid x-api-key',
    );
  });
}
