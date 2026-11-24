import 'package:material_ui/material_ui.dart';

/// ふ in a circle, the toggle for furigana. When [off], a line crosses the
/// circle from top left to bottom right. Sized and colored by the [IconTheme].
class FuriganaIcon extends StatelessWidget {
  const FuriganaIcon({super.key, required this.off});

  final bool off;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final size = theme.size ?? 24;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _FuriganaPainter(theme.color!, off: off)),
    );
  }
}

/// The outline of ふ from Noto Sans CJK JP Regular, centered on the origin
/// and scaled so its wider side is 1.
final _fu = Path()
  ..moveTo(0.0011, -0.1882)
  ..lineTo(0.0553, -0.1372)
  ..cubicTo(0.0954, -0.1654, 0.1573, -0.2142, 0.1833, -0.2359)
  ..lineTo(0.1627, -0.2923)
  ..cubicTo(0.0976, -0.3400, -0.0217, -0.3997, -0.1052, -0.4344)
  ..lineTo(-0.1551, -0.3715)
  ..cubicTo(-0.0716, -0.3379, 0.0304, -0.2825, 0.0781, -0.2446)
  ..cubicTo(0.0618, -0.2316, 0.0315, -0.2088, 0.0022, -0.1903)
  ..close()
  ..moveTo(-0.2072, 0.3281)
  ..lineTo(-0.1952, 0.4181)
  ..cubicTo(-0.1464, 0.4268, -0.0868, 0.4344, -0.0174, 0.4344)
  ..cubicTo(0.0607, 0.4344, 0.1692, 0.4051, 0.1692, 0.2717)
  ..cubicTo(0.1692, 0.1741, 0.0976, 0.0786, -0.0043, -0.0277)
  ..cubicTo(-0.0293, -0.0559, -0.0564, -0.0851, -0.0824, -0.1123)
  ..lineTo(-0.1464, -0.0569)
  ..cubicTo(-0.1161, -0.0309, -0.0835, -0.0005, -0.0597, 0.0255)
  ..cubicTo(0.0011, 0.0916, 0.0792, 0.1893, 0.0792, 0.2630)
  ..cubicTo(0.0792, 0.3335, 0.0195, 0.3541, -0.0304, 0.3541)
  ..cubicTo(-0.0987, 0.3541, -0.1508, 0.3454, -0.2061, 0.3292)
  ..close()
  ..moveTo(0.4197, 0.3693)
  ..lineTo(0.5000, 0.3248)
  ..cubicTo(0.4664, 0.2294, 0.3850, 0.0743, 0.3102, -0.0136)
  ..lineTo(0.2386, 0.0266)
  ..cubicTo(0.3134, 0.1112, 0.3883, 0.2663, 0.4187, 0.3693)
  ..close()
  ..moveTo(-0.1703, 0.1578)
  ..lineTo(-0.2213, 0.0927)
  ..cubicTo(-0.2831, 0.1600, -0.4100, 0.2565, -0.5000, 0.3042)
  ..lineTo(-0.4490, 0.3758)
  ..cubicTo(-0.3438, 0.3129, -0.2354, 0.2218, -0.1725, 0.1567)
  ..close();

class _FuriganaPainter extends CustomPainter {
  _FuriganaPainter(this.color, {required this.off});

  final Color color;
  final bool off;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    canvas.save();
    canvas.scale(unit);
    const center = Offset(12, 12);
    final stroke = Paint()
      ..color = color
      ..style = .stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, 9, stroke);

    final slashFrom = center + const Offset(-6.36, -6.36);
    final slashTo = center + const Offset(6.36, 6.36);
    canvas.saveLayer(Offset.zero & const Size(24, 24), Paint());
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(12);
    canvas.drawPath(_fu, Paint()..color = color);
    canvas.drawPath(
      _fu,
      Paint()
        ..color = color
        ..style = .stroke
        ..strokeWidth = 0.5 / 12,
    );
    canvas.restore();
    if (off) {
      canvas.drawLine(
        slashFrom,
        slashTo,
        Paint()
          ..blendMode = .clear
          ..strokeWidth = 3.5,
      );
    }
    canvas.restore();
    if (off) canvas.drawLine(slashFrom, slashTo, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FuriganaPainter old) =>
      old.color != color || old.off != off;
}
