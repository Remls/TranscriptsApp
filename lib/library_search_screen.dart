import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'languages.dart';
import 'library_search.dart';
import 'search.dart';
import 'srt.dart';

/// A library search hit the user picked, with the query that found it.
typedef PickedHit = ({LibraryHit hit, String query});

/// Searches every recording's transcript, translation and notes. Pops with
/// the [PickedHit] the user taps.
class LibrarySearchScreen extends StatefulWidget {
  const LibrarySearchScreen({
    super.key,
    required this.rootPath,
    required this.languageOf,
    this.search = searchLibraryInBackground,
  });

  final String rootPath;
  final Language Function(String code) languageOf;
  final Future<LibrarySearchResult> Function(String rootPath, String query)
  search;

  @override
  State<LibrarySearchScreen> createState() => _LibrarySearchScreenState();
}

class _LibrarySearchScreenState extends State<LibrarySearchScreen> {
  final _field = TextEditingController();
  Timer? _debounce;
  String _query = '';
  LibrarySearchResult? _result;
  bool _running = false;
  int _generation = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _run(text));
  }

  Future<void> _run(String text) async {
    _debounce?.cancel();
    final generation = ++_generation;
    setState(() {
      _query = text;
      _running = text.trim().isNotEmpty;
      if (!_running) _result = null;
    });
    if (!_running) return;
    final result = await widget.search(widget.rootPath, text);
    if (!mounted || generation != _generation) return;
    setState(() {
      _result = result;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _field,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: _run,
          decoration: const InputDecoration(
            hintText: 'Search all recordings',
            border: InputBorder.none,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: _running
              ? const LinearProgressIndicator()
              : const SizedBox(height: 4),
        ),
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final result = _result;
    if (result == null) {
      return _Message(
        _running
            ? ''
            : 'Searches the transcripts, translations and notes of every '
                  'recording.',
      );
    }
    if (result.hits.isEmpty) return const _Message('No matches');

    final groups = <String, List<LibraryHit>>{};
    for (final hit in result.hits) {
      (groups[hit.relPath] ??= []).add(hit);
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (final MapEntry(key: relPath, value: hits) in groups.entries) ...[
          _GroupHeader(relPath: relPath, count: hits.length),
          for (final line in _byLine(hits))
            _HitTile(
              hits: line,
              language: widget.languageOf(line.first.lang),
              onTap: () => Navigator.pop<PickedHit>(context, (
                hit: line.first,
                query: _query,
              )),
            ),
        ],
        if (result.capped)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Showing the first ${result.hits.length} matches. Search for '
              'something longer to narrow them down.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// [hits] in runs that share one line or note.
List<List<LibraryHit>> _byLine(List<LibraryHit> hits) {
  final lines = <List<LibraryHit>>[];
  for (final hit in hits) {
    final last = lines.isEmpty ? null : lines.last.first;
    if (last != null &&
        last.source == hit.source &&
        last.cue == hit.cue &&
        last.item == hit.item &&
        last.noteId == hit.noteId) {
      lines.last.add(hit);
    } else {
      lines.add([hit]);
    }
  }
  return lines;
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: .center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.relPath, required this.count});

  final String relPath;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (folder, name) = recordingTitle(relPath);
    return Container(
      color: theme.colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        crossAxisAlignment: .baseline,
        textBaseline: .alphabetic,
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$folder / ',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  TextSpan(text: name),
                ],
              ),
              maxLines: 1,
              overflow: .ellipsis,
              style: theme.textTheme.titleSmall,
            ),
          ),
          Text(
            '$count',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _HitTile extends StatelessWidget {
  const _HitTile({
    required this.hits,
    required this.language,
    required this.onTap,
  });

  /// The matches in one line or note, in order.
  final List<LibraryHit> hits;
  final Language language;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hit = hits.first;
    final (text, start, _) = snippet(hit.text, hit.start, hits.last.end);
    final shift = start - hit.start;
    final spans = <TextSpan>[];
    var at = 0;
    for (final h in hits) {
      spans
        ..add(TextSpan(text: text.substring(at, h.start + shift)))
        ..add(
          TextSpan(
            text: text.substring(h.start + shift, h.end + shift),
            style: const TextStyle(backgroundColor: matchColor),
          ),
        );
      at = h.end + shift;
    }
    spans.add(TextSpan(text: text.substring(at)));
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: .start,
          children: [
            Text(
              '${hit.source.label}, ${formatClock(hit.time)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            SizedBox(
              width: double.infinity,
              child: Text.rich(
                TextSpan(children: spans),
                textDirection: language.rtl ? .rtl : .ltr,
                textScaler: TextScaler.linear(language.textScale),
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
