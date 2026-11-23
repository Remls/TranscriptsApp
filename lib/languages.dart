import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class Language {
  const Language({
    required this.code,
    required this.name,
    required this.script,
    this.rtl = false,
    this.textScale = 1.0,
    this.notes = '',
  });

  /// A recording whose language code is missing from the list.
  const Language.unknown(this.code)
    : name = 'Unknown language ($code)',
      script = '',
      rtl = false,
      textScale = 1.0,
      notes = '';

  factory Language.fromJson(Map<String, Object?> json) {
    return Language(
      code: json['code'] as String,
      name: json['name'] as String,
      script: json['script'] as String,
      rtl: json['rtl'] as bool? ?? false,
      textScale: (json['textScale'] as num?)?.toDouble() ?? 1.0,
      notes: json['notes'] as String? ?? '',
    );
  }

  final String code;
  final String name;
  final String script;
  final bool rtl;

  /// Size multiplier for transcript text in this language's script.
  final double textScale;

  /// Points for the transcription prompt, one per line.
  final String notes;

  Map<String, Object?> toJson() => {
    'code': code,
    'name': name,
    'script': script,
    'rtl': rtl,
    'textScale': textScale,
    'notes': notes,
  };
}

const defaultLang = 'dv';

/// The language list's file name at the library root.
const languageListFile = '.languages.json';

/// Codes that cannot be removed from the list.
const fixedLangs = {'dv', 'en'};

final _codePattern = RegExp(r'^[a-z]{2,}$');

bool isValidLangCode(String code) => _codePattern.hasMatch(code);

final _rtlLetter = RegExp(
  r'[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFF\u{10800}-\u{10FFF}\u{1E800}-\u{1EFFF}]',
  unicode: true,
);
final _letter = RegExp(r'\p{L}', unicode: true);

/// Whether [text] reads right to left in a view whose direction is [rtl]. A
/// line keeps the view's direction unless it has no letters in that
/// direction and some in the other.
bool lineIsRtl(String text, {required bool rtl}) {
  final hasRtl = _rtlLetter.hasMatch(text);
  final hasLtr = _letter.hasMatch(text.replaceAll(_rtlLetter, ''));
  return rtl ? hasRtl || !hasLtr : hasRtl && !hasLtr;
}

const defaultLanguages = [
  Language(
    code: 'dv',
    name: 'Dhivehi',
    script: 'Thaana',
    rtl: true,
    textScale: 1.15,
    notes:
        'This audio is in DHIVEHI (also called Maldivian, ISO code: dv), the '
        'language of the Maldives. It is NOT Sinhala (Sri Lankan).\n'
        'Dhivehi uses the Thaana script (e.g. ދިވެހި, އަޅުގަނޑު, ވަރަށް, '
        'ހުރިހާ). Thaana letters look like ހ ށ ނ ރ ބ ޅ ކ އ ވ މ ފ ދ ތ ލ ގ ޏ ސ ޑ '
        'ޒ ޓ ޔ ޕ ޖ ޗ ޘ ޙ ޚ ޛ ޜ ޝ ޞ ޟ ޠ ޡ ޢ ޣ ޤ ޥ.\n'
        'Do NOT output Sinhala script (e.g. ක ග ට ද න ම ය ර ල ව ස හ ඈ ඉ උ එ ඔ '
        '— these are WRONG). If you produce Sinhala characters anywhere, you '
        'have made an error.',
  ),
  Language(
    code: 'ja',
    name: 'Japanese',
    script: 'Japanese (kanji + hiragana/katakana)',
  ),
  Language(code: 'ko', name: 'Korean', script: 'Hangul'),
  Language(code: 'hi', name: 'Hindi', script: 'Devanagari'),
  Language(code: 'en', name: 'English', script: 'Latin'),
];

/// The languages recordings can be transcribed in, kept in a file at the
/// library root. Holds [defaultLanguages] until first changed.
class LanguageList extends ChangeNotifier {
  LanguageList(Directory root)
    : _file = File(p.join(root.path, languageListFile)) {
    _all = _read() ?? List.of(defaultLanguages);
  }

  final File _file;
  late List<Language> _all;

  List<Language> get all => List.unmodifiable(_all);

  Language? operator [](String code) {
    for (final l in _all) {
      if (l.code == code) return l;
    }
    return null;
  }

  bool contains(String code) => this[code] != null;

  /// The entry for [code], or [Language.unknown] when it is not in the list.
  Language resolve(String code) => this[code] ?? Language.unknown(code);

  /// Adds [language], or replaces the entry with its code.
  void put(Language language) {
    final i = _all.indexWhere((l) => l.code == language.code);
    if (i < 0) {
      _all.add(language);
    } else {
      _all[i] = language;
    }
    _save();
  }

  void remove(String code) {
    if (fixedLangs.contains(code)) return;
    _all.removeWhere((l) => l.code == code);
    _save();
  }

  /// The entries for [codes] that the list has, as the JSON of a list file.
  String jsonFor(Iterable<String> codes) {
    final wanted = codes.toSet();
    return _encode([
      for (final l in _all)
        if (wanted.contains(l.code)) l,
    ]);
  }

  /// Adds the entries of the list file [json] that this list lacks. A list
  /// that has never been changed takes every incoming entry instead. Returns
  /// how many entries were added or replaced.
  int merge(String json) {
    final incoming = _parse(json, addFixed: false);
    if (incoming == null || incoming.isEmpty) return 0;
    final fresh = !_file.existsSync();
    var changed = 0;
    for (final l in incoming) {
      final i = _all.indexWhere((e) => e.code == l.code);
      if (i < 0) {
        _all.add(l);
        changed++;
      } else if (fresh) {
        _all[i] = l;
        changed++;
      }
    }
    if (changed > 0) _save();
    return changed;
  }

  List<Language>? _read() =>
      _file.existsSync() ? _parse(_file.readAsStringSync()) : null;

  static String _encode(List<Language> list) =>
      const JsonEncoder.withIndent('  ')
          .convert([for (final l in list) l.toJson()]);

  List<Language>? _parse(String json, {bool addFixed = true}) {
    try {
      final data = jsonDecode(json);
      if (data is! List) return null;
      final list = [
        for (final e in data) Language.fromJson(e as Map<String, Object?>),
      ];
      for (final code in addFixed ? fixedLangs : const <String>{}) {
        if (!list.any((l) => l.code == code)) {
          list.add(defaultLanguages.firstWhere((l) => l.code == code));
        }
      }
      return list;
    } on Object {
      return null;
    }
  }

  void _save() {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(_encode(_all));
    notifyListeners();
  }
}
