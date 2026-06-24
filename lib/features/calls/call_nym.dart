// call_nym.dart - Decorated display name for the call UI (overlay tiles, chat
// from-line, call title, fly-reaction "who" pill, incoming-call name, mention
// rows). Native port of `calls.js:19-36 _callNymHtml`:
//
//   base nym + `#suffix` + purchased flair/supporter badges + verified ✓ badge
//   (developer/bot) + friend icon.
//
// `self` renders a plain "You" with no decorations (calls.js line 21).
//
// Self-contained: the verified ✓ and friend badges are drawn here so the call
// feature carries no dependency on the (separately-owned) context-menu badge
// widgets. Flair/supporter reuse the shared shop [CosmeticNymBadges] so the
// glyphs match the rest of the app.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/shop/cosmetics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';

/// A decorated call nym: `base` + dim `#suffix` + flair/supporter + verified ✓ +
/// friend badge. Pass [self] (or a pubkey equal to the local identity) to render
/// a plain "You" with no decorations.
class CallNym extends ConsumerWidget {
  const CallNym({
    super.key,
    required this.pubkey,
    this.nym,
    this.self = false,
    this.baseColor,
    this.baseStyle,
    this.suffixOpacity = 0.7,
    this.badgeSize = 14,
  });

  /// The participant's pubkey (drives suffix + verified/friend/cosmetics).
  final String pubkey;

  /// Optional already-known nym (falls back to `usersProvider`/pubkey prefix).
  final String? nym;

  /// Render a plain "You" with no decorations (calls.js `opts.self`).
  final bool self;

  /// Base-nym colour (defaults to the surrounding text colour).
  final Color? baseColor;

  /// Base-nym text style override (size/weight). Colour comes from [baseColor].
  final TextStyle? baseStyle;

  final double suffixOpacity;
  final double badgeSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final controller = ref.watch(nostrControllerProvider);
    final selfPubkey = controller.identity?.pubkey ?? '';

    final base = (baseStyle ?? const TextStyle()).copyWith(
      color: baseColor ?? c.textBright,
    );

    if (self || (pubkey.isNotEmpty && pubkey == selfPubkey)) {
      return Text('You', style: base, maxLines: 1, overflow: TextOverflow.ellipsis);
    }

    final users = ref.watch(usersProvider);
    final user = users[pubkey];
    final rawNym = (nym != null && nym!.isNotEmpty)
        ? nym!
        : (user?.nym.isNotEmpty == true ? user!.nym : pubkey);
    final baseNym = stripPubkeySuffix(rawNym);
    final suffix = getPubkeySuffix(pubkey);

    final isDev = controller.isVerifiedDeveloper(pubkey);
    final isBot = !isDev && controller.isVerifiedBot(pubkey);
    final isFriend = ref.watch(appStateProvider).friends.contains(pubkey);
    final cosmetics = ref.watch(userCosmeticsProvider(pubkey));

    // Genesis holders bold the base nym; the suffix stays weight 400.
    final genesis = hasGenesisFlair(cosmetics);

    // The base + dim suffix as a single ellipsizing run. Sized to content in
    // unbounded parents (Wrap / min-size Row) and ellipsized in bounded ones
    // (tile / pill with a maxWidth) — so no `Flexible` is needed, which keeps
    // this safe to drop anywhere in the call UI.
    final nameRun = Text.rich(
      TextSpan(children: [
        TextSpan(
          text: baseNym,
          style: base.copyWith(
            fontWeight: genesis ? FontWeight.w700 : base.fontWeight,
          ),
        ),
        TextSpan(
          text: '#$suffix',
          style: base.copyWith(
            fontWeight: FontWeight.w400,
            color: (baseColor ?? c.textBright).withValues(alpha: suffixOpacity),
          ),
        ),
      ]),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        Flexible(child: nameRun),
        CosmeticNymBadges(
          cosmetics: cosmetics,
          flairSize: badgeSize,
          supporterHeight: badgeSize,
        ),
        if (isDev || isBot) ...[
          const SizedBox(width: 3),
          _CallVerifiedBadge(size: badgeSize),
        ],
        if (isFriend) ...[
          const SizedBox(width: 3),
          _CallFriendBadge(size: badgeSize),
        ],
      ],
    );
  }
}

/// The blue verified ✓ badge (`.verified-badge`): a #1DA1F2 circle with a white
/// ✓. Self-contained copy for the call surface.
class _CallVerifiedBadge extends StatelessWidget {
  const _CallVerifiedBadge({required this.size});
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
          fontSize: size * 0.6,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

/// The friend badge (`.friend-badge`): people-with-check glyph in #4fc3f7.
class _CallFriendBadge extends StatelessWidget {
  const _CallFriendBadge({required this.size});
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
    final s = size.width / 16.0;
    final fill = Paint()
      ..color = _CallFriendBadge.color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final stroke = Paint()
      ..color = _CallFriendBadge.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * s
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    canvas.drawCircle(Offset(6 * s, 5 * s), 2.5 * s, fill);
    final body = Path()
      ..moveTo(1.5 * s, 14 * s)
      ..cubicTo(1.5 * s, 10.5 * s, 3.5 * s, 9 * s, 6 * s, 9 * s)
      ..cubicTo(8.5 * s, 9 * s, 10.5 * s, 10.5 * s, 10.5 * s, 14 * s);
    canvas.drawPath(body, fill);
    canvas.drawLine(Offset(13 * s, 6 * s), Offset(13 * s, 10 * s), stroke);
    canvas.drawLine(Offset(11 * s, 8 * s), Offset(15 * s, 8 * s), stroke);
  }

  @override
  bool shouldRepaint(covariant _FriendBadgePainter oldDelegate) => false;
}

/// Inline `@mention` highlighting for call-chat text (calls.js
/// `_formatCallChatText`, lines 1457-1472): `@name#suffix` segments rendered in
/// the primary colour, weight 600. Returns a [TextSpan] tree to drop into a
/// `Text.rich`.
TextSpan callChatTextSpans(String text, TextStyle base, Color mentionColor) {
  final raw = text;
  final re = RegExp(r'(^|\s)@([^\s#@]+)(#[0-9a-fA-F]{4})?');
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in re.allMatches(raw)) {
    if (m.start > last) {
      spans.add(TextSpan(text: raw.substring(last, m.start), style: base));
    }
    final pre = m.group(1) ?? '';
    final name = m.group(2) ?? '';
    final sfx = m.group(3) ?? '';
    if (pre.isNotEmpty) spans.add(TextSpan(text: pre, style: base));
    spans.add(TextSpan(
      text: '@$name$sfx',
      style: base.copyWith(color: mentionColor, fontWeight: FontWeight.w600),
    ));
    last = m.end;
  }
  if (last < raw.length) {
    spans.add(TextSpan(text: raw.substring(last), style: base));
  }
  return TextSpan(children: spans);
}
