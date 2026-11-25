import 'package:material_ui/material_ui.dart';

import 'library.dart';
import 'srt.dart';
import 'menu.dart';
import 'sheet.dart';

enum LibraryAction { search, import, newFolder, trash, settings }

enum FolderAction { summary, combine, shareZip, rename, trash }

enum RecordingAction { share, split, combine, rename, move, trash }

/// The actions on a recording, in menu order, with the groups they fall in.
const recordingActionGroups = [
  [(RecordingAction.share, Icons.share_outlined, 'Share')],
  [
    (RecordingAction.split, Icons.call_split, 'Split into chunks'),
    (RecordingAction.combine, Icons.merge, 'Combine with others'),
  ],
  [
    (RecordingAction.rename, Icons.edit_outlined, 'Rename'),
    (RecordingAction.move, Icons.drive_file_move_outlined, 'Move to folder'),
    (RecordingAction.trash, Icons.delete_outlined, 'Move to trash'),
  ],
];

/// The library's folders as expandable sections, each listing its
/// recordings.
class LibraryList extends StatefulWidget {
  const LibraryList({
    super.key,
    required this.sections,
    required this.selected,
    required this.expanded,
    required this.durationOf,
    required this.isBusy,
    required this.onSelect,
    required this.onFolderAction,
    required this.onRecordingAction,
  });

  final List<LibrarySection> sections;

  /// The open recording's path relative to the library root.
  final String? selected;

  /// The titles of the sections shown open. The list updates it as the user
  /// opens and closes sections.
  final Set<String> expanded;

  /// A recording's length in seconds, when known.
  final double? Function(Recording recording) durationOf;

  /// Whether a job is running on a recording.
  final bool Function(Recording recording) isBusy;
  final ValueChanged<Recording> onSelect;
  final void Function(LibrarySection section, FolderAction action)
  onFolderAction;
  final void Function(Recording recording, RecordingAction action)
  onRecordingAction;

  @override
  State<LibraryList> createState() => _LibraryListState();
}

class _LibraryListState extends State<LibraryList> {
  @override
  void initState() {
    super.initState();
    for (final section in widget.sections) {
      if (section.recordings.any((r) => r.relPath == widget.selected)) {
        widget.expanded.add(section.title);
      }
    }
  }

  void _toggle(String title) => setState(() {
    if (!widget.expanded.remove(title)) widget.expanded.add(title);
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        for (final section in widget.sections) ...[
          _FolderRow(
            section: section,
            open: widget.expanded.contains(section.title),
            busy: section.recordings.any(widget.isBusy),
            onToggle: () => _toggle(section.title),
            onAction: (action) => widget.onFolderAction(section, action),
          ),
          if (widget.expanded.contains(section.title))
            for (final r in section.recordings)
              _RecordingRow(
                recording: r,
                duration: widget.durationOf(r),
                busy: widget.isBusy(r),
                selected: r.relPath == widget.selected,
                onTap: () => widget.onSelect(r),
                onLongPress: () => _showRecordingActions(context, r),
              ),
        ],
      ],
    );
  }

  Future<void> _showRecordingActions(
    BuildContext context,
    Recording recording,
  ) async {
    final action = await showSheet<RecordingAction>(
      context,
      builder: (context) => SheetBody(
        title: recording.name,
        children: [
          for (final (i, group) in recordingActionGroups.indexed) ...[
            if (i > 0) const SheetDivider(),
            for (final (action, icon, label) in group)
              SheetOption(
                leading: Icon(icon),
                title: label,
                destructive: action == RecordingAction.trash,
                onTap: () => Navigator.pop(context, action),
              ),
          ],
        ],
      ),
    );
    if (action != null) widget.onRecordingAction(recording, action);
  }
}

// Column positions shared by folder and recording rows, so icons, names,
// numbers and trailing controls line up.
const _iconLeft = 32.0;
const _iconBox = 18.0;
const _nameGap = 8.0;
const _numberWidth = 40.0;
const _statusIcon = 14.0;
const _statusGap = 4.0;
const _trailingWidth = 3 * (_statusIcon + _statusGap);
const _rightPad = 14.0;

/// Digits have no descenders, so they look high when centred by line box.
/// This lowers them to sit level with the icons beside them.
const _digitNudge = 2.0;

/// Centres glyphs in their line box so text sits level with icons.
const _level = TextStyle(height: 1.2, leadingDistribution: .even);

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.square(
      dimension: 12,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}

/// A folder's header row: tap to open or close it.
class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.section,
    required this.open,
    required this.busy,
    required this.onToggle,
    required this.onAction,
  });

  final LibrarySection section;
  final bool open;
  final bool busy;
  final VoidCallback onToggle;
  final ValueChanged<FolderAction> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      child: InkWell(
        onTap: onToggle,
        child: SizedBox(
          height: 40,
          child: Row(
            children: [
              SizedBox(
                width: _iconLeft,
                child: Icon(
                  open ? Icons.expand_more : Icons.chevron_right,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              SizedBox(
                width: _iconBox,
                child: Icon(
                  section.folder == null
                      ? Icons.inbox_outlined
                      : open
                      ? Icons.folder_open
                      : Icons.folder,
                  size: _iconBox,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: _nameGap),
              Expanded(
                child: Row(
                  crossAxisAlignment: .baseline,
                  textBaseline: .alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        section.title,
                        maxLines: 1,
                        overflow: .ellipsis,
                        style: theme.textTheme.titleSmall?.merge(_level),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${section.recordings.length}',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant)
                          .merge(_level),
                    ),
                  ],
                ),
              ),
              if (busy) const _Spinner(),
              if (section.folder == null)
                const SizedBox(width: _trailingWidth + _rightPad)
              else
                MenuButton(
                  tooltip: 'Folder actions',
                  groups: [
                    [
                      menuEntry(
                        Icons.summarize_outlined,
                        'Summary',
                        () => onAction(FolderAction.summary),
                      ),
                      menuEntry(
                        Icons.merge,
                        'Combine recordings',
                        () => onAction(FolderAction.combine),
                      ),
                      menuEntry(
                        Icons.folder_zip_outlined,
                        'Share as .zip',
                        () => onAction(FolderAction.shareZip),
                      ),
                    ],
                    [
                      menuEntry(
                        Icons.edit_outlined,
                        'Rename',
                        () => onAction(FolderAction.rename),
                      ),
                      menuEntry(
                        Icons.delete_outline,
                        'Move to trash',
                        () => onAction(FolderAction.trash),
                        destructive: true,
                      ),
                    ],
                  ],
                  child: SizedBox(
                    width: _trailingWidth + _rightPad,
                    height: 40,
                    child: Align(
                      alignment: const Alignment(0.62, 0),
                      child: Icon(
                        Icons.more_vert,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One recording on a single line, indented under its folder.
class _RecordingRow extends StatelessWidget {
  const _RecordingRow({
    required this.recording,
    required this.duration,
    required this.busy,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final Recording recording;
  final double? duration;
  final bool busy;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    Widget status(IconData icon, String label, bool done) {
      return Padding(
        padding: const EdgeInsetsDirectional.only(start: _statusGap),
        child: Icon(
          icon,
          size: _statusIcon,
          semanticLabel: '$label: ${done ? 'done' : 'not done'}',
          color: done ? scheme.primary : scheme.outlineVariant,
        ),
      );
    }

    return Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(_iconLeft, 9, _rightPad, 9),
          child: Row(
            children: [
              SizedBox(
                width: _iconBox,
                child: Icon(
                  recording.isVideo
                      ? Icons.videocam_outlined
                      : Icons.graphic_eq,
                  size: 16,
                  color: muted,
                ),
              ),
              const SizedBox(width: _nameGap),
              Expanded(
                child: Text(
                  recording.name,
                  maxLines: 1,
                  overflow: .ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(
                        color: selected ? scheme.onSecondaryContainer : null,
                        fontWeight: selected ? .w600 : null,
                      )
                      .merge(_level),
                ),
              ),
              if (busy) const _Spinner(),
              Container(
                width: _numberWidth,
                padding: const EdgeInsets.only(top: _digitNudge),
                child: Text(
                  duration == null ? '' : formatClock(duration!),
                  textAlign: .end,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(
                        color: muted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      )
                      .merge(_level),
                ),
              ),
              status(Icons.subject, 'Transcript', recording.hasTranscript),
              status(Icons.translate, 'Translation', recording.hasTranslation),
              status(Icons.summarize_outlined, 'Summary', recording.hasSummary),
            ],
          ),
        ),
      ),
    );
  }
}
