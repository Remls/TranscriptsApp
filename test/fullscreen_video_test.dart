import 'package:flutter_test/flutter_test.dart';
import 'package:transcripts/fullscreen_video.dart';
import 'package:transcripts/settings.dart';
import 'package:transcripts/srt.dart';

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
}
