import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/channel.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/nym_icons.dart';
import '../../widgets/sidebar/pm_context_menu.dart';

/// One entry in the channel `.quick-context-menu` (sidebar-sections.js
/// `_buildSidebarMenuItems`).
class ChannelMenuAction {
  const ChannelMenuAction({
    required this.label,
    required this.svg,
    required this.onSelected,
    this.danger = false,
  });
  final String label;

  /// The leading glyph as a [NymIcons] SVG string.
  final String svg;
  final VoidCallback onSelected;
  final bool danger;
}

/// Builds the long-press / right-click action list for a channel row, mirroring
/// the PWA's `_buildSidebarMenuItems` (Favorite/Hide/Block) and adding the
/// task's Share + Copy link affordances. `#nymchat` (the default channel)
/// returns no Block/Leave entries — the PWA gives it an empty menu — but Share
/// and Copy link still apply.
List<ChannelMenuAction> buildChannelMenuActions(
  BuildContext context,
  WidgetRef ref,
  ChannelEntry entry,
) {
  final controller = ref.read(nostrControllerProvider);
  final state = ref.read(appStateProvider);
  final key = entry.key;
  final isDefault = key == kDefaultChannel;
  final isPinned = state.pinnedChannels.contains(key);
  final isHidden = state.hiddenChannels.contains(key);

  // The PWA's `_buildSidebarMenuItems` returns an EMPTY menu for #nymchat
  // (sidebar-sections.js:175) and exactly Favorite / Hide / Block for any
  // other public channel — no Share/Copy/Leave (those belong to group/PM rows).
  if (isDefault) return const <ChannelMenuAction>[];

  return <ChannelMenuAction>[
    ChannelMenuAction(
      label: isPinned ? 'Unfavorite channel' : 'Favorite channel',
      // PWA uses the same filled-star `favSvg` for both states.
      svg: NymIcons.sidebarFavorite,
      onSelected: () => controller.togglePin(key),
    ),
    ChannelMenuAction(
      label: isHidden ? 'Unhide channel' : 'Hide channel',
      // PWA uses the same eye-off `hideSvg` for both states.
      svg: NymIcons.sidebarHide,
      onSelected: () {
        if (isHidden) {
          ref.read(appStateProvider.notifier).unhideChannel(key);
        } else {
          controller.hideChannel(key);
        }
      },
    ),
    ChannelMenuAction(
      label: 'Block channel',
      svg: NymIcons.sidebarBlock,
      danger: true,
      onSelected: () => controller.blockChannel(key),
    ),
  ];
}

/// Shows the channel `.quick-context-menu` for [entry] at [globalPosition],
/// reusing the shared sidebar overlay ([showSidebarQuickMenu]) so the channel
/// rows match the PM / group rows' look + entrance animation exactly. Mirrors
/// the PWA's floating action menu (`_showSidebarActionMenu`).
Future<void> showChannelContextMenu(
  BuildContext context,
  WidgetRef ref,
  ChannelEntry entry,
  Offset globalPosition,
) async {
  final actions = buildChannelMenuActions(context, ref, entry);
  if (actions.isEmpty) return;

  final items = <SidebarQuickMenuItem>[
    for (final a in actions)
      SidebarQuickMenuItem(
        label: a.label,
        svg: a.svg,
        danger: a.danger,
        onSelected: a.onSelected,
      ),
  ];

  await showSidebarQuickMenu(context, globalPosition, items);
}
