import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/groups/group_logic.dart';
import '../../features/pms/pm_logic.dart';
import '../../models/channel.dart';
import '../../models/group.dart';
import '../../models/message.dart';
import '../../models/pm_conversation.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import '../chat/message_row.dart';
import '../common/nym_avatar.dart';

/// Fixed dimensions from `css/styles-columns.css`.
class _CvDimens {
  static const double column = 360; // .cv-column flex-basis/width
  static const double addColumn = 220; // .cv-add-column width
  static const double gap = 12; // .cv-strip gap
  static const double padding = 12; // .cv-strip padding
  // The PWA's mobile snap carousel is gated on `width <= 768`
  // (`styles-columns.css:496`, `_cvScrollToIndex`/`_cvAttachDnd` on
  // `innerWidth <= 768`).
  static const double mobileBreakpoint = 768;
}

/// The kind of conversation a deck column shows (`desc.type` in columns.js).
enum _ColumnKind { channel, pm, group }

/// A deck column descriptor (`_cvColumns` entry), mirroring `_cvDescForSave`.
/// Resolves its own storage key (into [AppState.messages]), unread key, title
/// and header icon so the deck can host channel / PM / group columns (gap F1).
class _ColumnDesc {
  const _ColumnDesc.channel(this.channel, this.geohash)
      : kind = _ColumnKind.channel,
        pubkey = '',
        nym = '',
        groupId = '';
  const _ColumnDesc.pm(this.pubkey, {this.nym = ''})
      : kind = _ColumnKind.pm,
        channel = '',
        geohash = '',
        groupId = '';
  const _ColumnDesc.group(this.groupId)
      : kind = _ColumnKind.group,
        channel = '',
        geohash = '',
        pubkey = '',
        nym = '';

  final _ColumnKind kind;
  final String channel;
  final String geohash;
  final String pubkey;
  final String nym;
  final String groupId;

  /// Stable identity key (`_cvColKey`): `#geo|channel`, the pm pubkey, or the
  /// group id. Also the unread-counts key for channels/PMs/groups.
  String get key => switch (kind) {
        _ColumnKind.channel =>
          (geohash.isNotEmpty ? geohash : channel).toLowerCase(),
        _ColumnKind.pm => pubkey,
        _ColumnKind.group => groupId,
      };

  /// Key into [AppState.messages].
  String get storageKey => switch (kind) {
        _ColumnKind.channel => '#${geohash.isNotEmpty ? geohash : channel}',
        _ColumnKind.pm => PmLogic.pmStorageKey(pubkey),
        _ColumnKind.group => GroupLogic.groupStorageKey(groupId),
      };

  /// Serializes to the same JSON shape the PWA persists (`_cvDescForSave`),
  /// stored under `nym_columns_layout` (`_cvSaveLayout`).
  Map<String, dynamic> toJson() => switch (kind) {
        _ColumnKind.channel => {
            'type': 'channel',
            'channel': channel,
            'geohash': geohash,
          },
        _ColumnKind.pm => {
            'type': 'pm',
            'pubkey': pubkey,
            'nym': nym,
          },
        _ColumnKind.group => {
            'type': 'group',
            'groupId': groupId,
          },
      };

  /// Rebuilds a descriptor from persisted JSON (`_cvLoadLayout`). Returns null
  /// for unrecognised / malformed entries so a bad key can't crash the deck.
  static _ColumnDesc? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type'];
    switch (type) {
      case 'channel':
        final channel = (raw['channel'] as String?) ?? '';
        final geohash = (raw['geohash'] as String?) ?? '';
        if (channel.isEmpty && geohash.isEmpty) return null;
        return _ColumnDesc.channel(channel, geohash);
      case 'pm':
        final pubkey = (raw['pubkey'] as String?) ?? '';
        if (pubkey.isEmpty) return null;
        return _ColumnDesc.pm(pubkey, nym: (raw['nym'] as String?) ?? '');
      case 'group':
        final groupId = (raw['groupId'] as String?) ?? '';
        if (groupId.isEmpty) return null;
        return _ColumnDesc.group(groupId);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _ColumnDesc && other.kind == kind && other.key == key;

  @override
  int get hashCode => Object.hash(kind, key);
}

/// The deck / multi-column view (`#columnsStrip .cv-strip`), shown when
/// `settings.chatViewMode == 'columns'`.
///
/// Desktop (width > 768): a horizontally-scrollable strip of 360px-wide columns
/// — channel, PM, or group (gap F1) — each draggable by its header to reorder
/// (`_cvAttachDnd`/`cv-drag-ghost`, gap F4) and clickable to focus
/// (`.cv-column.focused` primary border + glow), with a centered pager
/// (`.cv-pager`/`.cv-pdot`) above the strip. Ends in a 220px dashed
/// "+ Add column".
///
/// Mobile (width <= 768): a full-width [PageView] snap carousel (one column per
/// screen, `scroll-snap-type:x mandatory` / `flex:0 0 100%`), each header
/// showing a position-dot indicator (`.cv-hdot`) instead of the title/icon plus
/// prev/next move arrows (`.cv-col-move` → `_cvStepFocused`). Tapping the dots
/// opens a "Columns" bottom-sheet tab switcher (`_cvOpenTabsView`) with
/// drag-to-reorder rows (`.cv-tab`, gap F5).
///
/// Seeded from the persisted `nym_columns_layout` (`_cvSeedIfNeeded`) or, when
/// none is saved, `#nymchat` + the most-recent PM + the most-recent group
/// (`_cvSeedDefaults`); the order/layout is persisted on every mutation
/// (`_cvSaveLayout`). When `settings.columnsWallpaper` is on, the per-column
/// backgrounds go transparent so the wallpaper drawn by the shell behind the
/// deck shows through (`.columns-wallpaper`).
class ColumnsDeck extends ConsumerStatefulWidget {
  const ColumnsDeck({super.key});

  @override
  ConsumerState<ColumnsDeck> createState() => _ColumnsDeckState();
}

class _ColumnsDeckState extends ConsumerState<ColumnsDeck> {
  /// The columns currently shown. Seeded on first build (`_cvSeedDefaults`).
  final List<_ColumnDesc> _columns = [];
  bool _seeded = false;

  /// Mobile carousel page controller (`_cvScrollToIndex` on `innerWidth<=768`).
  final PageController _pageController = PageController();

  /// The focused / visible column index. On mobile this is the PageView page;
  /// on desktop it tracks the last-focused column for the pager highlight.
  int _focused = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // --- Persistence (`_cvSaveLayout` / `_cvLoadLayout`) -----------------------

  /// Persist the current column order/layout to `nym_columns_layout`, mirroring
  /// the PWA `_cvSaveLayout` (a JSON array of `_cvDescForSave` descriptors).
  /// Written directly through the [KeyValueStore] the deck already reaches via
  /// [settingsProvider] / [keyValueStoreProvider] — no other file is touched.
  void _saveLayout() {
    final kv = ref.read(keyValueStoreProvider);
    final data = _columns.map((c) => c.toJson()).toList();
    kv.setString(StorageKeys.columnsLayout, jsonEncode(data));
  }

  /// Load a saved layout (`_cvLoadLayout`); null when absent/empty/malformed.
  List<_ColumnDesc>? _loadLayout() {
    final kv = ref.read(keyValueStoreProvider);
    final raw = kv.getString(StorageKeys.columnsLayout);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final out = <_ColumnDesc>[];
      for (final entry in decoded) {
        final desc = _ColumnDesc.fromJson(entry);
        if (desc != null && !out.contains(desc)) out.add(desc);
      }
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  void _seedIfNeeded(
    List<ChannelEntry> channels,
    List<PMConversation> pms,
    List<Group> groups,
    bool pmOnly,
  ) {
    if (_seeded) return;
    _seeded = true;

    // PWA `_cvSeedIfNeeded`: restore the saved layout first if one exists.
    final saved = _loadLayout();
    if (saved != null && saved.isNotEmpty) {
      // In PM-only mode channel columns are not allowed (`cvAddColumn` guard).
      _columns.addAll(pmOnly
          ? saved.where((d) => d.kind != _ColumnKind.channel)
          : saved);
      if (_columns.isNotEmpty) return;
    }

    // `_cvSeedDefaults`: #nymchat (unless PM-only) + most-recent PM + group.
    if (!pmOnly) {
      final nymchat = channels.firstWhere(
        (ch) => ch.key == kDefaultChannel,
        orElse: () => channels.isNotEmpty
            ? channels.first
            : ChannelEntry(channel: kDefaultChannel),
      );
      _columns.add(_ColumnDesc.channel(nymchat.channel, nymchat.geohash));
    }
    if (pms.isNotEmpty) {
      // pmListProvider is already most-recent-first.
      _columns.add(_ColumnDesc.pm(pms.first.pubkey, nym: pms.first.nym));
    }
    if (groups.isNotEmpty) {
      final g = [...groups]
        ..sort((a, b) => b.lastMessageTime - a.lastMessageTime);
      _columns.add(_ColumnDesc.group(g.first.id));
    }
    // Mirror `_cvSeedDefaults`, which persists the freshly seeded layout.
    // Deferred to post-frame since seeding runs inside the first build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _saveLayout();
    });
  }

  void _removeColumn(_ColumnDesc desc) {
    final idx = _columns.indexOf(desc);
    if (idx < 0) return;
    setState(() {
      _columns.removeAt(idx);
      // `cvRemoveColumn`: keep the focus on a still-present neighbour.
      if (_focused >= _columns.length) {
        _focused = _columns.isEmpty ? 0 : _columns.length - 1;
      }
    });
    _saveLayout();
    _syncPageController();
  }

  /// Reorder a column from [oldIndex] to [newIndex] (desktop drag / tabs-sheet
  /// drag / `_cvMoveColumn`), then persist (`_cvSaveLayout`).
  void _reorderColumn(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _columns.length) return;
    if (newIndex < 0 || newIndex > _columns.length) return;
    setState(() {
      final moved = _columns.removeAt(oldIndex);
      if (newIndex > oldIndex) newIndex -= 1;
      newIndex = newIndex.clamp(0, _columns.length);
      _columns.insert(newIndex, moved);
      _focused = newIndex;
    });
    _saveLayout();
    _scrollToIndex(_focused);
  }

  /// Desktop "click a column to focus it" (`columns.js:175-179` →
  /// `_cvOpenConversation`/`_cvFocusColumn`): clicking a non-focused column
  /// marks it focused so its header shows the primary border + `--shadow-glow`.
  void _focusColumn(int index) {
    if (index < 0 || index >= _columns.length) return;
    if (_focused != index) setState(() => _focused = index);
  }

  /// Step the visible column one slot left/right (`_cvStepFocused`, mobile
  /// arrows — navigates the carousel, it does not reorder).
  void _stepFocused(int dir) {
    final to = _focused + dir;
    if (to < 0 || to >= _columns.length) return;
    _scrollToIndex(to);
  }

  /// `_cvScrollToIndex`: on mobile snap the carousel by page width; on desktop
  /// this just records the focused column for the pager highlight.
  void _scrollToIndex(int idx) {
    if (idx < 0 || idx >= _columns.length) return;
    if (_isMobile && _pageController.hasClients) {
      _pageController.animateToPage(
        idx,
        duration: NymMotion.transition,
        curve: NymMotion.curve,
      );
    }
    if (_focused != idx) setState(() => _focused = idx);
  }

  /// Keep the PageView page valid after a removal/reorder changes the count.
  void _syncPageController() {
    if (!_isMobile || !_pageController.hasClients) return;
    final page = _pageController.page?.round() ?? 0;
    if (page != _focused && _focused < _columns.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients) {
          _pageController.jumpToPage(_focused.clamp(0, _columns.length - 1));
        }
      });
    }
  }

  bool get _isMobile {
    final w = MediaQuery.of(context).size.width;
    return w <= _CvDimens.mobileBreakpoint;
  }

  Future<void> _openAddColumn(
    List<ChannelEntry> channels,
    List<PMConversation> pms,
    List<Group> groups,
    bool pmOnly,
  ) async {
    // `_cvAvailableConversations`: channels (unless PM-only) + PMs + groups not
    // already open.
    final open = _columns.toSet();
    final available = <_ColumnDesc>[
      if (!pmOnly)
        for (final ch in channels) _ColumnDesc.channel(ch.channel, ch.geohash),
      for (final pm in pms) _ColumnDesc.pm(pm.pubkey, nym: pm.nym),
      for (final g in groups) _ColumnDesc.group(g.id),
    ].where((d) => !open.contains(d)).toList();

    final picked = await showModalBottomSheet<_ColumnDesc>(
      context: context,
      backgroundColor: context.nym.bgSecondary,
      builder: (ctx) {
        final c = ctx.nym;
        if (available.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text('No conversations',
                style: TextStyle(color: c.textDim, fontSize: 14)),
          );
        }
        return ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Add a column',
                  style: TextStyle(
                      color: c.textBright,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
            ),
            for (final d in available)
              ListTile(
                leading: _columnIcon(ctx, d, size: 24),
                title: Text(_columnTitle(ctx, d),
                    style: TextStyle(color: c.text)),
                onTap: () => Navigator.of(ctx).pop(d),
              ),
          ],
        );
      },
    );
    if (picked != null && mounted) {
      setState(() {
        _columns.add(picked);
        _focused = _columns.length - 1;
      });
      _saveLayout();
      // `_cvOpenAddColumn` scrolls the new column into view on add.
      _scrollToIndex(_columns.length - 1);
    }
  }

  /// The "Columns" bottom-sheet tab switcher (`_cvOpenTabsView` /
  /// `_cvBuildTabsView`): a list of `.cv-tab` rows with drag-to-reorder, a
  /// per-row close, the active column highlighted, and a "+ Add column" footer
  /// (gap F5). Metrics from `styles-columns.css:684-772`.
  Future<void> _openTabsView(
    List<ChannelEntry> channels,
    List<PMConversation> pms,
    List<Group> groups,
    bool pmOnly,
  ) async {
    final result = await showModalBottomSheet<_TabsResult>(
      context: context,
      // `.cv-tabs-overlay` background rgba(0,0,0,0.5).
      barrierColor: Colors.black.withValues(alpha: 0.5),
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _TabsSheet(
        columns: List<_ColumnDesc>.from(_columns),
        focused: _focused,
        titleOf: (d) => _columnTitle(ctx, d),
        iconOf: (d) => _columnIcon(ctx, d, size: 24),
      ),
    );
    if (result == null || !mounted) return;
    switch (result.action) {
      case _TabsAction.select:
        _scrollToIndex(result.index!);
      case _TabsAction.remove:
        _removeColumn(_columns[result.index!]);
      case _TabsAction.reorder:
        // The sheet returns the fully reordered list.
        setState(() {
          _columns
            ..clear()
            ..addAll(result.reordered!);
          _focused = _focused.clamp(0, _columns.length - 1);
        });
        _saveLayout();
        _scrollToIndex(_focused);
      case _TabsAction.add:
        await _openAddColumn(channels, pms, groups, pmOnly);
    }
  }

  /// Resolves a column's title (`_cvColTitle`).
  String _columnTitle(BuildContext context, _ColumnDesc d) {
    final app = ref.read(appStateProvider);
    switch (d.kind) {
      case _ColumnKind.channel:
        return '#${d.geohash.isNotEmpty ? d.geohash : d.channel}';
      case _ColumnKind.pm:
        final conv = app.pmConversations
            .where((c) => c.pubkey == d.pubkey)
            .toList();
        final nym = conv.isNotEmpty ? conv.first.nym : null;
        return (nym != null && nym.isNotEmpty)
            ? nym
            : (d.nym.isNotEmpty
                ? d.nym
                : (app.users[d.pubkey]?.nym ?? 'Direct message'));
      case _ColumnKind.group:
        final g = app.groups.where((g) => g.id == d.groupId).toList();
        return (g.isNotEmpty && g.first.name.isNotEmpty)
            ? g.first.name
            : 'Group chat';
    }
  }

  /// Resolves a column's header icon (`_cvColIcon`): a `#` text glyph for
  /// channels, a multi-person SVG for groups without an avatar (both in
  /// `--text-dim`), and a 20px round avatar for PMs / avatar-bearing groups.
  Widget _columnIcon(BuildContext context, _ColumnDesc d, {double size = 20}) {
    final c = context.nym;
    final app = ref.read(appStateProvider);
    switch (d.kind) {
      case _ColumnKind.channel:
        // `_cvColIcon` returns the literal text '#'; `.cv-col-icon` is text-dim.
        return Text(
          '#',
          style: TextStyle(
            color: c.textDim,
            fontSize: 16,
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        );
      case _ColumnKind.pm:
        final u = app.users[d.pubkey];
        return NymAvatar(
          seed: _columnTitle(context, d),
          size: size,
          imageUrl: u?.profile?.picture,
        );
      case _ColumnKind.group:
        final g = app.groups.where((g) => g.id == d.groupId).toList();
        final avatar = g.isNotEmpty ? g.first.avatar : null;
        if (avatar != null && avatar.isNotEmpty) {
          return NymAvatar(
            seed: _columnTitle(context, d),
            size: size,
            imageUrl: avatar,
          );
        }
        // Group fallback: the 16×16 multi-person SVG, stroked in text-dim.
        return SizedBox(
          width: 16,
          height: 16,
          child: CustomPaint(painter: _GroupGlyphPainter(color: c.textDim)),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final channels = ref.watch(channelsProvider);
    final pms = ref.watch(pmListProvider);
    final groups = ref.watch(groupsProvider);
    final pmOnly =
        ref.watch(settingsProvider.select((s) => s.groupChatPMOnlyMode));
    final transparentColumns =
        ref.watch(settingsProvider.select((s) => s.columnsWallpaper));
    _seedIfNeeded(channels, pms, groups, pmOnly);

    if (_focused >= _columns.length) {
      _focused = _columns.isEmpty ? 0 : _columns.length - 1;
    }

    return Container(
      key: const Key('columnsStrip'),
      color: Colors.transparent,
      child: _isMobile
          ? _buildMobile(c, channels, pms, groups, pmOnly, transparentColumns)
          : _buildDesktop(c, channels, pms, groups, pmOnly, transparentColumns),
    );
  }

  // --- Desktop (>768): horizontal strip + drag-reorder + pager ---------------

  Widget _buildDesktop(
    NymColors c,
    List<ChannelEntry> channels,
    List<PMConversation> pms,
    List<Group> groups,
    bool pmOnly,
    bool transparentColumns,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // `.cv-pager` (centered, ≥769 only, hidden for a single column).
        if (_columns.length > 1)
          _Pager(
            count: _columns.length,
            active: _focused,
            onTap: () => _openTabsView(channels, pms, groups, pmOnly),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(_CvDimens.padding),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < _columns.length; i++) ...[
                    _DesktopColumnSlot(
                      key: ValueKey('cvcol_${_columns[i].key}'),
                      index: i,
                      total: _columns.length,
                      desc: _columns[i],
                      title: _columnTitle(context, _columns[i]),
                      icon: _columnIcon(context, _columns[i]),
                      focused: i == _focused,
                      transparent: transparentColumns,
                      onClose: () => _removeColumn(_columns[i]),
                      onFocus: () => _focusColumn(i),
                      onReorder: _reorderColumn,
                    ),
                    const SizedBox(width: _CvDimens.gap),
                  ],
                  _AddColumnButton(
                    c: c,
                    width: _CvDimens.addColumn,
                    onTap: () => _openAddColumn(channels, pms, groups, pmOnly),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // --- Mobile (<=768): full-width PageView snap carousel ---------------------

  Widget _buildMobile(
    NymColors c,
    List<ChannelEntry> channels,
    List<PMConversation> pms,
    List<Group> groups,
    bool pmOnly,
    bool transparentColumns,
  ) {
    // The "+ Add column" tile is the trailing page (PWA: it stays in the snap
    // strip at `flex:0 0 100%`).
    final pageCount = _columns.length + 1;
    return PageView.builder(
      controller: _pageController,
      itemCount: pageCount,
      onPageChanged: (i) {
        if (i < _columns.length && i != _focused) {
          setState(() => _focused = i);
        }
      },
      itemBuilder: (context, i) {
        if (i >= _columns.length) {
          // Full-width dashed add-column page (`.cv-add-column flex:0 0 100%`).
          return Padding(
            padding: const EdgeInsets.all(_CvDimens.padding),
            child: _AddColumnButton(
              c: c,
              width: double.infinity,
              onTap: () => _openAddColumn(channels, pms, groups, pmOnly),
            ),
          );
        }
        final desc = _columns[i];
        return _MobileColumn(
          index: i,
          total: _columns.length,
          desc: desc,
          transparent: transparentColumns,
          onClose: () => _removeColumn(desc),
          onPrev: () => _stepFocused(-1),
          onNext: () => _stepFocused(1),
          onOpenTabs: () => _openTabsView(channels, pms, groups, pmOnly),
        );
      },
    );
  }
}

/// A desktop column wrapped as a horizontal drag-source + drag-target so columns
/// can be reordered by dragging the 6-dot grip (`_cvAttachDnd`, gap F4). The
/// drag feedback is a translucent clone (`.cv-drag-ghost`, opacity 0.92) and the
/// source dims to opacity 0.4 (`.cv-column.cv-dragging`).
class _DesktopColumnSlot extends StatefulWidget {
  const _DesktopColumnSlot({
    super.key,
    required this.index,
    required this.total,
    required this.desc,
    required this.title,
    required this.icon,
    required this.focused,
    required this.transparent,
    required this.onClose,
    required this.onFocus,
    required this.onReorder,
  });

  final int index;
  final int total;
  final _ColumnDesc desc;
  final String title;
  final Widget icon;
  final bool focused;
  final bool transparent;
  final VoidCallback onClose;
  final VoidCallback onFocus;
  final void Function(int from, int to) onReorder;

  @override
  State<_DesktopColumnSlot> createState() => _DesktopColumnSlotState();
}

class _DesktopColumnSlotState extends State<_DesktopColumnSlot> {
  bool _dragging = false;
  bool _dragOver = false;

  /// Builds a `_DeckColumn` for this slot. When [draggable] is true the column
  /// header is the drag source (`_cvAttachDnd` attaches `mousedown` to the whole
  /// header, excluding close/move/dots); the floating drag clone passes false so
  /// it isn't itself draggable.
  Widget _buildColumn({required bool draggable}) {
    return _DeckColumn(
      desc: widget.desc,
      title: widget.title,
      icon: widget.icon,
      focused: widget.focused,
      transparent: widget.transparent,
      mobile: false,
      index: widget.index,
      total: widget.total,
      onClose: widget.onClose,
      // The whole header (grip + icon + title) starts the drag — matches the
      // PWA `cursor:grab` header (live column on the strip only).
      headerDragBuilder: draggable
          ? (header) => Draggable<int>(
                data: widget.index,
                axis: Axis.horizontal,
                dragAnchorStrategy: childDragAnchorStrategy,
                onDragStarted: () => setState(() => _dragging = true),
                onDragEnd: (_) => setState(() => _dragging = false),
                onDraggableCanceled: (_, __) =>
                    setState(() => _dragging = false),
                feedback: _DragGhost(
                  width: _CvDimens.column,
                  child: _buildColumn(draggable: false),
                ),
                childWhenDragging: header,
                child: header,
              )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Clicking anywhere on the column focuses it (`columns.js:175-179`); the
    // header drag-source sits above this so a grab doesn't read as a click.
    final column = GestureDetector(
      onTap: widget.onFocus,
      behavior: HitTestBehavior.deferToChild,
      child: _buildColumn(draggable: true),
    );

    // The whole column is a drop target; dropping before its midpoint inserts
    // the dragged column at this slot (`_cvStartColumnDrag`'s live reorder).
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) {
        if (details.data == widget.index) return false;
        setState(() => _dragOver = true);
        return true;
      },
      onLeave: (_) => setState(() => _dragOver = false),
      onAcceptWithDetails: (details) {
        setState(() => _dragOver = false);
        widget.onReorder(details.data, widget.index);
      },
      builder: (context, candidate, rejected) {
        return AnimatedOpacity(
          duration: NymMotion.slide,
          opacity: _dragging ? 0.4 : 1.0,
          child: DecoratedBox(
            // A subtle primary edge marks the live drop slot.
            decoration: BoxDecoration(
              borderRadius: NymRadius.rmd,
              border: _dragOver
                  ? Border.all(color: context.nym.primary, width: 2)
                  : null,
            ),
            child: column,
          ),
        );
      },
    );
  }
}

/// The translucent drag clone shown under the pointer (`.cv-drag-ghost`:
/// fixed, shadow-lg, opacity 0.92).
class _DragGhost extends StatelessWidget {
  const _DragGhost({required this.width, required this.child});
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.92,
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox(
          width: width,
          // Constrain height so the floating clone matches the column footprint
          // without unbounded layout.
          height: MediaQuery.of(context).size.height * 0.7,
          child: child,
        ),
      ),
    );
  }
}

/// A mobile carousel page: a full-width column whose header shows a position-dot
/// indicator + prev/next move arrows instead of the title/icon (gap F5).
class _MobileColumn extends StatelessWidget {
  const _MobileColumn({
    required this.index,
    required this.total,
    required this.desc,
    required this.transparent,
    required this.onClose,
    required this.onPrev,
    required this.onNext,
    required this.onOpenTabs,
  });

  final int index;
  final int total;
  final _ColumnDesc desc;
  final bool transparent;
  final VoidCallback onClose;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onOpenTabs;

  @override
  Widget build(BuildContext context) {
    return _DeckColumn(
      desc: desc,
      // Title/icon are hidden on mobile; the dots take the title's slot.
      title: '',
      icon: const SizedBox.shrink(),
      // Mobile columns reset `.cv-column.focused` border/shadow to none.
      focused: false,
      transparent: transparent,
      mobile: true,
      index: index,
      total: total,
      onClose: onClose,
      onPrev: onPrev,
      onNext: onNext,
      onOpenTabs: onOpenTabs,
    );
  }
}

/// A single deck column (`.cv-column`): 360px wide on desktop / full-width on
/// mobile, header + compact message list for one channel / PM / group.
class _DeckColumn extends ConsumerStatefulWidget {
  const _DeckColumn({
    required this.desc,
    required this.title,
    required this.icon,
    required this.focused,
    required this.transparent,
    required this.mobile,
    required this.index,
    required this.total,
    required this.onClose,
    this.onPrev,
    this.onNext,
    this.onOpenTabs,
    this.headerDragBuilder,
  });

  final _ColumnDesc desc;
  final String title;
  final Widget icon;

  /// Desktop only: the focused column shows a primary border + `--shadow-glow`
  /// (`.cv-column.focused`). Always false on mobile (the PWA resets it to none).
  final bool focused;
  final bool transparent;
  final bool mobile;
  final int index;
  final int total;
  final VoidCallback onClose;

  /// Mobile prev/next carousel step (`_cvStepFocused`).
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  /// Mobile: tapping the dot indicator opens the "Columns" tabs sheet.
  final VoidCallback? onOpenTabs;

  /// Desktop: wraps the whole header (the drag region) in a [Draggable] so the
  /// column can be dragged anywhere on its header to reorder (`_cvAttachDnd`).
  final Widget Function(Widget header)? headerDragBuilder;

  @override
  ConsumerState<_DeckColumn> createState() => _DeckColumnState();
}

class _DeckColumnState extends ConsumerState<_DeckColumn> {
  final ScrollController _scroll = ScrollController();
  bool _atBottom = true;
  bool _showScrollButton = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // Reversed list: offset 0 == newest at the bottom, so offset is the distance
    // from the bottom. The PWA decouples the two thresholds
    // (`_cvAttachColumnScroll`): at-bottom (autoscroll/mark-read) at <120, and
    // the scroll-to-bottom button shows at >150.
    final distanceFromBottom = _scroll.offset;
    final atBottom = distanceFromBottom < 120;
    final showButton = distanceFromBottom > 150;
    if (atBottom != _atBottom || showButton != _showScrollButton) {
      setState(() {
        _atBottom = atBottom;
        _showScrollButton = showButton;
      });
    }
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: NymMotion.transition,
      curve: NymMotion.curve,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final transparent = widget.transparent;
    final mobile = widget.mobile;
    final settings = ref.watch(settingsProvider);
    final app = ref.watch(appStateProvider);
    final reactions = ref.watch(reactionsProvider);
    final messages = [...(app.messages[widget.desc.storageKey] ?? const <Message>[])];
    messages.sort(compareMessages);

    // Per-column typing indicator (`.cv-typing`): the pubkeys typing in this
    // column's conversation, keyed off `app.typing` (`<storageKey>|<pubkey>`,
    // matching the focused-view `typingForCurrentViewProvider`).
    final typingPubkeys = _typingFor(app);

    // `.cv-column.focused` (desktop): primary border + `--shadow-glow`
    // (`0 0 20px primary@0.1`). Mobile resets focused styling to none.
    final showFocus = widget.focused && !mobile;

    final body = Container(
      decoration: BoxDecoration(
        color: transparent ? Colors.transparent : c.bgSecondary,
        // Mobile columns drop the border/radius/shadow (`flex:0 0 100%`,
        // `border:none; border-radius:0; box-shadow:none`).
        borderRadius: mobile ? null : NymRadius.rmd,
        border: mobile
            ? null
            : Border.all(color: showFocus ? c.primary : c.glassBorder),
        // .cv-column box-shadow: focused → --shadow-glow (0 0 20px primary@0.1,
        // desktop only); else --shadow-md (0 4px 16px black@0.4), dropped on
        // mobile / under the columns wallpaper.
        boxShadow: showFocus
            ? [BoxShadow(color: c.primaryA(0.1), blurRadius: 20)]
            : (transparent || mobile)
                ? null
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      offset: const Offset(0, 4),
                      blurRadius: 16,
                    ),
                  ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildHeader(c, mobile),
          // .cv-column-scroller / .cv-list (padding 10) + scroll-to-bottom.
          // .messages-container background rgba(0,0,0,0.15) (transparent only
          // under the columns wallpaper).
          Expanded(
            child: ColoredBox(
              color: transparent
                  ? Colors.transparent
                  : Colors.black.withValues(alpha: 0.15),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: messages.isEmpty
                        ? Center(
                            // `.msg-empty-note`: text-dim, 13px, "No recent
                            // messages[ in #channel]".
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 24),
                              child: Text(
                                _emptyNoteText(),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: c.textDim, fontSize: 13),
                              ),
                            ),
                          )
                        : ListView.builder(
                            controller: _scroll,
                            reverse: true,
                            padding: const EdgeInsets.all(10),
                            itemCount: messages.length,
                            itemBuilder: (context, revIndex) {
                              final m =
                                  messages[messages.length - 1 - revIndex];
                              return MessageRow(
                                message: m,
                                settings: settings,
                                reactions: reactions[m.id] ?? const [],
                                showAvatar: false,
                              );
                            },
                          ),
                  ),
                  // .cv-scroll-bottom: 36×36 circle, bottom/right 16, shown when
                  // scrolled >150px from the bottom (gap F10).
                  if (_showScrollButton && messages.isNotEmpty)
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: _ScrollBottomButton(onTap: _scrollToBottom),
                    ),
                ],
              ),
            ),
          ),
          // `.cv-typing` per-column typing indicator (animated 0→24, black@0.15).
          _TypingRow(pubkeys: typingPubkeys),
        ],
      ),
    );

    return mobile ? body : SizedBox(width: _CvDimens.column, child: body);
  }

  /// The empty-state text (`_appendEmptyNote`): "No recent messages in
  /// #channel" for channels (`messages.js:2840`), else "No recent messages".
  String _emptyNoteText() {
    final d = widget.desc;
    if (d.kind == _ColumnKind.channel) {
      final name = d.geohash.isNotEmpty ? d.geohash : d.channel;
      return 'No recent messages in #$name';
    }
    return 'No recent messages';
  }

  /// Resolves the pubkeys currently typing in this column's conversation from
  /// `app.typing` (keyed `<storageKey>|<pubkey>`, non-expired).
  List<String> _typingFor(AppState app) {
    final prefix = '${widget.desc.storageKey}|';
    final now = DateTime.now().millisecondsSinceEpoch;
    final out = <String>[];
    app.typing.forEach((k, expiry) {
      if (k.startsWith(prefix) && expiry > now) {
        out.add(k.substring(prefix.length));
      }
    });
    return out;
  }

  /// The `.cv-column-header` (padding 10/12, bottom border, gap 8). On desktop:
  /// 6-dot grip + icon + title (all draggable to reorder, `cursor:grab`) + a
  /// close button. On mobile: prev arrow + position dots (in the title's slot) +
  /// next arrow + close. The `.cv-col-unread` pill and the desktop move arrows
  /// are intentionally omitted (dead/desktop-hidden in the PWA).
  Widget _buildHeader(NymColors c, bool mobile) {
    final children = <Widget>[];

    if (mobile) {
      // `.cv-col-move` prev arrow.
      children.add(_HeaderIconButton(
        icon: Icons.chevron_left,
        tooltip: 'Previous column',
        enabled: widget.index > 0,
        onTap: widget.onPrev,
      ));
      // `.cv-col-dots`: the position-dot indicator, fills the title slot, taps
      // to open the tabs sheet.
      children.add(Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onOpenTabs,
          child: SizedBox(
            height: 20,
            child: _HeaderDots(count: widget.total, active: widget.index),
          ),
        ),
      ));
      // `.cv-col-move` next arrow.
      children.add(_HeaderIconButton(
        icon: Icons.chevron_right,
        tooltip: 'Next column',
        enabled: widget.index < widget.total - 1,
        onTap: widget.onNext,
      ));
      // `.cv-col-close`.
      children.add(const SizedBox(width: 8));
      children.add(_buildCloseButton(c));
      return _headerContainer(c, Row(children: children));
    }

    // Desktop: the whole header is the drag source (`_cvAttachDnd` mousedown on
    // the header, excluding the close button). The grip + icon + title form the
    // draggable region; `.cv-col-move` arrows are desktop-hidden (reorder is
    // drag-only) and the unread pill is never shown (`.cv-col-unread:empty`).
    children.add(_DragHandle(color: c.textDim));
    children.add(const SizedBox(width: 8));
    children.add(widget.icon);
    children.add(const SizedBox(width: 8));
    children.add(Expanded(
      child: Text(
        widget.title,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: c.secondary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ));

    Widget dragRegion = Row(children: children);
    if (widget.headerDragBuilder != null) {
      dragRegion = widget.headerDragBuilder!(dragRegion);
    }
    // `.cv-column-header { cursor: grab }` over the draggable region.
    dragRegion = MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: dragRegion,
    );

    return _headerContainer(
      c,
      Row(
        children: [
          Expanded(child: dragRegion),
          const SizedBox(width: 8),
          _buildCloseButton(c),
        ],
      ),
    );
  }

  /// The `.cv-col-close` button (text-dim → danger on hover).
  Widget _buildCloseButton(NymColors c) {
    return IconButton(
      tooltip: 'Remove column',
      icon: Icon(Icons.close, size: 16, color: c.textDim),
      hoverColor: c.danger.withValues(alpha: 0.12),
      onPressed: widget.onClose,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
    );
  }

  /// The `.cv-column-header` chrome (padding 10/12, glass bg, bottom border).
  Widget _headerContainer(NymColors c, Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: widget.transparent ? Colors.transparent : c.glassBg,
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: child,
    );
  }
}

/// The `.cv-drag-handle` 6-dot grip (14×14 svg, two columns of three dots,
/// text-dim → text-bright on hover). Desktop only.
class _DragHandle extends StatefulWidget {
  const _DragHandle({required this.color});
  final Color color;

  @override
  State<_DragHandle> createState() => _DragHandleState();
}

class _DragHandleState extends State<_DragHandle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: SizedBox(
        width: 14,
        height: 14,
        child: CustomPaint(
          painter: _SixDotPainter(
            color: _hover ? c.textBright : widget.color,
          ),
        ),
      ),
    );
  }
}

/// Paints the two-column, three-row dot grip from the PWA SVG
/// (`circle cx=9/15 cy=6/12/18 r=1.4` in a 24×24 box).
class _SixDotPainter extends CustomPainter {
  _SixDotPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final sx = size.width / 24, sy = size.height / 24;
    const r = 1.4;
    for (final cx in [9.0, 15.0]) {
      for (final cy in [6.0, 12.0, 18.0]) {
        canvas.drawCircle(Offset(cx * sx, cy * sy), r * sx, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_SixDotPainter old) => old.color != color;
}

/// The group-header fallback glyph (`_cvColIcon` multi-person SVG): three heads
/// + shoulders, stroked (no fill), `stroke-width 1.75` in a 24×24 viewBox.
class _GroupGlyphPainter extends CustomPainter {
  _GroupGlyphPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24; // uniform scale (16×16 box).
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.75 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Offset p(double x, double y) => Offset(x * s, y * s);

    // Center head + shoulders: circle cx12 cy7 r2.75; M5 21v-1.5 a7 7 0 0 1 14 0 V21.
    canvas.drawCircle(p(12, 7), 2.75 * s, paint);
    final centre = Path()
      ..moveTo(5 * s, 21 * s)
      ..relativeLineTo(0, -1.5 * s)
      ..arcToPoint(p(19, 19.5), radius: Radius.circular(7 * s), clockwise: true)
      ..lineTo(19 * s, 21 * s);
    canvas.drawPath(centre, paint);

    // Left figure: circle cx4.5 cy9.5 r2; M1 20v-1 a4.5 4.5 0 0 1 5.5-4.35.
    canvas.drawCircle(p(4.5, 9.5), 2 * s, paint);
    final left = Path()
      ..moveTo(1 * s, 20 * s)
      ..relativeLineTo(0, -1 * s)
      ..relativeArcToPoint(p(5.5, -4.35),
          radius: Radius.circular(4.5 * s), clockwise: true);
    canvas.drawPath(left, paint);

    // Right figure: circle cx19.5 cy9.5 r2; M23 20v-1 a4.5 4.5 0 0 0-5.5-4.35.
    canvas.drawCircle(p(19.5, 9.5), 2 * s, paint);
    final right = Path()
      ..moveTo(23 * s, 20 * s)
      ..relativeLineTo(0, -1 * s)
      ..relativeArcToPoint(p(-5.5, -4.35),
          radius: Radius.circular(4.5 * s), clockwise: false);
    canvas.drawPath(right, paint);
  }

  @override
  bool shouldRepaint(_GroupGlyphPainter old) => old.color != color;
}

/// The mobile per-column position dots (`.cv-hdot`): 6px circles, 2px h-margin,
/// the active one primary/opaque (`styles-columns.css:573-587`).
class _HeaderDots extends StatelessWidget {
  const _HeaderDots({required this.count, required this.active});
  final int count;
  final int active;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i == active
                    ? c.primary
                    : c.textDim.withValues(alpha: 0.4),
              ),
            ),
        ],
      ),
    );
  }
}

/// A small header control button used for the mobile `.cv-col-move` prev/next
/// carousel arrows (`_cvStepFocused`). text-dim → text-bright on hover, dimmed
/// when disabled. (Desktop move arrows don't exist — reorder is drag-only.)
class _HeaderIconButton extends StatefulWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  State<_HeaderIconButton> createState() => _HeaderIconButtonState();
}

class _HeaderIconButtonState extends State<_HeaderIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final color = !widget.enabled
        ? c.textDim.withValues(alpha: 0.3)
        : (_hover ? c.textBright : c.textDim);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(widget.icon, size: 16, color: color),
          ),
        ),
      ),
    );
  }
}

/// The desktop `.cv-pager`: centered row of `.cv-pdot` (7px) dots above the
/// strip, the active column's dot primary/opaque; the whole cluster opens the
/// tabs view. Shown only for >1 column (gap F5).
class _Pager extends StatefulWidget {
  const _Pager({required this.count, required this.active, required this.onTap});
  final int count;
  final int active;
  final VoidCallback onTap;

  @override
  State<_Pager> createState() => _PagerState();
}

class _PagerState extends State<_Pager> {
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
        behavior: HitTestBehavior.opaque,
        child: Tooltip(
          message: 'Switch columns',
          child: Padding(
            // `.cv-pager` padding: 12px 8px 0.
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < widget.count; i++)
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == widget.active
                          ? c.primary
                          : c.textDim.withValues(
                              alpha: _hover ? 0.7 : 0.4),
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

/// Result of the "Columns" tabs bottom-sheet.
enum _TabsAction { select, remove, reorder, add }

class _TabsResult {
  const _TabsResult.select(this.index)
      : action = _TabsAction.select,
        reordered = null;
  const _TabsResult.remove(this.index)
      : action = _TabsAction.remove,
        reordered = null;
  const _TabsResult.reorder(this.reordered)
      : action = _TabsAction.reorder,
        index = null;
  const _TabsResult.add()
      : action = _TabsAction.add,
        index = null,
        reordered = null;

  final _TabsAction action;
  final int? index;
  final List<_ColumnDesc>? reordered;
}

/// The "Columns" bottom-sheet (`.cv-tabs-overlay`/`.cv-tabs-sheet`): a
/// reorderable list of `.cv-tab` rows (drag handle + icon + title + close), the
/// active column highlighted, plus a "+ Add column" footer (gap F5). Metrics
/// from `styles-columns.css:623-772`.
class _TabsSheet extends StatefulWidget {
  const _TabsSheet({
    required this.columns,
    required this.focused,
    required this.titleOf,
    required this.iconOf,
  });

  final List<_ColumnDesc> columns;
  final int focused;
  final String Function(_ColumnDesc) titleOf;
  final Widget Function(_ColumnDesc) iconOf;

  @override
  State<_TabsSheet> createState() => _TabsSheetState();
}

class _TabsSheetState extends State<_TabsSheet> {
  late List<_ColumnDesc> _local;
  bool _reordered = false;
  late int _activeKeyIndex;
  _ColumnDesc? _activeDesc;

  @override
  void initState() {
    super.initState();
    _local = List<_ColumnDesc>.from(widget.columns);
    _activeKeyIndex = widget.focused;
    _activeDesc = (widget.focused >= 0 && widget.focused < _local.length)
        ? _local[widget.focused]
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final size = MediaQuery.of(context).size;
    // `@media(min-width:769px)`: the overlay centers the sheet, which gets an
    // all-corner `--radius-lg` and a 70vh cap. Below that it's a bottom sheet
    // with top-only radius and a 75vh cap.
    final desktop = size.width >= 769;
    final maxHeight = size.height * (desktop ? 0.70 : 0.75);
    return SafeArea(
      top: false,
      child: Align(
        alignment: desktop ? Alignment.center : Alignment.bottomCenter,
        child: ConstrainedBox(
          // `.cv-tabs-sheet`: max-width 520.
          constraints: BoxConstraints(maxWidth: 520, maxHeight: maxHeight),
          child: Container(
            decoration: BoxDecoration(
              color: c.bgSecondary,
              border: Border.all(color: c.glassBorder),
              borderRadius: desktop
                  ? NymRadius.rlg
                  : const BorderRadius.vertical(
                      top: Radius.circular(NymRadius.lg),
                    ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 32,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // `.cv-tabs-head`: padding 14/16, bottom border, primary title.
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    border:
                        Border(bottom: BorderSide(color: c.glassBorder)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Columns',
                          style: TextStyle(
                            color: c.primary,
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        icon: Icon(Icons.close, size: 18, color: c.textDim),
                        onPressed: () => Navigator.of(context).pop(),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
                // `.cv-tabs-list`: the reorderable `.cv-tab` rows.
                Flexible(
                  child: ReorderableListView.builder(
                    shrinkWrap: true,
                    buildDefaultDragHandles: false,
                    padding: const EdgeInsets.all(8),
                    itemCount: _local.length,
                    onReorder: (oldIndex, newIndex) {
                      if (newIndex > oldIndex) newIndex -= 1;
                      setState(() {
                        final moved = _local.removeAt(oldIndex);
                        _local.insert(newIndex, moved);
                        _reordered = true;
                        // Track the active row across reorders by identity.
                        if (_activeDesc != null) {
                          _activeKeyIndex = _local.indexOf(_activeDesc!);
                        }
                      });
                    },
                    itemBuilder: (context, i) {
                      final desc = _local[i];
                      return _TabRow(
                        key: ValueKey('cvtab_${desc.key}'),
                        index: i,
                        active: i == _activeKeyIndex,
                        icon: widget.iconOf(desc),
                        title: widget.titleOf(desc),
                        onTap: () {
                          if (_reordered) {
                            // Commit the new order first, then select.
                            Navigator.of(context)
                                .pop(_TabsResult.reorder(_local));
                          } else {
                            Navigator.of(context).pop(_TabsResult.select(i));
                          }
                        },
                        onClose: () =>
                            Navigator.of(context).pop(_TabsResult.remove(i)),
                      );
                    },
                  ),
                ),
                // `.cv-tabs-add`: dashed "+ Add column" footer.
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: _AddColumnButton(
                    c: c,
                    width: double.infinity,
                    height: 44,
                    onTap: () =>
                        Navigator.of(context).pop(const _TabsResult.add()),
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

/// A single `.cv-tab` row in the tabs sheet: drag handle + icon + title + close,
/// active rows get a primary border (`styles-columns.css:690-755`).
class _TabRow extends StatelessWidget {
  const _TabRow({
    super.key,
    required this.index,
    required this.active,
    required this.icon,
    required this.title,
    required this.onTap,
    required this.onClose,
  });

  final int index;
  final bool active;
  final Widget icon;
  final String title;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      // `.cv-tab` margin-bottom 6.
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.white.withValues(alpha: 0.03),
        shape: RoundedRectangleBorder(
          borderRadius: NymRadius.rsm,
          side: BorderSide(color: active ? c.primary : c.glassBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            // `.cv-tab` padding 10, gap 10.
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                // `.cv-tab-handle` (6-dot grip).
                ReorderableDragStartListener(
                  index: index,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CustomPaint(
                        painter: _SixDotPainter(color: c.textDim),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(width: 24, height: 24, child: Center(child: icon)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.secondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                // `.cv-tab-close` (text-dim → danger on hover).
                IconButton(
                  tooltip: 'Remove column',
                  icon: Icon(Icons.close, size: 16, color: c.textDim),
                  hoverColor: c.danger.withValues(alpha: 0.12),
                  onPressed: onClose,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The per-column typing indicator (`.typing-indicator.cv-typing`): hidden
/// (height 0 / opacity 0) until someone is typing, then animates to a 24px-tall
/// row (`padding 4px 20px`, 12px text-dim, bg `rgba(0,0,0,0.15)`) showing up to
/// 3 overlapping 18px avatars + "X is typing" / "X and Y are typing" /
/// "N people are typing" (`_renderTypingInto`, `styles-features.css:4227`).
class _TypingRow extends ConsumerWidget {
  const _TypingRow({required this.pubkeys});
  final List<String> pubkeys;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final active = pubkeys.isNotEmpty;
    final app = ref.watch(appStateProvider);

    String nymOf(String pk) {
      final u = app.users[pk];
      final nym = u?.nym;
      return (nym != null && nym.isNotEmpty) ? nym : 'Someone';
    }

    final style = TextStyle(color: c.textDim, fontSize: 12, height: 1);

    Widget content;
    if (!active) {
      content = const SizedBox.shrink();
    } else {
      final visible = pubkeys.take(3).toList();
      final String text;
      if (pubkeys.length == 1) {
        text = '${nymOf(pubkeys[0])} is typing';
      } else if (pubkeys.length == 2) {
        text = '${nymOf(pubkeys[0])} and ${nymOf(pubkeys[1])} are typing';
      } else {
        text = '${pubkeys.length} people are typing';
      }
      content = Padding(
        // `.typing-indicator.active` padding: 4px 20px (trimmed to 3px vertical
        // so the 18px avatars sit inside the 24px row without overflow).
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 3),
        child: Row(
          children: [
            // `.typing-indicator-avatars`: 18px round, +img margin-left -6.
            for (var i = 0; i < visible.length; i++)
              Transform.translate(
                offset: Offset(-6.0 * i, 0),
                child: NymAvatar(
                  seed: nymOf(visible[i]),
                  size: 18,
                  imageUrl: app.users[visible[i]]?.profile?.picture,
                ),
              ),
            // The avatars overlap by 6px each (Transform doesn't shrink layout),
            // so claw back the shifted gap before the 8px text gap.
            if (visible.isNotEmpty)
              SizedBox(
                  width: (8 - 6.0 * (visible.length - 1)).clamp(0, 8).toDouble()),
            Expanded(child: Text(text, style: style, maxLines: 1)),
          ],
        ),
      );
    }

    // Animate the 0↔24 height + opacity, matching the CSS transition.
    return ClipRect(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
        height: active ? 24 : 0,
        width: double.infinity,
        color: Colors.black.withValues(alpha: 0.15),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: active ? 1 : 0,
          child: content,
        ),
      ),
    );
  }
}

/// `.cv-scroll-bottom`: 36×36 circle, glassBg fill, 1px border, primary chevron,
/// shadow-md, hover scale 1.1 (gap F10).
class _ScrollBottomButton extends StatefulWidget {
  const _ScrollBottomButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_ScrollBottomButton> createState() => _ScrollBottomButtonState();
}

class _ScrollBottomButtonState extends State<_ScrollBottomButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.1 : 1.0,
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover ? c.primaryA(0.15) : c.glassBg,
              shape: BoxShape.circle,
              border: Border.all(
                color: _hover ? c.primaryA(0.30) : c.glassBorder,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  offset: const Offset(0, 4),
                  blurRadius: 16,
                ),
              ],
            ),
            child: Icon(Icons.keyboard_arrow_down, size: 20, color: c.primary),
          ),
        ),
      ),
    );
  }
}

/// The dashed "+ Add column" affordance (`.cv-add-column` / `.cv-tabs-add`).
/// Hover (desktop) swaps the border/label to primary and fills primary@0.04
/// (F24). Width/height are configurable so it can serve the 220px strip tile,
/// the full-width mobile carousel page, and the 44px tabs-sheet footer.
class _AddColumnButton extends StatefulWidget {
  const _AddColumnButton({
    required this.c,
    required this.onTap,
    this.width = _CvDimens.addColumn,
    this.height,
  });

  final NymColors c;
  final VoidCallback onTap;
  final double width;
  final double? height;

  @override
  State<_AddColumnButton> createState() => _AddColumnButtonState();
}

class _AddColumnButtonState extends State<_AddColumnButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final borderColor = _hover ? c.primary : c.glassBorder;
    final labelColor = _hover ? c.textBright : c.textDim;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          key: const Key('cvAddColumn'),
          onTap: widget.onTap,
          borderRadius: NymRadius.rmd,
          child: DottedBorderBox(
            color: borderColor,
            radius: NymRadius.md,
            fill: _hover ? c.primaryA(0.04) : null,
            child: Center(
              child: Text(
                '+ Add column',
                style: TextStyle(
                  color: labelColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A 2px dashed rounded border (the CSS `border: 2px dashed var(--glass-border)`
/// on `.cv-add-column`), with an optional [fill] (hover state, F24).
class DottedBorderBox extends StatelessWidget {
  const DottedBorderBox({
    super.key,
    required this.child,
    required this.color,
    required this.radius,
    this.fill,
  });

  final Widget child;
  final Color color;
  final double radius;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(color: color, radius: radius, fill: fill),
      child: child,
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius, this.fill});

  final Color color;
  final double radius;
  final Color? fill;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(1, 1, size.width - 2, size.height - 2),
      Radius.circular(radius),
    );
    if (fill != null) {
      canvas.drawRRect(rrect, Paint()..color = fill!);
    }
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path()..addRRect(rrect);
    const dash = 6.0, gap = 4.0;
    for (final metric in path.computeMetrics()) {
      double dist = 0;
      while (dist < metric.length) {
        canvas.drawPath(
          metric.extractPath(dist, dist + dash),
          paint,
        );
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color || old.radius != radius || old.fill != fill;
}
