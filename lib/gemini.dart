import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'text_generator.dart';

class GeminiException implements Exception {
  const GeminiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A file held by the Gemini Files API.
class GeminiFile {
  const GeminiFile({
    required this.name,
    required this.uri,
    required this.mimeType,
    required this.state,
  });

  factory GeminiFile.fromJson(Map<String, dynamic> json) {
    return GeminiFile(
      name: json['name'] as String,
      uri: json['uri'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? '',
      state: json['state'] as String? ?? '',
    );
  }

  final String name;
  final String uri;
  final String mimeType;
  final String state;
}

/// Words in the ids of Gemini models made for something other than
/// transcribing and writing text.
const _specialGeminiWords = [
  'tts',
  'image',
  'live',
  'native-audio',
  'embedding',
  'computer-use',
  'robotics',
  'gemma',
  'aqa',
  'learnlm',
];

final _geminiLine = RegExp(r'^gemini-(\d+(?:\.\d+)?)-(pro|flash-lite|flash)\b');

/// Whether [id] is a Gemini Pro, Flash or Flash-Lite model for general use.
bool isMainGeminiModel(String id) =>
    _geminiLine.hasMatch(id) && !_specialGeminiWords.any(id.contains);

/// Orders models with the main ones first, newest version first, then Pro,
/// Flash and Flash-Lite, then the rest by id.
int compareGeminiModels(ModelInfo a, ModelInfo b) {
  if (a.main != b.main) return a.main ? -1 : 1;
  final x = _geminiLine.firstMatch(a.id);
  final y = _geminiLine.firstMatch(b.id);
  if (x != null && y != null) {
    final byVersion = double.parse(y[1]!).compareTo(double.parse(x[1]!));
    if (byVersion != 0) return byVersion;
    const tiers = ['pro', 'flash', 'flash-lite'];
    final byTier = tiers.indexOf(x[2]!).compareTo(tiers.indexOf(y[2]!));
    if (byTier != 0) return byTier;
  }
  return a.id.compareTo(b.id);
}

class GeminiClient {
  GeminiClient({
    required this.apiKey,
    required this.client,
    this.baseUrl = 'https://generativelanguage.googleapis.com',
  });

  final String apiKey;
  final http.Client client;
  final String baseUrl;

  Map<String, String> get _auth => {'x-goog-api-key': apiKey};

  /// Uploads [file] with the resumable protocol, streaming it from disk.
  /// [onProgress] receives the fraction sent, from 0 to 1.
  Future<GeminiFile> upload(
    File file,
    String mimeType, {
    void Function(double fraction)? onProgress,
  }) async {
    final size = await file.length();
    final start =
        http.Request('POST', Uri.parse('$baseUrl/upload/v1beta/files'))
          ..headers.addAll({
            ..._auth,
            'X-Goog-Upload-Protocol': 'resumable',
            'X-Goog-Upload-Command': 'start',
            'X-Goog-Upload-Header-Content-Length': '$size',
            'X-Goog-Upload-Header-Content-Type': mimeType,
            'Content-Type': 'application/json',
          })
          ..body = '{"file": {}}';
    final startRes = await http.Response.fromStream(await client.send(start));
    _check(startRes);
    final uploadUrl = startRes.headers['x-goog-upload-url'];
    if (uploadUrl == null) {
      throw const GeminiException('upload did not return a session URL');
    }

    final put = http.StreamedRequest('POST', Uri.parse(uploadUrl))
      ..contentLength = size
      ..headers.addAll({
        'X-Goog-Upload-Offset': '0',
        'X-Goog-Upload-Command': 'upload, finalize',
      });
    var sent = 0;
    final body = file.openRead().map((chunk) {
      sent += chunk.length;
      if (size > 0) onProgress?.call(sent / size);
      return chunk;
    });
    unawaited(
      put.sink.addStream(body).then((_) => put.sink.close()).catchError((
        Object e,
      ) {
        put.sink.addError(e);
        put.sink.close();
      }),
    );
    final res = await http.Response.fromStream(await client.send(put));
    _check(res);
    return GeminiFile.fromJson(_json(res)['file'] as Map<String, dynamic>);
  }

  Future<GeminiFile> getFile(String name) async {
    final res = await client.get(
      Uri.parse('$baseUrl/v1beta/$name'),
      headers: _auth,
    );
    _check(res);
    return GeminiFile.fromJson(_json(res));
  }

  /// Polls until the file leaves PROCESSING, and fails unless it is ACTIVE.
  Future<GeminiFile> waitUntilActive(
    GeminiFile file, {
    Duration interval = const Duration(seconds: 2),
  }) async {
    var current = file;
    while (current.state == 'PROCESSING') {
      await Future<void>.delayed(interval);
      current = await getFile(current.name);
    }
    if (current.state != 'ACTIVE') {
      throw GeminiException('file processing failed (state=${current.state})');
    }
    return current;
  }

  Future<void> deleteFile(String name) async {
    _check(
      await client.delete(Uri.parse('$baseUrl/v1beta/$name'), headers: _auth),
    );
  }

  /// The text of a streamed generation, chunk by chunk.
  Stream<String> generateStream({
    required String model,
    required String prompt,
    String? input,
    GeminiFile? file,
    List<PromptImage> images = const [],
  }) async* {
    final req =
        http.Request(
            'POST',
            Uri.parse(
              '$baseUrl/v1beta/models/$model:streamGenerateContent?alt=sse',
            ),
          )
          ..headers.addAll({..._auth, 'Content-Type': 'application/json'})
          ..body = jsonEncode({
            'contents': [
              {
                'role': 'user',
                'parts': [
                  {'text': prompt},
                  if (input != null) {'text': input},
                  for (final image in images) ...[
                    {'text': image.label},
                    {
                      'inline_data': {
                        'mime_type': image.mimeType,
                        'data': base64Encode(image.bytes),
                      },
                    },
                  ],
                  if (file != null)
                    {
                      'file_data': {
                        'mime_type': file.mimeType,
                        'file_uri': file.uri,
                      },
                    },
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
      final error = event['error'];
      if (error is Map) {
        throw GeminiException('${error['message'] ?? 'generation failed'}');
      }
      final blocked = (event['promptFeedback'] as Map?)?['blockReason'];
      if (blocked != null) {
        throw GeminiException('request blocked ($blocked)');
      }
      final candidates = event['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) continue;
      final parts = ((candidates.first as Map)['content'] as Map?)?['parts'];
      if (parts is! List) continue;
      for (final part in parts) {
        if (part is! Map || part['thought'] == true) continue;
        final text = part['text'];
        if (text is String && text.isNotEmpty) yield text;
      }
    }
  }

  /// Names of the models that can generate content, without the "models/"
  /// prefix.
  /// The models that generate content, the main ones first by
  /// [compareGeminiModels].
  Future<List<ModelInfo>> listModels() async {
    final res = await client.get(
      Uri.parse('$baseUrl/v1beta/models?pageSize=1000'),
      headers: _auth,
    );
    _check(res);
    final models = _json(res)['models'] as List? ?? const [];
    return [
      for (final m in models.cast<Map<String, dynamic>>())
        if ((m['supportedGenerationMethods'] as List? ?? const []).contains(
          'generateContent',
        ))
          _info(m),
    ]..sort(compareGeminiModels);
  }

  ModelInfo _info(Map<String, dynamic> m) {
    final id = (m['name'] as String).replaceFirst('models/', '');
    final name = (m['displayName'] as String?)?.trim() ?? '';
    return (
      id: id,
      name: name.isEmpty ? id : name,
      main: isMainGeminiModel(id),
    );
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
    throw GeminiException(message);
  }
}
