import 'package:flutter/material.dart';

/// The blue verified checkmark badge (`.verified-badge`, styles-components.css
/// :1382-1411): a 20×20 #1DA1F2 circle with a white ✓ (12px, w700). Rendered
/// after the nym for `isVerifiedDeveloper` / `isVerifiedBot`
/// (ui-context.js:407-411). `margin-left:4px; margin-right:2px` is applied by
/// the caller's row gap.
class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: Color(0xFF1DA1F2),
        shape: BoxShape.circle,
      ),
      child: Text(
        '✓',
        style: TextStyle(
          color: Colors.white,
          // CSS ✓ is 12px inside the 20px circle; scale for other sizes.
          fontSize: size * 0.6,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

/// The friend badge (`.friend-badge`, styles-features.css:1483-1495): a
/// people-with-check glyph in #4fc3f7, appended after the nym for friends
/// (ui-context.js:412-414). Drawn to match the PWA's inline SVG
/// (16×16 viewBox: head circle + shoulders arc + a small plus to the right).
class FriendBadge extends StatelessWidget {
  const FriendBadge({super.key, this.size = 20});

  static const Color color = Color(0xFF4FC3F7);

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _FriendBadgePainter()),
    );
  }
}

class _FriendBadgePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // The PWA SVG is authored in a 16×16 box; scale uniformly to [size].
    final s = size.width / 16.0;
    final fill = Paint()
      ..color = FriendBadge.color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final stroke = Paint()
      ..color = FriendBadge.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * s
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    // <circle cx="6" cy="5" r="2.5" /> — head (filled).
    canvas.drawCircle(Offset(6 * s, 5 * s), 2.5 * s, fill);

    // <path d="M 1.5 14 C 1.5 10.5 3.5 9 6 9 C 8.5 9 10.5 10.5 10.5 14" /> —
    // shoulders arc (filled body in the PWA via fill="currentColor").
    final body = Path()
      ..moveTo(1.5 * s, 14 * s)
      ..cubicTo(1.5 * s, 10.5 * s, 3.5 * s, 9 * s, 6 * s, 9 * s)
      ..cubicTo(8.5 * s, 9 * s, 10.5 * s, 10.5 * s, 10.5 * s, 14 * s);
    canvas.drawPath(body, fill);

    // The two check lines forming a "+" to the right of the head:
    // <line x1="13" y1="6" x2="13" y2="10" /> and <line x1="11" y1="8" x2="15" y2="8" />.
    canvas.drawLine(Offset(13 * s, 6 * s), Offset(13 * s, 10 * s), stroke);
    canvas.drawLine(Offset(11 * s, 8 * s), Offset(15 * s, 8 * s), stroke);
  }

  @override
  bool shouldRepaint(covariant _FriendBadgePainter oldDelegate) => false;
}
