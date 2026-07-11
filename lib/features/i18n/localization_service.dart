import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../services/api/api_client.dart';
import '../../services/storage/key_value_store.dart';
import '../translate/translate_service.dart';

/// App-wide **static text** localization, distinct from the on-the-fly message
/// translation ([TranslateService], which localizes user chat content).
///
/// The app ships its UI text in English (the source of truth lives inline in
/// the widget tree). Rather than hand-author ARB catalogs for the ~130
/// languages the message translator already supports, this service localizes
/// the UI at runtime by routing each English source string through the SAME
/// backend translate proxy the message translator uses, then caching the
/// result **per language** on-device so a given string is only ever translated
/// once.
///
/// ## How call sites use it
///
/// Every user-facing literal is wrapped with the top-level [tr] helper
/// (`i18n.dart`), e.g. `Text(tr('Settings'))` or, with interpolation,
/// `tr('Step {n} of {total}', {'n': i + 1, 'total': count})`. [tr] delegates
/// to [LocalizationService.instance.translate].
///
/// ## Reactivity
///
/// [translate] is synchronous: it returns the cached translation when present,
/// otherwise the English source **immediately** (so the UI never blocks) and
/// enqueues the string for background translation. When a batch of
/// translations lands, [onChanged] fires; the root widget bumps a Riverpod
/// version provider it watches, rebuilding the whole tree so the freshly
/// cached strings render. This means individual widgets need not be
/// `Consumer`s to become localized — the rebuild flows from the root.
///
/// ## English is a no-op
///
/// When the selected language is empty or `en`, [translate] returns the source
/// verbatim (after placeholder substitution) and never touches the network, so
/// the default experience — and every widget test that doesn't configure a
/// language — is unchanged.
class LocalizationService {
  LocalizationService._();

  /// The process-wide instance. A plain singleton (not a provider) so [tr] can
  /// be a bare top-level function callable from any widget, Consumer or not.
  static final LocalizationService instance = LocalizationService._();

  /// Storage-key prefix for a per-language cache blob (`nym_ui_i18n_<lang>`),
  /// a JSON object mapping English source → translated string.
  static const String _cachePrefix = 'nym_ui_i18n_';

  KeyValueStore? _kv;
  TranslateService? _translator;

  /// The active UI language code (e.g. `es`, `zh-tw`). Empty or `en` ⇒ English
  /// source is shown verbatim and nothing is translated.
  String _lang = '';
  String get language => _lang;

  /// Whether a non-English language is active.
  bool get isActive => _lang.isNotEmpty && _lang != 'en';

  /// English source → translated string, for the [_lang] currently loaded.
  final Map<String, String> _cache = {};

  /// Every English source [translate] has ever been asked for, so that on a
  /// language switch we can proactively translate the strings already on
  /// screen (the rest fill in on demand as new screens are visited).
  final Set<String> _seen = {};

  /// Sources awaiting a background translation pass (misses not yet requested).
  final Set<String> _pending = {};

  /// Sources with an in-flight or completed request, so we never re-request
  /// the same string within a language session.
  final Set<String> _requested = {};

  Timer? _debounce;
  bool _flushing = false;

  /// Fires after a batch of translations is cached, so the host can trigger a
  /// rebuild (root widget bumps its version provider). Set by the root widget.
  VoidCallback? onChanged;

  /// Wires the backing store + translator and loads the initial [language]'s
  /// cache. Safe to call more than once (idempotent per language); the root
  /// widget calls this at boot with the persisted UI-language setting.
  void configure({
    required KeyValueStore kv,
    required String language,
    ApiClient? apiClient,
  }) {
    _kv = kv;
    _translator ??= TranslateService(api: apiClient ?? ApiClient());
    setLanguage(language);
  }

  /// Switches the active UI language: loads that language's on-device cache and
  /// kicks a background pass over every already-seen source so the current
  /// screen localizes without waiting to be revisited. A no-op when [code] is
  /// already active. Passing `''`/`en` returns the app to English instantly.
  void setLanguage(String code) {
    final next = code.trim();
    if (next == _lang) return;
    _lang = next;
    _cache.clear();
    _requested.clear();
    _pending.clear();
    if (!isActive) {
      // English: nothing to load or translate; just repaint.
      onChanged?.call();
      return;
    }
    _loadCache();
    // Re-translate anything already rendered so the switch is visible at once.
    for (final s in _seen) {
      if (!_cache.containsKey(s)) _pending.add(s);
    }
    _scheduleFlush();
    onChanged?.call();
  }

  /// Returns the localized form of [source] for the active language, applying
  /// `{name}` placeholder substitution from [args] afterwards.
  ///
  /// Synchronous and non-blocking: on a cache miss it returns the English
  /// [source] now and schedules a background translation; the eventual
  /// [onChanged] repaint swaps in the translated text.
  String translate(String source, [Map<String, Object?>? args]) {
    if (source.isEmpty) return source;
    _seen.add(source);
    if (!isActive) return _subst(source, args);
    final hit = _cache[source];
    if (hit != null) return _subst(hit, args);
    if (!_requested.contains(source)) {
      _pending.add(source);
      _scheduleFlush();
    }
    // English fallback until the translation lands.
    return _subst(source, args);
  }

  /// Registers [sources] as strings the app is about to render, so a bulk
  /// [pretranslate] pass (and every future language switch) covers them even
  /// before they first appear on screen. Used to pre-translate the onboarding
  /// tutorial the moment a language is chosen — a static overlay that never
  /// rebuilds on its own, so it must be translated up front rather than on
  /// demand. If the active language already has some of these cached, they're
  /// skipped; anything missing is queued.
  void prime(Iterable<String> sources) {
    for (final s in sources) {
      if (s.isEmpty) continue;
      _seen.add(s);
      if (isActive && !_cache.containsKey(s) && !_requested.contains(s)) {
        _pending.add(s);
      }
    }
    if (_pending.isNotEmpty) _scheduleFlush();
  }

  /// Awaitable bulk translation used by the first-run language picker so it can
  /// show progress while the strings already registered are localized before
  /// the user proceeds. Reports progress as `(done, total)`. Completes
  /// immediately for English.
  Future<void> pretranslate({
    Iterable<String>? sources,
    void Function(int done, int total)? onProgress,
  }) async {
    if (!isActive) {
      onProgress?.call(1, 1);
      return;
    }
    final todo = <String>{
      ...(sources ?? _seen),
    }..removeWhere((s) => _cache.containsKey(s) || s.isEmpty);
    final total = todo.length;
    if (total == 0) {
      onProgress?.call(1, 1);
      return;
    }
    todo.forEach(_requested.add);
    var done = 0;
    await _mapPooled(todo.toList(), 8, (s) async {
      await _translateOne(s);
      done++;
      onProgress?.call(done, total);
    });
    _persist();
    onChanged?.call();
  }

  // --- internals ------------------------------------------------------------

  /// Replaces every `{key}` token in [text] with `args[key]` (missing keys are
  /// left intact). No args ⇒ the string is returned unchanged, so plain labels
  /// pay no substitution cost.
  static String _subst(String text, Map<String, Object?>? args) {
    if (args == null || args.isEmpty || !text.contains('{')) return text;
    return text.replaceAllMapped(_rxPlaceholder, (m) {
      final key = m.group(1)!;
      return args.containsKey(key) ? '${args[key]}' : m.group(0)!;
    });
  }

  static final RegExp _rxPlaceholder = RegExp(r'\{(\w+)\}');

  void _loadCache() {
    final kv = _kv;
    if (kv == null) return;
    final raw = kv.getString('$_cachePrefix$_lang');
    if (raw == null || raw.isEmpty) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      map.forEach((k, v) {
        if (v is String) _cache[k] = v;
      });
    } catch (_) {
      // Corrupt blob — discard and rebuild on demand.
    }
  }

  void _persist() {
    final kv = _kv;
    if (kv == null || !isActive) return;
    try {
      kv.setString('$_cachePrefix$_lang', jsonEncode(_cache));
    } catch (_) {}
  }

  void _scheduleFlush() {
    if (_pending.isEmpty || _flushing) return;
    _debounce?.cancel();
    // Coalesce the many `tr()` calls a single screen makes into one batch.
    _debounce = Timer(const Duration(milliseconds: 200), _flush);
  }

  Future<void> _flush() async {
    if (_flushing || !isActive) return;
    final batch = _pending.toList();
    if (batch.isEmpty) return;
    _pending.clear();
    batch.forEach(_requested.add);
    _flushing = true;
    final lang = _lang;
    try {
      await _mapPooled(batch, 8, _translateOne);
    } finally {
      _flushing = false;
    }
    // A language switch mid-flight invalidates these results.
    if (lang != _lang) return;
    _persist();
    onChanged?.call();
    // Anything that missed while we were flushing gets the next pass.
    if (_pending.isNotEmpty) _scheduleFlush();
  }

  /// Translates a single [source] into [_lang] and stores it. Placeholders are
  /// shielded so the upstream can't translate/reorder them.
  Future<void> _translateOne(String source) async {
    final translator = _translator;
    if (translator == null) return;
    final lang = _lang;
    final shielded = _shieldPlaceholders(source);
    try {
      final res = await translator.translate(shielded.text, lang);
      if (lang != _lang) return; // language changed under us
      _cache[source] = _restorePlaceholders(res.translatedText, shielded.tokens);
    } catch (_) {
      // Leave uncached ⇒ English fallback; a later pass may retry.
    }
  }

  /// Runs [action] over [items] with at most [concurrency] in flight.
  static Future<void> _mapPooled<T>(
    List<T> items,
    int concurrency,
    Future<void> Function(T) action,
  ) async {
    var index = 0;
    Future<void> worker() async {
      while (index < items.length) {
        final i = index++;
        await action(items[i]);
      }
    }

    final workers = <Future<void>>[];
    for (var i = 0; i < concurrency && i < items.length; i++) {
      workers.add(worker());
    }
    await Future.wait(workers);
  }

  /// Replaces `{name}` tokens with an ASCII sentinel (`__NYMPH0__`) that survives
  /// machine translation intact, returning the tokens to restore afterwards.
  static _Shield _shieldPlaceholders(String text) {
    if (!text.contains('{')) return _Shield(text, const []);
    final tokens = <String>[];
    final shielded = text.replaceAllMapped(_rxPlaceholder, (m) {
      final idx = tokens.length;
      tokens.add(m.group(0)!); // the whole `{name}`
      return '__NYMPH${idx}__';
    });
    return _Shield(shielded, tokens);
  }

  static final RegExp _rxSentinel = RegExp(r'__NYMPH(\d+)__');

  static String _restorePlaceholders(String text, List<String> tokens) {
    if (tokens.isEmpty) return text;
    return text.replaceAllMapped(_rxSentinel, (m) {
      final idx = int.parse(m.group(1)!);
      return (idx >= 0 && idx < tokens.length) ? tokens[idx] : m.group(0)!;
    });
  }
}

class _Shield {
  const _Shield(this.text, this.tokens);
  final String text;
  final List<String> tokens;
}
