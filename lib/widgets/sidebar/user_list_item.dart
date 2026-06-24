import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/shop/cosmetics.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../common/nym_avatar.dart';
import '../context_menu/profile_badges.dart';

/// A single ONLINE NYMS row (`.user-item`, users.js `_createUserItem` /
/// `_fillUserLabel`): padding 6/12, margin 2/4, dim text at
/// `calc(--user-text-size - 3px)`, gap 8, a 20px avatar wrapped in
/// `.user-avatar-wrap` with the live `.user-status-dot` (8px, ring) overlaid on
/// its bottom-right, then `nym` + `#suffix` + flair + verified ✓ + friend badge.
class UserListItem extends ConsumerWidget {
  const UserListItem({
    super.key,
    required this.user,
    required this.textSize,
    required this.onTap,
  });

  final User user;
  final double textSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final status = user.effectiveStatus();
    final controller = ref.read(nostrControllerProvider);
    final isDev = controller.isVerifiedDeveloper(user.pubkey);
    final isBot = controller.isVerifiedBot(user.pubkey);
    final isFriend = ref.watch(appStateProvider).isFriend(user.pubkey);

    // `_fillUserLabel`: the base nym is hard-truncated to 20 chars + '...'
    // BEFORE the `#suffix` + badges are appended.
    final base = stripPubkeySuffix(user.nym);
    final displayNym = base.length > 20 ? '${base.substring(0, 20)}...' : base;
    final suffix = getPubkeySuffix(user.pubkey);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: NymRadius.rxs,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const BoxDecoration(borderRadius: NymRadius.rxs),
            child: Row(
              children: [
                // `.user-avatar-wrap` (20×20, position:relative) with the
                // `.user-status-dot` overlaid bottom-right (-1px), 8px + a 2px
                // #0a0a0f ring (content-box → 12px outer).
                _AvatarWithStatus(
                  seed: user.pubkey,
                  imageUrl: user.profile?.picture,
                  status: status,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: displayNym),
                        TextSpan(
                          // `.nym-suffix`: opacity .7, 0.9em, weight 100.
                          text: '#$suffix',
                          style: TextStyle(
                            color: c.textDim.withValues(alpha: 0.7),
                            fontSize: (textSize - 3) * 0.9,
                            fontWeight: FontWeight.w100,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.textDim,
                      fontSize: textSize - 3,
                    ),
                  ),
                ),
                CosmeticNymBadges(
                  cosmetics: userCosmeticsFromUser(user),
                  flairSize: 13,
                  supporterHeight: 13,
                ),
                // Verified developer / bot ✓ then friend badge
                // (`_fillUserLabel`: `verified-badge` margin-left 4, friend after).
                if (isDev || isBot) ...[
                  const SizedBox(width: 4),
                  const VerifiedBadge(size: 13),
                ],
                if (isFriend) ...[
                  const SizedBox(width: 2),
                  const FriendBadge(size: 13),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `.user-avatar-wrap` + `.user-status-dot`: a 20px [NymAvatar] with an 8px
/// status dot overlaid on the bottom-right corner (-1px), ringed by a 2px
/// `#0a0a0f` border (CSS `box-sizing:content-box` → 12px outer). Hidden for the
/// `hidden` status (`.user-avatar-wrap.no-status .user-status-dot`).
class _AvatarWithStatus extends StatelessWidget {
  const _AvatarWithStatus({
    required this.seed,
    required this.imageUrl,
    required this.status,
  });

  final String seed;
  final String? imageUrl;
  final UserStatus status;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        NymAvatar(seed: seed, size: 20, imageUrl: imageUrl),
        if (status != UserStatus.hidden)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: statusColor(status),
                shape: BoxShape.circle,
                // `border: 2px solid #0a0a0f` (the PWA hardcodes `--bg`).
                border: Border.all(color: const Color(0xFF0A0A0F), width: 2),
              ),
            ),
          ),
      ],
    );
  }
}
