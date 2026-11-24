import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:transcripts/notes.dart';
import 'package:transcripts/ruby_text.dart';
import 'package:transcripts/search.dart';
import 'package:transcripts/srt.dart';
import 'package:transcripts/transcript_view.dart';

import 'languages_fixture.dart';

void main() {
  test('folding ignores case and full-width forms, keeping offsets', () {
    expect(foldForSearch('Hello WORLD'), 'hello world');
    expect(foldForSearch('ＡＢＣ　１２３'), 'abc 123');
    expect(foldForSearch('ދިވެހި'), 'ދިވެހި');
    expect(foldForSearch('日本語のテキスト'), '日本語のテキスト');
    for (final s in ['Ünïcode', 'ＡＢＣ', '한국어 Text']) {
      expect(foldForSearch(s).length, s.length);
    }
  });

  test('matches cover lines and notes in reading order', () {
    final cues = [
      Cue(0, 5, const [CueItem('1', 'Plan the plan'), CueItem('2', 'no hit')]),
      Cue(10, 15, const [CueItem('1', 'ＰＬＡＮ ahead')]),
    ];
    const notes = [Note(id: 'a', time: 7, text: 'note about the plan')];
    final rows = transcriptRows(cues, notes);
    final matches = findMatches(rows, cues, 'plan');

    expect(
      [for (final m in matches) (m.row, m.cue, m.item, m.start, m.end)],
      [
        (0, 0, 0, 0, 4),
        (0, 0, 0, 9, 13),
        (1, null, null, 15, 19),
        (2, 1, 0, 0, 4),
      ],
    );
    expect(findMatches(rows, cues, '  '), isEmpty);
    expect(findMatches(rows, cues, 'missing'), isEmpty);
  });

  test('matches do not overlap', () {
    final cues = [
      Cue(0, 1, const [CueItem(null, 'aaaa')]),
    ];
    final matches = findMatches(transcriptRows(cues, const []), cues, 'aa');
    expect([for (final m in matches) m.start], [0, 2]);
  });

  test('Thaana and Japanese text match as written', () {
    final cues = [
      Cue(0, 1, const [CueItem('1', 'މި ދިވެހި ބަސް')]),
      Cue(1, 2, const [CueItem('1', '今日は会議です')]),
    ];
    final rows = transcriptRows(cues, const []);
    expect(findMatches(rows, cues, 'ދިވެހި').single.start, 3);
    expect(findMatches(rows, cues, '会議').single.cue, 1);
  });

  testWidgets('the list highlights matches and scrolls to the current one', (
    tester,
  ) async {
    final cues = [
      for (var i = 0; i < 60; i++)
        Cue(i * 2.0, i * 2.0 + 2, [
          CueItem('1', i % 20 == 5 ? 'line $i has a word' : 'line $i'),
        ]),
    ];
    final rows = transcriptRows(cues, const []);
    final matches = findMatches(rows, cues, 'word');
    expect(matches.length, 3);

    Widget view(SearchHighlight? search) => MaterialApp(
      home: Scaffold(
        body: TranscriptView(
          cues: cues,
          notes: const [],
          onNoteTap: (_) {},
          noteImage: (_) => null,
          onPictureTap: (_) {},
          language: shipped('en'),
          speakerNames: const {},
          speakerOverrides: const {},
          activeIndex: ValueNotifier(0),
          onSeek: (_) {},
          onLineLongPress: (_, _) {},
          search: search,
        ),
      ),
    );

    await tester.pumpWidget(view(SearchHighlight(matches, 0)));
    await tester.pumpAndSettle();
    expect(find.text('line 5 has a word'), findsOneWidget);
    expect(find.text('line 45 has a word'), findsNothing);

    TextSpan spanOf(String text) =>
        tester.widget<Text>(find.text(text)).textSpan! as TextSpan;
    final first = spanOf('line 5 has a word');
    expect(
      [for (final s in first.children!) (s as TextSpan).text],
      ['line 5 has a ', 'word'],
    );
    final current = (first.children![1] as TextSpan).style!.backgroundColor;

    await tester.pumpWidget(view(SearchHighlight(matches, 2)));
    await tester.pumpAndSettle();
    expect(find.text('line 45 has a word'), findsOneWidget);
    final last = spanOf('line 45 has a word');
    expect((last.children![1] as TextSpan).style!.backgroundColor, current);

    await tester.pumpWidget(view(null));
    await tester.pumpAndSettle();
    expect(find.text('line 0'), findsOneWidget);
    expect(spanOf('line 0').children, isNull);
  });

  testWidgets('matches are marked inside words with readings', (tester) async {
    final cues = [
      Cue(0, 2, const [CueItem(null, '今日は東京に行く')]),
    ];
    final readings = [
      Cue(0, 2, const [CueItem(null, '今日《きょう》は｜東京《とうきょう》に行く')]),
    ];
    final matches = findMatches(transcriptRows(cues, const []), cues, '京に');
    expect(matches, hasLength(1));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranscriptView(
            cues: cues,
            readings: readings,
            notes: const [],
            onNoteTap: (_) {},
            noteImage: (_) => null,
            onPictureTap: (_) {},
            language: shipped('ja'),
            speakerNames: const {},
            speakerOverrides: const {},
            activeIndex: ValueNotifier(-1),
            onSeek: (_) {},
            onLineLongPress: (_, _) {},
            search: SearchHighlight(matches, 0),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RubyWord), findsNWidgets(2));
    final word = tester.widget<RubyWord>(
      find.byWidgetPredicate((w) => w is RubyWord && w.reading == 'とうきょう'),
    );
    final parts = (word.base as TextSpan).children!.cast<TextSpan>();
    expect(parts.map((s) => s.text), ['東', '京']);
    expect(parts.last.style?.backgroundColor, currentMatchColor);

    final line = tester.widget<Text>(
      find.byWidgetPredicate(
        (w) => w is Text && w.textSpan?.toPlainText().contains('に行く') == true,
      ),
    );
    final marked = (line.textSpan! as TextSpan).children!
        .whereType<TextSpan>()
        .where((s) => s.style?.backgroundColor == currentMatchColor);
    expect(marked.map((s) => s.text), ['に']);
  });
}
