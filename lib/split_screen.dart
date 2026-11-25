import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'combine.dart';
import 'job.dart';
import 'job_panel.dart';
import 'library.dart';
import 'rechunk.dart';
import 'session.dart';
import 'srt.dart';

const _targetPref = 'rechunkTarget';
const _maxPref = 'rechunkMax';
const _defaultTargetMinutes = 10;
const _defaultMaxMinutes = 15;

/// Describes and runs the split of a recording's family into even chunks.
/// Pops with the first chunk.
class SplitScreen extends StatefulWidget {
  const SplitScreen({
    super.key,
    required this.session,
    required this.recording,
  });

  final Session session;
  final Recording recording;

  @override
  State<SplitScreen> createState() => _SplitScreenState();
}

class _SplitScreenState extends State<SplitScreen> {
  late final List<File> _members = familyMembers(widget.recording.file);
  final _durations = <String, double>{};
  late final _target = TextEditingController(
    text:
        '${widget.session.prefs.getInt(_targetPref) ?? _defaultTargetMinutes}',
  );
  late final _max = TextEditingController(
    text: '${widget.session.prefs.getInt(_maxPref) ?? _defaultMaxMinutes}',
  );
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    for (final f in _members) {
      _durations[f.path] = await widget.session.media.duration(f) ?? 0;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _target.dispose();
    _max.dispose();
    super.dispose();
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), persist: false));
  }

  Future<void> _run(int targetMin, int maxMin) async {
    final session = widget.session;
    final described = [for (final m in _members) session.library.describe(m)];
    if (described.any((r) => session.recordingBusy(r.relPath))) {
      _showMessage('Wait for the running job to finish');
      return;
    }
    await session.prefs.setInt(_targetPref, targetMin);
    await session.prefs.setInt(_maxPref, maxMin);
    final open = session.recording?.relPath;
    if (described.any((r) => r.relPath == open)) await session.close();
    if (!mounted) return;

    final job = session.startRechunk(
      widget.recording,
      targetMin * 60,
      maxMin * 60,
    );
    await showJobProgress(context, job, title: 'Splitting');
    if (!mounted) return;
    switch (job.state) {
      case JobState.done:
        Navigator.pop(context, job.chunks.first);
      case JobState.failed:
        _showMessage('Split failed: ${job.error}');
      default:
        _showMessage('Split cancelled');
    }
  }

  @override
  Widget build(BuildContext context) {
    const title = Text('Split into chunks');
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: title),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final theme = Theme.of(context);
    final library = widget.session.library;
    final members = [
      for (final f in _members)
        (p.basenameWithoutExtension(f.path), _durations[f.path] ?? 0.0),
    ];
    final total = members.fold(0.0, (sum, m) => sum + m.$2);
    final targetMin = int.tryParse(_target.text) ?? 0;
    final maxMin = int.tryParse(_max.text) ?? 0;
    final carry = SplitCarry.of([
      for (final f in _members)
        CombinePart.load(library, f, _durations[f.path] ?? 0),
    ]);
    final problem =
        splitProblem(total, targetMin * 60, maxMin * 60) ??
        carry.problems.firstOrNull;

    Widget field(TextEditingController controller, String label) => Expanded(
      child: TextField(
        controller: controller,
        keyboardType: .number,
        decoration: InputDecoration(labelText: label, suffixText: 'min'),
        onChanged: (_) => setState(() {}),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: title),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const SectionHeading('Recordings'),
          for (final (name, seconds) in members)
            ListTile(
              dense: true,
              leading: const Icon(Icons.graphic_eq, size: 20),
              title: Text(name),
              trailing: Text(formatClock(seconds)),
            ),
          const SectionHeading('Chunk length'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                field(_target, 'Target'),
                const SizedBox(width: 16),
                field(_max, 'Max'),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Chunks are cut at the target length. A short leftover is added '
              'to the last chunk as long as that stays under the max.',
            ),
          ),
          if (problem != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(
                problem,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            )
          else ...[
            const SectionHeading('What will happen'),
            for (final line in describeSplit(
              members,
              familyBase(widget.recording.name),
              p.extension(widget.recording.file.path),
              targetMin * 60,
              maxMin * 60,
              carry: carry,
              languageName: (code) =>
                  widget.session.languages.resolve(code).name,
            ))
              BulletLine(line),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
              child: FilledButton(
                onPressed: () => _run(targetMin, maxMin),
                child: const Text('Split'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
