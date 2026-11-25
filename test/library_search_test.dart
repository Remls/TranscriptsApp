import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:transcripts/languages.dart';
import 'package:transcripts/library_search.dart';
import 'package:transcripts/library_search_screen.dart';

const _srt =
    '1\n00:00:01,000 --> 00:00:04,000\nSpeaker 1: the budget is set\n\n'
    '2\n00:00:10,000 --> 00:00:12,000\nSpeaker 2: no hit here\n'
    'Speaker 1: Budget again\n';

void main() {
  late Directory root;

  void touch(String rel, String content) {
    File(p.joinAll([root.path, ...rel.split('/')]))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('library_search_test');
    touch('set/a.mp3', 'audio');
    touch('set/.a/transcript.srt', _srt);
    touch('set/.a/lang', 'dv\n');
    touch(
      'set/.a/translation.srt',
      '1\n00:00:01,000 --> 00:00:04,000\nThe budget\n',
    );
    touch(
      'set/.a/translation.ja.srt',
      '1\n00:00:01,000 --> 00:00:04,000\nbudget の話\n',
    );
    touch(
      'set/.a/notes.json',
      '[{"id": "n1", "time": 7.5, "text": "check the budget"}]',
    );
    touch('loose.m4a', 'audio');
    touch(
      '.loose/transcript.srt',
      '1\n00:00:02,000 --> 00:00:03,000\nbudget\n',
    );
    touch('.trash/1-0/old.mp3', 'audio');
    touch('.trash/1-0/.old/transcript.srt', _srt);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('finds lines, translations and notes, skipping the trash', () {
    final result = searchLibrary(root.path, 'BUDGET');
    expect(result.capped, isFalse);
    expect(
      [
        for (final h in result.hits)
          (h.relPath, h.source, h.time, h.cue, h.item, h.noteId, h.lang),
      ],
      [
        ('set/a.mp3', HitSource.transcript, 1.0, 0, 0, null, 'dv'),
        ('set/a.mp3', HitSource.transcript, 10.0, 1, 1, null, 'dv'),
        ('set/a.mp3', HitSource.translation, 1.0, 0, 0, null, 'en'),
        ('set/a.mp3', HitSource.translation, 1.0, 0, 0, null, 'ja'),
        ('set/a.mp3', HitSource.note, 7.5, null, null, 'n1', 'en'),
        ('loose.m4a', HitSource.transcript, 2.0, 0, 0, null, 'dv'),
      ],
    );
    final first = result.hits.first;
    expect(first.text.substring(first.start, first.end), 'budget');
    expect(searchLibrary(root.path, ' ').hits, isEmpty);
  });

  test('the search stops at its limit', () {
    final result = searchLibrary(root.path, 'budget', limit: 3);
    expect(result.hits.length, 3);
    expect(result.capped, isTrue);
    expect(searchLibrary(root.path, 'budget', limit: 6).capped, isFalse);
  });

  test('snippets keep the match and mark cut ends', () {
    final text = '${'a' * 60}MATCH${'b' * 60}';
    final (s, start, end) = snippet(text, 60, 65, context: 10);
    expect(s, '…${'a' * 10}MATCH${'b' * 10}…');
    expect(s.substring(start, end), 'MATCH');
    expect(snippet('one\ntwo', 4, 7), ('one two', 4, 7));
  });

  test('titles name the folder and the recording', () {
    expect(recordingTitle('set/a.mp3'), ('set', 'a'));
    expect(recordingTitle('loose.m4a'), ('Other', 'loose'));
  });

  testWidgets('tapping a hit returns it with the query', (tester) async {
    const hit = LibraryHit(
      relPath: 'set/a.mp3',
      lang: 'en',
      source: HitSource.translation,
      time: 65,
      cue: 3,
      item: 0,
      noteId: null,
      text: 'The budget is set',
      start: 4,
      end: 10,
    );
    final queries = <String>[];
    PickedHit? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await Navigator.push<PickedHit>(
                context,
                MaterialPageRoute(
                  builder: (_) => LibrarySearchScreen(
                    rootPath: '/library',
                    languageOf: Language.unknown,
                    search: (_, query) async {
                      queries.add(query);
                      return const LibrarySearchResult([hit], capped: true);
                    },
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'budget');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(queries, ['budget']);
    expect(find.text('set / a'), findsOneWidget);
    expect(find.text('Translation, 1:05'), findsOneWidget);
    expect(find.text('The budget is set'), findsOneWidget);
    expect(find.textContaining('Showing the first 1 matches'), findsOneWidget);

    await tester.tap(find.text('The budget is set'));
    await tester.pumpAndSettle();
    expect(picked?.hit, same(hit));
    expect(picked?.query, 'budget');
  });

  testWidgets('matches in one line show as one result', (tester) async {
    LibraryHit at(int start) => LibraryHit(
      relPath: 'a.mp3',
      lang: 'en',
      source: HitSource.transcript,
      time: 0,
      cue: 0,
      item: 0,
      noteId: null,
      text: 'meeting here',
      start: start,
      end: start + 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LibrarySearchScreen(
          rootPath: '/library',
          languageOf: Language.unknown,
          search: (_, _) async =>
              LibrarySearchResult([at(1), at(2), at(9)], capped: false),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'e');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('meeting here'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    final span =
        tester.widget<Text>(find.text('meeting here')).textSpan! as TextSpan;
    expect(
      [for (final s in span.children!) (s as TextSpan).text],
      ['m', 'e', '', 'e', 'ting h', 'e', 're'],
    );
  });
}
