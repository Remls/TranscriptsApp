import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:transcripts/language_editor.dart';
import 'package:transcripts/language_lookup.dart';
import 'package:transcripts/languages.dart';

http.Response _sse(String text) {
  final event = {
    'candidates': [
      {
        'content': {
          'parts': [
            {'text': text},
          ],
        },
      },
    ],
  };
  return http.Response.bytes(
    utf8.encode('data: ${jsonEncode(event)}\n\n'),
    200,
  );
}

void main() {
  final catalog = LanguageCatalog.parse(
    File('assets/languages.json').readAsStringSync(),
  );

  test('the bundled table finds languages by name, own name and code', () {
    String first(String q) => catalog.search(q).first.code;
    expect(first('tamil'), 'ta');
    expect(first('Urd'), 'ur');
    expect(first('தமிழ்'), 'ta');
    expect(first('fil'), 'fil');
    expect(first('persian'), 'fa');

    final urdu = catalog.search('urdu').first;
    expect((urdu.script, urdu.rtl), ('Arabic', true));
    expect(catalog.search('kurdish').length, greaterThan(1));
    expect(catalog.search('zzzz'), isEmpty);
    expect(catalog.search('a').length, 6);
  });

  test('Gemini answers become suggestions', () async {
    late String prompt;
    final client = MockClient((req) async {
      prompt = (jsonDecode(req.body) as Map)['contents'][0]['parts'][0]['text'];
      return _sse(
        '```json\n{"code": "XYZ", "name": "Example", "script": "Latin", '
        '"rtl": false}\n```',
      );
    });
    final found = await askGeminiForLanguage(
      client,
      apiKey: 'key',
      model: 'model-x',
      name: 'example',
    );
    expect(prompt, languagePrompt('example'));
    expect(
      (found.code, found.name, found.script, found.rtl),
      ('xyz', 'Example', 'Latin', false),
    );

    final unknown = MockClient((_) async => _sse('{"error": "unknown"}'));
    expect(
      askGeminiForLanguage(unknown, apiKey: 'k', model: 'm', name: 'blah'),
      throwsA(isA<LookupException>()),
    );
  });

  testWidgets('the add form fills in from the table and from Gemini', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('language_lookup_test');
    addTearDown(() => root.deleteSync(recursive: true));
    final list = LanguageList(root);
    final asked = <String>[];
    final lookup = LanguageLookup(
      catalog: Future.value(catalog),
      askGemini: (name) async {
        asked.add(name);
        return const LanguageSuggestion(
          code: 'xyz',
          name: 'Example',
          script: 'Old script',
          rtl: true,
        );
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showLanguageEditor(context, list, lookup),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'japan');
    await tester.pump();
    expect(find.text('Added'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'urd');
    await tester.pump();
    await tester.tap(find.text('Urdu (اردو)'));
    await tester.pump();
    String text(int i) =>
        tester.widget<TextField>(find.byType(TextField).at(i)).controller!.text;
    expect([text(0), text(1), text(2)], ['Urdu', 'ur', 'Arabic']);
    expect(find.textContaining('Ask Gemini'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'qqq');
    await tester.pump();
    await tester.tap(find.textContaining('Ask Gemini'));
    await tester.pumpAndSettle();
    expect(asked, ['qqq']);
    expect([text(0), text(1), text(2)], ['Example', 'xyz', 'Old script']);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(list['xyz']?.rtl, isTrue);
  });

  testWidgets('a set code is locked and filled in from the table', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('language_lookup_test');
    addTearDown(() => root.deleteSync(recursive: true));
    final list = LanguageList(root);
    final lookup = LanguageLookup(
      catalog: Future.value(catalog),
      askGemini: (_) => throw const LookupException('offline'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showLanguageEditor(context, list, lookup, code: 'ur'),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final code = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Code'),
    );
    expect((code.controller!.text, code.enabled), ('ur', false));
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Name'))
          .controller!
          .text,
      'Urdu',
    );
    expect(find.textContaining('Ask Gemini'), findsNothing);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(list['ur']?.rtl, isTrue);
  });
}
