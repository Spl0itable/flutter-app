import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/channels/channel_share.dart';
import '../../features/notifications/notifications_panel.dart';
import '../../features/onboarding/tutorial_overlay.dart';
import '../../features/p2p/p2p_transfers_modal.dart';
import '../../features/settings/about_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/shop/shop_modal.dart';
import '../../models/channel.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../common/app_dialog.dart';
import '../common/nym_avatar.dart';
import 'composer.dart';
import 'messages_list.dart';

/// Signature for the call-start hook the calls feature wires later. [peer] is
/// the PM peer pubkey (or '' for a channel/group), [video] selects video vs
/// audio. The header never implements calls itself — it only invokes this.
typedef OnStartCall = void Function(String peer, {required bool video});

/// Signature for starting a group call (group id + video flag).
typedef OnStartGroupCall = void Function(String groupId, {required bool video});

/// The main chat column: header + messages list + composer
/// (`main.main-content`, docs/specs/02 §1.1, §5.4–5.5).
class ChatPane extends ConsumerWidget {
  const ChatPane({
    super.key,
    this.onOpenSidebar,
    this.compact = false,
    this.onStartCall,
    this.onStartGroupCall,
  });

  /// Mobile/tablet: opens the off-canvas sidebar drawer (hamburger).
  final VoidCallback? onOpenSidebar;

  /// Mobile/tablet chrome (hamburger + stacked composer). Driven by
  /// `width <= 1024` so the mobile header shows across the whole 0–1024 range.
  final bool compact;

  /// Optional call-start hooks (wired by the calls feature; null = no calls).
  final OnStartCall? onStartCall;
  final OnStartGroupCall? onStartGroupCall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    return Container(
      color: c.bg,
      child: Column(
        children: [
          _ChatHeader(
            onOpenSidebar: onOpenSidebar,
            compact: compact,
            onStartCall: onStartCall,
            onStartGroupCall: onStartGroupCall,
          ),
          // `#messagesContainer` — tutorial spotlight target.
          Expanded(
            child: KeyedSubtree(
              key: TutorialTargets.keyFor(TutorialTarget.messagesContainer),
              child: const MessagesList(),
            ),
          ),
          // `.input-container` — tutorial spotlight target.
          KeyedSubtree(
            key: TutorialTargets.keyFor(TutorialTarget.composer),
            child: Composer(compact: compact),
          ),
        ],
      ),
    );
  }
}

/// `.chat-header`: title (primary, textSize+3, weight700) + meta line + nav and
/// action icon buttons. Mobile shows the hamburger + a notification toggle.
class _ChatHeader extends ConsumerStatefulWidget {
  const _ChatHeader({
    this.onOpenSidebar,
    required this.compact,
    this.onStartCall,
    this.onStartGroupCall,
  });
  final VoidCallback? onOpenSidebar;
  final bool compact;
  final OnStartCall? onStartCall;
  final OnStartGroupCall? onStartGroupCall;

  @override
  ConsumerState<_ChatHeader> createState() => _ChatHeaderState();
}

class _ChatHeaderState extends ConsumerState<_ChatHeader> {
  // A simple back/forward navigation history (channels.js `navigationHistory` /
  // `navigationIndex`). Each entry is a [ChatView]. Forward is disabled when at
  // the tip; back is disabled at the start (like the PWA).
  final List<ChatView> _history = [];
  int _index = -1;
  bool _navigating = false;

  bool get _canBack => _index > 0;
  bool get _canForward => _index >= 0 && _index < _history.length - 1;

  void _recordView(ChatView view) {
    if (_navigating) return;
    if (_index >= 0 && _history[_index] == view) return;
    // Truncate any forward entries, then push.
    if (_index < _history.length - 1) {
      _history.removeRange(_index + 1, _history.length);
    }
    _history.add(view);
    if (_history.length > 50) _history.removeAt(0);
    _index = _history.length - 1;
  }

  void _back() {
    if (!_canBack) return;
    _index--;
    _go(_history[_index]);
  }

  void _forward() {
    if (!_canForward) return;
    _index++;
    _go(_history[_index]);
  }

  void _go(ChatView view) {
    _navigating = true;
    ref.read(appStateProvider.notifier).switchView(view);
    // Reset the flag after the frame so didChangeDependencies doesn't re-record.
    WidgetsBinding.instance.addPostFrameCallback((_) => _navigating = false);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final compact = widget.compact;
    final settings = ref.watch(settingsProvider);
    final app = ref.watch(appStateProvider);
    final view = ref.watch(currentViewProvider);
    _recordView(view);

    final title = _titleFor(app, view);
    final meta = _metaFor(app, view);
    final metaText = meta.text;
    final titleSize = settings.textSize + 3.0;

    final isChannel = view.kind == ViewKind.channel;
    final channelKey = isChannel ? view.id.toLowerCase() : '';
    final isPinned = isChannel && app.pinnedChannels.contains(channelKey);
    final isDefault = channelKey == kDefaultChannel;

    // `.chat-header`: padding 16/24 (mobile 15/10, top 12); bg --glass-bg,
    // bottom hairline.
    return Container(
      decoration: BoxDecoration(
        color: c.glassBg,
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      padding: compact
          ? const EdgeInsets.fromLTRB(10, 12, 10, 15)
          : const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: SafeArea(
        bottom: false,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // `.channel-header-controls`: the back/forward + favorite/share
              // (channel) or audio/video (PM/group) cluster, LEFT of the title
              // at ALL widths (no breakpoint hides it; the PWA shows it on
              // mobile too — gap, MISSING). 28×28 desktop / 24×24 compact.
              _channelControls(
                view: view,
                isChannel: isChannel,
                channelKey: channelKey,
                isPinned: isPinned,
                isDefault: isDefault,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // `.channel-title` (#currentChannel): a plain `#name` for a
                    // channel; `.pm-header-row` (26px avatar + status dot + name)
                    // for a PM; `.group-header-row` (group glyph + stacked member
                    // avatars + name) for a group.
                    _titleLine(c, app, view, title, titleSize),
                    if (metaText.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Lock glyph prefix for E2E PM/group meta (PWA
                          // `lockSvg`, 12px). Channel meta has no glyph.
                          if (meta.icon != null) ...[
                            Icon(meta.icon, size: 12, color: c.textDim),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: Text(
                              metaText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: c.textDim, fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              if (compact)
                _mobileActions()
              else
                // `.header-actions`: bounded so the text pills can wrap
                // (`flex-wrap:wrap`) rather than overflow on narrow desktops.
                Flexible(child: _headerActionPills()),
            ],
          ),
        ),
      ),
    );
  }

  /// The `.channel-title` content (`#currentChannel`). Channel → bare `#name`.
  /// PM → `.pm-header-row`: a 26px avatar with a status dot + the nym. Group →
  /// `.group-header-row`: the group glyph + up to four overlapping 18px member
  /// avatars (or the custom group avatar) + the name. The title text itself is
  /// primary / weight-700 / +3px in all three.
  Widget _titleLine(
    NymColors c,
    AppState app,
    ChatView view,
    String title,
    double titleSize,
  ) {
    final titleStyle = TextStyle(
      color: c.primary,
      fontSize: titleSize,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
    );
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: titleStyle,
    );

    switch (view.kind) {
      case ViewKind.channel:
        return titleText;

      case ViewKind.pm:
        final user = app.users[view.id];
        final status = user?.effectiveStatus() ?? UserStatus.offline;
        // `.pm-header-avatar`: 26px round, margin-right 10, with a 7px status dot
        // (bottom-right -2) ringed by the bg. Hidden status drops the dot.
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                NymAvatar(
                  seed: view.id,
                  size: 26,
                  imageUrl: user?.profile?.picture,
                ),
                if (status != UserStatus.hidden)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: statusColor(status),
                        shape: BoxShape.circle,
                        border: Border.all(color: c.bg, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 10),
            Flexible(child: titleText),
          ],
        );

      case ViewKind.group:
        final g = app.groups.firstWhere(
          (g) => g.id == view.id,
          orElse: () => app.groups.isNotEmpty
              ? app.groups.first
              : throw StateError('no group'),
        );
        final customAvatar = g.avatar;
        final hasCustom = customAvatar != null && customAvatar.isNotEmpty;
        final others =
            g.members.where((pk) => pk != app.selfPubkey).take(4).toList();

        if (hasCustom) {
          // `.group-header-custom-wrap`: a 26px round custom avatar, margin-right
          // 8 (mirrors the PM avatar slot).
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              NymAvatar(seed: g.id, size: 26, imageUrl: customAvatar),
              const SizedBox(width: 8),
              Flexible(child: titleText),
            ],
          );
        }

        // `.group-header-icon` (18px glyph) + stacked 18px `.group-header-avatar`s
        // (overlap −4, 1px bg ring) + name. The PWA clips this row
        // (`.group-header-row { overflow: hidden }`); to avoid a RenderFlex
        // overflow on a very narrow header we instead drop trailing avatars that
        // wouldn't fit, then let the name ellipsize in the remainder.
        return LayoutBuilder(
          builder: (context, constraints) {
            const double iconW = 18 + 5; // glyph + its 5px gap
            const double avatarStep = 14; // 18px avatar minus the 4px overlap
            // Reserve room for the glyph + a minimum name width; fit as many
            // avatars as the rest allows (cap 4).
            final avail = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 9999.0;
            final budget = avail - iconW - 40; // 40 ≈ minimum name slot
            var fit = others.length;
            if (budget < fit * avatarStep) {
              fit = (budget / avatarStep).floor().clamp(0, others.length);
            }
            final shown = others.take(fit).toList();

            final prefix = <Widget>[
              Icon(Icons.groups, size: 18, color: c.primary),
              const SizedBox(width: 5),
            ];
            for (var i = 0; i < shown.length; i++) {
              prefix.add(Transform.translate(
                offset: Offset(i == 0 ? 0 : -4.0 * i, 0),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: c.bg, width: 1),
                  ),
                  child: NymAvatar(
                    seed: shown[i],
                    size: 18,
                    imageUrl: app.users[shown[i]]?.profile?.picture,
                  ),
                ),
              ));
            }
            // `.nm-grp-ml8`: 8px gap before the name when avatars are shown
            // (offset by the cumulative overlap so the name doesn't drift right).
            if (shown.isNotEmpty) {
              prefix.add(SizedBox(
                  width: (8 - 4.0 * (shown.length - 1)).clamp(0.0, 8.0)));
            }
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...prefix,
                Flexible(child: titleText),
              ],
            );
          },
        );
    }
  }

  /// `.mobile-header-actions`: the `.icon-btn`-class notif + hamburger toggles,
  /// gap 8, margin-left 12 (gap F14). The notif toggle carries the unread badge.
  Widget _mobileActions() {
    final unread =
        ref.watch(notificationHistoryProvider.select((s) => s.unread));
    final settings = ref.watch(settingsProvider);
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // `#p2pTransfersModal` trigger — present only while transfers/seeds
          // exist (`openP2PTransfersModal`, p2p.js:732).
          _transfersMobileToggle(),
          _MobileToggle(
            icon: settings.notificationsEnabled
                ? Icons.notifications_none
                : Icons.notifications_off_outlined,
            tooltip: 'Notifications',
            badge: unread,
            onTap: _openNotifications,
          ),
          const SizedBox(width: 8),
          _MobileToggle(
            icon: Icons.menu,
            tooltip: 'Menu',
            onTap: widget.onOpenSidebar,
          ),
        ],
      ),
    );
  }

  /// `.channel-header-controls` (LEFT of the title, all widths): a 2-column grid
  /// (`grid-template-columns:auto auto; row-gap:12; column-gap:2`) into which
  /// `.channel-nav-buttons` (back/forward) and `.channel-action-buttons` flow
  /// (both `display:contents`). The action buttons are **favorite + share** in a
  /// channel; **audio + video** in a PM/group (the PWA `calls.js` keeps the call
  /// buttons hidden unless `inPMMode && (currentPM||currentGroup)` — they are
  /// `nm-call-hidden` in channel view). No discover/new-PM/poll buttons live
  /// here — those are sidebar/composer actions in the PWA.
  Widget _channelControls({
    required ChatView view,
    required bool isChannel,
    required String channelKey,
    required bool isPinned,
    required bool isDefault,
  }) {
    final controller = ref.read(nostrControllerProvider);
    final isCall = view.kind == ViewKind.pm || view.kind == ViewKind.group;

    final buttons = <Widget>[
      _NavBtn(
        icon: Icons.chevron_left,
        tooltip: 'Go back',
        onTap: _canBack ? _back : null,
        disabled: !_canBack,
      ),
      _NavBtn(
        icon: Icons.chevron_right,
        tooltip: 'Go forward',
        onTap: _canForward ? _forward : null,
        disabled: !_canForward,
      ),
      if (isChannel) ...[
        _NavBtn(
          icon: isPinned ? Icons.star : Icons.star_border,
          tooltip: isDefault
              ? '#nymchat is always favorited'
              : (isPinned ? 'Unfavorite channel' : 'Favorite channel'),
          active: isPinned,
          disabled: isDefault,
          onTap: isDefault ? null : () => controller.togglePin(channelKey),
        ),
        _NavBtn(
          key: TutorialTargets.keyFor(TutorialTarget.shareButton),
          icon: Icons.ios_share,
          tooltip: 'Share channel URL',
          onTap: () => ShareChannelModal.open(context, channelKey),
        ),
      ] else if (isCall) ...[
        // PM/group only: audio + video (mirrors `_refreshCallButtons`).
        _NavBtn(
          icon: Icons.call_outlined,
          tooltip: 'Start audio call',
          onTap: () => _startCall(view, video: false),
        ),
        _NavBtn(
          icon: Icons.videocam_outlined,
          tooltip: 'Start video call',
          onTap: () => _startCall(view, video: true),
        ),
      ],
    ];

    // 2-column grid: each run holds up to two buttons (column-gap 2); runs stack
    // with a 12px row-gap (`.channel-header-controls` grid). Pairing the buttons
    // into per-run Rows keeps the 2-wide wrap regardless of available width.
    return Wrap(
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < buttons.length; i += 2)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              buttons[i],
              if (i + 1 < buttons.length) ...[
                const SizedBox(width: 2),
                buttons[i + 1],
              ],
            ],
          ),
      ],
    );
  }

  /// `.header-actions` (desktop, RIGHT): the text-pill group (Notifications +
  /// badge / Flair / Settings / About / Logout), wrapped (`flex-wrap:wrap`) —
  /// tutorial `mainMenu` target.
  Widget _headerActionPills() {
    final unread =
        ref.watch(notificationHistoryProvider.select((s) => s.unread));
    return KeyedSubtree(
      key: TutorialTargets.keyFor(TutorialTarget.mainMenu),
      child: Wrap(
        spacing: 5,
        runSpacing: 5,
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // `#p2pTransfersModal` trigger (`openP2PTransfersModal`, p2p.js:732):
          // only present while there are active transfers or seeds; the pill
          // appears/disappears live as the service notifies.
          _transfersPill(),
          _HeaderPill(
            icon: Icons.notifications_none,
            label: 'Notifications',
            badge: unread,
            onTap: _openNotifications,
          ),
          _HeaderPill(
            icon: Icons.star_border,
            label: 'Flair',
            onTap: () => ShopModal.open(context),
          ),
          _HeaderPill(
            icon: Icons.settings_outlined,
            label: 'Settings',
            onTap: () => SettingsScreen.open(context),
          ),
          _HeaderPill(
            icon: Icons.info_outline,
            label: 'About',
            onTap: () => AboutScreen.open(context),
          ),
          _HeaderPill(
            icon: Icons.logout,
            label: 'Logout',
            // `data-action="signOut"` → confirm, then real sign-out (app.js
            // `signOut`, 6740-6741). `signOut()` clears the identity and bumps
            // the boot generation so the app remounts the first-run gate.
            onTap: _confirmSignOut,
          ),
        ],
      ),
    );
  }

  /// Confirms then signs out (app.js `signOut`: `showAppConfirm('Sign out and
  /// disconnect from Nymchat?', { okLabel: 'Sign out', danger: true })`).
  Future<void> _confirmSignOut() async {
    final ok = await showAppConfirm(
      context,
      'Sign out and disconnect from Nymchat?',
      okLabel: 'Sign out',
      danger: true,
    );
    if (!ok) return;
    await ref.read(nostrControllerProvider).signOut();
  }

  /// Opens the notifications modal and marks history viewed. The modal UI is
  /// owned by the calls/notifications slice; until it lands this clears the
  /// unread badge and surfaces a lightweight summary so the bell is functional.
  void _openNotifications() {
    showNotificationsPanel(context);
    ref.read(notificationHistoryProvider.notifier).markAllViewed();
  }

  /// Opens `#p2pTransfersModal` (`openP2PTransfersModal`, p2p.js:732), driven
  /// live by [P2PService]. The modal `AnimatedBuilder`s on the service, so it
  /// auto-refreshes as transfers progress / stop / cancel.
  void _openTransfers() {
    P2PTransfersModal.open(context, ref.read(p2pServiceProvider));
  }

  /// The desktop `.header-actions` "Transfers" pill, present only while there
  /// are active transfers or seeds (`service.transfers.isNotEmpty ||
  /// service.seeding.isNotEmpty`). Listens to the service so it appears /
  /// disappears as the transfer/seed set changes.
  Widget _transfersPill() {
    final service = ref.watch(p2pServiceProvider);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        if (service.transfers.isEmpty && service.seeding.isEmpty) {
          return const SizedBox.shrink();
        }
        return _HeaderPill(
          icon: Icons.swap_vert,
          label: 'Transfers',
          onTap: _openTransfers,
        );
      },
    );
  }

  /// The mobile `.mobile-header-actions` transfers toggle, present only while
  /// there are active transfers or seeds. A trailing 8px gap keeps the row gap
  /// consistent when shown.
  Widget _transfersMobileToggle() {
    final service = ref.watch(p2pServiceProvider);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        if (service.transfers.isEmpty && service.seeding.isEmpty) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: _MobileToggle(
            icon: Icons.swap_vert,
            tooltip: 'Transfers',
            onTap: _openTransfers,
          ),
        );
      },
    );
  }

  void _startCall(ChatView view, {required bool video}) {
    switch (view.kind) {
      case ViewKind.pm:
        widget.onStartCall?.call(view.id, video: video);
      case ViewKind.group:
        widget.onStartGroupCall?.call(view.id, video: video);
      case ViewKind.channel:
        // Channel calls aren't a thing in the PWA; ignore.
        break;
    }
  }

  String _titleFor(AppState app, ChatView view) {
    switch (view.kind) {
      case ViewKind.channel:
        final ch = app.channels.firstWhere(
          (c) => c.key == view.id,
          orElse: () => ChannelEntry(channel: view.id),
        );
        return '#${ch.isGeohash ? ch.geohash : ch.channel}';
      case ViewKind.pm:
        return app.users[view.id]?.nym ?? 'PM';
      case ViewKind.group:
        final g = app.groups.firstWhere(
          (g) => g.id == view.id,
          orElse: () => app.groups.first,
        );
        return g.name;
    }
  }

  /// The `#channelMeta` line (11px text-dim). Channel: the live online-nym count
  /// `"<n> online nyms"` (users.js `_renderUserList`, 1451). PM: lock glyph +
  /// `"End-to-end encrypted private message"` (pms.js:2940). Group: lock glyph +
  /// `"End-to-end encrypted group chat"` (groups.js:3264).
  ({IconData? icon, String text}) _metaFor(AppState app, ChatView view) {
    switch (view.kind) {
      case ViewKind.channel:
        // `channelUserCount`: online/away nyms, excluding self (matches the
        // sidebar "Nyms (N online)" active set).
        final count = app.users.values.where((u) {
          if (u.pubkey == app.selfPubkey) return false;
          final st = u.effectiveStatus();
          return st == UserStatus.online || st == UserStatus.away;
        }).length;
        return (icon: null, text: '${_abbreviateCount(count)} online nyms');
      case ViewKind.pm:
        return (
          icon: Icons.lock_outline,
          text: 'End-to-end encrypted private message',
        );
      case ViewKind.group:
        return (
          icon: Icons.lock_outline,
          text: 'End-to-end encrypted group chat',
        );
    }
  }

  /// Mirrors the PWA `abbreviateNumber` (users.js:2069): <1000 raw; <1M → "N.Nk"
  /// (1 decimal under 10k, 0 above); else "N.NM".
  String _abbreviateCount(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k';
    }
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }
}

/// `.channel-nav-btn`: 28×28 desktop / 24×24 compact, radius 4, textDim →
/// primary; hover paints a white@0.08 fill (gap F18). Disabled buttons render at
/// 0.3 opacity (PWA `.channel-nav-btn:disabled`).
class _NavBtn extends StatefulWidget {
  const _NavBtn({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.active = false,
    this.disabled = false,
  });
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool active;
  final bool disabled;

  @override
  State<_NavBtn> createState() => _NavBtnState();
}

class _NavBtnState extends State<_NavBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Compact (mobile) shrinks nav buttons to 24×24 (`styles-themes-responsive
    // .css:316-319`); desktop is 28×28.
    final compact =
        MediaQuery.of(context).size.width <= NymDimens.tabletBreakpoint;
    final size = compact ? 24.0 : 28.0;

    final color = widget.disabled
        ? c.textDim.withValues(alpha: 0.3)
        : ((widget.active || _hover) ? c.primary : c.textDim);

    final btn = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: widget.disabled ? null : (widget.onTap ?? () {}),
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // `.channel-nav-btn:hover { background: rgba(255,255,255,0.08) }`.
            color: (_hover && !widget.disabled)
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: const BorderRadius.all(Radius.circular(4)),
          ),
          child: Icon(widget.icon, size: 18, color: color),
        ),
      ),
    );
    return widget.tooltip != null
        ? Tooltip(message: widget.tooltip!, child: btn)
        : btn;
  }
}

/// Resolved `.icon-btn` fill/border/foreground for the current mode + hover.
@immutable
class _IconBtnStyle {
  const _IconBtnStyle({
    required this.fill,
    required this.border,
    required this.foreground,
  });
  final Color fill;
  final Color border;
  final Color foreground;
}

/// The shared `.icon-btn` token set (`styles-shell.css:912-935` +
/// `styles-themes-responsive.css:595-605`). Used by both `_HeaderPill` and
/// `_MobileToggle`.
///
/// - Dark base: fill white@0.05, border `--glass-border`, fg `--text`.
/// - Dark hover: fill `--primary`@0.12, border `--primary`@0.3, fg `--primary`.
/// - Light base: fill black@0.03, border black@0.1, fg `--primary`.
/// - Light hover: fill black@0.06, border `--primary`, fg `--primary`.
_IconBtnStyle _iconBtnStyle(NymColors c, bool hover) {
  if (c.isLight) {
    return _IconBtnStyle(
      fill: hover
          ? Colors.black.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.03),
      border: hover ? c.primary : Colors.black.withValues(alpha: 0.1),
      foreground: c.primary,
    );
  }
  return _IconBtnStyle(
    fill: hover ? c.primaryA(0.12) : Colors.white.withValues(alpha: 0.05),
    border: hover ? c.primaryA(0.30) : c.glassBorder,
    foreground: hover ? c.primary : c.text,
  );
}

/// `.icon-btn` text pill in `.header-actions` (gap F6): white@0.05 fill, 1px
/// glass border, radius xs, padding 7/14, 12px w500 uppercase ls 0.8, icon 14 +
/// 5 gap. Hover → primary@12 fill / primary text / primary@30 border / glow.
/// Light mode mirrors `body.light-mode .icon-btn` (black@0.03 fill / black@0.1
/// border / `--primary` text). An optional unread [badge] overlays the top-right.
class _HeaderPill extends StatefulWidget {
  const _HeaderPill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge = 0,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final int badge;

  @override
  State<_HeaderPill> createState() => _HeaderPillState();
}

class _HeaderPillState extends State<_HeaderPill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final style = _iconBtnStyle(c, _hover);
    final fg = style.foreground;
    final pill = AnimatedContainer(
      duration: NymMotion.transition,
      curve: NymMotion.curve,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: style.fill,
        borderRadius: NymRadius.rxs,
        border: Border.all(color: style.border),
        boxShadow: _hover
            ? [BoxShadow(color: c.primaryA(0.10), blurRadius: 15)]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(widget.icon, size: 14, color: fg),
          const SizedBox(width: 5),
          Text(
            widget.label.toUpperCase(),
            style: TextStyle(
              color: fg,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: widget.label,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: NymRadius.rxs,
          child: widget.badge > 0
              ? _withBadge(pill, widget.badge)
              : pill,
        ),
      ),
    );
  }
}

/// `.mobile-menu-toggle` / `.mobile-notif-toggle` in `.mobile-header-actions`
/// (gap F14): these are plain `.icon-btn`-class buttons — bg white@0.05 (dark) /
/// black@0.03 (light), 1px glass/black@0.1 border, **radius xs (8)**, color
/// `--text`/`--primary`, padding `7px 14px`, icon 20. (NOT a fixed 40×40
/// square, NOT rgba(20,20,35,0.8), NOT radius-sm — those were inventions.)
/// Optional unread [badge] overlay.
class _MobileToggle extends StatelessWidget {
  const _MobileToggle({
    required this.icon,
    this.tooltip,
    this.onTap,
    this.badge = 0,
  });
  final IconData icon;
  final String? tooltip;
  final VoidCallback? onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final style = _iconBtnStyle(c, false);
    final box = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: style.fill,
        borderRadius: NymRadius.rxs,
        border: Border.all(color: style.border),
      ),
      child: Icon(icon, size: 20, color: style.foreground),
    );
    final child = InkWell(
      onTap: onTap,
      borderRadius: NymRadius.rxs,
      child: badge > 0 ? _withBadge(box, badge) : box,
    );
    return tooltip != null ? Tooltip(message: tooltip!, child: child) : child;
  }
}

/// `.notification-count-badge`: absolute top/right −4px, danger bg, white 10px
/// w700, min 16×16 pill. Wraps [child] in a clip-free stack with the badge.
Widget _withBadge(Widget child, int count) {
  return Stack(
    clipBehavior: Clip.none,
    children: [
      child,
      Positioned(
        top: -4,
        right: -4,
        child: _CountBadge(count: count),
      ),
    ],
  );
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.danger,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}
