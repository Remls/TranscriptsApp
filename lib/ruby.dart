/// A run of text, with the reading shown above it when [reading] is set.
typedef RubySegment = ({String base, String? reading});

/// Kanji, including the iteration and abbreviation marks used with them.
final _kanji = RegExp(r'[㐀-䶿一-鿿豈-﫿々〆ヶ]');

/// A reading in Aozora Bunko notation: `｜漢字《かんじ》`. The `｜` may be
/// left out when the base is the kanji right before `《`.
final _ruby = RegExp(r'｜([^｜《》]+)《([^《》]*)》|《([^《》]*)》');

/// [text] split into plain runs and runs with readings.
List<RubySegment> parseRuby(String text) {
  final segments = <RubySegment>[];
  var plain = StringBuffer();
  var last = 0;

  void flush() {
    if (plain.isNotEmpty) segments.add((base: plain.toString(), reading: null));
    plain = StringBuffer();
  }

  for (final m in _ruby.allMatches(text)) {
    plain.write(text.substring(last, m.start));
    last = m.end;
    final marked = m.group(1);
    if (marked != null) {
      flush();
      segments.addAll(_trimmed(marked, _reading(m.group(2)!)));
      continue;
    }
    final before = plain.toString();
    var cut = before.length;
    while (cut > 0 && _kanji.hasMatch(before[cut - 1])) {
      cut--;
    }
    if (cut == before.length) continue;
    plain = StringBuffer(before.substring(0, cut));
    flush();
    segments.add((base: before.substring(cut), reading: _reading(m.group(3)!)));
  }
  plain.write(text.substring(last));
  flush();
  return segments;
}

/// [base] with [reading], with the kana they share at either end split off
/// as plain runs, so the reading sits over the kanji only.
List<RubySegment> _trimmed(String base, String? reading) {
  if (reading == null) return [(base: base, reading: null)];
  var head = 0;
  while (head < base.length - 1 &&
      head < reading.length - 1 &&
      base[head] == reading[head] &&
      !_kanji.hasMatch(base[head])) {
    head++;
  }
  var tail = 0;
  while (tail < base.length - head - 1 &&
      tail < reading.length - head - 1 &&
      base[base.length - 1 - tail] == reading[reading.length - 1 - tail] &&
      !_kanji.hasMatch(base[base.length - 1 - tail])) {
    tail++;
  }
  return [
    if (head > 0) (base: base.substring(0, head), reading: null),
    (
      base: base.substring(head, base.length - tail),
      reading: reading.substring(head, reading.length - tail),
    ),
    if (tail > 0) (base: base.substring(base.length - tail), reading: null),
  ];
}

String? _reading(String raw) {
  final reading = raw.trim();
  return reading.isEmpty ? null : reading;
}

/// [text] without its readings and their marks.
String stripRuby(String text) =>
    parseRuby(text).map((segment) => segment.base).join();

/// Whether [text] has any readings.
bool hasRuby(String text) => text.contains('《');

/// [marked] when it is [plain] with readings added, else null.
String? withReadings(String plain, String? marked) =>
    marked != null && hasRuby(marked) && stripRuby(marked) == plain
    ? marked
    : null;
