import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'gemini.dart';
import 'search.dart';
import 'srt.dart';

/// A language found by a lookup, to fill in the add form.
class LanguageSuggestion {
  const LanguageSuggestion({
    required this.code,
    required this.name,
    required this.script,
    required this.rtl,
    this.native = '',
  });

  factory LanguageSuggestion.fromJson(Map<String, Object?> json) {
    return LanguageSuggestion(
      code: json['code'] as String,
      name: json['name'] as String,
      native: json['native'] as String? ?? '',
      script: json['script'] as String,
      rtl: json['rtl'] as bool? ?? false,
    );
  }

  final String code;
  final String name;

  /// The language's name for itself.
  final String native;
  final String script;
  final bool rtl;
}

/// The languages in the bundled CLDR table.
class LanguageCatalog {
  LanguageCatalog(this.entries);

  factory LanguageCatalog.parse(String json) {
    return LanguageCatalog([
      for (final e in jsonDecode(json) as List)
        LanguageSuggestion.fromJson(e as Map<String, Object?>),
    ]);
  }

  static Future<LanguageCatalog> load() async => LanguageCatalog.parse(
    await rootBundle.loadString('assets/languages.json'),
  );

  final List<LanguageSuggestion> entries;

  /// Up to [limit] entries whose name, own name or code matches [query],
  /// best matches first.
  List<LanguageSuggestion> search(String query, {int limit = 6}) {
    final q = foldForSearch(query.trim());
    if (q.isEmpty) return const [];
    int? rank(LanguageSuggestion e) {
      final name = foldForSearch(e.name);
      final native = foldForSearch(e.native);
      if (e.code == q || name == q || native == q) return 0;
      if (name.startsWith(q)) return 1;
      if (native.startsWith(q)) return 2;
      if (name.split(RegExp(r'[\s(]+')).any((w) => w.startsWith(q))) return 3;
      if (name.contains(q) || native.contains(q)) return 4;
      return null;
    }

    final ranked =
        [
          for (final e in entries)
            if (rank(e) case final r?) (r, e),
        ]..sort((a, b) {
          final byRank = a.$1.compareTo(b.$1);
          return byRank != 0 ? byRank : a.$2.name.length - b.$2.name.length;
        });
    return [for (final (_, e) in ranked.take(limit)) e];
  }
}

/// A lookup that could not finish, with a message for the user.
class LookupException implements Exception {
  const LookupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Where the add form looks languages up: the bundled table, and Gemini for
/// names the table does not have.
class LanguageLookup {
  LanguageLookup({required this.catalog, required this.askGemini});

  final Future<LanguageCatalog> catalog;

  /// Asks Gemini for the language called [name]. Throws [LookupException].
  final Future<LanguageSuggestion> Function(String name) askGemini;
}

String languagePrompt(String name) =>
    '''Identify the spoken language called "$name".
Reply with only a JSON object, no code fences or commentary:
{"code": "...", "name": "...", "script": "...", "rtl": false}
- code: its ISO 639-1 code if it has one, else its ISO 639-3 code. Lowercase letters only.
- name: its usual English name.
- script: the name of the writing system it is most commonly written in.
- rtl: true if that writing system runs right to left.
If "$name" is not a language, reply {"error": "unknown"}.''';

/// Asks Gemini [model] for the language called [name].
Future<LanguageSuggestion> askGeminiForLanguage(
  http.Client client, {
  required String apiKey,
  required String model,
  required String name,
}) async {
  final String reply;
  try {
    reply =
        (await GeminiClient(apiKey: apiKey, client: client)
                .generateStream(model: model, prompt: languagePrompt(name))
                .toList())
            .join();
  } on GeminiException catch (e) {
    throw LookupException('Gemini could not look it up: ${e.message}');
  }
  try {
    final data = jsonDecode(stripCodeFence(reply.trim()));
    if (data is Map<String, Object?> && data['code'] is String) {
      return LanguageSuggestion(
        code: (data['code'] as String).trim().toLowerCase(),
        name: (data['name'] as String?)?.trim() ?? name,
        script: (data['script'] as String?)?.trim() ?? '',
        rtl: data['rtl'] == true,
      );
    }
  } on FormatException {
    // Falls through to the message below.
  }
  throw LookupException('Gemini does not know a language called "$name"');
}
