import 'package:material_ui/material_ui.dart';

import 'job.dart';
import 'language_editor.dart';
import 'language_lookup.dart';
import 'languages.dart';
import 'prompts.dart';

const _addLanguage = '';

/// Picks a code from [languages], leaving out [exclude], with an entry at the
/// end that adds one.
class LanguageDropdown extends StatelessWidget {
  const LanguageDropdown({
    super.key,
    required this.languages,
    required this.lookup,
    required this.value,
    required this.onChanged,
    this.exclude = const {},
  });

  final LanguageList languages;
  final LanguageLookup lookup;

  /// The chosen code, or null for none.
  final String? value;
  final ValueChanged<String> onChanged;
  final Set<String> exclude;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: languages,
      builder: (context, _) {
        final shown = [
          for (final l in languages.all)
            if (!exclude.contains(l.code)) l,
        ];
        return DropdownButton<String>(
          value: shown.any((l) => l.code == value)
              ? value
              : shown.any((l) => l.code == defaultLang)
              ? defaultLang
              : shown.firstOrNull?.code,
          items: [
            for (final l in shown)
              DropdownMenuItem(value: l.code, child: Text(l.name)),
            const DropdownMenuItem(
              value: _addLanguage,
              child: Text('Add language…'),
            ),
          ],
          onChanged: (code) async {
            if (code == null) return;
            if (code != _addLanguage) {
              onChanged(code);
              return;
            }
            final added = await showLanguageEditor(context, languages, lookup);
            if (added != null) onChanged(added.code);
          },
        );
      },
    );
  }
}

/// The optional note about a recording that goes to the model with it.
class ContextField extends StatefulWidget {
  const ContextField({
    super.key,
    required this.initialText,
    required this.onChanged,
  });

  final String initialText;
  final ValueChanged<String> onChanged;

  @override
  State<ContextField> createState() => _ContextFieldState();
}

class _ContextFieldState extends State<ContextField> {
  late final _controller = TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: TextField(
        controller: _controller,
        onChanged: widget.onChanged,
        maxLength: contextLimit,
        minLines: 2,
        maxLines: 5,
        textCapitalization: .sentences,
        decoration: const InputDecoration(
          labelText: 'Context (optional)',
          hintText: 'Names, topics or terms that come up',
          alignLabelWithHint: true,
          border: OutlineInputBorder(),
        ),
      ),
    );
  }
}

/// A labelled language picker row.
class LanguageRow extends StatelessWidget {
  const LanguageRow({
    super.key,
    required this.label,
    required this.languages,
    required this.lookup,
    required this.value,
    required this.onChanged,
    this.exclude = const {},
  });

  final String label;
  final LanguageList languages;
  final LanguageLookup lookup;
  final String? value;
  final ValueChanged<String> onChanged;

  /// Languages left out of the choices.
  final Set<String> exclude;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: .min,
      children: [
        Flexible(child: Text(label)),
        const SizedBox(width: 12),
        LanguageDropdown(
          languages: languages,
          lookup: lookup,
          value: value,
          onChanged: onChanged,
          exclude: exclude,
        ),
      ],
    );
  }
}

/// Shown where generated content is missing: the control to start generating
/// it, or the progress of a running job.
class JobPanel extends StatelessWidget {
  const JobPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.actionLabel,
    required this.onStart,
    required this.job,
    this.note,
    this.options,
    this.outputRtl = false,
    this.showOutput,
  });

  final IconData icon;
  final String title;
  final String actionLabel;

  /// Starts the job. Null disables the button.
  final VoidCallback? onStart;

  /// The latest run, if any.
  final Job? job;

  /// Explains what the action does or what it is waiting on.
  final String? note;

  /// Extra controls shown above the button.
  final Widget? options;

  /// Whether the streamed output reads right to left.
  final bool outputRtl;

  /// The streamed output as shown, when it differs from what the model
  /// writes.
  final String Function(String output)? showOutput;

  @override
  Widget build(BuildContext context) {
    final job = this.job;
    if (job == null) return _idle(context, null);
    return ListenableBuilder(
      listenable: job,
      builder: (context, _) => job.state == JobState.running
          ? _running(context, job)
          : _idle(context, job),
    );
  }

  Widget _idle(BuildContext context, Job? ended) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: .min,
          children: [
            Icon(icon, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            if (options != null) ...[options!, const SizedBox(height: 16)],
            if (note != null) ...[
              Text(
                note!,
                textAlign: .center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
            ],
            FilledButton(onPressed: onStart, child: Text(actionLabel)),
            if (ended?.state == JobState.failed) ...[
              const SizedBox(height: 16),
              Text(
                ended!.error ?? 'Failed',
                textAlign: .center,
                style: TextStyle(color: scheme.error),
              ),
            ],
            if (ended?.state == JobState.cancelled) ...[
              const SizedBox(height: 16),
              Text(
                'Cancelled',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _running(BuildContext context, Job job) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: .stretch,
        children: [
          Text(job.status, style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              reverse: true,
              child: Align(
                alignment: outputRtl ? .topRight : .topLeft,
                child: Text(
                  showOutput?.call(job.output.toString()) ??
                      job.output.toString(),
                  textDirection: outputRtl ? .rtl : .ltr,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: OutlinedButton.icon(
              onPressed: job.cancel,
              icon: const Icon(Icons.close),
              label: const Text('Cancel'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks before replacing generated content. Resolves to true on confirm.
Future<bool> confirmRegenerate(
  BuildContext context, {
  required String what,
  Widget? options,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Regenerate $what?'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .start,
          children: [
            Text('The current $what is replaced when the new one finishes.'),
            if (options != null) ...[const SizedBox(height: 12), options],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Regenerate'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Runs [task] behind a progress dialog titled [title] that cannot be
/// dismissed.
Future<T> runWithProgressDialog<T>(
  BuildContext context,
  String title,
  Future<T> Function(void Function(double fraction) report) task,
) async {
  final progress = ValueNotifier<double>(0);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: ValueListenableBuilder(
          valueListenable: progress,
          builder: (context, value, _) => Column(
            mainAxisSize: .min,
            crossAxisAlignment: .start,
            children: [
              LinearProgressIndicator(value: value),
              const SizedBox(height: 12),
              Text('${(value * 100).round()}%'),
            ],
          ),
        ),
      ),
    ),
  );
  final navigator = Navigator.of(context, rootNavigator: true);
  try {
    return await task((fraction) => progress.value = fraction);
  } finally {
    navigator.pop();
  }
}

/// Shows [job]'s status in a dialog with a Cancel button until it ends.
Future<void> showJobProgress(
  BuildContext context,
  Job job, {
  required String title,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: ListenableBuilder(
        listenable: job,
        builder: (context, _) {
          if (job.state != JobState.running) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) Navigator.pop(context);
            });
          }
          return AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: .min,
              crossAxisAlignment: .start,
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(job.status),
              ],
            ),
            actions: [
              TextButton(onPressed: job.cancel, child: const Text('Cancel')),
            ],
          );
        },
      ),
    ),
  );
}

/// A coloured heading above a group of controls or statements.
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// One bulleted statement of what an operation will do.
class BulletLine extends StatelessWidget {
  const BulletLine(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Row(
        crossAxisAlignment: .start,
        children: [
          const SizedBox(width: 16, child: Text('•')),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

/// A thin row above generated content: what it is on the left, the actions
/// for it on the right.
class ActionStrip extends StatelessWidget {
  const ActionStrip({super.key, this.info, this.hint, required this.actions});

  final String? info;
  final String? hint;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: .start,
                mainAxisSize: .min,
                children: [
                  if (info != null)
                    Text(info!, style: theme.textTheme.labelMedium),
                  if (hint != null)
                    Text(hint!, style: muted, maxLines: 1, overflow: .ellipsis),
                ],
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}
