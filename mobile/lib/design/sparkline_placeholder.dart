import 'package:flutter/material.dart';

/// Stands in for a price sparkline where the kit draws one, without
/// fabricating a price history that doesn't exist. A flat, dashed line reads
/// as "no data" rather than "flat/zero movement" — a real 0% line would look
/// identical to this and would be a lie.
class SparklinePlaceholder extends StatelessWidget {
  const SparklinePlaceholder({this.width = 50, this.height = 25, super.key});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _DashedLinePainter(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  const _DashedLinePainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = color
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round;
    const dash = 4.0;
    const gap = 3.0;
    var x = 0.0;
    final y = size.height / 2;
    while (x < size.width) {
      canvas.drawLine(Offset(x, y), Offset(x + dash, y), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_DashedLinePainter oldDelegate) =>
      oldDelegate.color != color;
}
