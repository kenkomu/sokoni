import 'package:flutter/material.dart';

import '../../data/api/sokoni_api.dart';
import '../../design/theme.dart';

/// A candlestick chart, hand-painted rather than pulled from fl_chart: the
/// pinned fl_chart version (0.69.2) has bar/line/pie/radar/scatter charts
/// but no candlestick support, and this shape (wick + body per bucket, one
/// y-axis range across the visible window) is small enough not to be worth
/// a second charting dependency mid-build.
class CandleChart extends StatelessWidget {
  const CandleChart({required this.candles, super.key});

  final List<Candle> candles;

  @override
  Widget build(BuildContext context) {
    final colors =
        Theme.of(context).extension<SokoniColors>() ??
        const SokoniColors(bid: Colors.green, ask: Colors.red);
    return SizedBox(
      height: 220,
      child:
          candles.isEmpty
              ? const Center(child: Text('No candles yet.'))
              : CustomPaint(
                painter: _CandlePainter(candles: candles, colors: colors),
                size: Size.infinite,
              ),
    );
  }
}

class _CandlePainter extends CustomPainter {
  _CandlePainter({required this.candles, required this.colors});

  final List<Candle> candles;
  final SokoniColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty) return;

    double? high;
    double? low;
    for (final c in candles) {
      final h = double.tryParse(c.high);
      final l = double.tryParse(c.low);
      if (h != null) high = high == null ? h : (h > high ? h : high);
      if (l != null) low = low == null ? l : (l < low ? l : low);
    }
    if (high == null || low == null || high == low) return;

    final range = high - low;
    final slotWidth = size.width / candles.length;
    final bodyWidth = (slotWidth * 0.6).clamp(1.0, slotWidth);

    double y(double v) => size.height - ((v - low!) / range) * size.height;

    for (var i = 0; i < candles.length; i++) {
      final c = candles[i];
      final open = double.tryParse(c.open);
      final closeV = double.tryParse(c.close);
      final h = double.tryParse(c.high);
      final l = double.tryParse(c.low);
      if (open == null || closeV == null || h == null || l == null) continue;

      final up = closeV >= open;
      final paint =
          Paint()
            ..color = up ? colors.bid : colors.ask
            ..strokeWidth = 1;

      final cx = slotWidth * i + slotWidth / 2;

      // Wick.
      canvas.drawLine(Offset(cx, y(h)), Offset(cx, y(l)), paint);

      // Body.
      final top = y(up ? closeV : open);
      final bottom = y(up ? open : closeV);
      final rect = Rect.fromLTRB(
        cx - bodyWidth / 2,
        top,
        cx + bodyWidth / 2,
        bottom == top ? top + 1 : bottom,
      );
      canvas.drawRect(rect, paint..style = PaintingStyle.fill);
    }
  }

  @override
  bool shouldRepaint(covariant _CandlePainter oldDelegate) =>
      !identical(oldDelegate.candles, candles);
}
