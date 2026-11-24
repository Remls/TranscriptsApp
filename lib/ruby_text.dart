import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'ruby.dart';

/// Line height for text with readings, leaving room above for them.
const rubyLineHeight = 2.2;

/// [ruby] as spans in [style], with readings drawn above their words.
/// [build] gives the spans for a run of the plain text starting at [offset].
TextSpan rubySpan(
  String ruby,
  TextStyle style,
  List<InlineSpan> Function(String text, int offset) build,
) {
  final spans = <InlineSpan>[];
  var offset = 0;
  for (final segment in parseRuby(ruby)) {
    final base = build(segment.base, offset);
    final reading = segment.reading;
    if (reading == null) {
      spans.addAll(base);
    } else {
      spans.add(
        WidgetSpan(
          alignment: .baseline,
          baseline: .alphabetic,
          child: RubyWord(
            base: TextSpan(style: style, children: base),
            reading: reading,
            style: style,
          ),
        ),
      );
    }
    offset += segment.base.length;
  }
  return TextSpan(style: style, children: spans);
}

TextPainter _readingPainter(String reading, TextStyle style) => TextPainter(
  text: TextSpan(
    text: reading,
    style: style.copyWith(
      fontSize: (style.fontSize ?? 14) * 0.5,
      height: 1,
      backgroundColor: Colors.transparent,
    ),
  ),
  textDirection: .ltr,
  textScaler: .noScaling,
)..layout();

/// The box a [RubyWord] of [base] and [reading] in [style] takes, scaled by
/// [scale].
PlaceholderDimensions rubyWordDimensions(
  String base,
  String reading,
  TextStyle style, {
  double scale = 1,
}) {
  final readingPainter = _readingPainter(reading, style);
  final basePainter = TextPainter(
    text: TextSpan(text: base, style: style),
    textDirection: .ltr,
    textScaler: .noScaling,
  )..layout();
  final dimensions = PlaceholderDimensions(
    size:
        Size(max(basePainter.width, readingPainter.width), basePainter.height) *
        scale,
    alignment: .baseline,
    baseline: .alphabetic,
    baselineOffset:
        basePainter.computeDistanceToActualBaseline(.alphabetic) * scale,
  );
  readingPainter.dispose();
  basePainter.dispose();
  return dimensions;
}

/// [base] with [reading] drawn above it in small type.
class RubyWord extends StatelessWidget {
  const RubyWord({
    super.key,
    required this.base,
    required this.reading,
    required this.style,
  });

  final InlineSpan base;
  final String reading;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final fontSize = style.fontSize ?? 14;
    final readingPainter = _readingPainter(reading, style);
    final basePainter = TextPainter(
      text: base,
      textDirection: .ltr,
      textScaler: .noScaling,
    )..layout();
    final baseline = basePainter.computeDistanceToActualBaseline(.alphabetic);
    basePainter.dispose();
    return CustomPaint(
      foregroundPainter: _ReadingPainter(
        readingPainter,
        bottom: baseline - fontSize * 0.92,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: readingPainter.width),
        child: Align(
          widthFactor: 1,
          heightFactor: 1,
          child: Text.rich(base, textScaler: .noScaling),
        ),
      ),
    );
  }
}

class _ReadingPainter extends CustomPainter {
  _ReadingPainter(this.reading, {required this.bottom});

  final TextPainter reading;

  /// Where the reading's bottom edge sits, from the top of the word.
  final double bottom;

  @override
  void paint(Canvas canvas, Size size) {
    reading.paint(
      canvas,
      Offset((size.width - reading.width) / 2, bottom - reading.height),
    );
  }

  @override
  bool shouldRepaint(_ReadingPainter old) =>
      old.reading.text != reading.text || old.bottom != bottom;
}
