import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../wallpaper/wallpaper_layer.dart';

/// Fixed dimensions from `css/styles-columns.css`.
class _CvDimens {
  static const double column = 360; // .cv-column flex-basis/width
  static const double addColumn = 220; // .cv-add-column width
  static const double gap = 12; // .cv-strip gap
  static const double padding = 12; // .cv-strip padding
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
        groupId = '';
  const _ColumnDesc.pm(this.pubkey)
      : kind = _ColumnKind.pm,
        channel = '',
        geohash = '',
        groupId = '';
  const _ColumnDesc.group(this.groupId)
      : kind = _ColumnKind.group,
        channel = '',
        geohash = '',
        pubkey = '';

  final _ColumnKind kind;
  final String channel;
  final String geohash;
  final String pubkey;
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

  @override
  bool operator ==(Object other) =>
      other is _ColumnDesc && other.kind == kind && other.key == key;

  @override
  int get hashCode => Object.hash(kind, key);
}

/// The deck / multi-column view (`#columnsStrip .cv-strip`), shown when
/// `settings.chatViewMode == 'columns'`.
///
/// A horizontally-scrollable strip of 360px-wide columns — channel, PM, or
/// group (gap F1) — each a header (icon + title + unread badge + close) over a
/// compact reversed message list with a scroll-to-bottom affordance (gap F10),
/// ending in a 220px dashed "+ Add column". Seeded from `#nymchat` + the most
/// recent PM + the most recent group (`_cvSeedDefaults`). When
/// `settings.columnsWallpaper` is on, the per-column backgrounds go transparent
/// so the [WallpaperLayer] behind the deck shows through (`.columns-wallpaper`).
///
/// DEFERRED (gap F4/F5): desktop drag-to-reorder + the mobile snap carousel /
/// header-dots / pager / tabs sheet. See the TODO in [build].
class ColumnsDeck extends ConsumerStatefulWidget {
  const ColumnsDeck({super.key});

  @override
  ConsumerState<ColumnsDeck> createState() => _ColumnsDeckState();
}

class _ColumnsDeckState extends ConsumerState<ColumnsDeck> {
  /// The columns currently shown. Seeded on first build (`_cvSeedDefaults`).
  final List<_ColumnDesc> _columns = [];
  bool _seeded = false;

  void _seedIfNeeded(
    List<ChannelEntry> channels,
    List<PMConversation> pms,
    List<Group> groups,
    bool pmOnly,
  ) {
    if (_seeded) return;
    _seeded = true;
    // PWA `_cvSeedDefaults`: #nymchat (unless PM-only) + most-recent PM + group.
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
      _columns.add(_ColumnDesc.pm(pms.first.pubkey));
    }
    if (groups.isNotEmpty) {
      final g = [...groups]
        ..sort((a, b) => b.lastMessageTime - a.lastMessageTime);
      _columns.add(_ColumnDesc.group(g.first.id));
    }
  }

  void _removeColumn(_ColumnDesc desc) {
    setState(() => _columns.remove(desc));
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
      for (final pm in pms) _ColumnDesc.pm(pm.pubkey),
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
      setState(() => _columns.add(picked));
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
            : (app.users[d.pubkey]?.nym ?? 'Direct message');
      case _ColumnKind.group:
        final g = app.groups.where((g) => g.id == d.groupId).toList();
        return (g.isNotEmpty && g.first.name.isNotEmpty)
            ? g.first.name
            : 'Group chat';
    }
  }

  /// Resolves a column's header icon (`_cvColIcon`): `#` glyph for channels, a
  /// 20px PM/group avatar otherwise.
  Widget _columnIcon(BuildContext context, _ColumnDesc d, {double size = 20}) {
    final c = context.nym;
    final app = ref.read(appStateProvider);
    switch (d.kind) {
      case _ColumnKind.channel:
        return Icon(Icons.tag, size: 18, color: c.secondary);
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
        return Icon(Icons.groups_outlined, size: 18, color: c.secondary);
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
    final unread = ref.watch(unreadCountsProvider);
    _seedIfNeeded(channels, pms, groups, pmOnly);

    // TODO(ui-parity): gap F4/F5 — add desktop column drag-to-reorder (6-dot
    // grip, `_cvAttachDnd`) and the mobile (<=768) snap carousel (PageView,
    // header position dots, pager, "Columns" tabs bottom-sheet,
    // `_cvRebuildHeaderDots`/`_cvOpenTabsView`). Today every width renders the
    // same horizontal 360px-column scroller.

    return Container(
      key: const Key('columnsStrip'),
      color: Colors.transparent,
      padding: const EdgeInsets.all(_CvDimens.padding),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final desc in _columns) ...[
              _DeckColumn(
                desc: desc,
                title: _columnTitle(context, desc),
                icon: _columnIcon(context, desc),
                unread: unread[desc.key] ?? 0,
                transparent: transparentColumns,
                onClose: () => _removeColumn(desc),
              ),
              const SizedBox(width: _CvDimens.gap),
            ],
            _AddColumnButton(
              c: c,
              onTap: () => _openAddColumn(channels, pms, groups, pmOnly),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single deck column (`.cv-column`): 360px wide, header + compact message
/// list for one channel / PM / group.
class _DeckColumn extends ConsumerStatefulWidget {
  const _DeckColumn({
    required this.desc,
    required this.title,
    required this.icon,
    required this.unread,
    required this.transparent,
    required this.onClose,
  });

  final _ColumnDesc desc;
  final String title;
  final Widget icon;
  final int unread;
  final bool transparent;
  final VoidCallback onClose;

  @override
  ConsumerState<_DeckColumn> createState() => _DeckColumnState();
}

class _DeckColumnState extends ConsumerState<_DeckColumn> {
  final ScrollController _scroll = ScrollController();
  bool _atBottom = true;

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
    // Reversed list: offset 0 == newest at the bottom.
    final atBottom = _scroll.offset <= 24;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
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
    final settings = ref.watch(settingsProvider);
    final app = ref.watch(appStateProvider);
    final reactions = ref.watch(reactionsProvider);
    final messages = [...(app.messages[widget.desc.storageKey] ?? const <Message>[])];
    messages.sort(compareMessages);

    return SizedBox(
      width: _CvDimens.column,
      child: Container(
        decoration: BoxDecoration(
          color: transparent ? Colors.transparent : c.bgSecondary,
          borderRadius: NymRadius.rmd,
          border: Border.all(color: c.glassBorder),
          // .cv-column box-shadow: --shadow-md (0 4px 16px black@0.4).
          boxShadow: transparent
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
            // .cv-column-header (padding 10/12, bottom border, gap 8).
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: transparent ? Colors.transparent : c.glassBg,
                border: Border(bottom: BorderSide(color: c.glassBorder)),
              ),
              child: Row(
                children: [
                  widget.icon,
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.secondary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // .cv-col-unread (gap F9).
                  if (widget.unread > 0) ...[
                    _CvUnreadPill(count: widget.unread),
                    const SizedBox(width: 8),
                  ],
                  IconButton(
                    tooltip: 'Remove column',
                    icon: Icon(Icons.close, size: 16, color: c.textDim),
                    onPressed: widget.onClose,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            // .cv-column-scroller / .cv-list (padding 10) + scroll-to-bottom.
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: messages.isEmpty
                        ? Center(
                            child: Text('No messages yet',
                                style:
                                    TextStyle(color: c.textDim, fontSize: 12)),
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
                  // not at bottom (gap F10).
                  if (!_atBottom && messages.isNotEmpty)
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: _ScrollBottomButton(onTap: _scrollToBottom),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `.cv-col-unread`: bg primary, color bg, pill, 10px w600, tabular-nums (F9).
class _CvUnreadPill extends StatelessWidget {
  const _CvUnreadPill({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      constraints: const BoxConstraints(minWidth: 24),
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

/// The dashed "+ Add column" affordance (`.cv-add-column`): 220px wide. Hover
/// (desktop) swaps the border/label to primary and fills primary@0.04 (F24).
class _AddColumnButton extends StatefulWidget {
  const _AddColumnButton({required this.c, required this.onTap});

  final NymColors c;
  final VoidCallback onTap;

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
      width: _CvDimens.addColumn,
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
