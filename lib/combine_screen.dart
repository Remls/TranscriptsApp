import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'combine.dart';
import 'job.dart';
import 'job_panel.dart';
import 'session.dart';
import 'srt.dart';
import 'transcript_edits.dart';
import 'transcript_view.dart';

const _newSpeaker = '\u0000new';

/// Chooses recordings from one folder, their order and how their speakers
/// line up, describes the outcome, and combines them. Pops with the combined
/// recording.
class CombineScreen extends StatefulWidget {
  const CombineScreen({
    super.key,
    required this.session,
    required this.folder,
    required this.preselected,
  });

  final Session session;
  final Directory folder;

  /// Paths of the recordings ticked when the screen opens.
  final Set<String> preselected;

  @override
  State<CombineScreen> createState() => _CombineScreenState();
}

class _CombineScreenState extends State<CombineScreen> {
  late final List<File> _files = [
    for (final r in widget.session.library.recordingsIn(widget.folder)) r.file,
  ]..sort(compareForCombining);
  late final Set<String> _selected = {...widget.preselected};
  final _durations = <String, double>{};
  final _name = TextEditingController();
  bool _nameEdited = false;
  bool _loading = true;

  /// The user's choices of combined speaker, by part path and part speaker.
  final _choices = <(String, String), String>{};

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    for (final f in _files) {
      _durations[f.path] = await widget.session.media.duration(f) ?? 0;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  List<CombinePart> get _parts => [
    for (final f in _files)
      if (_selected.contains(f.path))
        CombinePart.load(widget.session.library, f, _durations[f.path] ?? 0),
  ];

  /// The default matching with the user's choices applied on top.
  SpeakerMapping _mapping(List<CombinePart> parts) {
    final mapping = defaultSpeakerMapping(parts);
    for (final (i, part) in parts.indexed) {
      for (final speaker in part.speakers) {
        final choice = _choices[(part.file.path, speaker)];
        if (choice == null) continue;
        mapping[i][speaker] = choice == _newSpeaker
            ? nextSpeakerId([for (final m in mapping) ...m.values])
            : choice;
      }
    }
    return mapping;
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), persist: false));
  }

  Future<void> _run(List<CombinePart> parts, SpeakerMapping mapping) async {
    final session = widget.session;
    final library = session.library;
    if (parts.any(
      (part) => session.recordingBusy(library.describe(part.file).relPath),
    )) {
      _showMessage('Wait for the running job to finish');
      return;
    }
    final open = session.recording?.file.path;
    if (parts.any((part) => part.file.path == open)) await session.close();
    if (!mounted) return;

    final job = session.startCombine(parts, mapping, _name.text);
    await showJobProgress(context, job, title: 'Combining');
    if (!mounted) return;
    switch (job.state) {
      case JobState.done:
        Navigator.pop(context, job.result);
      case JobState.failed:
        _showMessage('Combine failed: ${job.error}');
      default:
        _showMessage('Combine cancelled');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Combine recordings')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final parts = _parts;
    final problems = combineProblems(parts);
    final ready = problems.isEmpty;
    final mapping = ready ? _mapping(parts) : const <Map<String, String>>[];
    if (!_nameEdited && parts.isNotEmpty) {
      _name.text = defaultCombinedName(parts);
    }
    final nameOk = _name.text.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Combine recordings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const SectionHeading('Recordings, in order'),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (from, to) => setState(() {
              _files.insert(to, _files.removeAt(from));
            }),
            children: [
              for (final (i, f) in _files.indexed)
                CheckboxListTile(
                  key: ValueKey(f.path),
                  dense: true,
                  controlAffinity: .leading,
                  value: _selected.contains(f.path),
                  title: Text(p.basename(f.path)),
                  subtitle: Text(formatClock(_durations[f.path] ?? 0)),
                  secondary: ReorderableDragStartListener(
                    index: i,
                    child: const Icon(Icons.drag_handle),
                  ),
                  onChanged: (on) => setState(() {
                    on == true
                        ? _selected.add(f.path)
                        : _selected.remove(f.path);
                  }),
                ),
            ],
          ),
          for (final problem in problems)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                problem,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          if (ready) ...[
            const SectionHeading('Name'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _name,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  suffixText: p.extension(parts.first.file.path),
                ),
                onChanged: (_) => setState(() => _nameEdited = true),
              ),
            ),
            if (hasTranscripts(parts) && mapping.any((m) => m.isNotEmpty)) ...[
              const SectionHeading('Speakers'),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Check that each speaker in the later recordings is matched '
                  'to the right person.',
                ),
              ),
              ..._speakerRows(parts, mapping),
            ],
            const SectionHeading('What will happen'),
            for (final line in describeCombination(
              parts,
              mapping,
              _name.text.trim(),
            ))
              BulletLine(line),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
              child: FilledButton(
                onPressed: nameOk ? () => _run(parts, mapping) : null,
                child: const Text('Combine'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _speakerRows(List<CombinePart> parts, SpeakerMapping mapping) {
    final names = combinedSpeakerNames(parts, mapping);
    final targets = {for (final m in mapping) ...m.values}.toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    String label(String id) => names[id] ?? 'Speaker $id';
    final rows = <Widget>[];
    for (final (i, part) in parts.indexed) {
      for (final speaker in part.speakers) {
        final target = mapping[i][speaker]!;
        rows.add(
          ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 8,
              backgroundColor: speakerColor(target),
            ),
            title: Text(
              '${part.names[speaker] ?? 'Speaker $speaker'} in ${part.name}',
            ),
            subtitle: Text(
              part.sampleLine(speaker) ?? '',
              maxLines: 2,
              overflow: .ellipsis,
            ),
            trailing: i == 0
                ? Text(label(target))
                : DropdownButton<String>(
                    value: target,
                    items: [
                      for (final id in targets)
                        DropdownMenuItem(value: id, child: Text(label(id))),
                      const DropdownMenuItem(
                        value: _newSpeaker,
                        child: Text('New speaker'),
                      ),
                    ],
                    onChanged: (choice) => setState(() {
                      if (choice != null) {
                        _choices[(part.file.path, speaker)] = choice;
                      }
                    }),
                  ),
          ),
        );
      }
    }
    return rows;
  }
}
