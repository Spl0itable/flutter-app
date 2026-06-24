import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';

/// Cryptographic-verification state of a sealed (NIP-17/NIP-59) message,
/// mirroring the PWA's tri-state `senderVerified` (`messages.js:732-757`):
///
/// * [verified] — the seal was signed by the sender's long-term identity key
///   and that signer matches the claimed author (green lock + check).
/// * [unverified] — a Bitchat-format seal signed with a throwaway per-message
///   key with no identity binding (red lock + ✗).
/// * [unknown] — the seal isn't available on this device (e.g. restored from
///   history), so verification can't be performed (grey lock + ?).
enum CryptoVerifyState { verified, unverified, unknown }

/// The `.crypto-verified-badge` lock shown next to a PM/group message's
/// timestamp (`messages.js:758` `mkLock`, `styles-components.css:1421`). A 12×12
/// stroked padlock whose interior glyph + colour encode the [state]; tapping it
/// opens the verification-info popup (`showVerificationPopup`,
/// `messages.js:3405`).
class CryptoVerifiedBadge extends StatelessWidget {
  const CryptoVerifiedBadge({super.key, required this.state, this.size = 12});

  final CryptoVerifyState state;
  final double size;

  /// Lock colour per state (`.crypto-verified-badge` / `.unverified` /
  /// `.unknown`): verified `#2ecc71`, unverified `#e74c3c`, unknown `#9aa0a6`.
  Color get _color {
    switch (state) {
      case CryptoVerifyState.verified:
        return const Color(0xFF2ECC71);
      case CryptoVerifyState.unverified:
        return const Color(0xFFE74C3C);
      case CryptoVerifyState.unknown:
        return const Color(0xFF9AA0A6);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showVerificationPopup(context, state),
      child: Padding(
        // `.crypto-verified-badge { margin-left: 4px }`.
        padding: const EdgeInsets.only(left: 4),
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: _LockPainter(state, _color)),
        ),
      ),
    );
  }
}

/// Strokes the padlock + state glyph from the PWA's inline SVG path data, in the
/// 24-unit viewBox the SVG uses, scaled to the widget size. `stroke-width:2`,
/// round caps/joins, no fill (`messages.js:746-756`).
class _LockPainter extends CustomPainter {
  _LockPainter(this.state, this.color);

  final CryptoVerifyState state;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24.0, size.height / 24.0);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    // Lock body: <rect x=3 y=11 w=18 h=11 rx=2 ry=2>.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(3, 11, 18, 11),
        const Radius.circular(2),
      ),
      paint,
    );
    // Shackle: M7 11V7 a5 5 0 0 1 10 0 v4.
    final shackle = Path()
      ..moveTo(7, 11)
      ..lineTo(7, 7)
      ..arcToPoint(const Offset(17, 7),
          radius: const Radius.circular(5), clockwise: true)
      ..lineTo(17, 11);
    canvas.drawPath(shackle, paint);

    // Interior glyph per state.
    final glyph = Path();
    switch (state) {
      case CryptoVerifyState.verified:
        // M8.5 16.5 l2.5 2.5 4.5-4.5  (check)
        glyph
          ..moveTo(8.5, 16.5)
          ..lineTo(11, 19)
          ..lineTo(15.5, 14.5);
        break;
      case CryptoVerifyState.unverified:
        // M9.5 14 l5 5  /  M14.5 14 l-5 5  (✗)
        glyph
          ..moveTo(9.5, 14)
          ..lineTo(14.5, 19)
          ..moveTo(14.5, 14)
          ..lineTo(9.5, 19);
        break;
      case CryptoVerifyState.unknown:
        // M9.6 14.6 a2.4 2.4 0 0 1 3.6 2 c0 1 -1.2 1.4 -1.2 2.4  +  dot
        glyph
          ..moveTo(9.6, 14.6)
          ..arcToPoint(const Offset(13.2, 16.6),
              radius: const Radius.circular(2.4), clockwise: true)
          ..cubicTo(13.2, 17.6, 12, 18, 12, 19)
          ..moveTo(12, 21.2)
          ..lineTo(12, 21.21);
        break;
    }
    canvas.drawPath(glyph, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LockPainter old) =>
      old.state != state || old.color != color;
}

/// Opens the verification-info popup (`showVerificationPopup`,
/// `messages.js:3405-3424`): a small `.verification-popup` card with a
/// state-coloured title and an explanatory body.
void showVerificationPopup(BuildContext context, CryptoVerifyState state) {
  final c = context.nym;
  final (title, titleColor, body) = switch (state) {
    CryptoVerifyState.verified => (
        'Cryptographically verified',
        const Color(0xFF2ECC71),
        "The seal wrapping this message (NIP-17 / NIP-59 kind 13) was signed by "
            "the sender's long-term identity key, and that signer matches the "
            "author the message claims. The displayed identity is "
            "cryptographically authenticated and cannot be forged by a relay or "
            "third party.",
      ),
    CryptoVerifyState.unknown => (
        'Verification unknown',
        const Color(0xFF9AA0A6),
        "This message's sender could not be cryptographically verified on this "
            "device — its verification seal isn't available (for example, it was "
            "restored from saved history). The displayed identity is unconfirmed: "
            "don't assume it is authenticated.",
      ),
    CryptoVerifyState.unverified => (
        'Unverified sender',
        const Color(0xFFE74C3C),
        "This message uses a Bitchat-format seal signed with a throwaway, "
            "per-message key that has no binding to any long-term identity. The "
            "displayed sender is an unverified, self-asserted claim — treat the "
            "identity with caution, as it could be spoofed.",
      ),
  };

  showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => Dialog(
      backgroundColor: c.bgSecondary,
      shape: RoundedRectangleBorder(
        borderRadius: NymRadius.rmd,
        side: BorderSide(color: c.glassBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Padding(
          // `.verification-popup { padding: 12px 14px; gap: 6px }`.
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: titleColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 6),
              Opacity(
                opacity: 0.85,
                child: Text(
                  body,
                  style: TextStyle(
                    color: c.text,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
