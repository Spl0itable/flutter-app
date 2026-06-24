import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/shop/cosmetics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../common/nym_avatar.dart';
import '../context_menu/profile_badges.dart';
import 'pm_context_menu.dart';

/// A single PM thread row (`.pm-item`, pms.js `createPMConversation`). Same box
/// metrics as `.channel-item` with a 26px PM avatar (`margin-right:4px`), the
/// `.pm-name` (`{nym}<span class="nym-suffix">#suffix</span>{flair} {verified}
/// {friend}`) and an optional unread pill. The live sidebar PM row has **no**
/// status dot — that lives only in the chat-header avatar.
///
/// A long-press (mobile) or secondary-tap / right-click (desktop) opens the
/// `.quick-context-menu` (Block/Unblock user, Leave conversation) — see
/// [showPmContextMenu].
class PMListItem extends ConsumerWidget {
  const PMListItem({
    super.key,
    required this.nym,
    required this.pubkey,
    required this.active,
    required this.unread,
    required this.textSize,
    required this.onTap,
  });

  final String nym;
  final String pubkey;
  final bool active;
  final int unread;
  final double textSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final controller = ref.read(nostrControllerProvider);
    final appState = ref.watch(appStateProvider);
    final picture = appState.users[pubkey]?.profile?.picture;
    final isDev = controller.isVerifiedDeveloper(pubkey);
    final isBot = controller.isVerifiedBot(pubkey);
    final isFriend = appState.isFriend(pubkey);
    final base = stripPubkeySuffix(nym);
    final suffix = getPubkeySuffix(pubkey);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (d) =>
              showPmContextMenu(context, ref, pubkey, d.globalPosition),
          onSecondaryTapDown: (d) =>
              showPmContextMenu(context, ref, pubkey, d.globalPosition),
          child: InkWell(
            onTap: onTap,
            borderRadius: NymRadius.rxs,
            // `.pm-item.active` shares `.channel-item.active`: primary fill/
            // border/glow + a 3px primary accent bar (NOT purple).
            child: Stack(
            children: [
              Container(
                constraints: const BoxConstraints(minHeight: 36),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: active ? c.primaryA(0.10) : Colors.transparent,
                  borderRadius: NymRadius.rxs,
                  border: Border.all(
                    color: active ? c.primaryA(0.20) : Colors.transparent,
                    width: 1,
                  ),
                  boxShadow: active
                      ? [BoxShadow(color: c.primaryA(0.05), blurRadius: 12)]
                      : null,
                ),
                child: Row(
                  children: [
                    // `.avatar-pm`: 26px, margin-right 4 (no sidebar status dot).
                    NymAvatar(seed: pubkey, size: 26, imageUrl: picture),
                    const SizedBox(width: 4),
                    Flexible(
                      // `.pm-name`: color --text-dim, normal weight, with a dim
                      // `.nym-suffix` tail.
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: base),
                            TextSpan(
                              text: '#$suffix',
                              style: TextStyle(
                                color: c.textDim.withValues(alpha: 0.7),
                                fontSize: textSize * 0.9,
                                fontWeight: FontWeight.w100,
                              ),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.textDim,
                          fontSize: textSize,
                          fontWeight: FontWeight.w400,
                          height: 1.3,
                        ),
                      ),
                    ),
                    Consumer(
                      builder: (context, ref, _) => CosmeticNymBadges(
                        cosmetics: ref.watch(userCosmeticsProvider(pubkey)),
                        flairSize: 14,
                        supporterHeight: 14,
                      ),
                    ),
                    if (isDev || isBot) ...[
                      const SizedBox(width: 4),
                      const VerifiedBadge(size: 14),
                    ],
                    if (isFriend) ...[
                      const SizedBox(width: 2),
                      const FriendBadge(size: 14),
                    ],
                    const Spacer(),
                    if (unread > 0) _UnreadPill(count: unread),
                  ],
                ),
              ),
              if (active)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: FractionallySizedBox(
                      heightFactor: 0.6,
                      child: Container(
                        width: 3,
                        decoration: BoxDecoration(
                          color: c.primary,
                          borderRadius: const BorderRadius.only(
                            topRight: Radius.circular(3),
                            bottomRight: Radius.circular(3),
                          ),
                          boxShadow: [
                            BoxShadow(color: c.primaryA(0.4), blurRadius: 8),
                          ],
                        ),
                      ),
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
}

class _UnreadPill extends StatelessWidget {
  const _UnreadPill({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `.unread-badge`: bg --primary, text --bg, pill, tabular-nums; caps at 99+.
    return Container(
      constraints: const BoxConstraints(minWidth: 30),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.primary,
        borderRadius: const BorderRadius.all(Radius.circular(20)),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: c.bg,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
