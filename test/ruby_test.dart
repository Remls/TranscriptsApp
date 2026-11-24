import 'package:flutter_test/flutter_test.dart';
import 'package:transcripts/ruby.dart';

void main() {
  test('readings split from their words', () {
    expect(parseRuby('｜東京《とうきょう》に｜行《い》く'), [
      (base: '東京', reading: 'とうきょう'),
      (base: 'に', reading: null),
      (base: '行', reading: 'い'),
      (base: 'く', reading: null),
    ]);
    expect(parseRuby('今日《きょう》は晴れ'), [
      (base: '今日', reading: 'きょう'),
      (base: 'は晴れ', reading: null),
    ]);
    expect(parseRuby('Speaker 1: ｜食べ《たべ》る'), [
      (base: 'Speaker 1: ', reading: null),
      (base: '食', reading: 'た'),
      (base: 'べ', reading: null),
      (base: 'る', reading: null),
    ]);
    expect(parseRuby('｜お茶《おちゃ》'), [
      (base: 'お', reading: null),
      (base: '茶', reading: 'ちゃ'),
    ]);
    expect(parseRuby('no readings'), [(base: 'no readings', reading: null)]);
  });

  test('stripping leaves the plain text', () {
    expect(stripRuby('｜東京《とうきょう》に今日《きょう》行く'), '東京に今日行く');
    expect(stripRuby('unmatched ｜bar'), 'unmatched ｜bar');
    expect(hasRuby('｜東京《とうきょう》'), isTrue);
    expect(hasRuby('東京'), isFalse);
  });
}
