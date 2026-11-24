import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:transcripts/fullscreen_video.dart';
import 'package:transcripts/settings.dart';
import 'package:transcripts/srt.dart';

import 'languages_fixture.dart';

void main() {
  test('subtitles cycle off, transcript, translation', () {
    SubtitleMode next(SubtitleMode m, bool translated) =>
        nextSubtitleMode(m, hasTranslation: translated);
    expect(next(.off, true), SubtitleMode.transcript);
    expect(next(.transcript, true), SubtitleMode.translation);
    expect(next(.translation, true), SubtitleMode.off);
    expect(next(.transcript, false), SubtitleMode.off);
  });

  test('subtitle lines drop speaker labels and empty lines', () {
    final cue = Cue(0, 4, const [
      CueItem('1', 'first speaker'),
      CueItem('2', '  second speaker '),
      CueItem(null, ' '),
    ]);
    expect(subtitleLines(cue), ['first speaker', 'second speaker']);
  });

  test('subtitle lines take readings where they match', () {
    final cue = Cue(0, 4, const [CueItem('1', '東京に行く'), CueItem('2', '今日は雨')]);
    final readings = Cue(0, 4, const [
      CueItem('1', ' ｜東京《とうきょう》に行く'),
      CueItem('2', '昨日《きのう》は雨'),
    ]);
    expect(subtitleLines(cue, readings: readings), ['｜東京《とうきょう》に行く', '今日は雨']);
    expect(subtitleLines(cue, readings: Cue(0, 4, const [CueItem('1', 'x')])), [
      '東京に行く',
      '今日は雨',
    ]);
  });

  testWidgets('the subtitle layer leaves the screen its full size', (
    tester,
  ) async {
    const fill = Key('fill');
    Future<void> show(List<Cue> cues, int index) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(
                child: ColoredBox(key: fill, color: Colors.black),
              ),
              SubtitleLayer(
                cues: cues,
                index: ValueNotifier(index),
                language: shipped('en'),
                raised: false,
              ),
            ],
          ),
        ),
      ),
    );

    await show(const [], -1);
    expect(tester.getSize(find.byKey(fill)), const Size(800, 600));

    await show([
      Cue(0, 4, const [CueItem('1', 'a line')]),
    ], 0);
    expect(tester.getSize(find.byKey(fill)), const Size(800, 600));
    expect(find.text('a line'), findsOneWidget);
  });
}
