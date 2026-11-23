import 'package:transcripts/languages.dart';

/// The shipped entry for [code].
Language shipped(String code) =>
    defaultLanguages.firstWhere((l) => l.code == code);
