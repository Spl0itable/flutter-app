import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/theme/nym_colors.dart';
import '../../features/polls/poll_card.dart';
import '../../features/reactions/reaction_picker.dart';
import '../../models/message.dart';
import '../../models/poll.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import 'message_row.dart';
import 'message_skeleton.dart';
import 'typing_indicator.dart';

/// Scroll-to-a-specific-message handle for the active [MessagesList], shared via
/// [messageListScrollerProvider] so the blockquote tap (in `message_content.dart`)
/// can jump the list to a quoted source message — the infrastructure behind the
/// PWA's `_scrollToQuotedMessage` (`target.scrollIntoView({block:'center'})`,
/// messages.js:2768-2774). The list reverses (newest at index 0), and items are
/// built lazily, so a plain `ListView` can't land on an off-screen message — this
/// wraps the package's [ItemScrollController] and a live message-id → render-index
/// map the list republishes on every build.
class MessageListScroller {
  ItemScrollController? _controller;

  /// message id → reversed render-unit index (the `ScrollablePositionedList`
  /// index), rebuilt by [MessagesList] each build for the current view.
  Map<String, int> _indexById = const {};

  /// Called by [MessagesList] every build to (re)bind its controller + the
  /// current id→index map.
  void bind(ItemScrollController controller, Map<String, int> indexById) {
    _controller = controller;
    _indexById = indexById;
  }

  /// Whether [messageId] is in the currently-rendered set (so a jump can land).
  bool canScrollTo(String messageId) =>
      _indexById.containsKey(messageId) && (_controller?.isAttached ?? false);

  /// Smooth-scrolls the list so [messageId] sits ~centered (PWA `block:'center'`).
  /// No-ops when the message isn't in the loaded set or the list isn't attached
  /// (the PWA likewise bails — "Original message is not available" — when the
  /// target can't be found). Returns true when a scroll was issued.
  bool scrollToMessage(String messageId) {
    final index = _indexById[messageId];
    final controller = _controller;
    if (index == null || controller == null || !controller.isAttached) {
      return false;
    }
    controller.scrollTo(
      index: index,
      // Leading-edge fraction of the viewport — ~0.4 lands the message a little
      // above center, the closest analogue to `scrollIntoView({block:'center'})`.
      alignment: 0.4,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
    return true;
  }
}

/// The shared [MessageListScroller] for the mounted message list. A plain
/// `Provider` (single instance for the app's lifetime); [MessagesList] binds its
/// controller into it on build.
final messageListScrollerProvider =
    Provider<MessageListScroller>((ref) => MessageListScroller());

/// The scrolling message list (`.messages-container`, column-reverse). Renders
/// `messagesForCurrentViewProvider` newest-at-bottom via a reversed ListView,
/// supporting both IRC and bubble layouts. Bubble mode groups consecutive
/// same-author messages within 5 minutes (collapse name + tail). Inline poll
/// cards (`pollsForCurrentViewProvider`) are interleaved by `createdAt`.
/// (docs/specs/02 §6, docs/specs/03 §2.7)
class MessagesList extends ConsumerStatefulWidget {
  const MessagesList({super.key});

  @override
  ConsumerState<MessagesList> createState() => _MessagesListState();
}

class _MessagesListState extends ConsumerState<MessagesList> {
  static const int _groupWindowSec = 300; // 5 min

  /// Drives [ScrollablePositionedList.scrollTo] for the jump-to-quoted-message
  /// feature; bound into [messageListScrollerProvider] on every build.
  final ItemScrollController _itemScrollController = ItemScrollController();

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final settings = ref.watch(settingsProvider);
    final app = ref.watch(appStateProvider);
    final messages = ref.watch(messagesForCurrentViewProvider);
    final reactions = ref.watch(reactionsProvider);
    final polls = ref.watch(pollsForCurrentViewProvider);

    // `.messages-container`: bg rgba(0,0,0,0.15) dark; light-mode flips it to
    // rgba(255,255,255,0.3) (a light wash over the page), so it must be
    // mode-aware or the message area looks dark-tinted in light mode.
    final containerColor = c.isLight
        ? const Color(0x4DFFFFFF) // white @ 0.3
        : const Color(0x26000000); // black @ 0.15

    if (messages.isEmpty && polls.isEmpty) {
      // PWA shows the shimmer skeleton FIRST while the conversation loads, then
      // settles an empty channel/PM into the "No recent messages" note after a
      // grace period (`messages.js:_showMessageSkeleton` → `_appendEmptyNote`,
      // `.msg-skeleton` / `.msg-empty-note`). An arriving message clears the
      // empty branch entirely (this widget no longer renders). The typing row
      // still animates in below for an empty PM/group where the peer is typing.
      return ColoredBox(
        color: containerColor,
        child: Column(
          children: [
            Expanded(
              // Keyed on the active view so re-entering a conversation re-runs
              // the shimmer-then-settle grace period.
              child: _EmptyOrLoading(
                key: ValueKey(app.view),
                useBubbles: settings.useBubbles,
              ),
            ),
            const TypingIndicatorRow(),
          ],
        ),
      );
    }

    final mentionToken = '@${_baseNym(app.selfNym)}';

    // Merge messages + polls into one chronological list (oldest first), each
    // message carrying its resolved reactions + mention flag.
    final merged = <_ListEntry>[
      for (final m in messages)
        _MsgEntry(MessageGroupEntry(
          message: m,
          reactions: reactions[m.id] ?? const [],
          mentioned: !m.isOwn && m.content.contains(mentionToken),
        )),
      for (final p in polls) _PollEntry(p),
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    // Fold consecutive same-author bubble messages into render groups (the PWA's
    // `.message-group`), so the group's single avatar can span and glide over the
    // whole run. The fold runs over the MERGED order, so an interleaved poll — or
    // a system / `/me` row — correctly breaks a same-author run (PWA
    // `_rewrapBubbleGroups` resets the current group on any non-message or poll).
    // Polls render standalone; in IRC mode `_groupsWith` is gated off so every
    // message is its own (bare) group.
    final units = <_RenderUnit>[];
    for (final e in merged) {
      if (e is _PollEntry) {
        units.add(_PollUnit(e.poll));
        continue;
      }
      final entry = (e as _MsgEntry).entry;
      final last = units.isNotEmpty ? units.last : null;
      if (settings.useBubbles &&
          last is _GroupUnit &&
          _groupsWith(last.entries.last.message, entry.message)) {
        last.entries.add(entry);
      } else {
        units.add(_GroupUnit([entry]));
      }
    }

    // Publish a message-id → reversed-render-index map so the blockquote tap can
    // jump to a quoted source message (`ScrollablePositionedList.scrollTo`). The
    // reversed list uses index 0 = newest at the bottom, so a unit at forward
    // position `f` lives at reversed index `units.length - 1 - f`; every message
    // inside a group maps to that same unit index.
    final indexById = <String, int>{};
    for (var f = 0; f < units.length; f++) {
      final unit = units[f];
      if (unit is _GroupUnit) {
        final revIndex = units.length - 1 - f;
        for (final entry in unit.entries) {
          indexById[entry.message.id] = revIndex;
        }
      }
    }
    ref.read(messageListScrollerProvider).bind(_itemScrollController, indexById);

    // Reversed list: index 0 = newest at the bottom; the typing row is pinned
    // below the newest message, above the composer (`.typing-indicator`).
    // ScrollablePositionedList (vs a plain ListView) is what lets the quote tap
    // land on an OFF-SCREEN, lazily-built message via `scrollTo(index:…)`.
    return ColoredBox(
      color: containerColor,
      child: Column(
        children: [
          Expanded(
            child: ScrollablePositionedList.builder(
              itemScrollController: _itemScrollController,
              reverse: true,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              itemCount: units.length,
              itemBuilder: (context, revIndex) {
                final unit = units[units.length - 1 - revIndex];
                if (unit is _PollUnit) {
                  return PollCard(poll: unit.poll, settings: settings);
                }
                return MessageGroup(
                  entries: (unit as _GroupUnit).entries,
                  settings: settings,
                  onReactionPicker: (msg) =>
                      showReactionPicker(context, ref, msg),
                );
              },
            ),
          ),
          const TypingIndicatorRow(),
        ],
      ),
    );
  }

  /// Whether [cur] bubble-groups onto [prev]: same author within the 5-minute
  /// window, neither a system pill nor a `/me` action. (Polls are filtered out
  /// before this is reached, so they never merge.)
  bool _groupsWith(Message prev, Message cur) =>
      !prev.isSystemRow &&
      !cur.isSystemRow &&
      !prev.isMeAction &&
      !cur.isMeAction &&
      prev.pubkey == cur.pubkey &&
      (cur.createdAt - prev.createdAt).abs() <= _groupWindowSec;

  String _baseNym(String nym) {
    final hash = nym.indexOf('#');
    return hash > 0 ? nym.substring(0, hash) : nym;
  }
}

/// The empty-conversation surface: the shimmer [MessageSkeleton] while history
/// is plausibly still loading, settling into the centered "No recent messages"
/// note after a grace period — a 1:1 port of the PWA's `_showMessageSkeleton`
/// (shimmer) → `_appendEmptyNote` (note) flow with the same ~3s settle timer
/// (`messages.js:3030`, `this._msgSkeletonSettleMs || 3000`). Recreated (via a
/// view-keyed instance in [MessagesList]) each time an empty conversation is
/// opened, so the shimmer plays on every entry. Once a message arrives the
/// empty branch stops rendering, which removes this widget — matching the PWA
/// where an incoming message clears the skeleton/note immediately.
class _EmptyOrLoading extends StatefulWidget {
  const _EmptyOrLoading({super.key, required this.useBubbles});

  final bool useBubbles;

  @override
  State<_EmptyOrLoading> createState() => _EmptyOrLoadingState();
}

class _EmptyOrLoadingState extends State<_EmptyOrLoading> {
  // `this._msgSkeletonSettleMs || 3000`.
  static const _settle = Duration(seconds: 3);

  Timer? _timer;
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_settle, () {
      if (mounted) setState(() => _settled = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_settled) {
      return MessageSkeleton(useBubbles: widget.useBubbles);
    }
    final c = context.nym;
    return Center(
      child: Text(
        'No recent messages',
        style: TextStyle(color: c.textDim, fontSize: 13),
      ),
    );
  }
}

/// A merged conversation entry, used only to interleave messages + polls in
/// chronological order before folding into render units.
sealed class _ListEntry {
  int get createdAt;
}

class _MsgEntry extends _ListEntry {
  _MsgEntry(this.entry);
  final MessageGroupEntry entry;
  @override
  int get createdAt => entry.message.createdAt;
}

class _PollEntry extends _ListEntry {
  _PollEntry(this.poll);
  final Poll poll;
  @override
  int get createdAt => poll.createdAt;
}

/// A render unit in the reversed list: either a standalone poll card or a
/// same-author [MessageGroup] (one or more messages sharing a sticky avatar).
sealed class _RenderUnit {}

class _PollUnit extends _RenderUnit {
  _PollUnit(this.poll);
  final Poll poll;
}

class _GroupUnit extends _RenderUnit {
  _GroupUnit(this.entries);
  final List<MessageGroupEntry> entries;
}
