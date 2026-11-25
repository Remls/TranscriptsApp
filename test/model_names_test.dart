import 'package:flutter_test/flutter_test.dart';
import 'package:transcripts/model_names.dart';

void main() {
  test('model ids read as names', () {
    expect(modelDisplayName('gemini-3.8-flash'), 'Gemini 3.8 Flash');
    expect(modelDisplayName('gemini-3.8-flash-lite'), 'Gemini 3.8 Flash-Lite');
    expect(
      modelDisplayName('gemini-3.8-pro-preview'),
      'Gemini 3.8 Pro Preview',
    );
    expect(modelDisplayName('claude-opus-5-5'), 'Claude Opus 5.5');
    expect(modelDisplayName('claude-sonnet-4-5-20250929'), 'Claude Sonnet 4.5');
    expect(modelDisplayName('custom'), 'Custom');
  });
}
