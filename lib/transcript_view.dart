import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'languages.dart';
import 'notes.dart';
import 'search.dart';
import 'srt.dart';

const _speakerColors = [
  Color(0xFFEF5350),
  Color(0xFF42A5F5),
  Color(0xFF66BB6A),
  Color(0xFFFFA726),
  Color(0xFFAB47BC),
  Color(0xFF26C6DA),
  Color(0xFFEC407A),
  Color(0xFF9CCC65),
];

Color speakerColor(String speaker) {
  final n = int.tryParse(speaker) ?? 1;
  return _speakerColors[(n - 1).clamp(0, 1 << 30) % _speakerColors.length];
}

/// The cue list. Follows the active cue until the user scrolls away, then
/// offers a button to jump back.
class TranscriptView extends StatefulWidget {
  const TranscriptView({
    super.key,
    required this.cues,
    required this.notes,
    required this.language,
    required this.speakerNames,
    required this.speakerOverrides,
    required this.activeIndex,
    required this.onSeek,
    required this.onLineLongPress,
    required this.onNoteTap,
    required this.noteImage,
    required this.onPictureTap,
    this.search,
  });

  final List<Cue> cues;

  /// The user's notes, shown between the cues at their times.
  final List<Note> notes;
  final Language language;
  final Map<String, String> speakerNames;

  /// Speaker ids keyed by "cueIndex:itemIndex", replacing the SRT's own label.
  final Map<String, String> speakerOverrides;
  final ValueListenable<int> activeIndex;
  final ValueChanged<double> onSeek;

  /// Called with the cue index and the line's index within the cue.
  final void Function(int cue, int item) onLineLongPress;
  final ValueChanged<Note> onNoteTap;

  /// The picture attached to a note, if it has one.
  final File? Function(Note note) noteImage;
  final ValueChanged<File> onPictureTap;

  /// The open search, or null when none is open. While one is open the list
  /// shows the current match instead of following playback.
  final SearchHighlight? search;

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<TranscriptView> {
  final _scroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  bool _userScrolled = false;

  /// The list's rows: cue indexes and notes, in reading order.
  late List<Object> _rows;

  /// The row each cue is on.
  late List<int> _rowOfCue;

  /// The row that was active when the list was first built, or 0.
  late final int _initialIndex;

  void _layOutRows() {
    _rows = transcriptRows(widget.cues, widget.notes);
    _rowOfCue = List.filled(widget.cues.length, 0);
    for (final (row, entry) in _rows.indexed) {
      if (entry is int) _rowOfCue[entry] = row;
    }
  }

  /// The row of the active cue, or -1.
  int get _activeRow {
    final active = widget.activeIndex.value;
    return active >= 0 && active < _rowOfCue.length ? _rowOfCue[active] : -1;
  }

  @override
  void initState() {
    super.initState();
    _layOutRows();
    _initialIndex =
        widget.search?.currentMatch?.row ?? (_activeRow > 0 ? _activeRow : 0);
    widget.activeIndex.addListener(_onActiveChanged);
  }

  @override
  void didUpdateWidget(TranscriptView old) {
    super.didUpdateWidget(old);
    if (old.cues != widget.cues || old.notes != widget.notes) _layOutRows();
    if (old.activeIndex != widget.activeIndex) {
      old.activeIndex.removeListener(_onActiveChanged);
      widget.activeIndex.addListener(_onActiveChanged);
    }
    final match = widget.search?.currentMatch;
    final before = old.search?.currentMatch;
    if (match != null &&
        (before == null ||
            match.row != before.row ||
            match.item != before.item ||
            match.start != before.start)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(match.row));
    } else if (old.search != null && widget.search == null) {
      _userScrolled = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToCurrent());
    }
  }

  @override
  void dispose() {
    widget.activeIndex.removeListener(_onActiveChanged);
    super.dispose();
  }

  bool _isFullyVisible(int index) {
    return _positions.itemPositions.value.any(
      (p) =>
          p.index == index && p.itemLeadingEdge >= 0 && p.itemTrailingEdge <= 1,
    );
  }

  /// Whether the active cue is off-screen above the visible cues (true) or
  /// below them (false). Null when there is no active cue or any part of it
  /// is on screen.
  bool? _activeIsAbove() {
    final active = _activeRow;
    if (active < 0) return null;
    final visible = [
      for (final p in _positions.itemPositions.value)
        if (p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1) p.index,
    ];
    if (visible.isEmpty || visible.contains(active)) return null;
    return active < visible.reduce((a, b) => a < b ? a : b);
  }

  void _scrollTo(int index) {
    if (!_scroll.isAttached) return;
    _scroll.scrollTo(
      index: index,
      alignment: 0.35,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _onActiveChanged() {
    if (widget.search != null) return;
    final index = _activeRow;
    if (index < 0) return;
    if (!_userScrolled) {
      _scrollTo(index);
    } else if (_isFullyVisible(index)) {
      setState(() => _userScrolled = false);
    }
  }

  void _jumpToCurrent() {
    setState(() => _userScrolled = false);
    final index = _activeRow;
    if (index >= 0) _scrollTo(index);
  }

  @override
  Widget build(BuildContext context) {
    final language = widget.language;
    final search = widget.search;
    final highlights = <int, List<_Highlight>>{};
    if (search != null) {
      for (final (i, m) in search.matches.indexed) {
        (highlights[m.row] ??= []).add((
          item: m.item,
          start: m.start,
          end: m.end,
          current: i == search.current,
        ));
      }
    }
    return Stack(
      children: [
        NotificationListener<UserScrollNotification>(
          onNotification: (n) {
            if (n.direction != ScrollDirection.idle && !_userScrolled) {
              setState(() => _userScrolled = true);
            }
            return false;
          },
          child: Directionality(
            textDirection: language.rtl ? .rtl : .ltr,
            child: ValueListenableBuilder<int>(
              valueListenable: widget.activeIndex,
              builder: (context, active, _) {
                return ScrollablePositionedList.builder(
                  itemScrollController: _scroll,
                  itemPositionsListener: _positions,
                  initialScrollIndex: _initialIndex,
                  initialAlignment: _initialIndex > 0 ? 0.35 : 0,
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
                  itemCount: _rows.length,
                  itemBuilder: (context, row) {
                    final entry = _rows[row];
                    if (entry is Note) {
                      return _NoteTile(
                        note: entry,
                        picture: widget.noteImage(entry),
                        highlights: highlights[row] ?? const [],
                        onTap: () => widget.onNoteTap(entry),
                        onPictureTap: widget.onPictureTap,
                      );
                    }
                    final i = entry as int;
                    return _CueTile(
                      cue: widget.cues[i],
                      index: i,
                      active: i == active,
                      highlights: highlights[row] ?? const [],
                      textScale: language.textScale,
                      speakerNames: widget.speakerNames,
                      speakerOverrides: widget.speakerOverrides,
                      onTap: () => widget.onSeek(widget.cues[i].start),
                      onLineLongPress: (item) =>
                          widget.onLineLongPress(i, item),
                    );
                  },
                );
              },
            ),
          ),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([
            widget.activeIndex,
            _positions.itemPositions,
          ]),
          builder: (context, _) {
            final above = _activeIsAbove();
            if (!_userScrolled || above == null || widget.search != null) {
              return const SizedBox.shrink();
            }
            return Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                child: FilledButton.tonalIcon(
                  onPressed: _jumpToCurrent,
                  icon: Icon(
                    above ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 18,
                  ),
                  label: const Text('Jump to current'),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// A search match within a row: the line it is on (null for a note's text),
/// its offsets, and whether it is the current match.
typedef _Highlight = ({int? item, int start, int end, bool current});

/// [text] in [style], with [highlights] marked, in order of their offsets.
TextSpan _highlighted(
  String text,
  List<_Highlight> highlights,
  TextStyle? style,
) {
  if (highlights.isEmpty) return TextSpan(text: text, style: style);
  final spans = <TextSpan>[];
  var at = 0;
  for (final h in highlights) {
    if (h.start > at) spans.add(TextSpan(text: text.substring(at, h.start)));
    spans.add(
      TextSpan(
        text: text.substring(h.start, h.end),
        style: TextStyle(
          backgroundColor: h.current ? currentMatchColor : matchColor,
          color: h.current ? Colors.black : null,
        ),
      ),
    );
    at = h.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return TextSpan(style: style, children: spans);
}

/// A note between cues. It reads left to right whatever the transcript's
/// direction, since the user writes it.
class _NoteTile extends StatelessWidget {
  const _NoteTile({
    required this.note,
    required this.picture,
    required this.highlights,
    required this.onTap,
    required this.onPictureTap,
  });

  final Note note;
  final File? picture;
  final List<_Highlight> highlights;
  final VoidCallback onTap;
  final ValueChanged<File> onPictureTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Directionality(
      textDirection: .ltr,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Material(
          color: scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: .antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
              child: Row(
                crossAxisAlignment: .start,
                children: [
                  Icon(
                    Icons.sticky_note_2_outlined,
                    size: 18,
                    color: scheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: .start,
                      children: [
                        Text(
                          'Note at ${formatClock(note.time)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onTertiaryContainer,
                          ),
                        ),
                        if (note.text.isNotEmpty)
                          Text.rich(
                            _highlighted(
                              note.text,
                              highlights,
                              theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onTertiaryContainer,
                              ),
                            ),
                          ),
                        if (picture != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: GestureDetector(
                              onTap: () => onPictureTap(picture!),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  picture!,
                                  height: 140,
                                  width: double.infinity,
                                  fit: .cover,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CueTile extends StatelessWidget {
  const _CueTile({
    required this.cue,
    required this.index,
    required this.active,
    required this.highlights,
    required this.textScale,
    required this.speakerNames,
    required this.speakerOverrides,
    required this.onTap,
    required this.onLineLongPress,
  });

  final Cue cue;
  final int index;
  final bool active;
  final List<_Highlight> highlights;
  final double textScale;
  final Map<String, String> speakerNames;
  final Map<String, String> speakerOverrides;
  final VoidCallback onTap;
  final ValueChanged<int> onLineLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final viewRtl = Directionality.of(context) == .rtl;
    return Material(
      color: active ? scheme.secondaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: .antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            children: [
              for (final (i, item) in cue.items.indexed)
                GestureDetector(
                  behavior: .opaque,
                  onLongPress: () => onLineLongPress(i),
                  child: _row(theme, i, item, viewRtl),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(ThemeData theme, int i, CueItem item, bool viewRtl) {
    final scheme = theme.colorScheme;
    final lineRtl = lineIsRtl(item.text, rtl: viewRtl);
    final speaker = speakerOverrides['$index:$i'] ?? item.speaker;
    return Row(
      crossAxisAlignment: .start,
      children: [
        SizedBox(
          width: 60,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: .start,
              children: [
                if (speaker != null)
                  Text(
                    speakerNames[speaker] ?? 'Sp $speaker',
                    maxLines: 1,
                    overflow: .ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: speakerColor(speaker),
                      fontWeight: .w600,
                    ),
                  ),
                if (i == 0)
                  Text(
                    formatClock(cue.start),
                    textDirection: .ltr,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text.rich(
            _highlighted(
              item.text,
              [
                for (final h in highlights)
                  if (h.item == i) h,
              ],
              theme.textTheme.bodyLarge?.copyWith(
                height: 1.6,
                color: active ? scheme.onSecondaryContainer : null,
              ),
            ),
            textDirection: lineRtl ? .rtl : .ltr,
            textAlign: viewRtl ? .right : .left,
            textScaler: TextScaler.linear(textScale),
          ),
        ),
      ],
    );
  }
}
