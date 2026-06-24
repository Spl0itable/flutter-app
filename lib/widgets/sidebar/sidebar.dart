import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/globe/geohash_explorer.dart';
import '../../features/identity/nick_edit_modal.dart';
import '../../features/identity/panic_overlay.dart';
import '../../features/identity/panic_wipe.dart';
import '../../features/onboarding/tutorial_overlay.dart';
import '../../features/pms/new_pm_modal.dart';
import '../../features/settings/about_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/shop/shop_modal.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../common/nym_avatar.dart';
import 'channel_list_item.dart';
import 'pm_list_item.dart';
import 'user_list_item.dart';

/// The three reorderable sidebar sections (`data-section` ids in the PWA).
enum _SectionId { channels, pms, nyms }

extension _SectionIdName on _SectionId {
  /// The persisted id, matching the PWA `data-section` values
  /// (`channels` / `pms` / `nyms`).
  String get id => switch (this) {
        _SectionId.channels => 'channels',
        _SectionId.pms => 'pms',
        _SectionId.nyms => 'nyms',
      };

  static _SectionId? fromId(String id) {
    for (final s in _SectionId.values) {
      if (s.id == id) return s;
    }
    return null;
  }
}

/// The left sidebar: identity header + three collapsible nav sections
/// (PUBLIC CHANNELS, PRIVATE MESSAGES, ONLINE NYMS). Width 290 desktop / 300 in
/// the mobile drawer (caller sizes it). bg `--bg-secondary`, right hairline
/// border. (docs/specs/02 §1.1, §5.3)
///
/// The whole column is a single scroll container (`.sidebar { overflow-y:auto }`,
/// gap F7) — the identity header + action row scroll away with the lists.
/// `.sidebar-actions` only mounts on compact (<=1024) layouts (gap F3); on the
/// fixed desktop sidebar those actions live in the header instead.
class Sidebar extends ConsumerStatefulWidget {
  const Sidebar({super.key, this.onItemSelected, this.compact = false});

  /// Called after a channel/PM is tapped (so the mobile drawer can close).
  final VoidCallback? onItemSelected;

  /// Compact (mobile/tablet, <=1024) layout: shows the `.sidebar-actions` row
  /// (Flair/Settings/About/Logout). On wide layouts those live in the header.
  final bool compact;

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  // Collapse state (persisted to `nym_sidebar_section_collapsed`, gap F11).
  final Set<_SectionId> _collapsed = {};

  // Section order (persisted to `nym_sidebar_section_order`, gap F12).
  late List<_SectionId> _order;

  // Reorder mode (500ms long-press on a title toggles it, gap F12).
  bool _reorderMode = false;

  bool _channelSearch = false;
  bool _pmSearch = false;
  bool _nymSearch = false;

  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _order = List.of(_SectionId.values);
    // Restore persisted collapse + order on first build (the KV store is a
    // provider, so defer to didChangeDependencies where ref.read is valid).
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final kv = ref.read(keyValueStoreProvider);

    // Collapse list.
    final collapsedRaw = kv.getString(StorageKeys.sidebarSectionCollapsed);
    for (final id in _decodeIds(collapsedRaw)) {
      final s = _SectionIdName.fromId(id);
      if (s != null) _collapsed.add(s);
    }

    // Order list — keep any missing sections appended in their default order.
    final orderRaw = kv.getString(StorageKeys.sidebarSectionOrder);
    final stored = _decodeIds(orderRaw)
        .map(_SectionIdName.fromId)
        .whereType<_SectionId>()
        .toList();
    if (stored.isNotEmpty) {
      final next = <_SectionId>[];
      for (final s in stored) {
        if (!next.contains(s)) next.add(s);
      }
      for (final s in _SectionId.values) {
        if (!next.contains(s)) next.add(s);
      }
      _order = next;
    }
  }

  List<String> _decodeIds(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {
      // Fall back to a bare comma list (defensive).
      return raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    }
    return const [];
  }

  void _persistCollapsed() {
    ref.read(keyValueStoreProvider).setString(
          StorageKeys.sidebarSectionCollapsed,
          jsonEncode(_collapsed.map((s) => s.id).toList()),
        );
  }

  void _persistOrder() {
    ref.read(keyValueStoreProvider).setString(
          StorageKeys.sidebarSectionOrder,
          jsonEncode(_order.map((s) => s.id).toList()),
        );
  }

  void _toggleCollapse(_SectionId s) {
    setState(() {
      if (!_collapsed.remove(s)) _collapsed.add(s);
    });
    _persistCollapsed();
  }

  void _toggleReorderMode() {
    HapticFeedback.selectionClick();
    setState(() => _reorderMode = !_reorderMode);
  }

  void _moveSection(_SectionId s, int delta) {
    final i = _order.indexOf(s);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= _order.length) return;
    setState(() {
      _order
        ..removeAt(i)
        ..insert(j, s);
    });
    _persistOrder();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final settings = ref.watch(settingsProvider);
    final textSize = settings.textSize.toDouble();

    final app = ref.watch(appStateProvider);
    final view = ref.watch(currentViewProvider);
    final channels = ref.watch(channelsProvider);
    final pms = ref.watch(pmListProvider);
    final users = ref.watch(usersProvider);
    final unread = ref.watch(unreadCountsProvider);

    final notifier = ref.read(appStateProvider.notifier);

    void select(ChatView v) {
      notifier.switchView(v);
      widget.onItemSelected?.call();
    }

    // Online nyms exclude self and offline-hidden.
    final onlineUsers = users.values
        .where((u) => u.pubkey != app.selfPubkey)
        .toList()
      ..sort((a, b) {
        int rank(User u) {
          switch (u.effectiveStatus()) {
            case UserStatus.online:
              return 0;
            case UserStatus.away:
              return 1;
            default:
              return 2;
          }
        }

        final r = rank(a) - rank(b);
        return r != 0 ? r : a.nym.compareTo(b.nym);
      });

    // Build the three sections, then emit them in the persisted order.
    Widget sectionFor(_SectionId s) {
      switch (s) {
        case _SectionId.channels:
          return _NavSection(
            key: const ValueKey('section-channels'),
            sectionKey: TutorialTargets.keyFor(TutorialTarget.channelList),
            title: 'Public Channels',
            open: !_collapsed.contains(s),
            searching: _channelSearch,
            reorderMode: _reorderMode,
            canMoveUp: _order.indexOf(s) > 0,
            canMoveDown: _order.indexOf(s) < _order.length - 1,
            onMoveUp: () => _moveSection(s, -1),
            onMoveDown: () => _moveSection(s, 1),
            onToggleOpen: () => _toggleCollapse(s),
            onToggleSearch: () =>
                setState(() => _channelSearch = !_channelSearch),
            onLongPressTitle: _toggleReorderMode,
            // `.discover-icon` (globe) → geohash explorer (gap F15).
            leadingIcon: _MiniIcon(
              key: TutorialTargets.keyFor(TutorialTarget.discoverIcon),
              icon: Icons.public,
              tooltip: 'Explore geohash channels',
              onTap: _openDiscover,
            ),
            searchHint: 'Search channels…',
            children: [
              for (final ch in channels)
                ChannelListItem(
                  entry: ch,
                  active: view.kind == ViewKind.channel && view.id == ch.key,
                  unread: unread[ch.key] ?? 0,
                  textSize: textSize,
                  onTap: () => select(ChatView.channel(ch.key)),
                ),
            ],
          );
        case _SectionId.pms:
          return _NavSection(
            key: const ValueKey('section-pms'),
            sectionKey: TutorialTargets.keyFor(TutorialTarget.pmList),
            title: 'Private Messages',
            open: !_collapsed.contains(s),
            searching: _pmSearch,
            reorderMode: _reorderMode,
            canMoveUp: _order.indexOf(s) > 0,
            canMoveDown: _order.indexOf(s) < _order.length - 1,
            onMoveUp: () => _moveSection(s, -1),
            onMoveDown: () => _moveSection(s, 1),
            onToggleOpen: () => _toggleCollapse(s),
            onToggleSearch: () => setState(() => _pmSearch = !_pmSearch),
            onLongPressTitle: _toggleReorderMode,
            // `.new-pm-btn` (plus) → new PM / group (gap F15).
            leadingIcon: _MiniIcon(
              icon: Icons.add,
              tooltip: 'New message',
              onTap: () {
                widget.onItemSelected?.call();
                NewPmModal.open(context);
              },
            ),
            searchHint: 'Search messages…',
            children: [
              for (final pm in pms)
                PMListItem(
                  nym: pm.nym,
                  pubkey: pm.pubkey,
                  active:
                      view.kind == ViewKind.pm && view.id == pm.pubkey,
                  status: users[pm.pubkey]?.effectiveStatus() ??
                      UserStatus.offline,
                  unread: unread[pm.pubkey] ?? 0,
                  textSize: textSize,
                  onTap: () => select(ChatView.pm(pm.pubkey)),
                ),
            ],
          );
        case _SectionId.nyms:
          // `.user-list` (gap F17): 10px padding, NO bottom divider.
          return _NavSection(
            key: const ValueKey('section-nyms'),
            sectionKey: TutorialTargets.keyFor(TutorialTarget.userList),
            title: 'Online Nyms',
            open: !_collapsed.contains(s),
            searching: _nymSearch,
            reorderMode: _reorderMode,
            isUserList: true,
            canMoveUp: _order.indexOf(s) > 0,
            canMoveDown: _order.indexOf(s) < _order.length - 1,
            onMoveUp: () => _moveSection(s, -1),
            onMoveDown: () => _moveSection(s, 1),
            onToggleOpen: () => _toggleCollapse(s),
            onToggleSearch: () => setState(() => _nymSearch = !_nymSearch),
            onLongPressTitle: _toggleReorderMode,
            searchHint: 'Search nyms…',
            children: [
              for (final u in onlineUsers)
                UserListItem(
                  user: u,
                  textSize: textSize,
                  onTap: () => select(ChatView.pm(u.pubkey)),
                ),
            ],
          );
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: c.bgSecondary,
        border: Border(right: BorderSide(color: c.glassBorder)),
      ),
      child: SafeArea(
        right: false,
        // `.sidebar { overflow-y:auto }`: the whole column is one scroll
        // container, header + actions + sections (gap F7).
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _header(context, app.selfNym),
            if (widget.compact)
              _SidebarActions(onItemSelected: widget.onItemSelected),
            for (final s in _order) sectionFor(s),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _openDiscover() async {
    widget.onItemSelected?.call();
    final gh = await Navigator.of(context).push<String>(
      GeohashExplorer.route(),
    );
    if (gh == null || gh.isEmpty || !mounted) return;
    ref.read(nostrControllerProvider).switchChannel(gh, geohash: gh);
  }

  /// `.sidebar-header` with `.nym-display` (avatar 32 + nym + status/connection).
  ///
  /// Panic gesture (`bindNymPanicGesture`, docs/specs/04 §10.1): a normal tap
  /// opens the nick editor; a 2000 ms press-and-hold triggers the emergency
  /// wipe. The post-hold tap is swallowed so the editor doesn't open over the
  /// scramble overlay.
  Widget _header(BuildContext context, String nym) {
    final c = context.nym;
    // `.sidebar-header`: padding 20/16, bottom hairline, bg black@0.15.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.15),
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: _PanicHoldDetector(
        onTap: () => NickEditModal.open(context),
        onHold: () => _triggerPanic(context),
        // `.nym-display`: padding 10/14, bg white@0.04, glass border, radius-sm.
        child: Container(
          key: TutorialTargets.keyFor(TutorialTarget.nymDisplay),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            border: Border.all(color: c.glassBorder),
            borderRadius: NymRadius.rsm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // `.nym-label`: 10px uppercase ls 1.5 textDim weight 500. Copy is
              // "Your Nym (click to edit)" in the PWA (gap F16).
              Text(
                'YOUR NYM (CLICK TO EDIT)',
                style: TextStyle(
                  color: c.textDim,
                  fontSize: 10,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              // `.nym-identity`: avatar 32 (`.avatar.nm-h-14`) + nym, gap 10.
              Row(
                children: [
                  NymAvatar(seed: nym, size: 32),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      nym,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.secondary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // `.status-indicator`: 11px textDim, gap 5, 8px dot.
              Row(
                key: TutorialTargets.keyFor(TutorialTarget.statusIndicator),
                children: [
                  const StatusDot(status: UserStatus.online, size: 8),
                  const SizedBox(width: 5),
                  Text(
                    'connected',
                    style: TextStyle(color: c.textDim, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _triggerPanic(BuildContext context) {
    PanicOverlay.show(
      context,
      wipe: PanicWipe.production(),
      onComplete: () {
        // Pop the overlay; a real app restart-to-first-run would re-bootstrap
        // the identity here.
        final nav = Navigator.of(context, rootNavigator: true);
        if (nav.canPop()) nav.pop();
      },
    );
  }
}

/// Wraps the identity header to implement the panic gesture: a tap fires
/// [onTap], while a press held for [holdMs] fires [onHold] (and suppresses the
/// following tap). Bound for pointer down/up/cancel, matching the PWA's
/// mouse/touch handlers (`bindNymPanicGesture`).
class _PanicHoldDetector extends StatefulWidget {
  const _PanicHoldDetector({
    required this.child,
    required this.onTap,
    required this.onHold,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback onHold;

  /// Press-and-hold threshold (`_PANIC_HOLD_MS`).
  static const int holdMs = 2000;

  @override
  State<_PanicHoldDetector> createState() => _PanicHoldDetectorState();
}

class _PanicHoldDetectorState extends State<_PanicHoldDetector> {
  Timer? _timer;
  bool _fired = false;

  void _start(PointerDownEvent _) {
    _fired = false;
    _timer?.cancel();
    _timer = Timer(
      const Duration(milliseconds: _PanicHoldDetector.holdMs),
      () {
        _fired = true;
        widget.onHold();
      },
    );
  }

  void _cancel([PointerEvent? _]) {
    _timer?.cancel();
    _timer = null;
  }

  void _up(PointerUpEvent _) {
    _cancel();
    if (!_fired) widget.onTap();
    _fired = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _start,
      onPointerUp: _up,
      onPointerCancel: _cancel,
      child: widget.child,
    );
  }
}

/// `.sidebar-actions`: the Flair / Settings / About / Logout button row that
/// sits under the identity header (index.html:440). Each is an `.icon-btn` with
/// an icon over a small label. Mounted only on compact layouts (gap F3); the
/// row carries the [TutorialTarget.mainMenu] key for the tour.
class _SidebarActions extends StatelessWidget {
  const _SidebarActions({this.onItemSelected});

  final VoidCallback? onItemSelected;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `.sidebar-actions`: padding 16/12, gap 6, top hairline border.
    return Container(
      key: TutorialTargets.keyFor(TutorialTarget.mainMenu),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _ActionButton(
            icon: Icons.star_border,
            label: 'Flair',
            onTap: () {
              onItemSelected?.call();
              ShopModal.open(context);
            },
          ),
          _ActionButton(
            icon: Icons.settings_outlined,
            label: 'Settings',
            onTap: () {
              onItemSelected?.call();
              SettingsScreen.open(context);
            },
          ),
          _ActionButton(
            icon: Icons.info_outline,
            label: 'About',
            onTap: () {
              onItemSelected?.call();
              AboutScreen.open(context);
            },
          ),
          _ActionButton(
            icon: Icons.logout,
            label: 'Logout',
            onTap: () {
              // TODO(verify): sign-out flow (signOut) is owned by the identity
              // subsystem.
            },
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: NymRadius.rxs,
        // `.sidebar-actions .icon-btn`: padding 6/4, gap 3, 9px label.
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Column(
            children: [
              Icon(icon, size: 16, color: c.text),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  color: c.text,
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A collapsible nav section: 10px uppercase title (letter-spacing 2,
/// textDim), an optional leading action icon (globe/plus), a search-toggle +
/// collapse chevron, optional reorder arrows, an optional search field, then
/// the list body. (docs/specs/02 §1.1, §4 nav-title)
///
/// `.nav-section` gets a bottom hairline divider (gap F21); the Online Nyms
/// section ([isUserList]) uses `.user-list` metrics: 10px padding, no divider
/// (gap F17). A 500ms long-press on the title toggles section reorder mode
/// (gap F12); the chevron alone toggles collapse (the title row no longer
/// toggles collapse, matching the PWA, gap F11).
class _NavSection extends StatelessWidget {
  const _NavSection({
    super.key,
    required this.sectionKey,
    required this.title,
    required this.open,
    required this.searching,
    required this.onToggleOpen,
    required this.onToggleSearch,
    required this.onLongPressTitle,
    required this.searchHint,
    required this.children,
    required this.reorderMode,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMoveUp,
    required this.onMoveDown,
    this.leadingIcon,
    this.isUserList = false,
  });

  /// Key attached to the section body (list area) for the tutorial spotlight.
  final Key sectionKey;
  final String title;
  final bool open;
  final bool searching;
  final VoidCallback onToggleOpen;
  final VoidCallback onToggleSearch;
  final VoidCallback onLongPressTitle;
  final String searchHint;
  final List<Widget> children;
  final bool reorderMode;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final Widget? leadingIcon;
  final bool isUserList;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `.nav-section` padding 16/12/12 + bottom divider; `.user-list` is 10px
    // padding with no divider.
    final pad = isUserList
        ? const EdgeInsets.all(10)
        : const EdgeInsets.fromLTRB(12, 16, 12, 12);
    return Container(
      padding: pad,
      decoration: isUserList
          ? null
          : BoxDecoration(
              border: Border(bottom: BorderSide(color: c.glassBorder)),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // `.nav-title`: long-press toggles reorder mode; the title text does
          // NOT toggle collapse (the chevron does).
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: onLongPressTitle,
            child: Padding(
              // `.nav-title` padding-left 8, margin-bottom 10.
              padding: const EdgeInsets.fromLTRB(8, 0, 0, 10),
              child: Row(
                children: [
                  if (reorderMode) ...[
                    _ReorderArrows(
                      canUp: canMoveUp,
                      canDown: canMoveDown,
                      onUp: onMoveUp,
                      onDown: onMoveDown,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      title.toUpperCase(),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textDim,
                        fontSize: 10,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (leadingIcon != null) ...[
                    leadingIcon!,
                    const SizedBox(width: 2),
                  ],
                  _MiniIcon(
                    icon: Icons.search,
                    active: searching,
                    tooltip: 'Search',
                    onTap: onToggleSearch,
                  ),
                  const SizedBox(width: 2),
                  // `.collapse-icon` chevron — rotates to ▾ open / ▸ collapsed.
                  _MiniIcon(
                    icon: open
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    tooltip: open ? 'Collapse section' : 'Expand section',
                    onTap: onToggleOpen,
                  ),
                ],
              ),
            ),
          ),
          if (searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 6),
              child: _SearchField(hint: searchHint),
            ),
          // The list body carries the tutorial key (`#channelList` etc.).
          KeyedSubtree(
            key: sectionKey,
            child: open
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// `.section-reorder-arrows`: up/down `.section-reorder-btn` (18×18, white@0.08
/// bg, primary hover, 0.25 disabled). Shown only in reorder mode (gap F12).
class _ReorderArrows extends StatelessWidget {
  const _ReorderArrows({
    required this.canUp,
    required this.canDown,
    required this.onUp,
    required this.onDown,
  });
  final bool canUp;
  final bool canDown;
  final VoidCallback onUp;
  final VoidCallback onDown;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ReorderBtn(icon: Icons.keyboard_arrow_up, enabled: canUp, onTap: onUp),
        const SizedBox(width: 3),
        _ReorderBtn(
          icon: Icons.keyboard_arrow_down,
          enabled: canDown,
          onTap: onDown,
        ),
      ],
    );
  }
}

class _ReorderBtn extends StatelessWidget {
  const _ReorderBtn({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Opacity(
      opacity: enabled ? 1 : 0.25,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: NymRadius.rxs,
        child: Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: NymRadius.rxs,
          ),
          child: Icon(icon, size: 14, color: c.text),
        ),
      ),
    );
  }
}

class _MiniIcon extends StatelessWidget {
  const _MiniIcon({
    super.key,
    required this.icon,
    this.active = false,
    this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final bool active;
  final String? tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final btn = InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(4)),
      child: Padding(
        // `.search-icon/.discover-icon/.collapse-icon`: 20×20 hit, 14 glyph.
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        child: Icon(
          icon,
          size: 14,
          color: active ? c.primary : c.textDim,
        ),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip!, child: btn) : btn;
  }
}

/// `.search-input`: radius rxs, padding 8/12, 12px, bg white@5.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.hint});
  final String hint;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return TextField(
      style: TextStyle(color: c.text, fontSize: 12),
      cursorColor: c.primary,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(color: c.textDim, fontSize: 12),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        prefixIcon: Icon(Icons.search, size: 16, color: c.textDim),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 34, minHeight: 0),
        border: OutlineInputBorder(
          borderRadius: NymRadius.rxs,
          borderSide: BorderSide(color: c.glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: NymRadius.rxs,
          borderSide: BorderSide(color: c.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: NymRadius.rxs,
          borderSide: BorderSide(color: c.primaryA(0.30)),
        ),
      ),
    );
  }
}
