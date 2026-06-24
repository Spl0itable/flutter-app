import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/channels/channel_context_menu.dart';
import '../../features/settings/settings_helpers.dart';
import '../../models/channel.dart';

/// The grey "pinned/favorited" tint the PWA paints on a `.channel-item.pinned`
/// row when it is not the active channel (`rgba(150,150,160,…)`,
/// styles-shell.css:348-366).
const Color _pinnedGrey = Color(0xFF9696A0); // rgb(150,150,160)

/// A single channel row in the sidebar PUBLIC CHANNELS list.
///
/// Mirrors `.channel-item` (docs/specs/02 §5.3): padding 9/12, margin 2/4,
/// radius rxs, min-height 36, 1px transparent border; active state gets a
/// primary@10 fill, primary@20 border, glow, and a 3px left accent bar. A
/// favorited (pinned) row that is not active gets a grey fill/border/glow + a
/// grey accent bar instead. Unread count renders as a pill badge — the PWA's
/// ONLY channel badge.
///
/// A long-press (mobile) or secondary-tap / right-click (desktop) opens the
/// `.channel-context-menu` (Favorite/Hide/Block) — see [showChannelContextMenu].
class ChannelListItem extends ConsumerWidget {
  const ChannelListItem({
    super.key,
    required this.entry,
    required this.active,
    required this.pinned,
    required this.unread,
    required this.textSize,
    required this.onTap,
  });

  final ChannelEntry entry;
  final bool active;
  final bool pinned;
  final int unread;
  final double textSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final name = '#${entry.isGeohash ? entry.geohash : entry.channel}';
    // `.channel-item.pinned:not(.active)` paints the grey treatment; the active
    // state always wins.
    final showPinned = pinned && !active;
    // Geohash rows get a `title="{getGeohashLocation(geohash)}"` hover tooltip.
    final location =
        entry.isGeohash ? geohashLocationLabel(entry.geohash) : '';

    final Color fill = active
        ? c.primaryA(0.10)
        : (showPinned ? _pinnedGrey.withValues(alpha: 0.10) : Colors.transparent);
    final Color borderColor = active
        ? c.primaryA(0.20)
        : (showPinned ? _pinnedGrey.withValues(alpha: 0.20) : Colors.transparent);
    final List<BoxShadow>? glow = active
        ? [BoxShadow(color: c.primaryA(0.05), blurRadius: 12)]
        : (showPinned
            ? [BoxShadow(color: _pinnedGrey.withValues(alpha: 0.05), blurRadius: 12)]
            : null);

    final nameText = Text(
      name,
      // `.channel-name`: white-space:normal; overflow-wrap:break-word → wraps.
      softWrap: true,
      style: TextStyle(
        color: c.text,
        fontSize: textSize,
        fontWeight: FontWeight.w400,
        height: 1.3,
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (d) =>
              showChannelContextMenu(context, ref, entry, d.globalPosition),
          onSecondaryTapDown: (d) =>
              showChannelContextMenu(context, ref, entry, d.globalPosition),
          child: InkWell(
            onTap: onTap,
            borderRadius: NymRadius.rxs,
            child: Stack(
              children: [
                Container(
                  constraints: const BoxConstraints(minHeight: 36),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: NymRadius.rxs,
                    border: Border.all(color: borderColor, width: 1),
                    // `.channel-item.active`: box-shadow 0 0 12px primary@5%
                    // (grey@5% when pinned-not-active).
                    boxShadow: glow,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        // `.channel-name` inherits `--text` weight normal even
                        // when active (active changes bg/border/bar only).
                        child: location.isEmpty
                            ? nameText
                            : Tooltip(message: location, child: nameText),
                      ),
                      // PWA `.channel-badges` only ever contains the unread
                      // pill. `.std-badge` / `.geohash-badge` are DEAD CSS —
                      // never emitted by channels.js/pms.js/groups.js. Geohash
                      // vs standard channels are distinguished by the name only.
                      if (unread > 0) ...[
                        const SizedBox(width: 8),
                        _UnreadPill(count: unread),
                      ],
                    ],
                  ),
                ),
                if (active || showPinned)
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
                            color: active ? c.primary : _pinnedGrey,
                            borderRadius: const BorderRadius.only(
                              topRight: Radius.circular(3),
                              bottomRight: Radius.circular(3),
                            ),
                            // `::before` accent bar glow 0 0 8px primary@40%
                            // (no glow on the grey pinned bar).
                            boxShadow: active
                                ? [
                                    BoxShadow(
                                      color: c.primaryA(0.4),
                                      blurRadius: 8,
                                    ),
                                  ]
                                : null,
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

/// `.unread-badge`: bg primary, text bg-color, pill, 10px weight 600, caps 99+.
class _UnreadPill extends StatelessWidget {
  const _UnreadPill({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `.unread-badge`: min-width 3ch (content-box) + 7px h-padding ≈ 30px.
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
