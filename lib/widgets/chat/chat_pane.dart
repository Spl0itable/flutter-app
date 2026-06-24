import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/channels/channel_share.dart';
import '../../features/globe/geohash_explorer.dart';
import '../../features/notifications/notifications_panel.dart';
import '../../features/onboarding/tutorial_overlay.dart';
import '../../features/pms/new_pm_modal.dart';
import '../../features/polls/poll_create_modal.dart';
import '../../features/settings/about_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/shop/shop_modal.dart';
import '../../models/channel.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
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
              // Desktop leads with back/forward; the PWA mobile header leads
              // with the title and puts the hamburger + notif on the right
              // (`.mobile-header-actions`), so compact renders no leading nav.
              if (!compact) ...[
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
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.primary,
                        fontSize: titleSize,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                    ),
                    if (meta.isNotEmpty)
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.textDim, fontSize: 11),
                      ),
                  ],
                ),
              ),
              if (compact)
                _mobileActions()
              else
                // Bounded so the `.header-actions` pills can wrap
                // (`flex-wrap:wrap`) rather than overflow on narrow desktops.
                Flexible(
                  child: _desktopHeader(
                    view: view,
                    app: app,
                    isChannel: isChannel,
                    channelKey: channelKey,
                    isPinned: isPinned,
                    isDefault: isDefault,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// `.mobile-header-actions`: 40×40 bordered pill toggles (notif + hamburger),
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

  /// The desktop header: the left channel nav/action cluster (back/forward +
  /// favorite/share/poll/call as 28×28 `.channel-nav-btn`s), then the right
  /// `.header-actions` text-pill group (Notifications+badge / Flair / Settings /
  /// About / Logout), wrapped (`flex-wrap:wrap`) — gap F6/F8/F22.
  Widget _desktopHeader({
    required ChatView view,
    required AppState app,
    required bool isChannel,
    required String channelKey,
    required bool isPinned,
    required bool isDefault,
  }) {
    final controller = ref.read(nostrControllerProvider);
    final unread =
        ref.watch(notificationHistoryProvider.select((s) => s.unread));

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Left: `.channel-action-buttons` (discover/new-PM + channel actions).
        _NavBtn(
          icon: Icons.public,
          tooltip: 'Discover channels',
          onTap: _openDiscover,
        ),
        _NavBtn(
          icon: Icons.edit_outlined,
          tooltip: 'New message',
          onTap: () => NewPmModal.open(context),
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
          _NavBtn(
            icon: Icons.poll_outlined,
            tooltip: 'Create poll',
            onTap: () => PollCreateModal.open(context),
          ),
        ],
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
        const SizedBox(width: 8),
        // Right: `.header-actions` text pills (tutorial mainMenu target).
        // Flexible so the Wrap is width-bounded and wraps (`flex-wrap:wrap`).
        Flexible(
          child: KeyedSubtree(
            key: TutorialTargets.keyFor(TutorialTarget.mainMenu),
            child: Wrap(
              spacing: 5,
              runSpacing: 5,
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
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
                onTap: () {
                  // TODO(verify): sign-out (signOut) is owned by the identity
                  // subsystem.
                },
              ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Opens the notifications modal and marks history viewed. The modal UI is
  /// owned by the calls/notifications slice; until it lands this clears the
  /// unread badge and surfaces a lightweight summary so the bell is functional.
  void _openNotifications() {
    showNotificationsPanel(context);
    ref.read(notificationHistoryProvider.notifier).markAllViewed();
  }

  Future<void> _openDiscover() async {
    // CROSS-FILE (Globe): use the non-opaque modal route (scrim over the app)
    // rather than a full opaque page push.
    final gh = await Navigator.of(context).push<String>(
      GeohashExplorer.route(),
    );
    if (gh == null || gh.isEmpty || !mounted) return;
    ref.read(nostrControllerProvider).switchChannel(gh, geohash: gh);
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

  String _metaFor(AppState app, ChatView view) {
    switch (view.kind) {
      case ViewKind.channel:
        final ch = app.channels.firstWhere(
          (c) => c.key == view.id,
          orElse: () => ChannelEntry(channel: view.id),
        );
        if (ch.isGeohash) {
          final loc = decodeGeohash(ch.geohash);
          final ns = loc.lat >= 0 ? 'N' : 'S';
          final ew = loc.lng >= 0 ? 'E' : 'W';
          return '${loc.lat.abs().toStringAsFixed(2)}°$ns, '
              '${loc.lng.abs().toStringAsFixed(2)}°$ew · geohash';
        }
        return 'public channel';
      case ViewKind.pm:
        return 'private message · end-to-end encrypted';
      case ViewKind.group:
        final g = app.groups.firstWhere(
          (g) => g.id == view.id,
          orElse: () => app.groups.first,
        );
        return '${g.members.length} members';
    }
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

/// `.icon-btn` text pill in `.header-actions` (gap F6): white@0.05 fill, 1px
/// glass border, radius xs, padding 7/14, 12px w500 uppercase ls 0.8, icon 14 +
/// 5 gap. Hover → primary@12 fill / primary text / primary@30 border / glow.
/// An optional unread [badge] (Notifications) overlays the top-right.
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
    final fg = _hover ? c.primary : c.text;
    final pill = AnimatedContainer(
      duration: NymMotion.transition,
      curve: NymMotion.curve,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: _hover
            ? c.primaryA(0.12)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: NymRadius.rxs,
        border: Border.all(
          color: _hover ? c.primaryA(0.30) : c.glassBorder,
        ),
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

/// `.mobile-menu-toggle` / `.mobile-notif-toggle` (gap F14): 40×40, radius sm,
/// bg rgba(20,20,35,0.8), 1px glass border, primary color, icon 20. Optional
/// unread [badge] overlay.
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
    final box = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xCC14141F), // rgba(20,20,35,0.8)
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Icon(icon, size: 20, color: c.primary),
    );
    final child = InkWell(
      onTap: onTap,
      borderRadius: NymRadius.rsm,
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
