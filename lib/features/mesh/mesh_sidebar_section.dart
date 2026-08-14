import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import 'mesh_controller.dart';
import 'mesh_screen.dart';

/// A dedicated "Bluetooth Mesh" section for the sidebar: it surfaces the Nearby
/// (public broadcast) channel and every discovered peer as an encrypted DM,
/// alongside the normal Nostr channels/PMs — so mesh chats live in the sidebar
/// like everything else. Tapping a row opens the canonical mesh screen.
///
/// The section is entirely sourced from [meshControllerProvider] and renders
/// nothing when the mesh isn't running, so it never affects the Nostr-backed
/// sections or their state.
class MeshSidebarSection extends ConsumerWidget {
  const MeshSidebarSection({super.key, this.onItemSelected});

  /// Called when a row is tapped (e.g. to close the drawer on phones), matching
  /// the other sidebar rows.
  final VoidCallback? onItemSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mesh = ref.watch(meshControllerProvider);
    if (!mesh.running) return const SizedBox.shrink();

    final c = context.nym;
    final textSize = ref.watch(settingsProvider.select((s) => s.textSize)).toDouble();

    // Peers with an existing conversation float to the top, then by recency.
    final peers = [...mesh.peers]..sort((a, b) {
        final at = mesh.threads.containsKey(a.peerID);
        final bt = mesh.threads.containsKey(b.peerID);
        if (at != bt) return at ? -1 : 1;
        return b.lastSeen.compareTo(a.lastSeen);
      });

    void open(Widget screen) {
      onItemSelected?.call();
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Section title, matching `.nav-title` (uppercase, dim, tracked).
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 0, 10),
            child: Row(
              children: [
                NymSvgIcon(NymIcons.bluetooth, size: 13, color: c.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tr('Bluetooth Mesh').toUpperCase(),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.textDim,
                      fontSize: 10,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${mesh.linkCount}',
                  style: TextStyle(
                    color: c.textDim.withValues(alpha: 0.7),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          // Nearby (public broadcast) channel.
          _MeshRow(
            colors: c,
            textSize: textSize,
            leading: _HashAvatar(colors: c),
            label: tr('Nearby'),
            subtitle: tr('public · everyone in range'),
            onTap: () => open(const MeshScreen()),
          ),
          // Joined mesh group channels.
          for (final ch in mesh.channels)
            _MeshRow(
              colors: c,
              textSize: textSize,
              leading: _HashAvatar(colors: c),
              label: ch.name,
              locked: ch.encrypted,
              onTap: () => open(MeshChannelScreen(
                  channel: ch.name, encrypted: ch.encrypted)),
            ),
          // Encrypted DMs, one per peer.
          for (final peer in peers)
            _MeshRow(
              colors: c,
              textSize: textSize,
              leading: NymAvatar(
                seed: peer.nostrPubkey ?? peer.peerID,
                size: 26,
                imageUrl: peer.avatarUrl,
                label: peer.displayName,
              ),
              label: peer.displayName,
              verified: peer.isVerified,
              onTap: () => open(MeshPmScreen(peer: peer)),
            ),
          if (peers.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
              child: Text(
                tr('No peers nearby yet'),
                style: TextStyle(color: c.textDim, fontSize: textSize * 0.85),
              ),
            ),
        ],
      ),
    );
  }
}

/// A sidebar row matching `.pm-item`/`.channel-item` metrics.
class _MeshRow extends StatelessWidget {
  const _MeshRow({
    required this.colors,
    required this.textSize,
    required this.leading,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.verified = false,
    this.locked = false,
  });

  final NymColors colors;
  final double textSize;
  final Widget leading;
  final String label;
  final String? subtitle;
  final bool verified;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: NymRadius.rxs,
          hoverColor: colors.hoverOverlay,
          child: Container(
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              label,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.textDim,
                                fontSize: textSize,
                                height: 1.3,
                              ),
                            ),
                          ),
                          if (verified) ...[
                            const SizedBox(width: 4),
                            NymSvgIcon(NymIcons.friendBadge,
                                size: 12, color: colors.primary),
                          ],
                          if (locked) ...[
                            const SizedBox(width: 4),
                            NymSvgIcon(NymIcons.lock, size: 11, color: colors.purple),
                          ],
                        ],
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textDim.withValues(alpha: 0.7),
                            fontSize: textSize * 0.8,
                          ),
                        ),
                    ],
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

/// A `#`-style leading glyph for the Nearby row (mirrors a channel avatar).
class _HashAvatar extends StatelessWidget {
  const _HashAvatar({required this.colors});
  final NymColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Text('#',
          style: TextStyle(
              color: colors.primary, fontWeight: FontWeight.w700, fontSize: 15)),
    );
  }
}
