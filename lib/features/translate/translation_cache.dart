import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'translate_service.dart';

/// Results of manual message translations, keyed by the text and the target
/// language that produced them.
///
/// [MessageTranslation] kicks its request off in `initState` and held the
/// Future in its State — which the message list does not preserve. The sliver
/// re-keys its children by index, so an ARRIVING MESSAGE tears down and
/// rebuilds the rows below it; the row came back with a fresh State, `initState`
/// ran again, and an already-translated message flashed "Translating..." and
/// spent another API call re-translating text it had already translated. The
/// same teardown is why `TranslatedMessages` exists for the "is it shown" flag;
/// this is its other half, the result.
///
/// Keyed on (text, target) rather than on a message id because that is what
/// actually determines the answer: the same text translated to the same
/// language is the same translation, whichever row is asking.
class TranslationCache {
  /// Bounded like `TranslatedMessages` — a long session in a busy channel would
  /// otherwise hold one entry per translation for the life of the process.
  static const int max = 500;

  final Map<String, Future<TranslationResult>> _entries = {};

  static String keyFor(String text, String targetLang) => '$targetLang $text';

  /// True when [text] to [targetLang] is already translated or in flight.
  bool has(String text, String targetLang) =>
      _entries.containsKey(keyFor(text, targetLang));

  /// The cached request for [text] to [targetLang], starting one via [start] on
  /// a miss. [onStarted] runs ONLY for a real request, so a caller's per-request
  /// side effects (the "Translation failed" system message) fire once rather
  /// than once per rebuild.
  Future<TranslationResult> resolve(
    String text,
    String targetLang,
    Future<TranslationResult> Function() start, {
    void Function(Future<TranslationResult> future)? onStarted,
  }) {
    final key = keyFor(text, targetLang);
    final existing = _entries[key];
    if (existing != null) {
      // Re-insert so eviction stays least-recently-used.
      _entries.remove(key);
      _entries[key] = existing;
      return existing;
    }
    final future = start();
    _entries[key] = future;
    // A failure must not be cached: the next attempt should re-request rather
    // than replay a stale error for the rest of the session. Swallowed here so
    // this bookkeeping never becomes a second unhandled rejection — callers
    // still see the error through the future they were handed.
    future.then<void>((_) {}, onError: (Object _) {
      if (identical(_entries[key], future)) _entries.remove(key);
    });
    while (_entries.length > max) {
      _entries.remove(_entries.keys.first);
    }
    onStarted?.call(future);
    return future;
  }

  void clear() => _entries.clear();
}

/// Container-scoped so tests are isolated from one another. A plain [Provider]
/// because this is a cache: reading it must never schedule a rebuild.
final translationCacheProvider =
    Provider<TranslationCache>((ref) => TranslationCache());
