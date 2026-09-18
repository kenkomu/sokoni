import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// Wraps a price display and briefly tints its background bid-green or
/// ask-red when [price] changes, so a live WebSocket tick *reads* as
/// movement rather than a number silently becoming a different number.
/// Skips the flash entirely under reduced-motion.
class PriceFlash extends StatefulWidget {
  const PriceFlash({required this.price, required this.child, super.key});

  final Decimal price;
  final Widget child;

  @override
  State<PriceFlash> createState() => _PriceFlashState();
}

class _PriceFlashState extends State<PriceFlash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );
  late Decimal _previous = widget.price;
  Color? _flashColor;

  @override
  void didUpdateWidget(covariant PriceFlash old) {
    super.didUpdateWidget(old);
    if (widget.price != _previous) {
      final sokoni = Theme.of(context).extension<SokoniColors>();
      _flashColor = widget.price > _previous ? sokoni?.bid : sokoni?.ask;
      _previous = widget.price;
      if (!MediaQuery.of(context).disableAnimations) {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final fade = 1 - _controller.value;
        final color = _flashColor?.withValues(alpha: 0.16 * fade);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(6),
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
