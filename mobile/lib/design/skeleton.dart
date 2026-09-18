import 'package:flutter/material.dart';

/// A pulsing placeholder block, shown in place of a row while its data is
/// still loading — cuts perceived latency versus a single centred spinner,
/// per the UX guidance on skeleton loaders. Freezes (no pulse) when the
/// platform has reduced-motion enabled, per the same guidance's
/// accessibility note.
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({
    required this.width,
    required this.height,
    this.borderRadius = 6,
    super.key,
  });

  final double width;
  final double height;
  final double borderRadius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    if (MediaQuery.of(context).disableAnimations) {
      return _box(base.withValues(alpha: 0.5));
    }
    return AnimatedBuilder(
      animation: _controller,
      builder:
          (context, _) =>
              _box(base.withValues(alpha: 0.35 + _controller.value * 0.25)),
    );
  }

  Widget _box(Color color) => Container(
    width: widget.width,
    height: widget.height,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(widget.borderRadius),
    ),
  );
}

/// A skeleton shaped like a market row (avatar + two text lines + trailing
/// price block) — matches [TokenAvatar]-based rows on Home/Markets/Portfolio
/// closely enough that the swap-in on load doesn't jump.
class SkeletonMarketRow extends StatelessWidget {
  const SkeletonMarketRow({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const SkeletonBox(width: 40, height: 40, borderRadius: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                SkeletonBox(width: 90, height: 14),
                SizedBox(height: 6),
                SkeletonBox(width: 40, height: 11),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: const [
              SkeletonBox(width: 56, height: 14),
              SizedBox(height: 6),
              SkeletonBox(width: 36, height: 11),
            ],
          ),
        ],
      ),
    );
  }
}

/// A vertical run of [SkeletonMarketRow]s, for a first-load list state.
class SkeletonMarketList extends StatelessWidget {
  const SkeletonMarketList({this.count = 4, super.key});
  final int count;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < count; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: const SkeletonMarketRow(),
        ),
    ],
  );
}
