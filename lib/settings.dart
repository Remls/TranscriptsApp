import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'languages.dart';
import 'model_names.dart';

/// Storage for API keys.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class KeystoreSecretStore implements SecretStore {
  const KeystoreSecretStore();

  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// The service that translates and summarizes.
enum TextProvider { gemini, anthropic }

const defaultGeminiModel = 'gemini-3.8-flash';

const _geminiKeyName = 'geminiApiKey';
const _anthropicKeyName = 'anthropicApiKey';
const _geminiModelPref = 'geminiModel';
const _anthropicModelPref = 'anthropicModel';
const _geminiModelNamePref = 'geminiModelName';
const _anthropicModelNamePref = 'anthropicModelName';
const _textProviderPref = 'textProvider';
const _themePref = 'theme';
const _transcribeLangPref = 'transcribeLang';
const _translateLangPref = 'translateLang';
const _wallpaperColorsPref = 'wallpaperColors';
const _readingsPref = 'readings';

class Settings extends ChangeNotifier {
  Settings._(this._prefs, this._secrets, this._geminiKey, this._anthropicKey);

  static Future<Settings> load(
    SharedPreferences prefs,
    SecretStore secrets,
  ) async {
    return Settings._(
      prefs,
      secrets,
      await secrets.read(_geminiKeyName) ?? '',
      await secrets.read(_anthropicKeyName) ?? '',
    );
  }

  final SharedPreferences _prefs;
  final SecretStore _secrets;
  String _geminiKey;
  String _anthropicKey;

  String get geminiKey => _geminiKey;
  String get anthropicKey => _anthropicKey;

  /// The transcription model. Falls back to [defaultGeminiModel] when none
  /// has been chosen.
  String get geminiModel {
    final chosen = _prefs.getString(_geminiModelPref) ?? '';
    return chosen.isEmpty ? defaultGeminiModel : chosen;
  }

  String get anthropicModel => _prefs.getString(_anthropicModelPref) ?? '';

  /// The name the chosen Gemini model shows people, or one made from its id
  /// when it was typed in.
  String get geminiModelName {
    final name = _prefs.getString(_geminiModelNamePref) ?? '';
    return name.isEmpty ? modelDisplayName(geminiModel) : name;
  }

  /// The name the chosen Claude model shows people, or one made from its id
  /// when it was typed in.
  String get anthropicModelName {
    final name = _prefs.getString(_anthropicModelNamePref) ?? '';
    return name.isEmpty ? modelDisplayName(anthropicModel) : name;
  }

  /// Whether Claude has a key and a model.
  bool get claudeReady => anthropicKey.isNotEmpty && anthropicModel.isNotEmpty;

  /// The provider for translations and summaries: the chosen one, or Gemini
  /// when Claude is chosen but not [claudeReady].
  TextProvider get textProvider {
    final name = _prefs.getString(_textProviderPref);
    final chosen = TextProvider.values.firstWhere(
      (p) => p.name == name,
      orElse: () => TextProvider.gemini,
    );
    return chosen == TextProvider.anthropic && !claudeReady
        ? TextProvider.gemini
        : chosen;
  }

  ThemeMode get themeMode {
    final name = _prefs.getString(_themePref);
    return ThemeMode.values.firstWhere(
      (m) => m.name == name,
      orElse: () => ThemeMode.system,
    );
  }

  /// The code of the language preselected for new transcriptions.
  String get transcribeLang =>
      _prefs.getString(_transcribeLangPref) ?? defaultLang;

  /// The code of the language preselected for new translations and
  /// summaries.
  String get translateLang =>
      _prefs.getString(_translateLangPref) ?? englishLang;

  /// Whether the theme takes its colors from the system wallpaper.
  bool get wallpaperColors => _prefs.getBool(_wallpaperColorsPref) ?? true;

  /// Whether transcripts show readings above kanji when they have them.
  bool get readings => _prefs.getBool(_readingsPref) ?? true;

  Future<void> setGeminiKey(String value) async {
    _geminiKey = value.trim();
    await _writeSecret(_geminiKeyName, _geminiKey);
  }

  Future<void> setAnthropicKey(String value) async {
    _anthropicKey = value.trim();
    await _writeSecret(_anthropicKeyName, _anthropicKey);
  }

  /// Chooses the Gemini model [value], shown as [name] when it has one.
  Future<void> setGeminiModel(String value, {String name = ''}) async {
    await _prefs.setString(_geminiModelNamePref, name);
    await _setPref(_geminiModelPref, value.trim());
  }

  /// Chooses the Claude model [value], shown as [name] when it has one.
  Future<void> setAnthropicModel(String value, {String name = ''}) async {
    await _prefs.setString(_anthropicModelNamePref, name);
    await _setPref(_anthropicModelPref, value.trim());
  }

  Future<void> setTextProvider(TextProvider value) =>
      _setPref(_textProviderPref, value.name);

  Future<void> setThemeMode(ThemeMode value) =>
      _setPref(_themePref, value.name);

  Future<void> setWallpaperColors(bool value) async {
    await _prefs.setBool(_wallpaperColorsPref, value);
    notifyListeners();
  }

  Future<void> setReadings(bool value) async {
    await _prefs.setBool(_readingsPref, value);
    notifyListeners();
  }

  Future<void> setTranscribeLang(String code) =>
      _setPref(_transcribeLangPref, code);

  Future<void> setTranslateLang(String code) =>
      _setPref(_translateLangPref, code);

  Future<void> _setPref(String key, String value) async {
    await _prefs.setString(key, value);
    notifyListeners();
  }

  Future<void> _writeSecret(String key, String value) async {
    if (value.isEmpty) {
      await _secrets.delete(key);
    } else {
      await _secrets.write(key, value);
    }
    notifyListeners();
  }
}
