import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transcripts/prompts.dart';
import 'package:transcripts/settings.dart';

import 'languages_fixture.dart';

class MemorySecretStore implements SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  test('settings start with defaults and persist changes', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySecretStore();

    final settings = await Settings.load(prefs, secrets);
    expect(settings.geminiKey, '');
    expect(settings.geminiModel, 'gemini-3.8-flash');
    expect(settings.textProvider, TextProvider.gemini);
    expect(settings.themeMode, ThemeMode.system);
    expect(settings.subtitleMode, SubtitleMode.transcript);
    expect(settings.wallpaperColors, isTrue);
    expect(settings.transcribeLang, 'dv');

    await settings.setGeminiKey('  secret ');
    await settings.setGeminiModel(' model-x ');
    await settings.setTextProvider(TextProvider.anthropic);
    await settings.setThemeMode(ThemeMode.dark);
    await settings.setSubtitleMode(SubtitleMode.off);
    await settings.setWallpaperColors(false);
    await settings.setTranscribeLang('ko');

    final reloaded = await Settings.load(prefs, secrets);
    expect(reloaded.geminiKey, 'secret');
    expect(reloaded.geminiModel, 'model-x');
    expect(reloaded.textProvider, TextProvider.anthropic);
    expect(reloaded.themeMode, ThemeMode.dark);
    expect(reloaded.subtitleMode, SubtitleMode.off);
    expect(reloaded.wallpaperColors, isFalse);
    expect(reloaded.transcribeLang, 'ko');
    expect(prefs.getKeys().any((k) => prefs.get(k) == 'secret'), isFalse);

    await reloaded.setGeminiModel('');
    expect(reloaded.geminiModel, 'gemini-3.8-flash');

    await reloaded.setGeminiKey('');
    expect(secrets.values, isEmpty);
  });

  test('transcription prompts match the fixtures', () {
    for (final lang in ['dv', 'ja', 'en']) {
      expect(
        buildTranscriptionPrompt(shipped(lang)),
        File('test/fixtures/prompt_$lang.txt').readAsStringSync(),
        reason: lang,
      );
    }
  });
}
