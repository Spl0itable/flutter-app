import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/globe/geohash_explorer.dart';
import '../../features/groups/group_logic.dart';
import '../../features/identity/nick_edit_modal.dart';
import '../../features/identity/panic_overlay.dart';
import '../../features/identity/panic_wipe.dart';
import '../../features/nymbot/bot_chat_screen.dart';
import '../../features/onboarding/tutorial_overlay.dart';
import '../../features/pms/new_pm_modal.dart';
import '../../features/relays/relay_stats_modal.dart';
import '../../features/settings/about_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/shop/shop_modal.dart';
import '../../models/channel.dart';
import '../../models/group.dart';
import '../../models/pm_conversation.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../common/app_dialog.dart';
import '../common/nym_avatar.dart';
import 'channel_list_item.dart';
import 'pm_context_menu.dart';
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

  // Live search terms per section (PWA `channelSearchTerm` / `pmSearchTerm` /
  // `userSearchTerm`), lower-cased at filter time.
  String _channelTerm = '';
  String _pmTerm = '';
  String _nymTerm = '';

  // View-more expansion per section: collapsed lists cap at 20 rows
  // (`COLLAPSED_CAP`), expanded shows all (nyms step to 500 — we expand fully).
  bool _channelExpanded = false;
  bool _pmExpanded = false;
  bool _nymExpanded = false;

  /// Collapsed row cap (`COLLAPSED_CAP` / `.list-collapsed :nth-child(n+21)`).
  static const int _collapsedCap = 20;

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
    // `sortedChannelsProvider`: nymchat → active → pinned → proximity →
    // activity/unread, with hidden/blocked channels filtered out (the PWA's
    // `sortChannelsByActivity` + `applyHiddenChannels`).
    final channels = ref.watch(sortedChannelsProvider);
    final pinned = app.pinnedChannels;
    final pms = ref.watch(pmListProvider);
    final groups = ref.watch(groupsProvider);
    final users = ref.watch(usersProvider);
    final unread = ref.watch(unreadCountsProvider);

    // Groups + 1:1 PMs share the PRIVATE MESSAGES list, ordered newest-first by
    // last-message time (PWA `insertPMInOrder` keys both off `lastMessageTime`).
    final pmEntries = <_PmEntry>[
      for (final pm in pms) _PmEntry.pm(pm),
      for (final g in groups) _PmEntry.group(g),
    ]..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));

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

    // Dynamic "Nyms (N online)" title (`activeCount`, users.js:1383): non-hidden
    // nyms that are online/away (recent), plus verified bots regardless of
    // recency.
    final controller = ref.read(nostrControllerProvider);
    final nymActiveCount = onlineUsers.where((u) {
      final st = u.effectiveStatus();
      if (st == UserStatus.hidden) return false;
      if (st == UserStatus.online || st == UserStatus.away) return true;
      return controller.isVerifiedBot(u.pubkey);
    }).length;

    // Apply the live search term + the collapse-to-20 cap, returning the capped
    // rows plus the hidden remainder count (0 when nothing is hidden). Searching
    // disables the cap (the PWA renders all matches).
    ({List<T> rows, int more}) capped<T>(
      List<T> all,
      String term,
      bool Function(T) matches,
      bool expanded,
    ) {
      final filtered =
          term.isEmpty ? all : all.where(matches).toList(growable: false);
      if (term.isNotEmpty || expanded || filtered.length <= _collapsedCap) {
        return (rows: filtered, more: 0);
      }
      return (
        rows: filtered.sublist(0, _collapsedCap),
        more: filtered.length - _collapsedCap,
      );
    }

    // Build the three sections, then emit them in the persisted order.
    Widget sectionFor(_SectionId s) {
      switch (s) {
        case _SectionId.channels:
          final term = _channelTerm.toLowerCase();
          final r = capped<ChannelEntry>(
            channels,
            term,
            (ch) => (ch.isGeohash ? ch.geohash : ch.channel)
                .toLowerCase()
                .contains(term),
            _channelExpanded,
          );
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
            onToggleSearch: () => setState(() {
              _channelSearch = !_channelSearch;
              if (!_channelSearch) _channelTerm = '';
            }),
            onSearchChanged: (v) => setState(() => _channelTerm = v),
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
              for (final ch in r.rows)
                ChannelListItem(
                  entry: ch,
                  active: view.kind == ViewKind.channel && view.id == ch.key,
                  pinned: pinned.contains(ch.key),
                  unread: unread[ch.key] ?? 0,
                  textSize: textSize,
                  onTap: () => select(ChatView.channel(ch.key)),
                ),
              if (r.more > 0)
                _ViewMoreButton(
                  more: r.more,
                  onTap: () => setState(() => _channelExpanded = true),
                )
              else if (term.isEmpty &&
                  _channelExpanded &&
                  channels.length > _collapsedCap)
                _ViewMoreButton(
                  more: 0,
                  onTap: () => setState(() => _channelExpanded = false),
                ),
            ],
          );
        case _SectionId.pms:
          final term = _pmTerm.toLowerCase();
          final r = capped<_PmEntry>(
            pmEntries,
            term,
            (e) => (e.group != null ? e.group!.name : e.pm!.nym)
                .toLowerCase()
                .contains(term),
            _pmExpanded,
          );
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
            onToggleSearch: () => setState(() {
              _pmSearch = !_pmSearch;
              if (!_pmSearch) _pmTerm = '';
            }),
            onSearchChanged: (v) => setState(() => _pmTerm = v),
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
              // Nymbot: a pinned PM row at the top of Private Messages — the
              // entry point to the dedicated bot chat (the PWA surfaces the bot
              // as a highlighted PM conversation). `PMListItem` renders its
              // avatar + verified ✓ from the pubkey; tap binds the paid session
              // then opens `BotChatScreen`.
              if (term.isEmpty || 'nymbot'.contains(term))
                PMListItem(
                  nym: 'Nymbot',
                  pubkey: NostrController.nymbotPubkey,
                  active: false,
                  unread: 0,
                  textSize: textSize,
                  onTap: () {
                    widget.onItemSelected?.call();
                    ref.read(nostrControllerProvider).bindBotChat();
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const BotChatScreen(),
                      ),
                    );
                  },
                ),
              for (final e in r.rows)
                if (e.group != null)
                  _GroupListItem(
                    group: e.group!,
                    active: view.kind == ViewKind.group &&
                        view.id == e.group!.id,
                    unread:
                        unread[GroupLogic.groupStorageKey(e.group!.id)] ?? 0,
                    textSize: textSize,
                    selfPubkey: app.selfPubkey,
                    users: users,
                    onTap: () => select(ChatView.group(e.group!.id)),
                  )
                else
                  PMListItem(
                    nym: e.pm!.nym,
                    pubkey: e.pm!.pubkey,
                    active:
                        view.kind == ViewKind.pm && view.id == e.pm!.pubkey,
                    unread: unread[e.pm!.pubkey] ?? 0,
                    textSize: textSize,
                    onTap: () => select(ChatView.pm(e.pm!.pubkey)),
                  ),
              if (r.more > 0)
                _ViewMoreButton(
                  more: r.more,
                  onTap: () => setState(() => _pmExpanded = true),
                )
              else if (term.isEmpty &&
                  _pmExpanded &&
                  pmEntries.length > _collapsedCap)
                _ViewMoreButton(
                  more: 0,
                  onTap: () => setState(() => _pmExpanded = false),
                ),
            ],
          );
        case _SectionId.nyms:
          final term = _nymTerm.toLowerCase();
          final r = capped<User>(
            onlineUsers,
            term,
            (u) => u.nym.toLowerCase().contains(term),
            _nymExpanded,
          );
          // `.user-list` (gap F17): 10px padding, NO bottom divider.
          return _NavSection(
            key: const ValueKey('section-nyms'),
            sectionKey: TutorialTargets.keyFor(TutorialTarget.userList),
            // Dynamic "Nyms (N online)" (`abbreviateNumber(activeCount)`).
            title: 'Nyms (${_abbreviateNumber(nymActiveCount)} online)',
            open: !_collapsed.contains(s),
            searching: _nymSearch,
            reorderMode: _reorderMode,
            isUserList: true,
            canMoveUp: _order.indexOf(s) > 0,
            canMoveDown: _order.indexOf(s) < _order.length - 1,
            onMoveUp: () => _moveSection(s, -1),
            onMoveDown: () => _moveSection(s, 1),
            onToggleOpen: () => _toggleCollapse(s),
            onToggleSearch: () => setState(() {
              _nymSearch = !_nymSearch;
              if (!_nymSearch) _nymTerm = '';
            }),
            onSearchChanged: (v) => setState(() => _nymTerm = v),
            onLongPressTitle: _toggleReorderMode,
            searchHint: 'Search nyms…',
            children: [
              for (final u in r.rows)
                UserListItem(
                  user: u,
                  textSize: textSize,
                  onTap: () => select(ChatView.pm(u.pubkey)),
                ),
              if (r.more > 0)
                _ViewMoreButton(
                  more: r.more,
                  onTap: () => setState(() => _nymExpanded = true),
                )
              else if (term.isEmpty &&
                  _nymExpanded &&
                  onlineUsers.length > _collapsedCap)
                _ViewMoreButton(
                  more: 0,
                  onTap: () => setState(() => _nymExpanded = false),
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
        child: Column(
          children: [
            // `.nym-display { margin-top:15px }` — the top gap above the box
            // (cosmetic in app mode where the ASCII logo above is hidden).
            const SizedBox(height: 15),
            // `.nym-display`: padding 10/14, bg white@0.04, glass border,
            // radius-sm.
            Container(
              key: TutorialTargets.keyFor(TutorialTarget.nymDisplay),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                border: Border.all(color: c.glassBorder),
                borderRadius: NymRadius.rsm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // `.nym-label` (block, `.sidebar-header { text-align:center }`):
                  // 10px uppercase ls 1.5 textDim weight 500, centered. Copy is
                  // "Your Nym (click to edit)" in the PWA (gap F16).
                  Text(
                    'YOUR NYM (CLICK TO EDIT)',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.textDim,
                      fontSize: 10,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // `.nym-identity` (flex) stays LEFT-aligned inside the box:
                  // avatar 32 (`.avatar.nm-h-14`) + nym, gap 10.
                  Row(
                    children: [
                      NymAvatar(
                        seed: ref.read(appStateProvider).selfPubkey,
                        size: 32,
                        imageUrl: ref
                            .read(appStateProvider)
                            .users[ref.read(appStateProvider).selfPubkey]
                            ?.profile
                            ?.picture,
                      ),
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
                  // `.status-indicator` (inline-flex → centered by the header):
                  // 11px textDim, gap 5, 8px dot. Tapping opens the Network Stats
                  // modal (index.html:434 `data-action="openRelayStats"`).
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => RelayStatsModal.open(context),
                      child: Row(
                        key: TutorialTargets.keyFor(
                            TutorialTarget.statusIndicator),
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const StatusDot(status: UserStatus.online, size: 8),
                          const SizedBox(width: 5),
                          Text(
                            'connected',
                            style: TextStyle(color: c.textDim, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
class _SidebarActions extends ConsumerWidget {
  const _SidebarActions({this.onItemSelected});

  final VoidCallback? onItemSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            // `.icon-btn` Logout → `signOut()` (app.js `signOut`, 6740-6741):
            // close the drawer (inline-bindings `signOutAndCloseSidebar`), then
            // confirm and disconnect. `signOut()` clears the identity + persisted
            // login keys and bumps the boot generation so the app remounts the
            // first-run gate.
            onTap: () async {
              final controller = ref.read(nostrControllerProvider);
              onItemSelected?.call();
              final ok = await showAppConfirm(
                context,
                'Sign out and disconnect from Nymchat?',
                okLabel: 'Sign out',
                danger: true,
              );
              if (!ok) return;
              await controller.signOut();
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
    required this.onSearchChanged,
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
  final ValueChanged<String> onSearchChanged;
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
                  // `.nav-title` children sit on a 10px flex gap; the icon hit
                  // boxes carry 5px side padding, so a 4px spacer reads ~10px.
                  if (leadingIcon != null) ...[
                    leadingIcon!,
                    const SizedBox(width: 4),
                  ],
                  _MiniIcon(
                    icon: Icons.search,
                    active: searching,
                    tooltip: 'Search',
                    onTap: onToggleSearch,
                  ),
                  const SizedBox(width: 4),
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
              child: _SearchField(
                hint: searchHint,
                onChanged: onSearchChanged,
              ),
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
        // `.search-icon/.discover-icon/.collapse-icon`: 20×20 hit (`padding:
        // 2px 5px`), 14 glyph.
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
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

/// A unified PRIVATE MESSAGES list entry: either a 1:1 PM thread or a group.
/// Carries the `lastMessageTime` both kinds sort by.
class _PmEntry {
  _PmEntry.pm(PMConversation pm)
      : pm = pm,
        group = null,
        lastMessageTime = pm.lastMessageTime;
  _PmEntry.group(Group g)
      : pm = null,
        group = g,
        lastMessageTime = g.lastMessageTime;

  final PMConversation? pm;
  final Group? group;
  final int lastMessageTime;
}

/// The PWA's stroked multi-person group glyph (`groupSvg`, groups.js:2539):
/// a 3-person icon, `stroke-width:1.75`, `currentColor` → `--primary`. `{C}` is
/// substituted with the resolved primary hex at render time.
const String _groupGlyphSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" '
    'stroke="{C}" stroke-width="1.75" stroke-linecap="round" '
    'stroke-linejoin="round">'
    '<circle cx="12" cy="7" r="2.75"/>'
    '<path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/>'
    '<circle cx="4.5" cy="9.5" r="2"/>'
    '<path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/>'
    '<circle cx="19.5" cy="9.5" r="2"/>'
    '<path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>';

String _hex(Color c) {
  int ch(double v) => (v * 255).round() & 0xff;
  return '#${ch(c.r).toRadixString(16).padLeft(2, '0')}'
      '${ch(c.g).toRadixString(16).padLeft(2, '0')}'
      '${ch(c.b).toRadixString(16).padLeft(2, '0')}';
}

/// A group conversation row in the PRIVATE MESSAGES list (`.pm-item.group-item`,
/// groups.js `_buildGroupItemHTML`). Same box metrics as [PMListItem]. The icon
/// is either a custom avatar, a 34×22 stack of up to 3 member avatars + a
/// corner group-glyph badge (the common case), or a 26px `.group-icon-wrap`
/// fallback (no other members). A tap opens the group; a sidebar long-press /
/// right-click opens the one-item "Leave conversation" `.quick-context-menu`
/// (the rich `#groupContextMenu` panel is opened from the chat header instead).
class _GroupListItem extends ConsumerWidget {
  const _GroupListItem({
    required this.group,
    required this.active,
    required this.unread,
    required this.textSize,
    required this.selfPubkey,
    required this.users,
    required this.onTap,
  });

  final Group group;
  final bool active;
  final int unread;
  final double textSize;
  final String selfPubkey;
  final Map<String, User> users;
  final VoidCallback onTap;

  void _leaveMenu(BuildContext context, WidgetRef ref, Offset at) {
    showSidebarQuickMenu(context, at, [
      SidebarQuickMenuItem(
        label: 'Leave conversation',
        icon: Icons.logout,
        danger: true,
        onSelected: () => ref.read(nostrControllerProvider).leaveGroup(group.id),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final avatarUrl = proxiedAvatarUrl(group.avatar);
    final name = group.name.isEmpty ? 'Group' : group.name;
    final otherMembers =
        group.members.where((pk) => pk != selfPubkey).toList(growable: false);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (d) => _leaveMenu(context, ref, d.globalPosition),
          onSecondaryTapDown: (d) => _leaveMenu(context, ref, d.globalPosition),
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
                    color: active ? c.primaryA(0.10) : Colors.transparent,
                    borderRadius: NymRadius.rxs,
                    border: Border.all(
                      color: active ? c.primaryA(0.20) : Colors.transparent,
                      width: 1,
                    ),
                    boxShadow: active
                        ? [BoxShadow(color: c.primaryA(0.05), blurRadius: 12)]
                        : null,
                  ),
                  child: Row(
                    children: [
                      // Custom avatar → 34×22 member stack → 26px icon-wrap
                      // fallback. `margin-right:6px`.
                      if (avatarUrl != null && avatarUrl.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ClipOval(
                            child: NymAvatar(
                              seed: group.id,
                              size: 26,
                              imageUrl: group.avatar,
                            ),
                          ),
                        )
                      else if (otherMembers.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: _GroupAvatarStack(
                            members: otherMembers.take(3).toList(),
                            users: users,
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: _GroupIconWrap(c: c),
                        ),
                      Flexible(
                        child: RichText(
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          text: TextSpan(
                            style: TextStyle(
                              color: c.textDim,
                              fontSize: textSize,
                              fontWeight: FontWeight.w400,
                              height: 1.3,
                            ),
                            children: [
                              TextSpan(text: name),
                              // `.group-member-count`: 0.8em, opacity .55,
                              // weight 300, abbreviated total member count.
                              TextSpan(
                                text:
                                    ' · ${_abbreviateNumber(group.members.length)}',
                                style: TextStyle(
                                  color: c.textDim.withValues(alpha: 0.55),
                                  fontSize: textSize * 0.8,
                                  fontWeight: FontWeight.w300,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Spacer(),
                      if (unread > 0) _GroupUnreadPill(count: unread),
                    ],
                  ),
                ),
                if (active)
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
                            color: c.primary,
                            borderRadius: const BorderRadius.only(
                              topRight: Radius.circular(3),
                              bottomRight: Radius.circular(3),
                            ),
                            boxShadow: [
                              BoxShadow(color: c.primaryA(0.4), blurRadius: 8),
                            ],
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

/// `.group-avatar-stack`: a 34×22 cluster of up to 3 overlapping 18px member
/// avatars (left 0/9/18, each with a 1px `--bg-primary` border) + a 13×13
/// `.group-icon-badge` corner badge holding the 8px group glyph
/// (styles-features.css:2400-2448).
class _GroupAvatarStack extends StatelessWidget {
  const _GroupAvatarStack({required this.members, required this.users});

  final List<String> members;
  final Map<String, User> users;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return SizedBox(
      width: 34,
      height: 22,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < members.length && i < 3; i++)
            Positioned(
              left: i * 9.0, // left 0 / 9 / 18
              top: 0,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: c.bg, width: 1),
                ),
                child: ClipOval(
                  child: NymAvatar(
                    seed: members[i],
                    size: 18,
                    imageUrl: users[members[i]]?.profile?.picture,
                  ),
                ),
              ),
            ),
          // `.group-icon-badge`: 13×13 at bottom -3 / right -4, bg-secondary
          // fill, 1px primary@30 border, 8px glyph.
          Positioned(
            right: -4,
            bottom: -3,
            child: Container(
              width: 13,
              height: 13,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.bgSecondary,
                shape: BoxShape.circle,
                border: Border.all(color: c.primaryA(0.3), width: 1),
              ),
              child: SvgPicture.string(
                _groupGlyphSvg.replaceAll('{C}', _hex(c.primary)),
                width: 8,
                height: 8,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `.group-icon-wrap` (styles-features.css:2450-2466): a 26px circle, primary@10
/// fill + 1px primary@25 border, holding the 14px group glyph (tinted primary).
/// Used only when the group has no other members.
class _GroupIconWrap extends StatelessWidget {
  const _GroupIconWrap({required this.c});
  final NymColors c;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.primaryA(0.10),
        border: Border.all(color: c.primaryA(0.25), width: 1),
      ),
      child: SvgPicture.string(
        _groupGlyphSvg.replaceAll('{C}', _hex(c.primary)),
        width: 14,
        height: 14,
      ),
    );
  }
}

/// `.unread-badge` for a group row (mirrors [PMListItem]'s pill).
class _GroupUnreadPill extends StatelessWidget {
  const _GroupUnreadPill({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
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

/// `.view-more-btn` (styles-shell.css:284-304): a full-width pill that toggles
/// the 20-item collapse. [more] > 0 → "VIEW {more} MORE…"; 0 → "SHOW LESS".
class _ViewMoreButton extends StatelessWidget {
  const _ViewMoreButton({required this.more, required this.onTap});
  final int more;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final label =
        more > 0 ? 'VIEW ${_abbreviateNumber(more)} MORE…' : 'SHOW LESS';
    return Padding(
      // `margin: 6px 10px`.
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: NymRadius.rxs,
        child: Container(
          width: double.infinity,
          // `padding: 8px 12px`.
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: NymRadius.rxs,
            border: Border.all(color: c.glassBorder),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            // 11px, uppercase, letter-spacing 1, weight 500, --text-dim.
            style: TextStyle(
              color: c.textDim,
              fontSize: 11,
              letterSpacing: 1,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// `abbreviateNumber` (users.js:2069): `<1000` raw, `<1M` → `N.Nk` (1 decimal
/// under 10k, else 0), else `N.NM`.
String _abbreviateNumber(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k';
  }
  return '${(n / 1000000).toStringAsFixed(1)}M';
}

/// `.search-input`: radius rxs, padding 8px 28px 8px 12px, 12px, bg white@5, no
/// leading icon. Shows a trailing ✕ `.search-clear` (right 6px, danger on hover)
/// once it has a value; clearing it resets the section's filter (gap: wired via
/// [onChanged]).
class _SearchField extends StatefulWidget {
  const _SearchField({required this.hint, required this.onChanged});
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final hasValue = _controller.text.isNotEmpty;
    return TextField(
      controller: _controller,
      autofocus: true,
      style: TextStyle(color: c.textBright, fontSize: 12),
      cursorColor: c.primary,
      onChanged: (v) {
        widget.onChanged(v);
        setState(() {}); // toggle the clear ✕ visibility
      },
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        hintStyle: TextStyle(color: c.textDim, fontSize: 12),
        // `padding: 8px 28px 8px 12px` (right room for the ✕).
        contentPadding: const EdgeInsets.fromLTRB(12, 8, 28, 8),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        suffixIcon: hasValue
            ? _SearchClear(onTap: () {
                _controller.clear();
                widget.onChanged('');
                setState(() {});
              })
            : null,
        suffixIconConstraints:
            const BoxConstraints(minWidth: 28, minHeight: 0),
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

/// `.search-clear` ✕ (styles-shell.css:255-276): 14px, `--text-dim`, danger on
/// hover, right 6px.
class _SearchClear extends StatefulWidget {
  const _SearchClear({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_SearchClear> createState() => _SearchClearState();
}

class _SearchClearState extends State<_SearchClear> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Text(
            '✕',
            style: TextStyle(
              color: _hover ? c.danger : c.textDim,
              fontSize: 14,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
