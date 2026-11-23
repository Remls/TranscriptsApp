import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'anthropic.dart';
import 'backup_section.dart';
import 'gemini.dart';
import 'job_panel.dart';
import 'languages_screen.dart';
import 'session.dart';
import 'settings.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.session});

  final Session session;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _geminiKey = TextEditingController(text: _settings.geminiKey);
  late final _geminiModel = TextEditingController(text: _settings.geminiModel);
  late final _anthropicKey = TextEditingController(
    text: _settings.anthropicKey,
  );
  late final _anthropicModel = TextEditingController(
    text: _settings.anthropicModel,
  );

  /// The title of the model list being fetched, if any.
  String? _loadingModels;

  Settings get _settings => widget.session.settings;

  @override
  void dispose() {
    _geminiKey.dispose();
    _geminiModel.dispose();
    _anthropicKey.dispose();
    _anthropicModel.dispose();
    super.dispose();
  }

  /// Lets the user choose from the models [load] returns, then stores the
  /// choice through [save].
  Future<void> _pickModel({
    required String title,
    required String apiKey,
    required String missingKey,
    required Future<List<String>> Function(http.Client client) load,
    required TextEditingController controller,
    required Future<void> Function(String model) save,
  }) async {
    if (apiKey.isEmpty) {
      _showMessage(missingKey);
      return;
    }
    setState(() => _loadingModels = title);
    final client = http.Client();
    List<String> models;
    try {
      models = await load(client);
    } catch (e) {
      _showMessage('Could not load models: $e');
      return;
    } finally {
      client.close();
      if (mounted) setState(() => _loadingModels = null);
    }
    if (!mounted) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: [
          for (final m in models)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, m),
              child: Text(m),
            ),
        ],
      ),
    );
    if (picked == null) return;
    controller.text = picked;
    await save(picked);
  }

  Future<void> _pickGeminiModel() => _pickModel(
    title: 'Gemini model',
    apiKey: _settings.geminiKey,
    missingKey: 'Enter the Gemini API key first',
    load: (client) =>
        GeminiClient(apiKey: _settings.geminiKey, client: client).listModels(),
    controller: _geminiModel,
    save: _settings.setGeminiModel,
  );

  Future<void> _pickAnthropicModel() => _pickModel(
    title: 'Claude model',
    apiKey: _settings.anthropicKey,
    missingKey: 'Enter the Anthropic API key first',
    load: (client) => AnthropicClient(
      apiKey: _settings.anthropicKey,
      client: client,
    ).listModels(),
    controller: _anthropicModel,
    save: _settings.setAnthropicModel,
  );

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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: _settings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            const _Heading('Transcription'),
            const Text('Transcription always uses Gemini.'),
            _Links([
              ('Get a Gemini key', 'https://aistudio.google.com/apikey'),
              (
                'Gemini usage and billing',
                'https://aistudio.google.com/billing',
              ),
            ], onOpen: _open),
            const SizedBox(height: 4),
            _KeyField(
              controller: _geminiKey,
              label: 'Gemini API key',
              onChanged: _settings.setGeminiKey,
            ),
            const SizedBox(height: 12),
            _ModelField(
              controller: _geminiModel,
              label: 'Gemini model',
              loading: _loadingModels == 'Gemini model',
              onPick: _pickGeminiModel,
              onChanged: _settings.setGeminiModel,
            ),
            const SizedBox(height: 8),
            LanguageRow(
              label: 'Default language',
              languages: widget.session.languages,
              lookup: widget.session.languageLookup,
              value: widget.session.transcribeLang,
              onChanged: _settings.setTranscribeLang,
            ),
            ListenableBuilder(
              listenable: widget.session.languages,
              builder: (context, _) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Languages'),
                subtitle: Text(
                  widget.session.languages.all.map((l) => l.name).join(', '),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LanguagesScreen(
                      languages: widget.session.languages,
                      lookup: widget.session.languageLookup,
                      library: widget.session.library,
                    ),
                  ),
                ),
              ),
            ),
            const _Heading('Translation and summaries'),
            SegmentedButton<TextProvider>(
              segments: const [
                ButtonSegment(
                  value: TextProvider.gemini,
                  label: Text('Gemini'),
                ),
                ButtonSegment(
                  value: TextProvider.anthropic,
                  label: Text('Claude'),
                ),
              ],
              selected: {_settings.textProvider},
              onSelectionChanged: (s) => _settings.setTextProvider(s.single),
            ),
            if (_settings.textProvider == TextProvider.anthropic) ...[
              const SizedBox(height: 12),
              const Text(
                'API usage is billed separately from a Claude subscription.',
              ),
              _Links([
                (
                  'Get an Anthropic key',
                  'https://platform.claude.com/settings/keys',
                ),
                (
                  'Claude usage and billing',
                  'https://platform.claude.com/settings/billing',
                ),
              ], onOpen: _open),
              const SizedBox(height: 4),
              _KeyField(
                controller: _anthropicKey,
                label: 'Anthropic API key',
                onChanged: _settings.setAnthropicKey,
              ),
              const SizedBox(height: 12),
              _ModelField(
                controller: _anthropicModel,
                label: 'Claude model',
                loading: _loadingModels == 'Claude model',
                onPick: _pickAnthropicModel,
                onChanged: _settings.setAnthropicModel,
              ),
            ],
            const _Heading('Appearance'),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('Auto')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {_settings.themeMode},
              onSelectionChanged: (s) => _settings.setThemeMode(s.single),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Wallpaper colors'),
              subtitle: const Text(
                'Takes the app colors from your wallpaper, on Android 12 and '
                'later',
              ),
              value: _settings.wallpaperColors,
              onChanged: _settings.setWallpaperColors,
            ),
            const _Heading('Backup'),
            BackupSection(session: widget.session),
            const _Heading('About'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Open-source licenses'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Transcripts',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Buttons that open web pages, each a label and its address.
class _Links extends StatelessWidget {
  const _Links(this.links, {required this.onOpen});

  final List<(String, String)> links;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      children: [
        for (final (label, url) in links)
          TextButton.icon(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
            onPressed: () => onOpen(url),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: Text(label),
          ),
      ],
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
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _ModelField extends StatelessWidget {
  const _ModelField({
    required this.controller,
    required this.label,
    required this.loading,
    required this.onPick,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final bool loading;
  final VoidCallback onPick;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autocorrect: false,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: label,
        suffixIcon: loading
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : IconButton(
                tooltip: 'Choose from your available models',
                icon: const Icon(Icons.list),
                onPressed: onPick,
              ),
      ),
      onChanged: onChanged,
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
