import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/group.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../common/nym_avatar.dart';
import 'context_menu_actions.dart';
import 'context_menu_panel.dart';

/// The `#groupContextMenu` slide-in panel (PWA `showGroupContextMenu`,
/// groups.js:2987-3088). A right-side panel mirroring the user context menu's
/// chrome (width 320, `translateX(100%)→0` over 150ms, dimmed barrier) that:
///
///  * shows the group banner + icon + name + member count + description,
///  * renders the owner-gated **Transfer Ownership** row (the one owner action
///    backed by a controller method here),
///  * lists the members (owner → mods → members) with a role badge; tapping a
///    member opens that user's context menu, which carries the group's
///    PM / kick / ban / promote / make-owner actions gated by role (via
///    `buildContextMenuActions` with the group context), and shows a back
///    chevron that returns here (`backToGroupId`).
///
/// Role gates are read-only from group state (`group.createdBy` / `group.mods`).
/// The metadata-mutating owner controls the PWA also offers (edit name /
/// description, change/remove avatar+banner, invite toggles, add members, leave)
/// are owned by the groups slice and are omitted here rather than shipped as
/// no-ops — see the CROSS-FILE NEEDS note in [_actionRows].
class GroupContextMenuPanel extends ConsumerStatefulWidget {
  const GroupContextMenuPanel({
    super.key,
    required this.groupId,
    required this.animation,
    required this.onClose,
  });

  final String groupId;
  final Animation<double> animation;
  final VoidCallback onClose;

  /// Presents the panel in the root overlay with the slide-in transition,
  /// mirroring [ContextMenuPanel.show].
  static Future<void> show(BuildContext context, String groupId) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'group context menu',
      barrierColor: const Color(0x99000000), // rgba(0,0,0,0.6)
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (ctx, anim, _) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, _, __) => Align(
        alignment: Alignment.centerRight,
        child: GroupContextMenuPanel(
          groupId: groupId,
          animation: anim,
          onClose: () => Navigator.of(ctx).maybePop(),
        ),
      ),
    );
  }

  @override
  ConsumerState<GroupContextMenuPanel> createState() =>
      _GroupContextMenuPanelState();
}

class _GroupContextMenuPanelState extends ConsumerState<GroupContextMenuPanel> {
  /// "Select a member to make owner" mode (PWA `_groupCtxTransferMode`,
  /// groups.js:3120). When on, member taps pick the new owner instead of opening
  /// the user menu.
  bool _transferMode = false;

  Group? _group(AppState s) {
    for (final g in s.groups) {
      if (g.id == widget.groupId) return g;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final s = ref.watch(appStateProvider);
    final group = _group(s);

    final body = group == null
        ? Center(
            child: Text('Group unavailable',
                style: TextStyle(color: c.textDim, fontSize: 13)),
          )
        : _content(c, s, group);

    final screenW = MediaQuery.of(context).size.width;
    final panelW = (screenW * 0.85).clamp(0.0, 320.0);

    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(
              CurvedAnimation(parent: widget.animation, curve: Curves.linear)),
      child: SizedBox(
        width: panelW,
        height: double.infinity,
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: c.glassBorder)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000), // rgba(0,0,0,0.4)
                blurRadius: 24,
                offset: Offset(-4, 0),
              ),
            ],
          ),
          child: Stack(
            children: [
              Material(color: c.bgTertiary, child: SafeArea(child: body)),
              Positioned(top: 14, right: 14, child: _closeBtn(c)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(NymColors c, AppState s, Group group) {
    final self = s.selfPubkey;
    final iAmOwner = group.createdBy == self;

    // Sort members: owner → mods → members (PWA `_memberRoleRank`).
    final sorted = [...group.members]
      ..sort((a, b) => _roleRank(group, a).compareTo(_roleRank(group, b)));

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(c, group),
          // Owner/member management rows (role-gated).
          Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _actionRows(c, group, iAmOwner),
            ),
          ),
          // Members section.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Text(
              _transferMode
                  ? 'Select a member to make owner'
                  : 'Members · ${group.members.length}',
              style: TextStyle(
                color: c.textDim,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
          for (final pk in sorted)
            // In transfer mode the owner can't pick themselves.
            if (!_transferMode || pk != self)
              _memberRow(c, group, pk, self),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Header (banner + icon + name + member count + description)
  // ---------------------------------------------------------------------------

  Widget _header(NymColors c, Group group) {
    final bannerUrl = proxiedAvatarUrl(group.banner);
    final hasBanner = bannerUrl != null && bannerUrl.isNotEmpty;
    final avatarUrl = proxiedAvatarUrl(group.avatar);

    // The group icon: custom avatar, else a stacked-people glyph (PWA groupSvg).
    final icon = SizedBox(
      width: 64,
      height: 64,
      child: (avatarUrl != null && avatarUrl.isNotEmpty)
          ? ClipOval(
              child: CachedNetworkImage(
                imageUrl: avatarUrl,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => _defaultGroupIcon(c),
              ),
            )
          : _defaultGroupIcon(c),
    );

    final header = Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Column(
        children: [
          if (!hasBanner) ...[icon, const SizedBox(height: 8)],
          Text(
            group.name.isEmpty ? 'Group' : group.name,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: c.secondary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${group.members.length} member${group.members.length == 1 ? '' : 's'}',
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
          if ((group.description ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              group.description!,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textDim, fontSize: 13, height: 1.4),
            ),
          ],
        ],
      ),
    );

    if (!hasBanner) return header;

    // Banner with the icon straddling its bottom edge (`margin-top:-36px`),
    // mirroring the user menu's banner overlap.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 140,
              width: double.infinity,
              child: CachedNetworkImage(
                imageUrl: bannerUrl,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
            Padding(padding: const EdgeInsets.only(top: 34), child: header),
          ],
        ),
        Positioned(
          top: 140 - 36,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                border: Border.fromBorderSide(
                  BorderSide(color: Color(0xF2141423), width: 3),
                ),
              ),
              child: icon,
            ),
          ),
        ),
      ],
    );
  }

  Widget _defaultGroupIcon(NymColors c) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.primary.withValues(alpha: 0.18),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.groups, size: 34, color: c.secondary),
    );
  }

  // ---------------------------------------------------------------------------
  // Action rows (role-gated owner/member controls)
  // ---------------------------------------------------------------------------

  List<Widget> _actionRows(NymColors c, Group group, bool iAmOwner) {
    final rows = <Widget>[];

    // Transfer Ownership — the one owner action with a controller method here
    // (`transferOwner`). Enters member-pick mode (PWA `groupCtxTransferOwner`).
    if (iAmOwner && group.members.length > 1) {
      rows.add(_ActionRow(
        icon: Icons.swap_horiz,
        label: 'Transfer Ownership',
        color: c.text,
        onTap: () => setState(() => _transferMode = true),
      ));
    }

    // NOTE (CROSS-FILE NEEDS): the PWA also offers owner controls for Edit Name/
    // Description, Change/Remove Avatar+Banner, the invite-link toggles, Add
    // Members, and Leave Group (groups.js:3046-3083). Those mutate group
    // metadata / membership via the groups slice (no controller methods exposed
    // to this widget), so they are intentionally omitted rather than shipped as
    // no-op rows. Wire them when the groups slice exposes the actions.

    return rows;
  }

  // ---------------------------------------------------------------------------
  // Member rows
  // ---------------------------------------------------------------------------

  int _roleRank(Group group, String pubkey) {
    if (group.createdBy == pubkey) return 0;
    if (group.mods.contains(pubkey)) return 1;
    return 2;
  }

  Widget _memberRow(NymColors c, Group group, String pubkey, String self) {
    final user = ref.watch(usersProvider)[pubkey];
    final base = stripPubkeySuffix(user?.nym ?? '');
    final suffix = getPubkeySuffix(pubkey);
    final isSelf = pubkey == self;
    final isOwner = group.createdBy == pubkey;
    final isMod = !isOwner && group.mods.contains(pubkey);
    final status = user?.effectiveStatus() ?? UserStatus.offline;

    return _MemberTile(
      colors: c,
      avatar: SizedBox(
        width: 32,
        height: 32,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            NymAvatar(
              seed: pubkey,
              size: 32,
              imageUrl: user?.profile?.picture,
              label: base.isNotEmpty ? base[0] : null,
            ),
            if (status != UserStatus.hidden)
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: statusColor(status),
                    shape: BoxShape.circle,
                    border: Border.all(color: c.bgTertiary, width: 1.5),
                  ),
                ),
              ),
          ],
        ),
      ),
      base: base.isEmpty ? '(unknown)' : base,
      suffix: '#$suffix',
      isSelf: isSelf,
      roleBadge: isOwner ? 'Owner' : (isMod ? 'Mod' : null),
      onTap: () => _onMemberTap(group, pubkey, base, isSelf),
    );
  }

  void _onMemberTap(Group group, String pubkey, String base, bool isSelf) {
    if (_transferMode) {
      // Pick the new owner (PWA `_openMemberFromGroupCtx` transfer branch). The
      // confirm dialog runs on THIS (still-mounted) panel; only on confirm do we
      // pop + transfer, so `ref` stays valid.
      setState(() => _transferMode = false);
      _confirmTransfer(group.id, pubkey, base);
      return;
    }
    // Open the user's context menu carrying this group as the back target so it
    // shows a "back" chevron and the group kick/ban/mod actions stay visible
    // (PWA `_openMemberFromGroupCtx`: showContextMenu(..., backToGroupId)).
    // Capture the root navigator context before popping (ours is then defunct).
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    widget.onClose();
    final target = CtxTarget(
      pubkey: pubkey,
      nym: base,
      isSelf: isSelf,
      backToGroupId: group.id,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (rootContext.mounted) {
        ContextMenuPanel.show(rootContext, target: target);
      }
    });
  }

  Future<void> _confirmTransfer(
      String groupId, String pubkey, String base) async {
    final c = context.nym;
    final controller = ref.read(nostrControllerProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.bgTertiary,
        content: Text(
          'Transfer group ownership to $base? You will lose owner privileges.',
          style: TextStyle(color: c.text, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel', style: TextStyle(color: c.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Transfer', style: TextStyle(color: c.danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      // Close the group menu, then run the transfer with the captured
      // controller (safe even after this panel disposes).
      widget.onClose();
      await controller.transferOwner(groupId, pubkey);
    }
  }

  Widget _closeBtn(NymColors c) {
    return InkWell(
      onTap: widget.onClose,
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.05),
          border: Border.all(color: c.glassBorder),
        ),
        child: Icon(Icons.close, size: 16, color: c.textDim),
      ),
    );
  }
}

/// A `.context-menu-item` management row (icon + label + optional trailing).
class _ActionRow extends StatefulWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.trailing,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  State<_ActionRow> createState() => _ActionRowState();
}

class _ActionRowState extends State<_ActionRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final iconColor = widget.color == c.text ? c.textDim : widget.color;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _hover ? Colors.white.withValues(alpha: 0.08) : null,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 16, color: iconColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: widget.color,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (widget.trailing != null) widget.trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

/// A `.group-ctx-member` row: avatar (+status dot), base nym + dim suffix
/// (+ "you"), and a role badge (Owner/Mod). Tapping opens the member's menu.
class _MemberTile extends StatefulWidget {
  const _MemberTile({
    required this.colors,
    required this.avatar,
    required this.base,
    required this.suffix,
    required this.isSelf,
    required this.roleBadge,
    required this.onTap,
  });

  final NymColors colors;
  final Widget avatar;
  final String base;
  final String suffix;
  final bool isSelf;
  final String? roleBadge;
  final VoidCallback onTap;

  @override
  State<_MemberTile> createState() => _MemberTileState();
}

class _MemberTileState extends State<_MemberTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          color: _hover ? Colors.white.withValues(alpha: 0.06) : null,
          child: Row(
            children: [
              widget.avatar,
              const SizedBox(width: 10),
              Expanded(
                child: RichText(
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    style: TextStyle(
                        color: c.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w500),
                    children: [
                      TextSpan(text: widget.base),
                      TextSpan(
                        text: widget.suffix,
                        style: TextStyle(
                          color: c.textDim.withValues(alpha: 0.7),
                          fontWeight: FontWeight.w100,
                        ),
                      ),
                      if (widget.isSelf)
                        TextSpan(
                          text: '  you',
                          style: TextStyle(
                              color: c.textDim,
                              fontSize: 11,
                              fontWeight: FontWeight.w400),
                        ),
                    ],
                  ),
                ),
              ),
              if (widget.roleBadge != null) ...[
                const SizedBox(width: 8),
                _RoleBadge(label: widget.roleBadge!, colors: c),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// `.group-ctx-role`: a small Owner/Mod chip (owner = primary, mod = secondary).
class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.label, required this.colors});
  final String label;
  final NymColors colors;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final isOwner = label == 'Owner';
    final accent = isOwner ? c.primary : c.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.16),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        border: Border.all(color: accent.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: accent,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
