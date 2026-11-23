import 'package:material_ui/material_ui.dart';

import 'language_lookup.dart';
import 'languages.dart';

const _sizes = [(1.0, 'Normal'), (1.15, 'Large'), (1.3, 'Larger')];

/// Opens the form for a new language, or for [existing], and stores the
/// result in [languages]. A new language gets [code] when given. Returns the
/// stored entry, or null when cancelled.
Future<Language?> showLanguageEditor(
  BuildContext context,
  LanguageList languages,
  LanguageLookup lookup, {
  Language? existing,
  String? code,
}) async {
  final language = await Navigator.push<Language>(
    context,
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => LanguageEditor(
        languages: languages,
        lookup: lookup,
        existing: existing,
        code: code,
      ),
    ),
  );
  if (language != null) languages.put(language);
  return language;
}

class LanguageEditor extends StatefulWidget {
  const LanguageEditor({
    super.key,
    required this.languages,
    required this.lookup,
    this.existing,
    this.code,
  });

  final LanguageList languages;
  final LanguageLookup lookup;
  final Language? existing;

  /// The code of a new language when it is already set, as for a code that
  /// recordings use.
  final String? code;

  @override
  State<LanguageEditor> createState() => _LanguageEditorState();
}

class _LanguageEditorState extends State<LanguageEditor> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _code = TextEditingController(
    text: widget.existing?.code ?? widget.code,
  );
  late final _script = TextEditingController(text: widget.existing?.script);
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late bool _rtl = widget.existing?.rtl ?? false;
  late double _textScale = widget.existing?.textScale ?? 1.0;
  bool _tried = false;
  LanguageCatalog? _catalog;

  /// Whether the fields hold a lookup result for the name as typed.
  bool _picked = false;
  bool _asking = false;
  String? _lookupError;

  @override
  void initState() {
    super.initState();
    if (widget.existing == null) {
      widget.lookup.catalog.then((c) {
        if (!mounted) return;
        setState(() => _catalog = c);
        final code = widget.code;
        if (code == null) return;
        for (final e in c.entries) {
          if (e.code == code) _apply(e);
        }
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _script.dispose();
    _notes.dispose();
    super.dispose();
  }

  String? get _nameError =>
      _name.text.trim().isEmpty ? 'Enter the language name' : null;

  bool get _codeLocked => widget.existing != null || widget.code != null;

  String? get _codeError {
    if (_codeLocked) return null;
    final code = _code.text.trim();
    if (!isValidLangCode(code)) {
      return 'Two or more lowercase letters, ideally the ISO code';
    }
    final taken = widget.languages[code];
    if (taken != null) return 'Already used by ${taken.name}';
    return null;
  }

  String? get _scriptError =>
      _script.text.trim().isEmpty ? 'Enter the script it is written in' : null;

  void _apply(LanguageSuggestion s) {
    setState(() {
      _name.text = s.name;
      _code.text = s.code;
      _script.text = s.script;
      _rtl = s.rtl;
      _picked = true;
      _lookupError = null;
    });
  }

  Future<void> _askGemini() async {
    final name = _name.text.trim();
    FocusScope.of(context).unfocus();
    setState(() {
      _asking = true;
      _lookupError = null;
    });
    try {
      final found = await widget.lookup.askGemini(name);
      if (mounted) _apply(found);
    } on LookupException catch (e) {
      if (mounted) setState(() => _lookupError = e.message);
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  List<Widget> _suggestions(BuildContext context) {
    final name = _name.text.trim();
    if (_codeLocked || _picked || name.isEmpty) return const [];
    final theme = Theme.of(context);
    final matches = _catalog?.search(name) ?? const [];
    return [
      for (final m in matches)
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          enabled: !widget.languages.contains(m.code),
          title: Text(
            m.native.isEmpty || m.native == m.name
                ? m.name
                : '${m.name} (${m.native})',
          ),
          subtitle: Text(
            '${m.code}, ${m.script}${m.rtl ? ', right to left' : ''}',
          ),
          trailing: widget.languages.contains(m.code)
              ? const Text('Added')
              : null,
          onTap: () => _apply(m),
        ),
      if (_asking)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: LinearProgressIndicator(),
        )
      else
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: _askGemini,
            icon: const Icon(Icons.travel_explore, size: 18),
            label: Text(
              matches.isEmpty
                  ? 'Not in the built-in list. Ask Gemini'
                  : 'Not listed? Ask Gemini',
            ),
          ),
        ),
      if (_lookupError != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            _lookupError!,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
    ];
  }

  void _save() {
    if (_nameError != null || _codeError != null || _scriptError != null) {
      setState(() => _tried = true);
      return;
    }
    Navigator.pop(
      context,
      Language(
        code: widget.existing?.code ?? _code.text.trim(),
        name: _name.text.trim(),
        script: _script.text.trim(),
        rtl: _rtl,
        textScale: _textScale,
        notes: _notes.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sizes = [
      ..._sizes,
      if (!_sizes.any((s) => s.$1 == _textScale))
        (_textScale, '${(_textScale * 100).round()}%'),
    ];
    InputDecoration field(String label, String? error, {String? helper}) =>
        InputDecoration(
          border: const OutlineInputBorder(),
          labelText: label,
          helperText: helper,
          helperMaxLines: 3,
          errorText: _tried ? error : null,
        );
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Add language' : 'Edit language'),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          TextField(
            controller: _name,
            autofocus: widget.existing == null,
            textCapitalization: .words,
            decoration: field('Name', _nameError),
            onChanged: (_) => setState(() {
              _picked = false;
              _lookupError = null;
            }),
          ),
          ..._suggestions(context),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            enabled: !_codeLocked,
            autocorrect: false,
            decoration: field(
              'Code',
              _codeError,
              helper: !_codeLocked
                  ? 'Stored with each recording. It cannot be changed later.'
                  : widget.existing == null
                  ? 'The code your recordings use.'
                  : 'Stored with each recording, so it cannot be changed.',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _script,
            decoration: field('Script', _scriptError),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Text('Direction', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Left to right')),
              ButtonSegment(value: true, label: Text('Right to left')),
            ],
            selected: {_rtl},
            onSelectionChanged: (s) => setState(() => _rtl = s.single),
          ),
          const SizedBox(height: 16),
          Text('Text size', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<double>(
            segments: [
              for (final (scale, label) in sizes)
                ButtonSegment(value: scale, label: Text(label)),
            ],
            selected: {_textScale},
            onSelectionChanged: (s) => setState(() => _textScale = s.single),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _notes,
            minLines: 3,
            maxLines: 10,
            decoration: field(
              'Notes for the model (optional)',
              null,
              helper:
                  'Given to Gemini as critical points when transcribing, one '
                  'per line. Use it to warn about languages it confuses this '
                  'one with.',
            ),
          ),
        ],
      ),
    );
  }
}
