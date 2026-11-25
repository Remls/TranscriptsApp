import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:transcripts/fullscreen_video.dart';
import 'package:transcripts/srt.dart';

import 'languages_fixture.dart';

void main() {
  test('the menu offers the transcript and every translation', () {
    expect(
      subtitleChoices(hasTranscript: false, translations: const []),
      isEmpty,
    );
    expect(subtitleChoices(hasTranscript: true, translations: const []), [
      (SubtitleMode.off, null),
      (SubtitleMode.transcript, null),
    ]);
    expect(
      subtitleChoices(hasTranscript: true, translations: const ['en', 'ja']),
      [
        (SubtitleMode.off, null),
        (SubtitleMode.transcript, null),
        (SubtitleMode.translation, 'en'),
        (SubtitleMode.translation, 'ja'),
      ],
    );
  });

  test('the first available subtitles are chosen, or off', () {
    SubtitleMode first(
      List<SubtitleMode> preferred,
      bool transcript,
      bool translated,
    ) => firstSubtitles(
      preferred,
      hasTranscript: transcript,
      hasTranslation: translated,
    );
    const summary = [SubtitleMode.translation, SubtitleMode.transcript];
    expect(first(const [.transcript], true, true), SubtitleMode.transcript);
    expect(first(const [.transcript], false, true), SubtitleMode.off);
    expect(first(const [.translation], true, false), SubtitleMode.off);
    expect(first(summary, true, true), SubtitleMode.translation);
    expect(first(summary, true, false), SubtitleMode.transcript);
    expect(first(summary, false, false), SubtitleMode.off);
  });

  test('subtitle lines drop speaker labels and empty lines', () {
    final cue = Cue(0, 4, const [
      CueItem('1', 'first speaker'),
      CueItem('2', '  second speaker '),
      CueItem(null, ' '),
    ]);
    expect(subtitleLines(cue), ['– first speaker', '– second speaker']);
  });

  test('lines from more than one speaker start with a dash', () {
    final mixed = Cue(0, 4, const [
      CueItem('1', 'first'),
      CueItem('2', 'second'),
    ]);
    expect(subtitleLines(mixed), ['– first', '– second']);
    expect(subtitleLines(mixed, speakerOf: (item) => '1'), ['first', 'second']);
    final one = Cue(0, 4, const [CueItem('1', 'a'), CueItem('1', 'b')]);
    expect(subtitleLines(one), ['a', 'b']);
    expect(subtitleLines(one, speakerOf: (item) => item == 1 ? '3' : null), [
      '– a',
      '– b',
    ]);
  });

  testWidgets('wrapped lines are evened out', (tester) async {
    const style = TextStyle(fontSize: 10);
    const span = TextSpan(text: 'aaaa bbbb cccc dddd eeee f', style: style);
    double width(double max) => balancedWidth(
      span,
      max,
      textScaler: TextScaler.noScaling,
      textDirection: .ltr,
    );
    expect(width(1000), 1000);
    final even = width(220);
    expect(even, lessThan(220));
    final painter = TextPainter(text: span, textDirection: .ltr)
      ..layout(maxWidth: even);
    final lines = painter.computeLineMetrics();
    expect(lines, hasLength(2));
    expect((lines[0].width - lines[1].width).abs(), lessThan(60));
    painter.dispose();
  });

  test('subtitle lines take readings where they match', () {
    final cue = Cue(0, 4, const [CueItem('1', '東京に行く'), CueItem('1', '今日は雨')]);
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

  testWidgets('the frame grows the video from the panel to fill the screen', (
    tester,
  ) async {
    const video = Key('video');
    const from = Rect.fromLTWH(0, 100, 400, 225);
    Future<Rect> at(double t, {double drop = 0}) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: .ltr,
          child: FullscreenFrame(
            t: t,
            from: from,
            drop: drop,
            aspectRatio: 16 / 9,
            video: const SizedBox(key: video),
          ),
        ),
      );
      return tester.getRect(find.byKey(video));
    }

    expect(await at(0), from);
    expect(await at(1), const Rect.fromLTWH(0, 75, 800, 450));
    expect(
      await at(0.5),
      Rect.lerp(from, const Rect.fromLTWH(0, 75, 800, 450), 0.5),
    );
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    expect(await at(1), const Rect.fromLTWH(-60, 100, 520, 292.5));
    tester.view.reset();
    final dropped = await at(1, drop: 120);
    expect(dropped.center.dy, 300 + 120);
    expect(dropped.width, lessThan(800));
  });
}
