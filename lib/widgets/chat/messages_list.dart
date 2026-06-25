import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// The scrolling message list (`.messages-container`, column-reverse). Renders
/// `messagesForCurrentViewProvider` newest-at-bottom via a reversed ListView,
/// supporting both IRC and bubble layouts. Bubble mode groups consecutive
/// same-author messages within 5 minutes (collapse name + tail). Inline poll
/// cards (`pollsForCurrentViewProvider`) are interleaved by `createdAt`.
/// (docs/specs/02 §6, docs/specs/03 §2.7)
class MessagesList extends ConsumerWidget {
  const MessagesList({super.key});

  static const int _groupWindowSec = 300; // 5 min

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    // Reversed list: index 0 = newest at the bottom; the typing row is pinned
    // below the newest message, above the composer (`.typing-indicator`).
    return ColoredBox(
      color: containerColor,
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
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
