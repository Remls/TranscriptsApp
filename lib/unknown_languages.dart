import 'package:material_ui/material_ui.dart';

import 'language_editor.dart';
import 'language_lookup.dart';
import 'languages.dart';
import 'library.dart';
import 'session.dart';

/// The language codes recordings in [library] use that [languages] lacks,
/// each with how many recordings use it.
Map<String, int> unknownLanguages(Library library, LanguageList languages) {
  final counts = <String, int>{};
  for (final section in library.scan()) {
    for (final r in section.recordings) {
      if (!languages.contains(r.lang)) {
        counts[r.lang] = (counts[r.lang] ?? 0) + 1;
      }
    }
  }
  return counts;
}

String recordingCount(int n) => '$n ${n == 1 ? 'recording' : 'recordings'}';

/// A row for a code recordings use that is missing from the list, with the
/// button that adds it.
class UnknownLanguageTile extends StatelessWidget {
  const UnknownLanguageTile({
    super.key,
    required this.code,
    required this.count,
    required this.languages,
    required this.lookup,
  });

  final String code;
  final int count;
  final LanguageList languages;
  final LanguageLookup lookup;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(code),
      subtitle: Text(recordingCount(count)),
      trailing: TextButton(
        onPressed: () =>
            showLanguageEditor(context, languages, lookup, code: code),
        child: const Text('Add'),
      ),
    );
  }
}

/// Lists the codes recordings use that the language list lacks, if any, so
/// the user can add them.
Future<void> askForUnknownLanguages(
  BuildContext context,
  Session session,
) async {
  final languages = session.languages;
  if (unknownLanguages(session.library, languages).isEmpty) return;
  await showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: languages,
      builder: (context, _) {
        final unknown = unknownLanguages(session.library, languages);
        return AlertDialog(
          title: const Text('Unknown languages'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: .min,
              crossAxisAlignment: .start,
              children: [
                Text(
                  unknown.isEmpty
                      ? 'Every recording\'s language is in your list now.'
                      : 'Some recordings use languages that are not in your '
                            'list. Add them so their transcripts show in the right '
                            'direction and size.',
                ),
                const SizedBox(height: 8),
                for (final MapEntry(key: code, value: count) in unknown.entries)
                  UnknownLanguageTile(
                    code: code,
                    count: count,
                    languages: languages,
                    lookup: session.languageLookup,
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(unknown.isEmpty ? 'Done' : 'Later'),
            ),
          ],
        );
      },
    ),
  );
}
