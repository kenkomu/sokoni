import 'package:flutter/material.dart';
// Prefixed: intl exports its own TextDirection, which shadows dart:ui's and
// breaks TextPainter below if imported unprefixed.
import 'package:intl/intl.dart' as intl;

import '../../data/api/sokoni_api.dart';
import '../../design/format.dart';
import '../../design/theme.dart';

/// Fewest candles a pinch-zoom is allowed to leave on screen — below this a
/// body is narrower than its own wick, which reads as noise, not detail.
const _minVisibleCandles = 8;

/// A candlestick chart, hand-painted rather than pulled from fl_chart: the
/// pinned fl_chart version (0.69.2) has bar/line/pie/radar/scatter charts
/// but no candlestick support, and this shape (wick + body per bucket, one
/// y-axis range across the visible window) is small enough not to be worth
/// a second charting dependency mid-build.
///
/// Pinch to zoom, drag to pan once zoomed, tap a candle to read its OHLC and
/// bucket time, double-tap to reset. Zoom re-scales the y-axis to whatever
/// is actually on screen — cropping to a Transform instead would leave a
/// zoomed-in view looking at a price range sized for the whole list.
class CandleChart extends StatefulWidget {
  const CandleChart({required this.candles, super.key});

  final List<Candle> candles;

  @override
  State<CandleChart> createState() => _CandleChartState();
}

class _CandleChartState extends State<CandleChart> {
  // The visible window is candles[_end - _count, _end). Both null means "show
  // everything", which also keeps live-appended candles in view for free —
  // there is nothing pinned to unpin.
  int? _visibleCount;
  int? _visibleEnd;
  int? _crosshairIndex;

  // Captured once per gesture so a pinch's `scale` (cumulative since gesture
  // start) reads as a delta against the window size at that moment, not
  // against whatever it has drifted to mid-gesture.
  int _gestureStartCount = 0;
  double _lastWidth = 1;

  int get _count => (_visibleCount ?? widget.candles.length).clamp(
    _minVisibleCandles.clamp(1, widget.candles.length),
    widget.candles.length,
  );

  int get _end => (_visibleEnd ?? widget.candles.length).clamp(
    _count,
    widget.candles.length,
  );

  @override
  void didUpdateWidget(covariant CandleChart old) {
    super.didUpdateWidget(old);
    // A genuinely different window (a new tab, not a live append onto the
    // same one) starts at a different first bucket — reset rather than try
    // to keep an index-based zoom aligned to buckets that no longer exist.
    final oldFirst = old.candles.isEmpty ? null : old.candles.first.bucketTs;
    final newFirst =
        widget.candles.isEmpty ? null : widget.candles.first.bucketTs;
    if (oldFirst != newFirst) {
      _visibleCount = null;
      _visibleEnd = null;
      _crosshairIndex = null;
    }
  }

  void _resetZoom() {
    setState(() {
      _visibleCount = null;
      _visibleEnd = null;
      _crosshairIndex = null;
    });
  }

  void _onScaleStart(ScaleStartDetails details) {
    _gestureStartCount = _count;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      if (details.scale != 1.0) {
        final next = (_gestureStartCount / details.scale).round();
        _visibleCount = next.clamp(
          _minVisibleCandles.clamp(1, widget.candles.length),
          widget.candles.length,
        );
      }
      // Incremental, not gesture-start-relative — a plain one-finger drag
      // reports scale == 1.0 for its whole duration, so panning has to move
      // by delta-since-last-frame instead.
      if (details.focalPointDelta.dx != 0 && _lastWidth > 0) {
        final slotWidth = _lastWidth / _count;
        final shift = -(details.focalPointDelta.dx / slotWidth).round();
        if (shift != 0) {
          _visibleEnd = _end + shift;
        }
      }
    });
  }

  void _onTapUp(TapUpDetails details) {
    if (widget.candles.isEmpty || _lastWidth <= 0) return;
    final slotWidth = _lastWidth / _count;
    final start = _end - _count;
    final tapped = start + (details.localPosition.dx / slotWidth).floor();
    setState(() {
      _crosshairIndex = tapped.clamp(start, _end - 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors =
        Theme.of(context).extension<SokoniColors>() ??
        const SokoniColors(bid: Colors.green, ask: Colors.red);
    if (widget.candles.isEmpty) {
      return const SizedBox(
        height: 260,
        child: Center(child: Text('No candles yet.')),
      );
    }

    final start = _end - _count;
    final visible = widget.candles.sublist(start, _end);
    final crosshair =
        _crosshairIndex != null &&
                _crosshairIndex! >= start &&
                _crosshairIndex! < _end
            ? widget.candles[_crosshairIndex!]
            : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (crosshair != null)
          _CrosshairReadout(candle: crosshair)
        else if (_count != widget.candles.length)
          _ZoomBadge(
            onReset: _resetZoom,
            visibleCount: _count,
            total: widget.candles.length,
          ),
        SizedBox(
          height: 220,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _lastWidth = constraints.maxWidth;
              // Scale's recognizer claims every single-finger drag that
              // starts here, vertical ones included, so a touch landing
              // directly on the chart pans it rather than scrolling the
              // page underneath — the same trade-off most candlestick
              // charts make. The rest of the screen (price header, chips,
              // trades, market info) scrolls normally.
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onTapUp: _onTapUp,
                onDoubleTap: _resetZoom,
                child: CustomPaint(
                  painter: _CandlePainter(
                    candles: visible,
                    colors: colors,
                    gridColor: Theme.of(context).colorScheme.outlineVariant,
                    labelColor: Theme.of(context).colorScheme.onSurfaceVariant,
                    crosshairIndex:
                        crosshair == null ? null : _crosshairIndex! - start,
                  ),
                  size: Size.infinite,
                ),
              );
            },
          ),
        ),
        SizedBox(
          height: 40,
          child: CustomPaint(
            painter: _VolumePainter(candles: visible, colors: colors),
            size: Size.infinite,
          ),
        ),
      ],
    );
  }
}

/// Small "zoomed to N of M — tap to reset" pill, shown only while zoomed so
/// it never competes for space with the crosshair readout.
class _ZoomBadge extends StatelessWidget {
  const _ZoomBadge({
    required this.onReset,
    required this.visibleCount,
    required this.total,
  });

  final VoidCallback onReset;
  final int visibleCount;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: onReset,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.zoom_in, size: 14, color: theme.colorScheme.primary),
            const SizedBox(width: 4),
            Text(
              'Showing $visibleCount of $total — tap to reset',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// OHLC + bucket time for the tapped candle, replacing the zoom badge's slot
/// so tapping a candle never shifts the chart itself.
class _CrosshairReadout extends StatelessWidget {
  const _CrosshairReadout({required this.candle});

  final Candle candle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget cell(String label, String value) => Padding(
      padding: const EdgeInsets.only(right: 10),
      child: RichText(
        text: TextSpan(
          style: style,
          children: [
            TextSpan(text: '$label '),
            TextSpan(
              text: value,
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              children: [
                cell('O', formatPrice(candle.open)),
                cell('H', formatPrice(candle.high)),
                cell('L', formatPrice(candle.low)),
                cell('C', formatPrice(candle.close)),
              ],
            ),
          ),
          Text(
            intl.DateFormat('MMM d, HH:mm').format(candle.bucketTs.toLocal()),
            style: style,
          ),
        ],
      ),
    );
  }
}

class _CandlePainter extends CustomPainter {
  _CandlePainter({
    required this.candles,
    required this.colors,
    required this.gridColor,
    required this.labelColor,
    required this.crosshairIndex,
  });

  final List<Candle> candles;
  final SokoniColors colors;
  final Color gridColor;
  final Color labelColor;

  /// Index into [candles] (the already-windowed slice), not the full list.
  final int? crosshairIndex;

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

    // A little headroom so the highest wick and the top gridline don't
    // touch, and price labels have room to sit above their line.
    final pad = (high - low) * 0.08;
    high += pad;
    low -= pad;
    final range = high - low;

    final slotWidth = size.width / candles.length;
    final bodyWidth = (slotWidth * 0.6).clamp(1.0, slotWidth);

    double y(double v) => size.height - ((v - low!) / range) * size.height;

    _paintGrid(canvas, size, high, low, y);

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

    final ci = crosshairIndex;
    if (ci != null && ci >= 0 && ci < candles.length) {
      _paintCrosshair(canvas, size, ci, slotWidth, y);
    }
  }

  void _paintGrid(
    Canvas canvas,
    Size size,
    double high,
    double low,
    double Function(double) y,
  ) {
    final gridPaint =
        Paint()
          ..color = gridColor
          ..strokeWidth = 0.5;
    final levels = [high, (high + low) / 2, low];
    for (final level in levels) {
      final ly = y(level);
      canvas.drawLine(Offset(0, ly), Offset(size.width, ly), gridPaint);
      final tp = TextPainter(
        text: TextSpan(
          text: formatPrice(level.toString(), maxDecimals: 4),
          style: TextStyle(color: labelColor, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final ty = (ly - tp.height).clamp(0.0, size.height - tp.height);
      tp.paint(canvas, Offset(size.width - tp.width - 2, ty));
    }
  }

  void _paintCrosshair(
    Canvas canvas,
    Size size,
    int index,
    double slotWidth,
    double Function(double) y,
  ) {
    final c = candles[index];
    final closeV = double.tryParse(c.close);
    if (closeV == null) return;
    final cx = slotWidth * index + slotWidth / 2;
    final cy = y(closeV);

    final dashPaint =
        Paint()
          ..color = labelColor.withValues(alpha: 0.6)
          ..strokeWidth = 1;
    _drawDashedLine(canvas, Offset(cx, 0), Offset(cx, size.height), dashPaint);
    _drawDashedLine(canvas, Offset(0, cy), Offset(size.width, cy), dashPaint);
    canvas.drawCircle(
      cy.isNaN ? Offset(cx, 0) : Offset(cx, cy),
      3,
      Paint()..color = labelColor,
    );
  }

  void _drawDashedLine(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dashLength = 4.0;
    const gapLength = 3.0;
    final total = (to - from).distance;
    if (total == 0) return;
    final direction = (to - from) / total;
    var covered = 0.0;
    while (covered < total) {
      final segmentEnd = (covered + dashLength).clamp(0.0, total);
      canvas.drawLine(
        from + direction * covered,
        from + direction * segmentEnd,
        paint,
      );
      covered += dashLength + gapLength;
    }
  }

  @override
  bool shouldRepaint(covariant _CandlePainter oldDelegate) =>
      !identical(oldDelegate.candles, candles) ||
      oldDelegate.crosshairIndex != crosshairIndex;
}

/// Volume bars beneath the price panel, sharing its x-axis mapping so each
/// bar lines up under its own candle. Kuru's candlestick response (and this
/// app's `candles` table) carries volume already; the chart just wasn't
/// showing it.
class _VolumePainter extends CustomPainter {
  _VolumePainter({required this.candles, required this.colors});

  final List<Candle> candles;
  final SokoniColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty) return;

    double maxVolume = 0;
    for (final c in candles) {
      final v = double.tryParse(c.volume);
      if (v != null && v > maxVolume) maxVolume = v;
    }
    if (maxVolume == 0) return;

    final slotWidth = size.width / candles.length;
    final barWidth = (slotWidth * 0.6).clamp(1.0, slotWidth);

    for (var i = 0; i < candles.length; i++) {
      final c = candles[i];
      final open = double.tryParse(c.open);
      final closeV = double.tryParse(c.close);
      final v = double.tryParse(c.volume);
      if (open == null || closeV == null || v == null) continue;

      final up = closeV >= open;
      final paint =
          Paint()
            ..color = (up ? colors.bid : colors.ask).withValues(alpha: 0.5);
      final cx = slotWidth * i + slotWidth / 2;
      final barHeight = (v / maxVolume) * size.height;
      canvas.drawRect(
        Rect.fromLTRB(
          cx - barWidth / 2,
          size.height - barHeight,
          cx + barWidth / 2,
          size.height,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VolumePainter oldDelegate) =>
      !identical(oldDelegate.candles, candles);
}
