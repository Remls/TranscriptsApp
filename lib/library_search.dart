import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'library.dart';
import 'notes.dart';
import 'search.dart';
import 'srt.dart';

/// Where a library search hit was found.
enum HitSource {
  transcript('Transcript'),
  translation('Translation'),
  note('Note');

  const HitSource(this.label);

  final String label;
}

/// One match of a library search: the recording, where in it, and the text
/// it is in with the match's code-unit offsets.
class LibraryHit {
  const LibraryHit({
    required this.relPath,
    required this.lang,
    required this.source,
    required this.time,
    required this.cue,
    required this.item,
    required this.noteId,
    required this.text,
    required this.start,
    required this.end,
  });

  /// The recording's path relative to the library root, with forward
  /// slashes.
  final String relPath;

  /// The language of [text]: the recording's for a transcript line, English
  /// for a translation line or a note.
  final String lang;
  final HitSource source;

  /// Seconds into the recording.
  final double time;
  final int? cue;
  final int? item;
  final String? noteId;
  final String text;
  final int start;
  final int end;
}

class LibrarySearchResult {
  const LibrarySearchResult(this.hits, {required this.capped});

  final List<LibraryHit> hits;

  /// Whether the search stopped at its limit with more hits left.
  final bool capped;
}

/// Every match of [query] in the transcripts, translations and notes of the
/// library at [rootPath], recording by recording, at most [limit].
LibrarySearchResult searchLibrary(
  String rootPath,
  String query, {
  int limit = 500,
}) {
  if (query.trim().isEmpty) {
    return const LibrarySearchResult([], capped: false);
  }
  final library = Library(Directory(rootPath));
  final hits = <LibraryHit>[];
  for (final section in library.scan()) {
    for (final recording in section.recordings) {
      final found = _searchRecording(library, recording, query);
      if (hits.length + found.length > limit) {
        hits.addAll(found.take(limit - hits.length));
        return LibrarySearchResult(hits, capped: true);
      }
      hits.addAll(found);
    }
  }
  return LibrarySearchResult(hits, capped: false);
}

List<LibraryHit> _searchRecording(
  Library library,
  Recording recording,
  String query,
) {
  final hits = <LibraryHit>[];
  void searchCues(Sidecar key, HitSource source, String lang) {
    final file = library.sidecarFile(recording.file, key);
    if (!file.existsSync()) return;
    final cues = parseSrt(file.readAsStringSync());
    for (final m in findMatches(transcriptRows(cues, const []), cues, query)) {
      final cue = cues[m.cue!];
      hits.add(
        LibraryHit(
          relPath: recording.relPath,
          lang: lang,
          source: source,
          time: cue.start,
          cue: m.cue,
          item: m.item,
          noteId: null,
          text: cue.items[m.item!].text,
          start: m.start,
          end: m.end,
        ),
      );
    }
  }

  searchCues(Sidecar.transcriptSrt, HitSource.transcript, recording.lang);
  searchCues(Sidecar.translation, HitSource.translation, 'en');
  final notes = readNotes(library, recording.file);
  final rows = transcriptRows(const [], notes);
  for (final m in findMatches(rows, const [], query)) {
    final note = rows[m.row] as Note;
    hits.add(
      LibraryHit(
        relPath: recording.relPath,
        lang: 'en',
        source: HitSource.note,
        time: note.time,
        cue: null,
        item: null,
        noteId: note.id,
        text: note.text,
        start: m.start,
        end: m.end,
      ),
    );
  }
  return hits;
}

Future<LibrarySearchResult> searchLibraryInBackground(
  String rootPath,
  String query,
) {
  return Isolate.run(() => searchLibrary(rootPath, query));
}

/// Up to [context] characters of [text] on each side of the match from
/// [start] to [end], on one line, with the match's offsets in the result.
/// Cut ends are marked with an ellipsis.
(String, int, int) snippet(
  String text,
  int start,
  int end, {
  int context = 40,
}) {
  final from = (start - context).clamp(0, text.length);
  final to = (end + context).clamp(0, text.length);
  final lead = from > 0 ? '…' : '';
  final body = text.substring(from, to).replaceAll('\n', ' ');
  final tail = to < text.length ? '…' : '';
  final offset = lead.length - from;
  return ('$lead$body$tail', start + offset, end + offset);
}

/// The name of the recording at [relPath] and the folder it is in, or
/// [looseSectionTitle] for a recording at the library root.
(String folder, String name) recordingTitle(String relPath) {
  final dir = p.posix.dirname(relPath);
  return (
    dir == '.' ? looseSectionTitle : dir,
    p.posix.basenameWithoutExtension(relPath),
  );
}
