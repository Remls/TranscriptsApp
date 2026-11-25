final _dateSuffix = RegExp(r'^\d{8}$');
final _number = RegExp(r'^\d+$');

/// A readable name for the model [id]: words capitalized, version numbers
/// joined with dots, and a release date left out. `gemini-3.8-flash-lite`
/// becomes "Gemini 3.8 Flash-Lite" and `claude-opus-5-5` "Claude Opus 5.5".
String modelDisplayName(String id) {
  final words = <String>[];
  final parts = id.split('-');
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    if (part.isEmpty || _dateSuffix.hasMatch(part)) continue;
    if (_number.hasMatch(part) &&
        words.isNotEmpty &&
        _number.hasMatch(parts[i - 1]) &&
        !_dateSuffix.hasMatch(parts[i - 1])) {
      words.last = '${words.last}.$part';
      continue;
    }
    if (part == 'lite' && words.isNotEmpty) {
      words.last = '${words.last}-Lite';
      continue;
    }
    words.add(
      RegExp(r'^[a-z]').hasMatch(part)
          ? '${part[0].toUpperCase()}${part.substring(1)}'
          : part,
    );
  }
  return words.isEmpty ? id : words.join(' ');
}
