import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'anthropic.dart';
import 'backup_section.dart';
import 'gemini.dart';
import 'job_panel.dart';
import 'languages.dart';
import 'languages_screen.dart';
import 'session.dart';
import 'settings.dart';
import 'sheet.dart';
import 'text_generator.dart';
import 'theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.session});

  final Session session;

  Settings get _settings => session.settings;

  Future<void> _pickLanguage(
    BuildContext context,
    String current,
    ValueChanged<String> save,
  ) async {
    final code = await pickLanguage(
      context,
      session.languages,
      session.languageLookup,
      current: current,
    );
    if (code != null) save(code);
  }

  void _push(BuildContext context, Widget screen) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final languages = session.languages;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: Listenable.merge([_settings, languages]),
        builder: (context, _) {
          final translateLang = languages.contains(_settings.translateLang)
              ? _settings.translateLang
              : englishLang;
          final count = languages.all.length;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              const _Heading('Languages'),
              _Group([
                _Row(
                  icon: Icons.subject,
                  title: 'Default for transcription',
                  value: languages.resolve(session.transcribeLang).name,
                  onTap: () => _pickLanguage(
                    context,
                    session.transcribeLang,
                    _settings.setTranscribeLang,
                  ),
                ),
                _Row(
                  icon: Icons.translate,
                  title: 'Default for translations and summaries',
                  value: languages.resolve(translateLang).name,
                  onTap: () => _pickLanguage(
                    context,
                    translateLang,
                    _settings.setTranslateLang,
                  ),
                ),
                _Row(
                  icon: Icons.language,
                  title: 'Language list',
                  value: '$count ${count == 1 ? 'language' : 'languages'}',
                  page: true,
                  onTap: () => _push(
                    context,
                    LanguagesScreen(
                      languages: languages,
                      lookup: session.languageLookup,
                      library: session.library,
                    ),
                  ),
                ),
              ]),
              const _Heading('AI models'),
              _Group([
                _Row(
                  icon: Icons.auto_awesome_outlined,
                  title: 'Gemini',
                  value: _settings.geminiKey.isEmpty
                      ? 'No API key'
                      : _settings.geminiModelName,
                  page: true,
                  onTap: () => _push(
                    context,
                    _ProviderScreen(
                      settings: _settings,
                      provider: TextProvider.gemini,
                    ),
                  ),
                ),
                _Row(
                  icon: Icons.auto_awesome_outlined,
                  title: 'Claude',
                  value: _settings.anthropicKey.isEmpty
                      ? 'No API key'
                      : _settings.anthropicModel.isEmpty
                      ? 'No model chosen'
                      : _settings.anthropicModelName,
                  page: true,
                  onTap: () => _push(
                    context,
                    _ProviderScreen(
                      settings: _settings,
                      provider: TextProvider.anthropic,
                    ),
                  ),
                ),
                _Choice<TextProvider>(
                  icon: Icons.graphic_eq,
                  title: 'Transcribe with',
                  options: const [(TextProvider.gemini, 'Gemini')],
                  value: TextProvider.gemini,
                  note: 'Only Gemini supports audio file uploads.',
                ),
                _Choice<TextProvider>(
                  icon: Icons.summarize_outlined,
                  title: 'Translate and summarize with',
                  options: const [
                    (TextProvider.gemini, 'Gemini'),
                    (TextProvider.anthropic, 'Claude'),
                  ],
                  disabled: {
                    if (!_settings.claudeReady) TextProvider.anthropic,
                  },
                  value: _settings.textProvider,
                  onChanged: _settings.setTextProvider,
                ),
              ]),
              const _Heading('Appearance'),
              _Group([
                _Choice<ThemeMode>(
                  icon: Icons.contrast,
                  title: 'Theme',
                  options: const [
                    (ThemeMode.system, 'Auto'),
                    (ThemeMode.light, 'Light'),
                    (ThemeMode.dark, 'Dark'),
                  ],
                  value: _settings.themeMode,
                  onChanged: _settings.setThemeMode,
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.palette_outlined),
                  title: const Text('Wallpaper colors'),
                  subtitle: wallpaperColorsAvailable
                      ? null
                      : const Text('Needs Android 12 or later'),
                  value: wallpaperColorsAvailable && _settings.wallpaperColors,
                  onChanged: wallpaperColorsAvailable
                      ? _settings.setWallpaperColors
                      : null,
                ),
              ]),
              const SizedBox(height: 24),
              _Group([
                _Row(
                  icon: Icons.settings_backup_restore,
                  title: 'Backup and restore',
                  page: true,
                  onTap: () => _push(context, _BackupScreen(session: session)),
                ),
                _Row(
                  icon: Icons.description_outlined,
                  title: 'Open-source licenses',
                  page: true,
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'Transcripts',
                  ),
                ),
              ]),
            ],
          );
        },
      ),
    );
  }
}

/// A provider's key and model, with links to get a key and see usage.
class _ProviderScreen extends StatefulWidget {
  const _ProviderScreen({required this.settings, required this.provider});

  final Settings settings;
  final TextProvider provider;

  @override
  State<_ProviderScreen> createState() => _ProviderScreenState();
}

class _ProviderScreenState extends State<_ProviderScreen> {
  Settings get _settings => widget.settings;
  bool get _gemini => widget.provider == TextProvider.gemini;

  late final _key = TextEditingController(
    text: _gemini ? _settings.geminiKey : _settings.anthropicKey,
  );
  bool _loading = false;

  String get _modelId =>
      _gemini ? _settings.geminiModel : _settings.anthropicModel;
  String get _modelName =>
      _gemini ? _settings.geminiModelName : _settings.anthropicModelName;

  String get _name => _gemini ? 'Gemini' : 'Claude';

  Future<void> _saveKey(String key) =>
      _gemini ? _settings.setGeminiKey(key) : _settings.setAnthropicKey(key);

  Future<void> _saveModel(String model, {String name = ''}) => _gemini
      ? _settings.setGeminiModel(model, name: name)
      : _settings.setAnthropicModel(model, name: name);

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  /// Lets the user choose from the models the provider lists for the key,
  /// or type a model id.
  Future<void> _pickModel() async {
    final key = _key.text.trim();
    var models = const <ModelInfo>[];
    if (key.isEmpty) {
      _showMessage(
        'Enter the ${_gemini ? 'Gemini' : 'Anthropic'} API key to list models',
      );
    } else {
      setState(() => _loading = true);
      final client = http.Client();
      try {
        models = _gemini
            ? await GeminiClient(apiKey: key, client: client).listModels()
            : await AnthropicClient(apiKey: key, client: client).listModels();
      } catch (e) {
        _showMessage('Could not load models: $e');
      } finally {
        client.close();
        if (mounted) setState(() => _loading = false);
      }
    }
    if (!mounted) return;
    final picked = await showSheet<ModelInfo>(
      context,
      builder: (context) =>
          _ModelSheet(title: '$_name model', models: models, current: _modelId),
    );
    if (picked == null || !mounted) return;
    if (picked.id.isNotEmpty) {
      await _saveModel(picked.id, name: picked.name);
      return;
    }
    final typed = await _askModelId();
    if (typed != null && typed.trim().isNotEmpty) await _saveModel(typed);
  }

  Future<String?> _askModelId() {
    final controller = TextEditingController(text: _modelId);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Model ID'),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          decoration: const InputDecoration(hintText: 'e.g. gemini-3.8-flash'),
          onSubmitted: (value) => Navigator.pop(context, value),
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
  }

  Future<void> _open(String url) async {
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } on PlatformException {
      opened = false;
    }
    if (!opened) _showMessage('Could not open $url');
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text), persist: false));
  }

  @override
  Widget build(BuildContext context) {
    final links = _gemini
        ? const [
            (
              Icons.key_outlined,
              'Get an API key',
              'https://aistudio.google.com/apikey',
            ),
            (
              Icons.bar_chart,
              'Usage and billing',
              'https://aistudio.google.com/billing',
            ),
          ]
        : const [
            (
              Icons.key_outlined,
              'Get an API key',
              'https://platform.claude.com/settings/keys',
            ),
            (
              Icons.bar_chart,
              'Usage and billing',
              'https://platform.claude.com/settings/billing',
            ),
          ];
    return Scaffold(
      appBar: AppBar(title: Text(_name)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _KeyField(controller: _key, label: 'API key', onChanged: _saveKey),
          const SizedBox(height: 16),
          ListenableBuilder(
            listenable: _settings,
            builder: (context, _) => _Group([
              _Row(
                icon: Icons.tune,
                title: 'Model',
                value: _modelId.isEmpty ? 'None chosen' : _modelName,
                detail: _modelName == _modelId ? null : _modelId,
                trailing: _loading
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: _loading ? () {} : _pickModel,
              ),
            ]),
          ),
          const SizedBox(height: 24),
          _Group([
            for (final (icon, label, url) in links)
              _Row(
                icon: icon,
                title: label,
                trailing: const Icon(Icons.open_in_new),
                onTap: () => _open(url),
              ),
          ]),
          if (!_gemini)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                'Billed separately from a Claude subscription.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The models to choose from: the main ones, and the rest after "Show all
/// models". Pops with the chosen [ModelInfo], or one with an empty id to
/// type an id.
class _ModelSheet extends StatefulWidget {
  const _ModelSheet({
    required this.title,
    required this.models,
    required this.current,
  });

  final String title;
  final List<ModelInfo> models;
  final String current;

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  late bool _all =
      !widget.models.any((m) => m.main) ||
      widget.models.any((m) => !m.main && m.id == widget.current);

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final m in widget.models)
        if (_all || m.main) m,
    ];
    final hidden = widget.models.length - shown.length;
    return SheetBody(
      title: widget.title,
      children: [
        for (final m in shown)
          SheetOption(
            title: m.name,
            subtitle: m.name == m.id ? null : m.id,
            selected: m.id == widget.current,
            onTap: () => Navigator.pop(context, m),
          ),
        if (shown.isNotEmpty) const SheetDivider(),
        if (hidden > 0)
          SheetOption(
            leading: const Icon(Icons.expand_more),
            title: 'Show all models ($hidden more)',
            onTap: () => setState(() => _all = true),
          ),
        SheetOption(
          leading: const Icon(Icons.edit_outlined),
          title: 'Enter a model ID…',
          onTap: () => Navigator.pop<ModelInfo>(context, (
            id: '',
            name: '',
            main: false,
          )),
        ),
      ],
    );
  }
}

/// Creating a backup of the library and restoring one.
class _BackupScreen extends StatelessWidget {
  const _BackupScreen({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup and restore')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'A backup is one zip file with every recording and its '
              'transcript, translations, summaries, notes and context, and '
              'your language list. The trash, API keys and the other settings '
              'are left out.',
            ),
          ),
          const SizedBox(height: 16),
          _Group([BackupSection(session: session)]),
        ],
      ),
    );
  }
}

/// A rounded block of settings rows.
class _Group extends StatelessWidget {
  const _Group(this.children);

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: .antiAlias,
      child: Column(mainAxisSize: .min, children: children),
    );
  }
}

/// A settings row: [title] with its current [value] below. A row that opens
/// a [page] ends with a chevron.
class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    this.value,
    this.detail,
    this.page = false,
    this.trailing,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? value;

  /// A second, smaller line below [value].
  final String? detail;
  final bool page;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: value == null
          ? null
          : Column(
              mainAxisSize: .min,
              crossAxisAlignment: .start,
              children: [
                Text(value!, maxLines: 1, overflow: .ellipsis),
                if (detail != null)
                  Text(
                    detail!,
                    maxLines: 1,
                    overflow: .ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
      trailing: trailing ?? (page ? const Icon(Icons.chevron_right) : null),
      onTap: onTap,
    );
  }
}

/// A setting chosen from a few [options], one active at a time, leaving
/// [disabled] ones greyed out. Without [onChanged] the whole choice is
/// greyed out, with [note] below it.
class _Choice<T> extends StatelessWidget {
  const _Choice({
    required this.icon,
    required this.title,
    required this.options,
    required this.value,
    this.disabled = const {},
    this.onChanged,
    this.note,
  });

  final IconData icon;
  final String title;
  final List<(T, String)> options;
  final T value;
  final Set<T> disabled;
  final ValueChanged<T>? onChanged;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 24, 16),
      child: Row(
        crossAxisAlignment: .start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: .stretch,
              children: [
                Text(title, style: theme.textTheme.bodyLarge),
                const SizedBox(height: 12),
                SegmentedButton<T>(
                  showSelectedIcon: false,
                  segments: [
                    for (final (option, label) in options)
                      ButtonSegment(
                        value: option,
                        label: Text(label),
                        enabled: !disabled.contains(option),
                      ),
                  ],
                  selected: {value},
                  onSelectionChanged: onChanged == null
                      ? null
                      : (s) => onChanged!(s.single),
                ),
                if (note != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    note!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _KeyField extends StatefulWidget {
  const _KeyField({
    required this.controller,
    required this.label,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final ValueChanged<String> onChanged;

  @override
  State<_KeyField> createState() => _KeyFieldState();
}

class _KeyFieldState extends State<_KeyField> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      obscureText: _hidden,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: widget.label,
        suffixIcon: IconButton(
          tooltip: _hidden ? 'Show' : 'Hide',
          icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
          onPressed: () => setState(() => _hidden = !_hidden),
        ),
      ),
      onChanged: widget.onChanged,
    );
  }
}
