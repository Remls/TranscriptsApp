import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'job.dart';
import 'job_panel.dart';
import 'markdown_view.dart';
import 'session.dart';
import 'share_sheet.dart';
import 'text_jobs.dart';

const _notes = {
  FolderSummaryMode.flat:
      'All transcripts are combined and summarized in one pass. Recordings '
      'without a transcript or translation get one first.',
  FolderSummaryMode.hierarchical:
      'Each recording is summarized, then those summaries are combined. '
      'Missing transcripts, translations and summaries are generated first.',
};

/// The flat and hierarchical summaries of one folder.
class FolderScreen extends StatelessWidget {
  const FolderScreen({
    super.key,
    required this.session,
    required this.folder,
    required this.onOpenSettings,
  });

  final Session session;
  final Directory folder;
  final VoidCallback onOpenSettings;

  void _start(BuildContext context, FolderSummaryMode mode) {
    final problem = session.startFolderSummary(folder, mode);
    if (problem == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(problem),
        persist: false,
        action: SnackBarAction(label: 'Settings', onPressed: onOpenSettings),
      ),
    );
  }

  Future<void> _regenerate(BuildContext context, FolderSummaryMode mode) async {
    if (await confirmRegenerate(context, what: 'summary') && context.mounted) {
      _start(context, mode);
    }
  }

  @override
  Widget build(BuildContext context) {
    const modes = FolderSummaryMode.values;
    return DefaultTabController(
      length: modes.length,
      child: ListenableBuilder(
        listenable: Listenable.merge([session, session.settings]),
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            title: Text(p.basename(folder.path)),
            bottom: const TabBar(
              tabs: [
                Tab(text: 'Flat summary'),
                Tab(text: 'Hierarchical'),
              ],
            ),
          ),
          body: TabBarView(
            children: [for (final mode in modes) _body(context, mode)],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, FolderSummaryMode mode) {
    final job = session.jobFor(folderJobKind(mode), folder.path);
    final file = session.library.folderSummaryFile(folder, mode.fileKey);
    if (file.existsSync() && job?.state != JobState.running) {
      final summary = file.readAsStringSync();
      return Column(
        children: [
          ActionStrip(
            actions: [
              TextButton.icon(
                onPressed: () =>
                    shareText(summary.trim(), subject: p.basename(folder.path)),
                icon: const Icon(Icons.share_outlined, size: 18),
                label: const Text('Share'),
              ),
              TextButton.icon(
                onPressed: () => _regenerate(context, mode),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Regenerate'),
              ),
            ],
          ),
          Expanded(child: MarkdownView(summary)),
        ],
      );
    }
    return JobPanel(
      icon: Icons.summarize_outlined,
      title: 'No summary yet',
      note: _notes[mode],
      actionLabel: 'Generate',
      job: job,
      options: LanguageRow(
        label: 'Language of untranscribed recordings',
        languages: session.languages,
        lookup: session.languageLookup,
        value: session.transcribeLang,
        onChanged: session.settings.setTranscribeLang,
      ),
      onStart: () => _start(context, mode),
    );
  }
}
