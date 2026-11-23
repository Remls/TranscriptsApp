import 'dart:ui';

import 'notes.dart';
import 'srt.dart';

/// One occurrence of the query: in line [item] of cue [cue], or in the text
/// of a note when [cue] is null. [row] is its row in [transcriptRows], and
/// [start] and [end] are code-unit offsets into the text.
class SearchMatch {
  const SearchMatch({
    required this.row,
    required this.cue,
    required this.item,
    required this.start,
    required this.end,
  });

  final int row;
  final int? cue;
  final int? item;
  final int start;
  final int end;
}

/// [text] with case and full-width forms folded, one code unit for one, so
/// offsets into the result are offsets into [text].
String foldForSearch(String text) {
  final units = text.codeUnits;
  final out = List<int>.filled(units.length, 0);
  for (var i = 0; i < units.length; i++) {
    var c = units[i];
    if (c >= 0xFF01 && c <= 0xFF5E) {
      c -= 0xFEE0;
    } else if (c == 0x3000) {
      c = 0x20;
    }
    if (c < 0xD800 || c > 0xDFFF) {
      final lower = String.fromCharCode(c).toLowerCase();
      if (lower.length == 1) c = lower.codeUnitAt(0);
    }
    out[i] = c;
  }
  return String.fromCharCodes(out);
}

/// The query's start and end offsets in [text], without overlaps.
List<(int, int)> _find(String text, String folded) {
  final hay = foldForSearch(text);
  final found = <(int, int)>[];
  var from = 0;
  while (true) {
    final at = hay.indexOf(folded, from);
    if (at < 0) return found;
    found.add((at, at + folded.length));
    from = at + folded.length;
  }
}

/// Every match of [query] in [rows], in reading order. Rows are cue indexes
/// into [cues] and notes, as [transcriptRows] lays them out.
List<SearchMatch> findMatches(List<Object> rows, List<Cue> cues, String query) {
  if (query.trim().isEmpty) return const [];
  final folded = foldForSearch(query);
  final matches = <SearchMatch>[];
  for (final (row, entry) in rows.indexed) {
    if (entry is Note) {
      for (final (start, end) in _find(entry.text, folded)) {
        matches.add(
          SearchMatch(row: row, cue: null, item: null, start: start, end: end),
        );
      }
    } else if (entry is int) {
      for (final (item, line) in cues[entry].items.indexed) {
        for (final (start, end) in _find(line.text, folded)) {
          matches.add(
            SearchMatch(
              row: row,
              cue: entry,
              item: item,
              start: start,
              end: end,
            ),
          );
        }
      }
    }
  }
  return matches;
}

/// The matches of an open search and the index of the current one.
class SearchHighlight {
  const SearchHighlight(this.matches, this.current);

  final List<SearchMatch> matches;
  final int current;

  SearchMatch? get currentMatch =>
      current >= 0 && current < matches.length ? matches[current] : null;
}

/// The background of a search match, and of the current one.
const matchColor = Color(0x66FFD54F);
const currentMatchColor = Color(0xFFFFB300);
