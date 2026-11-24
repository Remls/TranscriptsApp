import 'package:material_ui/material_ui.dart';

import 'library.dart';
import 'note_editor.dart';
import 'session.dart';
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

enum _LineAction { editText, changeSpeaker, renameSpeaker, addNote, delete }

/// The actions for line [item] of cue [cue] in the transcript or translation
/// shown from [source].
Future<void> showLineActions(
  BuildContext context,
  Session session, {
  required Sidecar source,
  required int cue,
  required int item,
}) async {
  final cues = source == Sidecar.translation
      ? session.translatedCues
      : session.cues;
  final line = cues[cue].items[item];
  final speaker = effectiveSpeaker(cues, session.speakerOverrides, cue, item);
  final action = await showModalBottomSheet<_LineAction>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: .min,
        children: [
          ListTile(
            title: Text(line.text, maxLines: 2, overflow: .ellipsis),
            subtitle: speaker == null
                ? null
                : Text(_speakerLabel(session, speaker)),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Edit text'),
            onTap: () => Navigator.pop(context, _LineAction.editText),
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: const Text('Change speaker'),
            onTap: () => Navigator.pop(context, _LineAction.changeSpeaker),
          ),
          ListTile(
            leading: const Icon(Icons.note_add_outlined),
            title: const Text('Add note here'),
            onTap: () => Navigator.pop(context, _LineAction.addNote),
          ),
          if (speaker != null)
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: Text('Rename ${_speakerLabel(session, speaker)}'),
              onTap: () => Navigator.pop(context, _LineAction.renameSpeaker),
            ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete line'),
            onTap: () => Navigator.pop(context, _LineAction.delete),
          ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case _LineAction.editText:
      await _editText(context, session, source, cue, item, line.text);
    case _LineAction.changeSpeaker:
      final picked = await _pickSpeaker(
        context,
        session,
        title: 'Who says this line?',
        current: speaker,
        allowNew: true,
      );
      if (picked == null || picked == speaker || !context.mounted) return;
      await _changeSpeaker(context, session, cue, item, speaker, picked);
    case _LineAction.renameSpeaker:
      await renameSpeaker(context, session, speaker!);
    case _LineAction.addNote:
      await editNote(context, session, at: cues[cue].start);
    case _LineAction.delete:
      await deleteLines(context, session, [(cue, item)]);
  }
}

/// Deletes [lines], each a (cue, item) pair, from the transcript and the
/// translation after asking.
Future<void> deleteLines(
  BuildContext context,
  Session session,
  List<(int, int)> lines,
) async {
  final count = lines.length;
  final ok = await _confirm(
    context,
    count == 1 ? 'Delete line' : 'Delete $count lines',
    session.translatedCues.isEmpty
        ? 'This cannot be undone.'
        : 'The matching translation ${count == 1 ? 'line is' : 'lines are'} '
              'deleted too. This cannot be undone.',
  );
  if (ok && context.mounted) {
    _edit(context, session, (e) => e.deleteLines(lines));
  }
}

enum _Scope { line, onward, swapOnward }

/// Gives line [item] of cue [cue] to [to]. When the line has a speaker, asks
/// whether the change covers only this line or runs to the end.
Future<void> _changeSpeaker(
  BuildContext context,
  Session session,
  int cue,
  int item,
  String? from,
  String to,
) async {
  var scope = _Scope.line;
  if (from != null) {
    final fromLabel = _speakerLabel(session, from);
    final toLabel = _speakerLabel(session, to);
    final exists = speakerLineCounts(
      session.cues,
      session.speakerOverrides,
    ).containsKey(to);
    final chosen = await showDialog<_Scope>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Change $fromLabel to $toLabel'),
        children: [
          ListTile(
            title: const Text('Only this line'),
            onTap: () => Navigator.pop(context, _Scope.line),
          ),
          ListTile(
            title: Text('$fromLabel\'s lines from here to the end'),
            subtitle: Text(
              'Every line of $fromLabel from this one on becomes $toLabel.',
            ),
            onTap: () => Navigator.pop(context, _Scope.onward),
          ),
          if (exists)
            ListTile(
              title: const Text('Swap the two from here to the end'),
              subtitle: Text(
                'From this line on, $fromLabel becomes $toLabel and '
                '$toLabel becomes $fromLabel.',
              ),
              onTap: () => Navigator.pop(context, _Scope.swapOnward),
            ),
        ],
      ),
    );
    if (chosen == null || !context.mounted) return;
    scope = chosen;
  }
  _edit(context, session, (e) {
    switch (scope) {
      case _Scope.line:
        e.setLineSpeaker(cue, item, to);
      case _Scope.onward:
        e.remapSpeakers({from!: to}, fromCue: cue, fromItem: item);
      case _Scope.swapOnward:
        e.remapSpeakers({from!: to, to: from}, fromCue: cue, fromItem: item);
    }
  });
}

Future<void> _editText(
  BuildContext context,
  Session session,
  Sidecar source,
  int cue,
  int item,
  String current,
) async {
  final lang = source == Sidecar.translation ? 'en' : session.recording!.lang;
  final rtl = session.languages.resolve(lang).rtl;
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
  _edit(context, session, (e) => e.setText(source, cue, item, text));
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

Widget _speakerTile(
  Session session,
  String speaker, {
  Widget? trailing,
  String? subtitle,
  VoidCallback? onTap,
}) {
  return ListTile(
    dense: true,
    leading: CircleAvatar(radius: 8, backgroundColor: speakerColor(speaker)),
    title: Text(_speakerLabel(session, speaker)),
    subtitle: subtitle == null ? null : Text(subtitle),
    trailing: trailing,
    onTap: onTap,
  );
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
  final speakers = speakerLineCounts(
    session.cues,
    session.speakerOverrides,
  ).keys.where((s) => s != exclude).toList();
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        for (final s in speakers)
          _speakerTile(
            session,
            s,
            trailing: s == current ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(context, s),
          ),
        if (allowNew)
          ListTile(
            dense: true,
            leading: const Icon(Icons.add, size: 18),
            title: const Text('New speaker'),
            onTap: () =>
                Navigator.pop(context, nextSpeakerId([...speakers, ?exclude])),
          ),
      ],
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
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => ListenableBuilder(
      listenable: session,
      builder: (sheetContext, _) {
        final counts = speakerLineCounts(
          session.cues,
          session.speakerOverrides,
        );
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: .min,
              children: [
                ListTile(
                  title: Text(
                    'Speakers',
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
                for (final MapEntry(key: speaker, value: lines)
                    in counts.entries)
                  _speakerTile(
                    session,
                    speaker,
                    subtitle: '$lines ${lines == 1 ? 'line' : 'lines'}',
                    trailing: const Icon(Icons.edit_outlined, size: 18),
                    onTap: () => renameSpeaker(context, session, speaker),
                  ),
                const Divider(),
                ListTile(
                  enabled: counts.length > 1,
                  leading: const Icon(Icons.swap_horiz),
                  title: const Text('Swap two speakers'),
                  onTap: () => _swap(context, session),
                ),
                ListTile(
                  enabled: counts.length > 1,
                  leading: const Icon(Icons.merge),
                  title: const Text('Merge one speaker into another'),
                  onTap: () => _merge(context, session),
                ),
                ListTile(
                  enabled: session.speakerOverrides.isNotEmpty,
                  leading: const Icon(Icons.restart_alt),
                  title: const Text('Reset speaker changes'),
                  onTap: () => _reset(context, session),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
