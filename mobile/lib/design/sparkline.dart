import 'package:flutter/material.dart';

/// A minimal price line, coloured by its own trend (last point vs first) —
/// this is the real-chart counterpart to [SparklinePlaceholder]; use one or
/// the other depending on whether [MarketSummary.sparkline] is populated.
class Sparkline extends StatelessWidget {
  const Sparkline({
    required this.values,
    this.width = 50,
    this.height = 25,
    super.key,
  });

  final List<double> values;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final up = values.isEmpty || values.last >= values.first;
    final color =
        up ? const Color(0xFF21BF73) : const Color(0xFFD90429); // bid/ask
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(painter: _SparklinePainter(values, color)),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  const _SparklinePainter(this.values, this.color);
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final min = values.reduce((a, b) => a < b ? a : b);
    final max = values.reduce((a, b) => a > b ? a : b);
    final span = (max - min).abs() < 1e-12 ? 1.0 : max - min;
    final dx = size.width / (values.length - 1);

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i * dx;
      final y = size.height - ((values[i] - min) / span) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}
