import 'package:material_ui/material_ui.dart';

import 'language_editor.dart';
import 'language_lookup.dart';
import 'languages.dart';
import 'library.dart';
import 'unknown_languages.dart';

/// The number of recordings in [library] marked with language [code].
int recordingsInLanguage(Library library, String code) {
  var count = 0;
  for (final section in library.scan()) {
    for (final r in section.recordings) {
      if (r.lang == code) count++;
    }
  }
  return count;
}

/// Lists the languages recordings can be transcribed in, to add, edit and
/// remove them.
class LanguagesScreen extends StatelessWidget {
  const LanguagesScreen({
    super.key,
    required this.languages,
    required this.lookup,
    required this.library,
  });

  final LanguageList languages;
  final LanguageLookup lookup;
  final Library library;

  Future<void> _remove(BuildContext context, Language language) async {
    final used = recordingsInLanguage(library, language.code);
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          used > 0 ? '${language.name} is in use' : 'Remove ${language.name}?',
        ),
        content: Text(
          used > 0
              ? '$used ${used == 1 ? 'recording is' : 'recordings are'} '
                    'in ${language.name}, so it cannot be removed.'
              : 'It will no longer be offered for transcription.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(used > 0 ? 'OK' : 'Cancel'),
          ),
          if (used == 0)
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove'),
            ),
        ],
      ),
    );
    if (remove ?? false) languages.remove(language.code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Languages')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showLanguageEditor(context, languages, lookup),
        icon: const Icon(Icons.add),
        label: const Text('Add language'),
      ),
      body: ListenableBuilder(
        listenable: languages,
        builder: (context, _) {
          final unknown = unknownLanguages(library, languages);
          return ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              for (final language in languages.all)
                ListTile(
                  title: Text(language.name),
                  subtitle: Text(
                    '${language.code}, ${language.script}'
                    '${language.rtl ? ', right to left' : ''}',
                  ),
                  onTap: () => showLanguageEditor(
                    context,
                    languages,
                    lookup,
                    existing: language,
                  ),
                  trailing: fixedLangs.contains(language.code)
                      ? null
                      : IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _remove(context, language),
                        ),
                ),
              if (unknown.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                  child: Text(
                    'Used in your library but not in your list',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                for (final MapEntry(key: code, value: count) in unknown.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: UnknownLanguageTile(
                      code: code,
                      count: count,
                      languages: languages,
                      lookup: lookup,
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}
