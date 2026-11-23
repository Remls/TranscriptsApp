import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:transcripts/job_panel.dart';
import 'package:transcripts/language_lookup.dart';
import 'package:transcripts/languages.dart';
import 'package:transcripts/prompts.dart';

import 'languages_fixture.dart';

const _tamil = Language(code: 'ta', name: 'Tamil', script: 'Tamil');

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('languages_test'));
  tearDown(() => root.deleteSync(recursive: true));

  test('the list starts with the shipped languages and keeps changes', () {
    final list = LanguageList(root);
    expect([for (final l in list.all) l.code], ['dv', 'ja', 'ko', 'hi', 'en']);
    expect(File(p.join(root.path, '.languages.json')).existsSync(), isFalse);

    list.put(_tamil);
    list.put(
      const Language(
        code: 'ko',
        name: 'Korean',
        script: 'Hangul',
        textScale: 1.3,
      ),
    );
    list.remove('hi');
    list.remove('en');

    final reloaded = LanguageList(root);
    expect(
      [for (final l in reloaded.all) l.code],
      ['dv', 'ja', 'ko', 'en', 'ta'],
    );
    expect(reloaded['ko']!.textScale, 1.3);
    expect(reloaded['ta']!.name, 'Tamil');
    expect(reloaded.resolve('xx').name, 'Unknown language (xx)');
    expect(reloaded.resolve('xx').rtl, isFalse);
  });

  test('a list file without the fixed languages gets them back', () {
    File(
      p.join(root.path, '.languages.json'),
    ).writeAsStringSync('[{"code": "ta", "name": "Tamil", "script": "Tamil"}]');
    expect(
      [for (final l in LanguageList(root).all) l.code],
      ['ta', 'dv', 'en'],
    );
  });

  test('merging adds missing entries, or takes all on an unchanged list', () {
    const incoming =
        '[{"code": "ta", "name": "Tamil", "script": "Tamil"}, '
        '{"code": "ko", "name": "Korean (theirs)", "script": "Hangul"}]';
    final fresh = LanguageList(root);
    expect(fresh.merge(incoming), 2);
    expect(fresh['ko']!.name, 'Korean (theirs)');

    root.deleteSync(recursive: true);
    root.createSync();
    final changed = LanguageList(root)..remove('hi');
    expect(changed.merge(incoming), 1);
    expect(changed['ko']!.name, 'Korean');
    expect(changed['ta']!.name, 'Tamil');
    expect(changed.merge('not json'), 0);

    final picked = LanguageList(root).jsonFor(['ta', 'xx']);
    expect(
      [for (final l in jsonDecode(picked) as List) (l as Map)['code']],
      ['ta'],
    );
  });

  test('a line flips direction only without letters in the view direction', () {
    expect(lineIsRtl('ދިވެހި', rtl: true), isTrue);
    expect(lineIsRtl('Shipping ދިވެހި cost', rtl: true), isTrue);
    expect(lineIsRtl("Okay, I'll send it today.", rtl: true), isFalse);
    expect(lineIsRtl('12:30 ...', rtl: true), isTrue);
    expect(lineIsRtl('first line', rtl: false), isFalse);
    expect(lineIsRtl('مرحبا', rtl: false), isTrue);
    expect(lineIsRtl('hello مرحبا', rtl: false), isFalse);
    expect(lineIsRtl('12:30', rtl: false), isFalse);
  });

  test('codes are two or more lowercase letters', () {
    expect(isValidLangCode('ta'), isTrue);
    expect(isValidLangCode('fil'), isTrue);
    for (final code in ['t', 'TA', 'ta1', 'zh-hant', '']) {
      expect(isValidLangCode(code), isFalse, reason: code);
    }
  });

  test('notes replace the plain language line in the prompt', () {
    final plain = buildTranscriptionPrompt(_tamil);
    expect(
      plain,
      contains(
        'LANGUAGE NOTE:\n- This audio is primarily in '
        'Tamil, written in Tamil.\n',
      ),
    );
    final noted = buildTranscriptionPrompt(
      const Language(
        code: 'ta',
        name: 'Tamil',
        script: 'Tamil',
        notes: 'It is not Malayalam.\n\n  Use Tamil script only. ',
      ),
    );
    expect(
      noted,
      contains(
        'CRITICAL LANGUAGE NOTE:\n- It is not Malayalam.\n'
        '- Use Tamil script only.\n- Speakers also mix in English',
      ),
    );
    expect(
      buildTranscriptionPrompt(shipped('dv')),
      File('test/fixtures/prompt_dv.txt').readAsStringSync(),
    );
  });

  testWidgets('the picker adds a language and selects it', (tester) async {
    final list = LanguageList(root);
    var value = 'dv';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => LanguageDropdown(
              languages: list,
              lookup: LanguageLookup(
                catalog: Future.value(LanguageCatalog([])),
                askGemini: (_) => throw const LookupException('offline'),
              ),
              value: value,
              onChanged: (code) => setState(() => value = code),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Dhivehi'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add language…').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Enter the language name'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Tamil');
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Code'), 'ja');
    await tester.pump();
    expect(find.text('Already used by Japanese'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Code'), 'ta');
    await tester.enterText(find.widgetWithText(TextField, 'Script'), 'Tamil');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(value, 'ta');
    expect(list['ta']!.name, 'Tamil');
    expect(find.text('Tamil'), findsOneWidget);
  });
}
