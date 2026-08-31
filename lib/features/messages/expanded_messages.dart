/// Which long message bodies the user expanded past their "Read more" clamp.
///
/// This lived as `_expanded` in the collapsible's own State, which loses it the
/// same two ways [TranslatedMessages] documents: the list is lazy, so a row
/// scrolled out of view is disposed, and an arriving message can re-parent a
/// still-visible row (a second message from the same author turns the group's
/// lone [MessageRow] into a Column of them, rebuilding the subtree). Either way
/// the body snapped shut mid-read. Keyed by the collapsible's own id — the
/// message id for a body, plus a suffix for a separately-clamped quote — it
/// survives both.
library;

import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class ExpandedMessages extends Notifier<Set<String>> {
  /// Bounded, for the same reason [TranslatedMessages] is: a long session in a
  /// busy channel would otherwise hold one entry per expanded body forever.
  static const int _max = 500;

  @override
  Set<String> build() => const {};

  bool isExpanded(String key) => state.contains(key);

  void expand(String key) {
    if (key.isEmpty || state.contains(key)) return;
    final next = LinkedHashSet<String>.from(state)..add(key);
    while (next.length > _max) {
      next.remove(next.first);
    }
    state = next;
  }

  void collapse(String key) {
    if (!state.contains(key)) return;
    state = LinkedHashSet<String>.from(state)..remove(key);
  }

  void toggle(String key, {required bool expanded}) =>
      expanded ? expand(key) : collapse(key);

  void clear() => state = const {};
}

final expandedMessagesProvider =
    NotifierProvider<ExpandedMessages, Set<String>>(ExpandedMessages.new);
