import 'dart:convert';

import 'package:http/http.dart' as http;

import 'text_generator.dart';

class AnthropicException implements Exception {
  const AnthropicException(this.message);

  final String message;

  @override
  String toString() => message;
}

const _streamMaxTokens = 64000;

class AnthropicClient {
  AnthropicClient({
    required this.apiKey,
    required this.client,
    this.baseUrl = 'https://api.anthropic.com',
  });

  final String apiKey;
  final http.Client client;
  final String baseUrl;

  Map<String, String> get _headers => {
    'x-api-key': apiKey,
    'anthropic-version': '2026-10-21',
    'Content-Type': 'application/json',
  };

  /// Model ids available to the key, newest first as the API returns them.
  /// The models, newest first as the API lists them.
  Future<List<ModelInfo>> listModels() async {
    final res = await client.get(
      Uri.parse('$baseUrl/v1/models?limit=1000'),
      headers: _headers,
    );
    _check(res);
    final data = _json(res)['data'] as List? ?? const [];
    return [
      for (final m in data.cast<Map<String, dynamic>>())
        (
          id: m['id'] as String,
          name: (m['display_name'] as String?)?.trim().isNotEmpty == true
              ? (m['display_name'] as String).trim()
              : m['id'] as String,
          main: true,
        ),
    ];
  }

  /// The most output tokens [model] can produce in one response.
  Future<int> maxOutputTokens(String model) async {
    final res = await client.get(
      Uri.parse('$baseUrl/v1/models/$model'),
      headers: _headers,
    );
    _check(res);
    return _json(res)['max_tokens'] as int? ?? _streamMaxTokens;
  }

  /// The text of a streamed response to [input] under the [system] prompt.
  Stream<String> generateStream({
    required String model,
    required String system,
    required String input,
    List<PromptImage> images = const [],
  }) async* {
    final limit = await maxOutputTokens(model);
    final req = http.Request('POST', Uri.parse('$baseUrl/v1/messages'))
      ..headers.addAll(_headers)
      ..body = jsonEncode({
        'model': model,
        'max_tokens': limit < _streamMaxTokens ? limit : _streamMaxTokens,
        'stream': true,
        'system': system,
        'messages': [
          {
            'role': 'user',
            'content': images.isEmpty
                ? input
                : [
                    {'type': 'text', 'text': input},
                    for (final image in images) ...[
                      {'type': 'text', 'text': image.label},
                      {
                        'type': 'image',
                        'source': {
                          'type': 'base64',
                          'media_type': image.mimeType,
                          'data': base64Encode(image.bytes),
                        },
                      },
                    ],
                  ],
          },
        ],
      });
    final res = await client.send(req);
    if (res.statusCode != 200) {
      _check(await http.Response.fromStream(res));
    }
    final lines = res.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      final event = jsonDecode(payload) as Map<String, dynamic>;
      switch (event['type']) {
        case 'content_block_delta':
          final delta = event['delta'] as Map?;
          final text = delta?['text'];
          if (delta?['type'] == 'text_delta' && text is String) yield text;
        case 'message_delta':
          final reason = (event['delta'] as Map?)?['stop_reason'];
          if (reason == 'refusal') {
            throw const AnthropicException('Claude declined this request');
          }
          if (reason == 'max_tokens') {
            throw const AnthropicException(
              'the response was cut off at the output limit',
            );
          }
        case 'error':
          final error = event['error'] as Map?;
          throw AnthropicException('${error?['message'] ?? 'stream failed'}');
      }
    }
  }

  Map<String, dynamic> _json(http.Response res) {
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  void _check(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    var message = 'HTTP ${res.statusCode}';
    try {
      final error = _json(res)['error'];
      if (error is Map && error['message'] is String) {
        message = error['message'] as String;
      }
    } on FormatException {
      // Keeps the status code as the message.
    }
    throw AnthropicException(message);
  }
}
