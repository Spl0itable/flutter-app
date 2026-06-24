import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../widgets/chat/message_row.dart' show abbreviateNumber;
import '../../widgets/context_menu/interaction_hooks.dart';
import 'zap_modal.dart';

/// The lightning bolt fill color (`--lightning`, `#f7931a`).
const Color _kLightning = Color(0xFFF7931A);

/// The inline `⚡ total` zap badge + quick-zap button shown at the FRONT of a
/// message's reactions row (`updateMessageZaps`, `zaps.js:1702-1784`). Reads
/// [zapsProvider] for [message]; renders nothing until the message has zaps.
///
/// - `.zap-badge` (`styles-chat.css:134-151`): orange-gradient pill (135°
///   .15→.08), border orange@.3, padding 3×10, radius 20, 14px lightning bolt,
///   12px/600 `--lightning` abbreviated total. `title` = "N zappers • M sats".
/// - `.add-zap-btn` (`styles-chat.css:332-355`): white@.04 pill, glass border,
///   padding 4×8, radius 20, opacity 0.6, 16px bolt+plus glyph; tap → quick-zap.
class ZapBadge extends ConsumerWidget {
  const ZapBadge({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zaps = ref.watch(zapsProvider)[message.id];
    if (zaps == null || zaps.totalSats <= 0) return const SizedBox.shrink();

    final total = zaps.totalSats;
    final zappers = zaps.zapperCount;
    final tooltip =
        '${abbreviateNumber(zappers)} zapper${zappers == 1 ? '' : 's'} • '
        '${abbreviateNumber(total)} sats total';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: tooltip,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0x26F7931A), Color(0x14F7931A)], // .15 / .08
              ),
              border: Border.all(color: const Color(0x4DF7931A)), // .3
              borderRadius: const BorderRadius.all(Radius.circular(20)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CustomPaint(painter: _BoltPainter(_kLightning)),
                ),
                const SizedBox(width: 4),
                Text(
                  abbreviateNumber(total),
                  style: const TextStyle(
                    color: _kLightning,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Quick-zap button: only when the author pubkey is known.
        if (message.pubkey.isNotEmpty) ...[
          const SizedBox(width: 5),
          _QuickZapBtn(
            onTap: () => _quickZap(context, ref),
          ),
        ],
      ],
    );
  }

  /// Resolves the author's lightning address and opens the zap modal, mirroring
  /// `handleQuickZap` (`zaps.js:1786`). Posts a system note when the author has
  /// no lightning address.
  Future<void> _quickZap(BuildContext context, WidgetRef ref) async {
    final baseNym = stripPubkeySuffix(message.author);
    final user = ref.read(usersProvider)[message.pubkey];
    final lnAddr = user?.profile?.lightningAddress;
    if (lnAddr == null || lnAddr.isEmpty) {
      ref.read(appStateProvider.notifier).addSystemMessage(
          '@$baseNym cannot receive zaps (no lightning address set)');
      return;
    }
    if (!context.mounted) return;
    await ZapModal.show(
      context,
      recipientPubkey: message.pubkey,
      recipientNym: baseNym,
      lightningAddress: lnAddr,
      messageId: message.id,
      originalKind:
          inferOriginalKind(message, view: ref.read(currentViewProvider)),
    );
  }
}

/// The `.add-zap-btn` pill (bolt+plus glyph, dim until hover/press).
class _QuickZapBtn extends StatelessWidget {
  const _QuickZapBtn({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Tooltip(
      message: 'Quick zap',
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: 0.6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              border: Border.all(color: c.glassBorder),
              borderRadius: const BorderRadius.all(Radius.circular(20)),
            ),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CustomPaint(painter: _BoltPlusPainter(c.text)),
            ),
          ),
        ),
      ),
    );
  }
}

/// The PWA lightning bolt (`M13 2L3 14h8l-1 8 10-12h-8l1-8z`, 24×24 viewBox).
class _BoltPainter extends CustomPainter {
  const _BoltPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final path = Path()
      ..moveTo(13 * s, 2 * s)
      ..lineTo(3 * s, 14 * s)
      ..lineTo(11 * s, 14 * s)
      ..lineTo(10 * s, 22 * s)
      ..lineTo(20 * s, 10 * s)
      ..lineTo(12 * s, 10 * s)
      ..lineTo(13 * s, 2 * s)
      ..close();
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant _BoltPainter old) => old.color != color;
}

/// The quick-zap glyph: a bolt offset left (`M11 2L1 14h8l-1 8 10-12h-8l1-8z`)
/// plus a small "+" at the top-right (the PWA `add-zap-btn` SVG).
class _BoltPlusPainter extends CustomPainter {
  const _BoltPlusPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final bolt = Path()
      ..moveTo(11 * s, 2 * s)
      ..lineTo(1 * s, 14 * s)
      ..lineTo(9 * s, 14 * s)
      ..lineTo(8 * s, 22 * s)
      ..lineTo(18 * s, 10 * s)
      ..lineTo(10 * s, 10 * s)
      ..lineTo(11 * s, 2 * s)
      ..close();
    canvas.drawPath(bolt, fill);
    // The "+" (vertical bar x=19 y=2..6, horizontal bar x=17..21 y=4).
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * s
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas.drawLine(Offset(19 * s, 2 * s), Offset(19 * s, 6 * s), stroke);
    canvas.drawLine(Offset(17 * s, 4 * s), Offset(21 * s, 4 * s), stroke);
  }

  @override
  bool shouldRepaint(covariant _BoltPlusPainter old) => old.color != color;
}
