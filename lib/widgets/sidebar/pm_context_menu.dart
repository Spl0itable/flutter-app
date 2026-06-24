import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';

/// One entry in a sidebar row's `.quick-context-menu` (sidebar-sections.js
/// `_buildSidebarMenuItems`).
class SidebarQuickMenuItem {
  const SidebarQuickMenuItem({
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

/// `.quick-context-menu` background `rgba(20,20,35,0.92)`.
const Color _menuBg = Color(0xE5141423);

/// Shows the PWA `.quick-context-menu` at [globalPosition] with [items], styled
/// exactly per `styles-features.css:2778-2846`: bg `rgba(20,20,35,0.92)`, radius
/// 14, padding 4, min-width 200, shadow `0 8 32 rgba(0,0,0,.4)`; items padding
/// 8/12, gap 10, radius 8, font 14, icon `--text-dim` (danger → `--danger`),
/// with a 150ms `scale(0.9→1) + translateY(-6→0) + opacity` entrance. Fires a
/// haptic tap when opened (PWA `window.nymHapticTap`). Returns the chosen item's
/// callback result after dismissal.
Future<void> showSidebarQuickMenu(
  BuildContext context,
  Offset globalPosition,
  List<SidebarQuickMenuItem> items,
) async {
  if (items.isEmpty) return;
  HapticFeedback.selectionClick();

  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return;
  final size = overlay.size;

  final selected = await Navigator.of(context, rootNavigator: true)
      .push<SidebarQuickMenuItem>(
    _QuickMenuRoute(anchor: globalPosition, overlaySize: size, items: items),
  );
  selected?.onSelected();
}

/// A transparent, barrier-dismissible route that positions the animated
/// `.quick-context-menu` near the press point and clamps it on-screen.
class _QuickMenuRoute extends PopupRoute<SidebarQuickMenuItem> {
  _QuickMenuRoute({
    required this.anchor,
    required this.overlaySize,
    required this.items,
  });

  final Offset anchor;
  final Size overlaySize;
  final List<SidebarQuickMenuItem> items;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 150);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    const double menuWidth = 200;
    final double itemH = 36; // ~14px font + 8/8 padding
    final double menuH = items.length * itemH + 8; // + 4/4 menu padding
    // Clamp the popup inside the overlay (8px inset).
    double left = anchor.dx;
    double top = anchor.dy;
    if (left + menuWidth > overlaySize.width - 8) {
      left = overlaySize.width - menuWidth - 8;
    }
    if (left < 8) left = 8;
    if (top + menuH > overlaySize.height - 8) {
      top = overlaySize.height - menuH - 8;
    }
    if (top < 8) top = 8;

    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          child: _QuickMenu(animation: animation, items: items),
        ),
      ],
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child; // entrance handled inside _QuickMenu via the animation.
}

class _QuickMenu extends StatelessWidget {
  const _QuickMenu({required this.animation, required this.items});

  final Animation<double> animation;
  final List<SidebarQuickMenuItem> items;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final curve = CurvedAnimation(parent: animation, curve: Curves.easeOut);
    return AnimatedBuilder(
      animation: curve,
      builder: (context, child) {
        final t = curve.value;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            // translateY(-6 → 0)
            offset: Offset(0, -6 * (1 - t)),
            child: Transform.scale(
              // scale(0.9 → 1), anchored top-left like the CSS transform-origin.
              scale: 0.9 + 0.1 * t,
              alignment: Alignment.topLeft,
              child: child,
            ),
          ),
        );
      },
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          constraints: const BoxConstraints(minWidth: 200),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: _menuBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: c.glassBorder),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000), // rgba(0,0,0,0.4)
                blurRadius: 32,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final a in items)
                _QuickMenuRow(item: a),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickMenuRow extends StatefulWidget {
  const _QuickMenuRow({required this.item});
  final SidebarQuickMenuItem item;

  @override
  State<_QuickMenuRow> createState() => _QuickMenuRowState();
}

class _QuickMenuRowState extends State<_QuickMenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final a = widget.item;
    final fg = a.danger ? c.danger : c.text;
    final iconColor = a.danger ? c.danger : c.textDim;
    // hover bg rgba(255,255,255,0.08); danger hover rgba(255,68,68,0.12).
    final hoverBg = a.danger
        ? const Color(0x1FFF4444)
        : const Color(0x14FFFFFF);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(a),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          // `.quick-context-item`: padding 8/12, gap 10, radius 8, font 14.
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _hover ? hoverBg : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(a.icon, size: 16, color: iconColor),
              const SizedBox(width: 10),
              Text(
                a.label,
                style: TextStyle(color: fg, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
  final controller = ref.read(nostrControllerProvider);
  final isBlocked = ref.read(appStateProvider).blockedUsers.contains(pubkey);

  final items = <SidebarQuickMenuItem>[
    SidebarQuickMenuItem(
      label: isBlocked ? 'Unblock user' : 'Block user',
      icon: isBlocked ? Icons.check_circle_outline : Icons.block,
      danger: !isBlocked,
      onSelected: () => controller.toggleBlockUser(pubkey),
    ),
    SidebarQuickMenuItem(
      label: 'Leave conversation',
      icon: Icons.logout,
      danger: true,
      onSelected: () => ref.read(appStateProvider.notifier).closePM(pubkey),
    ),
  ];

  await showSidebarQuickMenu(context, globalPosition, items);
}
