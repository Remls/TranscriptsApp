import 'package:http/http.dart' as http;

import 'anthropic.dart';
import 'gemini.dart';
import 'settings.dart';

/// A picture sent along with a prompt, introduced by [label].
class PromptImage {
  const PromptImage({
    required this.label,
    required this.bytes,
    required this.mimeType,
  });

  final String label;
  final List<int> bytes;
  final String mimeType;
}

/// Runs a text prompt on the provider chosen for translation and summaries.
class TextGenerator {
  const TextGenerator({
    required this.provider,
    required this.apiKey,
    required this.model,
  });

  /// The generator for the current settings, or a message naming the setting
  /// that is missing.
  static (TextGenerator?, String?) fromSettings(Settings settings) {
    switch (settings.textProvider) {
      case TextProvider.gemini:
        if (settings.geminiKey.isEmpty) {
          return (null, 'Add a Gemini API key in Settings');
        }
        if (settings.geminiModel.isEmpty) {
          return (null, 'Choose a Gemini model in Settings');
        }
        return (
          TextGenerator(
            provider: TextProvider.gemini,
            apiKey: settings.geminiKey,
            model: settings.geminiModel,
          ),
          null,
        );
      case TextProvider.anthropic:
        if (settings.anthropicKey.isEmpty) {
          return (null, 'Add an Anthropic API key in Settings');
        }
        if (settings.anthropicModel.isEmpty) {
          return (null, 'Choose a Claude model in Settings');
        }
        return (
          TextGenerator(
            provider: TextProvider.anthropic,
            apiKey: settings.anthropicKey,
            model: settings.anthropicModel,
          ),
          null,
        );
    }
  }

  final TextProvider provider;
  final String apiKey;
  final String model;

  /// Streams the response to [input] under the instructions in [prompt].
  Stream<String> generate(
    http.Client client, {
    required String prompt,
    required String input,
    List<PromptImage> images = const [],
  }) {
    return switch (provider) {
      TextProvider.gemini =>
        GeminiClient(apiKey: apiKey, client: client).generateStream(
          model: model,
          prompt: prompt,
          input: input,
          images: images,
        ),
      TextProvider.anthropic =>
        AnthropicClient(apiKey: apiKey, client: client).generateStream(
          model: model,
          system: prompt,
          input: input,
          images: images,
        ),
    };
  }
}
