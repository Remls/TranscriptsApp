import 'package:material_ui/material_ui.dart';

import 'languages.dart';
import 'library.dart';
import 'note_editor.dart';
import 'ruby.dart';
import 'session.dart';
import 'srt.dart';
import 'sheet.dart';
import 'transcript_edits.dart';
import 'transcript_view.dart';

void _showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), persist: false));
}

String _speakerLabel(Session session, String speaker) =>
    session.speakerNames[speaker] ?? 'Speaker $speaker';

/// Runs [change] on the open recording unless a job is rewriting its files.
void _edit(
  BuildContext context,
  Session session,
  void Function(TranscriptEditor editor) change,
) {
  if (session.recordingBusy(session.recording!.relPath)) {
    _showMessage(context, 'Wait for the running job to finish');
    return;
  }
  try {
    session.edit(change);
  } on LibraryException catch (e) {
    _showMessage(context, e.message);
  }
}

/// What the line sheet asks for.
sealed class _LineResult {
  const _LineResult();
}

class _Simple extends _LineResult {
  const _Simple(this.action);

  final _LineAction action;
}

/// Give the line to [to], over [scope].
class _NewSpeaker extends _LineResult {
  const _NewSpeaker(this.to, this.scope);

  final String to;
  final _Scope scope;
}

enum _LineAction { select, editText, renameSpeaker, addNote, delete }

/// The actions for line [item] of cue [cue] in the transcript, or in the
/// translation into [translation] when given. [onSelect] starts selecting
/// lines with this one.
Future<void> showLineActions(
  BuildContext context,
  Session session, {
  String? translation,
  required int cue,
  required int item,
  required VoidCallback onSelect,
}) async {
  final cues = translation == null ? session.cues : session.translatedCues;
  final line = cues[cue].items[item];
  final speaker = effectiveSpeaker(cues, session.speakerOverrides, cue, item);
  final rtl = session.languages
      .resolve(translation ?? session.recording!.lang)
      .rtl;
  final result = await showSheet<_LineResult>(
    context,
    builder: (context) => _LineSheet(
      session: session,
      text: line.text,
      rtl: lineIsRtl(line.text, rtl: rtl),
      time: cues[cue].start,
      speaker: speaker,
    ),
  );
  if (result == null || !context.mounted) return;
  switch (result) {
    case _NewSpeaker(:final to, :final scope):
      _edit(context, session, (e) {
        switch (scope) {
          case _Scope.line:
            e.setLineSpeaker(cue, item, to);
          case _Scope.onward:
            e.remapSpeakers({speaker!: to}, fromCue: cue, fromItem: item);
          case _Scope.swapOnward:
            e.remapSpeakers(
              {speaker!: to, to: speaker},
              fromCue: cue,
              fromItem: item,
            );
        }
      });
    case _Simple(:final action):
      switch (action) {
        case _LineAction.select:
          onSelect();
        case _LineAction.editText:
          await _editText(context, session, translation, cue, item, line.text);
        case _LineAction.renameSpeaker:
          await renameSpeaker(context, session, speaker!);
        case _LineAction.addNote:
          await editNote(context, session, at: cues[cue].start);
        case _LineAction.delete:
          await deleteLines(context, session, [(cue, item)]);
      }
  }
}

/// The line sheet: a preview of the line and its actions, then, for a new
/// speaker, the speaker and how far the change runs. Pops with a
/// [_LineResult].
class _LineSheet extends StatefulWidget {
  const _LineSheet({
    required this.session,
    required this.text,
    required this.rtl,
    required this.time,
    required this.speaker,
  });

  final Session session;
  final String text;
  final bool rtl;
  final double time;
  final String? speaker;

  @override
  State<_LineSheet> createState() => _LineSheetState();
}

class _LineSheetState extends State<_LineSheet> {
  /// Which step shows: the actions, the speakers, or the scope for [_to].
  var _step = 0;
  String? _to;

  void _done(_LineResult result) => Navigator.pop(context, result);

  void _pick(String to) {
    final from = widget.speaker;
    if (from == null) {
      _done(_NewSpeaker(to, _Scope.line));
    } else if (to != from) {
      setState(() {
        _to = to;
        _step = 2;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final speaker = widget.speaker;
    switch (_step) {
      case 1:
        return SheetBody(
          title: 'Who says this line?',
          onBack: () => setState(() => _step = 0),
          children: _speakerOptions(
            session,
            current: speaker,
            onPick: _pick,
            allowNew: true,
          ),
        );
      case 2:
        final from = _speakerLabel(session, speaker!);
        final to = _speakerLabel(session, _to!);
        final exists = speakerLineCounts(
          session.cues,
          session.speakerOverrides,
        ).containsKey(_to);
        return SheetBody(
          title: 'Change $from to $to',
          onBack: () => setState(() => _step = 1),
          children: [
            SheetOption(
              title: 'Only this line',
              onTap: () => _done(_NewSpeaker(_to!, _Scope.line)),
            ),
            SheetOption(
              title: '$from\'s lines from here to the end',
              subtitle: 'Every line of $from from this one on becomes $to.',
              onTap: () => _done(_NewSpeaker(_to!, _Scope.onward)),
            ),
            if (exists)
              SheetOption(
                title: 'Swap the two from here to the end',
                subtitle:
                    'From this line on, $from becomes $to and $to becomes '
                    '$from.',
                onTap: () => _done(_NewSpeaker(_to!, _Scope.swapOnward)),
              ),
          ],
        );
    }
    void act(_LineAction action) => _done(_Simple(action));
    return SheetBody(
      header: _LinePreview(
        session: session,
        text: widget.text,
        rtl: widget.rtl,
        time: widget.time,
        speaker: speaker,
      ),
      children: [
        Row(
          crossAxisAlignment: .start,
          children: [
            for (final (icon, label, onPressed) in [
              (
                Icons.edit_outlined,
                'Edit text',
                () => act(_LineAction.editText),
              ),
              (
                Icons.record_voice_over_outlined,
                'Change speaker',
                () => setState(() => _step = 1),
              ),
              (
                Icons.note_add_outlined,
                'Add note',
                () => act(_LineAction.addNote),
              ),
              (Icons.checklist, 'Select lines', () => act(_LineAction.select)),
            ])
              Expanded(
                child: SheetAction(
                  icon: icon,
                  label: label,
                  onPressed: onPressed,
                ),
              ),
          ],
        ),
        const SheetDivider(),
        if (speaker != null)
          SheetOption(
            leading: const Icon(Icons.badge_outlined),
            title: 'Rename ${_speakerLabel(session, speaker)}',
            onTap: () => act(_LineAction.renameSpeaker),
          ),
        SheetOption(
          leading: const Icon(Icons.delete_outline),
          title: 'Delete line',
          destructive: true,
          onTap: () => act(_LineAction.delete),
        ),
      ],
    );
  }
}

/// The line a sheet acts on: its speaker, time and text.
class _LinePreview extends StatelessWidget {
  const _LinePreview({
    required this.session,
    required this.text,
    required this.rtl,
    required this.time,
    required this.speaker,
  });

  final Session session;
  final String text;
  final bool rtl;
  final double time;
  final String? speaker;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final speaker = this.speaker;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: .stretch,
        children: [
          Row(
            children: [
              if (speaker != null) ...[
                SpeakerAvatar(session: session, speaker: speaker, radius: 12),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _speakerLabel(session, speaker),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: speakerColor(speaker),
                    ),
                  ),
                ),
              ] else
                const Spacer(),
              Text(
                formatClock(time),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            text,
            maxLines: 4,
            overflow: .ellipsis,
            textDirection: rtl ? .rtl : .ltr,
            style: theme.textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

/// A speaker's colored circle, with their name's first letter or their
/// number.
class SpeakerAvatar extends StatelessWidget {
  const SpeakerAvatar({
    super.key,
    required this.session,
    required this.speaker,
    this.radius = 18,
  });

  final Session session;
  final String speaker;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final color = speakerColor(speaker);
    final name = session.speakerNames[speaker]?.trim();
    final mark = name == null || name.isEmpty
        ? speaker
        : name.characters.first.toUpperCase();
    return CircleAvatar(
      radius: radius,
      backgroundColor: color,
      child: Text(
        mark,
        style: TextStyle(
          color: color.computeLuminance() > 0.5 ? Colors.black : Colors.white,
          fontSize: radius * 0.9,
          fontWeight: .w600,
        ),
      ),
    );
  }
}

/// Gives [lines], each a (cue, item) pair, to a speaker the user picks.
/// Resolves to whether anything changed.
Future<bool> changeSpeakerOf(
  BuildContext context,
  Session session,
  List<(int, int)> lines,
) async {
  final picked = await _pickSpeaker(
    context,
    session,
    title: lines.length == 1
        ? 'Who says this line?'
        : 'Who says these ${lines.length} lines?',
    allowNew: true,
  );
  if (picked == null || !context.mounted) return false;
  _edit(context, session, (e) => e.setLinesSpeaker(lines, picked));
  return true;
}

/// Deletes [lines], each a (cue, item) pair, from the transcript and every
/// translation after asking. Resolves to whether they were deleted.
Future<bool> deleteLines(
  BuildContext context,
  Session session,
  List<(int, int)> lines,
) async {
  final count = lines.length;
  final translations = session.recording!.translations.length;
  final matching = count == 1 ? 'line is' : 'lines are';
  final ok = await _confirm(
    context,
    count == 1 ? 'Delete line' : 'Delete $count lines',
    switch (translations) {
      0 => 'This cannot be undone.',
      1 =>
        'The matching translation $matching deleted too. '
            'This cannot be undone.',
      _ =>
        'The matching $matching deleted from all $translations translations '
            'too. This cannot be undone.',
    },
  );
  if (!ok || !context.mounted) return false;
  _edit(context, session, (e) => e.deleteLines(lines));
  return true;
}

enum _Scope { line, onward, swapOnward }

Future<void> _editText(
  BuildContext context,
  Session session,
  String? translation,
  int cue,
  int item,
  String current,
) async {
  final rtl = session.languages
      .resolve(translation ?? session.recording!.lang)
      .rtl;
  final readings = translation == null
      ? session.furiganaCues
      : session.translationFuriganaCues;
  final hasReadings =
      cue < readings.length &&
      item < readings[cue].items.length &&
      withReadings(current, readings[cue].items[item].text) != null;
  final controller = TextEditingController(text: current);
  final text = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Edit text'),
      content: TextField(
        controller: controller,
        autofocus: true,
        minLines: 1,
        maxLines: 8,
        textDirection: rtl ? .rtl : .ltr,
        decoration: InputDecoration(
          helperText: hasReadings
              ? "Saving removes this line's furigana."
              : null,
          helperMaxLines: 2,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (text == null || text == current || !context.mounted) return;
  _edit(
    context,
    session,
    (e) => e.setText(cue, item, text, translation: translation),
  );
}

/// Asks for a name for [speaker] in the open recording.
Future<void> renameSpeaker(
  BuildContext context,
  Session session,
  String speaker,
) async {
  final controller = TextEditingController(
    text: session.speakerNames[speaker] ?? '',
  );
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Rename Speaker $speaker'),
      content: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .start,
        children: [
          const Text('The name applies to this recording only.'),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: .words,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, ''),
          child: const Text('Reset to default'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (name == null || !context.mounted) return;
  _edit(context, session, (e) => e.setSpeakerName(speaker, name));
}

/// One sheet row per speaker of the open recording, leaving out [exclude],
/// with [current] ticked, and a row for a new speaker when [allowNew] is set.
List<Widget> _speakerOptions(
  Session session, {
  String? current,
  String? exclude,
  bool allowNew = false,
  required ValueChanged<String> onPick,
}) {
  final counts = speakerLineCounts(session.cues, session.speakerOverrides);
  final speakers = counts.keys.where((s) => s != exclude).toList();
  return [
    for (final s in speakers)
      SheetOption(
        leading: SpeakerAvatar(session: session, speaker: s),
        title: _speakerLabel(session, s),
        subtitle: '${counts[s]} ${counts[s] == 1 ? 'line' : 'lines'}',
        selected: s == current,
        onTap: () => onPick(s),
      ),
    if (allowNew) ...[
      const SheetDivider(),
      SheetOption(
        leading: const Icon(Icons.add),
        title: 'New speaker',
        onTap: () => onPick(nextSpeakerId([...counts.keys, ?exclude])),
      ),
    ],
  ];
}

/// Lets the user choose one of the recording's speakers, or a new one when
/// [allowNew] is set. Resolves to the speaker id, or null when cancelled.
Future<String?> _pickSpeaker(
  BuildContext context,
  Session session, {
  required String title,
  String? current,
  String? exclude,
  bool allowNew = false,
}) {
  return showSheet<String>(
    context,
    builder: (context) => SheetBody(
      title: title,
      children: _speakerOptions(
        session,
        current: current,
        exclude: exclude,
        allowNew: allowNew,
        onPick: (s) => Navigator.pop(context, s),
      ),
    ),
  );
}

Future<bool> _confirm(BuildContext context, String title, String body) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(title),
        ),
      ],
    ),
  );
  return confirmed == true;
}

Future<void> _swap(BuildContext context, Session session) async {
  final a = await _pickSpeaker(context, session, title: 'Swap which speaker?');
  if (a == null || !context.mounted) return;
  final b = await _pickSpeaker(
    context,
    session,
    title: 'Swap ${_speakerLabel(session, a)} with',
    exclude: a,
  );
  if (b == null || !context.mounted) return;
  final nameA = _speakerLabel(session, a);
  final nameB = _speakerLabel(session, b);
  final ok = await _confirm(
    context,
    'Swap speakers',
    'Every line of $nameA becomes $nameB, and every line of $nameB becomes '
        '$nameA.',
  );
  if (ok && context.mounted) {
    _edit(context, session, (e) => e.swapSpeakers(a, b));
  }
}

Future<void> _merge(BuildContext context, Session session) async {
  final from = await _pickSpeaker(
    context,
    session,
    title: 'Merge which speaker away?',
  );
  if (from == null || !context.mounted) return;
  final into = await _pickSpeaker(
    context,
    session,
    title: 'Merge ${_speakerLabel(session, from)} into',
    exclude: from,
  );
  if (into == null || !context.mounted) return;
  final ok = await _confirm(
    context,
    'Merge speakers',
    'Every line of ${_speakerLabel(session, from)} becomes '
        '${_speakerLabel(session, into)}.',
  );
  if (ok && context.mounted) {
    _edit(context, session, (e) => e.mergeSpeakers(from, into));
  }
}

Future<void> _reset(BuildContext context, Session session) async {
  final count = session.speakerOverrides.length;
  final ok = await _confirm(
    context,
    'Reset speaker changes',
    '$count ${count == 1 ? 'line goes' : 'lines go'} back to the speaker the '
        'transcript gave. Names are kept.',
  );
  if (ok && context.mounted) {
    _edit(context, session, (e) => e.resetSpeakerChanges());
  }
}

/// The open recording's speakers with their line counts, and the actions that
/// apply to the whole recording.
Future<void> showSpeakersSheet(BuildContext context, Session session) {
  return showSheet<void>(
    context,
    builder: (sheetContext) => ListenableBuilder(
      listenable: session,
      builder: (sheetContext, _) {
        final counts = speakerLineCounts(
          session.cues,
          session.speakerOverrides,
        );
        final several = counts.length > 1;
        final changed = session.speakerOverrides.isNotEmpty;
        return SheetBody(
          title: 'Speakers',
          children: [
            for (final MapEntry(key: speaker, value: lines) in counts.entries)
              SheetOption(
                leading: SpeakerAvatar(session: session, speaker: speaker),
                title: _speakerLabel(session, speaker),
                subtitle: '$lines ${lines == 1 ? 'line' : 'lines'}',
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => renameSpeaker(context, session, speaker),
              ),
            if (several || changed)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (several) ...[
                      FilledButton.tonalIcon(
                        onPressed: () => _swap(context, session),
                        icon: const Icon(Icons.swap_horiz),
                        label: const Text('Swap'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => _merge(context, session),
                        icon: const Icon(Icons.merge),
                        label: const Text('Merge'),
                      ),
                    ],
                    if (changed)
                      FilledButton.tonalIcon(
                        onPressed: () => _reset(context, session),
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('Reset changes'),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );
}
