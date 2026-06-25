import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';

/// The `.nym-switch` iOS-style toggle (the only one in the app —
/// index.html:1139 Low Data Mode panel): 40×22 track, 16px thumb,
/// off=white/0.12 + textBright thumb / on=primary track + white thumb
/// (thumb slides 18px). Pure presentational control: a [value] bool plus an
/// [onChanged] callback.
class NymSwitch extends StatelessWidget {
  const NymSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return GestureDetector(
      onTap: () => onChanged(!value),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: NymMotion.transition,
        curve: NymMotion.curve,
        width: 40,
        height: 22,
        decoration: BoxDecoration(
          color: value ? c.primary : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: value ? c.primary : c.glassBorder),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: NymMotion.transition,
              curve: NymMotion.curve,
              top: 2,
              left: value ? 18 : 2,
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: value ? Colors.white : c.textBright,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
