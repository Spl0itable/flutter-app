import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/message.dart';
import '../../models/settings.dart';
import 'translate_service.dart';

/// Lifecycle of a single message's auto-translation.
enum AutoTranslateStatus {
  /// Translation request is in flight; render the original meanwhile.
  loading,

  /// Translated text is ready and differs from the original — show it.
  ready,

  /// The message is already in the target language (or there was nothing to
  /// translate). Render the original with NO translation icon and, crucially,
  /// no "already in language" notice — auto-translate stays silent for these.
  noop,

  /// The request failed; fall back to the original silently.
  error,
}

/// One cached auto-translation, keyed by message id in [AutoTranslateNotifier].
class AutoTranslateEntry {
  const AutoTranslateEntry({
    required this.status,
    required this.source,
    required this.target,
    this.translated = '',
    this.detected = 'auto',
  });

  final AutoTranslateStatus status;

  /// The original message content this entry was computed from — lets the
  /// notifier invalidate when a message is edited.
  final String source;

  /// The target language this was translated into — lets the notifier
  /// invalidate when the user changes their translation language.
  final String target;

  /// The translated text (only meaningful when [status] is [ready]).
  final String translated;

  /// The upstream-detected source language (`auto` when unknown).
  final String detected;

  bool get isReady => status == AutoTranslateStatus.ready;
}

/// Automatically translates incoming messages in the active conversation into
/// the user's [Settings.translateLanguage], caching each result by message id
/// so a given message is only ever sent to the proxy once (scrolling back does
/// not re-request it).
///
/// Rows drive it lazily: a [MessageRow] that is eligible (auto-translate on,
/// the message's conversation type gated in, not the user's own message) calls
/// [ensure] as it builds, so only messages actually on screen in the viewed
/// conversation are translated — this is what keeps the proxy from being asked
/// to translate entire channel histories at once.
class AutoTranslateNotifier
    extends StateNotifier<Map<String, AutoTranslateEntry>> {
  AutoTranslateNotifier({TranslateService? service})
      : _service = service ?? TranslateService(),
        super(const {});

  final TranslateService _service;

  /// Keys (`id::target`) with a request in flight, so concurrent rebuilds of
  /// the same row don't fire duplicate proxy calls.
  final Set<String> _inflight = {};

  /// The cached entry for [messageId], but only if it still matches the current
  /// [target] language and [source] content; otherwise null (stale → re-fetch).
  AutoTranslateEntry? entryFor(String messageId, String target, String source) {
    final e = state[messageId];
    if (e == null) return null;
    if (e.target != target || e.source != source) return null;
    return e;
  }

  /// Ensures [message] is (or is being) translated into [target]. A no-op when
  /// there's no target, nothing to translate, or a matching cache entry already
  /// exists. Safe to call every build.
  void ensure(Message message, String target) {
    if (target.isEmpty) return;
    final source = message.content;
    if (source.trim().isEmpty) return;
    final existing = state[message.id];
    if (existing != null &&
        existing.target == target &&
        existing.source == source) {
      return; // already cached (or loading) for this exact input
    }
    final key = '${message.id}::$target';
    if (_inflight.contains(key)) return;
    _inflight.add(key);
    state = {
      ...state,
      message.id: AutoTranslateEntry(
        status: AutoTranslateStatus.loading,
        source: source,
        target: target,
      ),
    };
    _run(message.id, source, target, key);
  }

  Future<void> _run(
    String messageId,
    String source,
    String target,
    String key,
  ) async {
    try {
      final res = await _service.translate(source, target);
      final translated = res.translatedText.trim();
      // "Already in the target language" — detected == target, or the upstream
      // returned the input unchanged. Treated as a silent no-op (no icon, no
      // error), so the proxy result for a same-language message just renders
      // the original.
      final noop = translated.isEmpty ||
          translated == source.trim() ||
          (res.detectedLanguage != 'auto' && res.detectedLanguage == target);
      _set(
        messageId,
        AutoTranslateEntry(
          status: noop ? AutoTranslateStatus.noop : AutoTranslateStatus.ready,
          source: source,
          target: target,
          translated: res.translatedText,
          detected: res.detectedLanguage,
        ),
      );
    } catch (_) {
      _set(
        messageId,
        AutoTranslateEntry(
          status: AutoTranslateStatus.error,
          source: source,
          target: target,
        ),
      );
    } finally {
      _inflight.remove(key);
    }
  }

  /// Commits an entry only if it still reflects the latest requested input —
  /// guards against a stale in-flight result clobbering a newer edit/target.
  void _set(String messageId, AutoTranslateEntry entry) {
    if (!mounted) return;
    final current = state[messageId];
    if (current != null &&
        current.status == AutoTranslateStatus.loading &&
        (current.source != entry.source || current.target != entry.target)) {
      return;
    }
    state = {...state, messageId: entry};
  }
}

final autoTranslateProvider =
    StateNotifierProvider<AutoTranslateNotifier, Map<String, AutoTranslateEntry>>(
  (ref) => AutoTranslateNotifier(),
);

/// Whether auto-translate is enabled AND gated in for [message]'s conversation
/// type (public channel / PM / group), per [settings]. Own messages and
/// system/action rows are never auto-translated. Callers must still check that
/// a target language is set.
bool autoTranslateAppliesTo(Message message, Settings settings) {
  if (!settings.autoTranslate) return false;
  if (message.isOwn) return false;
  if (message.isSystemRow) return false;
  if (message.isGroup) return settings.autoTranslateGroups;
  if (message.isPM) return settings.autoTranslatePMs;
  // Neither PM nor group ⇒ a public channel message.
  return settings.autoTranslateChannels;
}
