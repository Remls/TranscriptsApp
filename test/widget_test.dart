import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:transcripts/file_drawer.dart';
import 'package:transcripts/library.dart';
import 'package:transcripts/markdown_view.dart';
import 'package:transcripts/notes.dart';
import 'package:transcripts/srt.dart';
import 'package:transcripts/transcript_view.dart';

import 'languages_fixture.dart';

Recording _recording(String relPath, {bool hasTranscript = false}) {
  return Recording(
    file: File('/library/$relPath'),
    relPath: relPath,
    lang: 'en',
    hasTranscript: hasTranscript,
    hasTranslation: false,
    hasSummary: false,
  );
}

void main() {
  testWidgets('drawer expands the open recording folder and reports taps', (
    tester,
  ) async {
    Recording? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FileDrawer(
            sections: [
              LibrarySection('first', [_recording('first/alpha.mp3')]),
              LibrarySection('second', [
                _recording('second/beta.mp3', hasTranscript: true),
                _recording('second/gamma.mp4'),
              ]),
            ],
            selected: 'second/beta.mp3',
            expanded: {},
            durationOf: (_) => 75,
            isBusy: (r) => r.relPath == 'second/gamma.mp4',
            onSelect: (r) => tapped = r,
            onLibraryAction: (_) {},
            onFolderAction: (_, _) {},
            onRecordingAction: (_, _) {},
          ),
        ),
      ),
    );

    expect(find.text('first'), findsOneWidget);
    expect(find.text('alpha'), findsNothing);
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('1:15'), findsNWidgets(2));
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
    expect(find.text('Trash'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    await tester.tap(find.text('gamma'));
    expect(tapped?.relPath, 'second/gamma.mp4');
  });

  testWidgets('drawer shows an empty state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FileDrawer(
            sections: const [],
            selected: null,
            expanded: {},
            durationOf: (_) => 75,
            isBusy: (r) => r.relPath == 'second/gamma.mp4',
            onSelect: (_) {},
            onLibraryAction: (_) {},
            onFolderAction: (_, _) {},
            onRecordingAction: (_, _) {},
          ),
        ),
      ),
    );
    expect(find.text('No recordings yet'), findsOneWidget);
  });

  testWidgets('transcript applies names and overrides, and seeks on tap', (
    tester,
  ) async {
    double? soughtTo;
    (int, int)? pressed;
    final active = ValueNotifier<int>(-1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranscriptView(
            cues: [
              Cue(1, 4, const [CueItem('1', 'first line')]),
              Cue(65, 70, const [
                CueItem('1', 'second line'),
                CueItem(null, 'third line'),
              ]),
            ],
            notes: const [],
            onNoteTap: (_) {},
            noteImage: (_) => null,
            onPictureTap: (_) {},
            language: shipped('en'),
            speakerNames: const {'2': 'Named'},
            speakerOverrides: const {'1:0': '2'},
            activeIndex: active,
            onSeek: (s) => soughtTo = s,
            onLineLongPress: (cue, item) => pressed = (cue, item),
          ),
        ),
      ),
    );

    expect(find.text('Sp 1'), findsOneWidget);
    expect(find.text('Named'), findsOneWidget);
    expect(find.text('0:01'), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget);
    expect(find.text('Jump to current'), findsNothing);

    await tester.tap(find.text('second line'));
    expect(soughtTo, 65);

    await tester.longPress(find.text('third line'));
    expect(pressed, (1, 1));

    active.value = 1;
    await tester.pumpAndSettle();
    expect(find.text('Jump to current'), findsNothing);
  });

  testWidgets('a line with no right-to-left letters reads left to right', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranscriptView(
            cues: [
              Cue(0, 5, const [CueItem('1', 'ދިވެހި line')]),
              Cue(5, 9, const [CueItem('2', 'English only.')]),
            ],
            notes: const [],
            onNoteTap: (_) {},
            noteImage: (_) => null,
            onPictureTap: (_) {},
            language: shipped('dv'),
            speakerNames: const {},
            speakerOverrides: const {},
            activeIndex: ValueNotifier<int>(-1),
            onSeek: (_) {},
            onLineLongPress: (_, _) {},
          ),
        ),
      ),
    );

    Text line(String text) => tester.widget<Text>(find.text(text));
    expect(line('ދިވެހި line').textDirection, TextDirection.rtl);
    expect(line('English only.').textDirection, TextDirection.ltr);
    expect(line('English only.').textAlign, TextAlign.right);
  });

  testWidgets('notes sit between the lines and open on tap', (tester) async {
    Note? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranscriptView(
            cues: [
              Cue(0, 5, const [CueItem('1', 'first')]),
              Cue(5, 9, const [CueItem('1', 'second')]),
            ],
            notes: const [Note(id: 'n', time: 3, text: 'what they mean')],
            onNoteTap: (n) => tapped = n,
            noteImage: (_) => null,
            onPictureTap: (_) {},
            language: shipped('dv'),
            speakerNames: const {},
            speakerOverrides: const {},
            activeIndex: ValueNotifier<int>(-1),
            onSeek: (_) {},
            onLineLongPress: (_, _) {},
          ),
        ),
      ),
    );

    expect(find.text('Note at 0:03'), findsOneWidget);
    final first = tester.getTopLeft(find.text('first')).dy;
    final note = tester.getTopLeft(find.text('what they mean')).dy;
    final second = tester.getTopLeft(find.text('second')).dy;
    expect(first < note && note < second, isTrue);

    await tester.tap(find.text('what they mean'));
    expect(tapped?.id, 'n');
  });

  testWidgets('jump button shows only for an off-screen line, pointing at it', (
    tester,
  ) async {
    final active = ValueNotifier<int>(-1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranscriptView(
            cues: [
              for (var i = 0; i < 60; i++)
                Cue(i * 2.0, i * 2.0 + 2, [CueItem('1', 'line $i')]),
            ],
            notes: const [],
            onNoteTap: (_) {},
            noteImage: (_) => null,
            onPictureTap: (_) {},
            language: shipped('en'),
            speakerNames: const {},
            speakerOverrides: const {},
            activeIndex: active,
            onSeek: (_) {},
            onLineLongPress: (_, _) {},
          ),
        ),
      ),
    );
    final list = find.byType(TranscriptView);

    active.value = 1;
    await tester.pumpAndSettle();
    await tester.drag(list, const Offset(0, -40));
    await tester.pumpAndSettle();
    expect(find.text('line 1'), findsOneWidget);
    expect(find.text('Jump to current'), findsNothing);

    await tester.drag(list, const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(find.text('line 1'), findsNothing);
    expect(find.text('Jump to current'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);

    active.value = 58;
    await tester.pumpAndSettle();
    expect(find.text('Jump to current'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);

    await tester.tap(find.text('Jump to current'));
    await tester.pumpAndSettle();
    expect(find.text('line 58'), findsOneWidget);
    expect(find.text('Jump to current'), findsNothing);
  });

  testWidgets('markdown renders headings, bullets and inline styles', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownView(
            '## Overview\n\nFirst line\nsecond line.\n\n'
            '- a **bold** point\n- snake_case_name stays\n',
          ),
        ),
      ),
    );

    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('First line second line.'), findsOneWidget);
    expect(find.text('a bold point'), findsOneWidget);
    expect(find.text('snake_case_name stays'), findsOneWidget);
    expect(find.text('•'), findsNWidgets(2));

    final spans = markdownSpans('a **b** and *c* with `d`');
    expect(spans.map((s) => (s as TextSpan).text), [
      'a ',
      'b',
      ' and ',
      'c',
      ' with ',
      'd',
    ]);
    expect((spans[1] as TextSpan).style?.fontWeight, FontWeight.w700);
    expect((spans[3] as TextSpan).style?.fontStyle, FontStyle.italic);
  });
}
