import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../state/app_state.dart';
import '../common/nym_avatar.dart';

/// The `.typing-indicator` row pinned at the bottom of the active conversation
/// (`_renderTypingInto`, `styles-features.css:4227`): hidden (height 0 / opacity
/// 0) until a peer is typing, then animates to a 24px row showing up to three
/// overlapping 18px avatars + "X is typing" / "X and Y are typing" / "N people
/// are typing".
///
/// Reads `AppState.typing` (`<storageKey>|<pubkey>` → expiry ms) directly with a
/// live clock so the indicator self-expires even when no other state changes,
/// matching the PWA's per-peer typing timeout.
class TypingIndicatorRow extends ConsumerStatefulWidget {
  const TypingIndicatorRow({super.key});

  @override
  ConsumerState<TypingIndicatorRow> createState() => _TypingIndicatorRowState();
}

class _TypingIndicatorRowState extends ConsumerState<TypingIndicatorRow> {
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Pubkeys typing in the active view (non-expired), computed against `now` so
  /// the row hides the instant an indicator lapses.
  List<String> _activeTypers(AppState app) {
    final prefix = '${app.view.storageKey}|';
    final now = DateTime.now().millisecondsSinceEpoch;
    final out = <String>[];
    app.typing.forEach((k, expiry) {
      if (k.startsWith(prefix) && expiry > now) out.add(k.substring(prefix.length));
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final app = ref.watch(appStateProvider);
    final pubkeys = _activeTypers(app);
    final active = pubkeys.isNotEmpty;

    // While anyone is typing, re-evaluate every second so the row animates out
    // when the last indicator expires (no incoming event would otherwise tick).
    if (active) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }

    String nymOf(String pk) {
      final nym = app.users[pk]?.nym;
      return (nym != null && nym.isNotEmpty) ? nym : 'Someone';
    }

    Widget content = const SizedBox.shrink();
    if (active) {
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
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 3),
        child: Row(
          children: [
            // `.typing-indicator-avatars`: 18px round, overlapping by 6px.
            for (var i = 0; i < visible.length; i++)
              Transform.translate(
                offset: Offset(-6.0 * i, 0),
                child: NymAvatar(
                  seed: visible[i],
                  size: 18,
                  imageUrl: app.users[visible[i]]?.profile?.picture,
                ),
              ),
            if (visible.isNotEmpty)
              SizedBox(
                width: (8 - 6.0 * (visible.length - 1)).clamp(0, 8).toDouble()),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: c.textDim, fontSize: 12, height: 1),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
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
