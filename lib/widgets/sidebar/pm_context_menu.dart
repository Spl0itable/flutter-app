import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';

/// One entry in a PM row's long-press / right-click menu (sidebar-sections.js
/// `_buildSidebarMenuItems` pm-item branch).
class _PmMenuAction {
  const _PmMenuAction({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.danger = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onSelected;
  final bool danger;
}

/// Shows the PM `.quick-context-menu` at [globalPosition] with Block/Unblock
/// user + Leave conversation, mirroring the PWA's `_buildSidebarMenuItems`
/// pm-item branch (sidebar-sections.js:216-235). Block toggles via
/// [NostrController.toggleBlockUser]; Leave closes the thread via
/// [AppStateNotifier.closePM] (`deletePM`).
Future<void> showPmContextMenu(
  BuildContext context,
  WidgetRef ref,
  String pubkey,
  Offset globalPosition,
) async {
  if (pubkey.isEmpty) return;
  final c = context.nym;
  final controller = ref.read(nostrControllerProvider);
  final isBlocked = ref.read(appStateProvider).blockedUsers.contains(pubkey);

  // Haptic on fire (PWA `window.nymHapticTap`).
  HapticFeedback.selectionClick();

  final actions = <_PmMenuAction>[
    _PmMenuAction(
      label: isBlocked ? 'Unblock user' : 'Block user',
      icon: isBlocked ? Icons.check_circle_outline : Icons.block,
      danger: !isBlocked,
      onSelected: () => controller.toggleBlockUser(pubkey),
    ),
    _PmMenuAction(
      label: 'Leave conversation',
      icon: Icons.logout,
      danger: true,
      onSelected: () =>
          ref.read(appStateProvider.notifier).closePM(pubkey),
    ),
  ];

  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return;

  final selected = await showMenu<_PmMenuAction>(
    context: context,
    color: c.bgTertiary,
    elevation: 8,
    shape: RoundedRectangleBorder(
      borderRadius: NymRadius.rsm,
      side: BorderSide(color: c.glassBorder),
    ),
    position: RelativeRect.fromRect(
      globalPosition & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final a in actions)
        PopupMenuItem<_PmMenuAction>(
          value: a,
          height: 40,
          child: Row(
            children: [
              Icon(a.icon, size: 16, color: a.danger ? c.danger : c.textDim),
              const SizedBox(width: 12),
              Text(
                a.label,
                style: TextStyle(
                  color: a.danger ? c.danger : c.text,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
    ],
  );
  selected?.onSelected();
}
