import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../services/api/api_client.dart';

/// On-demand message translation routed through the backend `/api/proxy`
/// worker (`?action=translate`), exactly like the PWA (`translate.js`
/// `_doTranslate`). The proxy is always tried first, because it keeps the
/// user's IP away from Google Translate — that is the whole reason it exists.
///
/// It can also fail for reasons that have nothing to do with this user. Google
/// rate-limits the `gtx` endpoint by caller IP, and a Cloudflare Worker
/// egresses from an address shared with every other Worker in its colo, so a
/// busy colo starts collecting HTTP 429 and the proxy returns 502 for everyone
/// behind it. Translation then stayed broken here while the same message
/// translated fine in the browser, because the PWA falls back to a direct
/// request and this app did not.
///
/// So it falls back now, matching the PWA. The trade-off is explicit and worth
/// stating: a direct request reaches Google from the user's own address rather
/// than the proxy's. That address is not rate-limited, which is exactly why the
/// fallback works — and it is visible to Google, which is exactly why it is a
/// fallback and not the default.
///
/// [translate] mirrors the PWA's `_translatePreservingMentions`
/// (`translate.js:292-328`) — the function BOTH the inline message-translate
/// (`translateMessage`) and the in-composer translate (`translateInputText`)
/// route through. It (1) shields emoji behind `EMJ<n>EMJ` placeholders so the
/// upstream can't drop/reorder them (`_shieldEmojis`, `translate.js:275-290`),
/// then (2) splits on `@mention` tokens and translates only the non-mention
/// chunks so handles survive verbatim, restoring per-chunk edge whitespace that
/// Google strips.
///
/// Lazy network: nothing runs until [translate] is awaited. The [ApiClient] is
/// injectable for tests (it accepts a mock `http.Client`).
class TranslateService {
  TranslateService({ApiClient? api, http.Client? directClient})
      : _api = api,
        _directClient = directClient;
  final ApiClient? _api;

  /// Injectable transport for the direct fallback (tests only; null in the app,
  /// where each call opens and closes its own).
  final http.Client? _directClient;

  /// The endpoint the proxy itself calls server-side, so a fallback returns the
  /// same translation the proxy would have.
  static const String _directEndpoint =
      'https://translate.googleapis.com/translate_a/single';

  /// One emoji "unit" (the PWA's `_shieldEmojis` regex, `translate.js:278`;
  /// identical to `_EMOJI_UNIT` ported at `message_content.dart:308-314`): a
  /// flag pair, a keycap, or a presentation/pictographic glyph with optional
  /// VS / skin-tone / ZWJ sequences and tags.
  static const String _emojiUnit =
      r'(?:[\u{1F1E0}-\u{1F1FF}]{2})|(?:[#*0-9]\u{FE0F}?\u{20E3})|'
      r'(?:(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})'
      r'(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?'
      r'(?:\u{200D}(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})'
      r'(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?)*)'
      r'(?:[\u{E0020}-\u{E007E}]+\u{E007F})?';

  static final RegExp _rxEmoji = RegExp(_emojiUnit, unicode: true);

  /// `EMJ<n>EMJ` placeholder restore (`translate.js:288-290`).
  static final RegExp _rxEmojiPlaceholder = RegExp(r'EMJ(\d+)EMJ');

  /// Tokens that must pass through translation UNTRANSLATED. Split out (like the
  /// PWA's `@mention` handling, `translate.js:298`) so the upstream never sees
  /// them and can't translate/reflow/break them:
  ///  * `` `inline code` `` — keeps command tokens (e.g. `` `?help` ``, `` `?model` ``
  ///    in the Nymbot welcome) and code verbatim (matched FIRST so anything
  ///    inside a code span is preserved whole);
  ///  * bare `http(s)://…` URLs — so media, rich link previews, and clickable
  ///    links survive in the re-rendered translation, and any `@` inside a URL
  ///    isn't mistaken for a mention (URL is matched before mentions);
  ///  * `@nym` mentions — handles stay clickable and nicknames aren't translated;
  ///  * `:shortcode:` custom emoji — render as inline images, not translated text.
  static final RegExp _rxPreserve =
      RegExp(r'`[^`\n]*`|https?://[^\s]+|@[^\s@]+|:[a-zA-Z0-9_+\-]+:');

  /// Per-chunk leading/trailing whitespace capture (`translate.js:305`).
  static final RegExp _rxEdgeWhitespace = RegExp(r'^(\s*)([\s\S]*?)(\s*)$');

  /// Translates [text] into [targetLang] (auto-detected source). Returns the
  /// translated text and the detected source language. Throws on failure.
  ///
  /// Mirrors `_translatePreservingMentions` (`translate.js:292-328`): emoji are
  /// shielded, `@mentions` are kept verbatim, only the in-between text chunks
  /// are sent upstream, edge whitespace is preserved, and the first non-`auto`
  /// detected language wins. When there is nothing translatable (the whole
  /// string is mentions/whitespace) the original [text] is returned with an
  /// `'auto'` detection, exactly like the PWA (`translate.js:309-311`).
  Future<TranslationResult> translate(String text, String targetLang) async {
    // 1. Shield emoji so the upstream can't strip/reorder them.
    final shield = _shieldEmojis(text);

    // 2. Split into interleaved translatable-text / preserved-token parts
    //    (URLs, @mentions, :shortcodes:). JS `split` with a capturing group
    //    interleaves the delimiters; Dart's `String.split` drops them, so build
    //    the same even=text / odd=preserved list by hand from the matches.
    final parts = _splitOnPreserved(shield.text);

    // 3. Collect the translatable (even-index, non-blank) chunks, capturing the
    //    leading/trailing whitespace Google would otherwise strip
    //    (`translate.js:302-307`).
    final translatable = <_Chunk>[];
    for (var i = 0; i < parts.length; i++) {
      if (i.isOdd)
        continue; // odd indices are preserved tokens — leave verbatim.
      final part = parts[i];
      if (part.trim().isEmpty) continue;
      final m = _rxEdgeWhitespace.firstMatch(part)!;
      translatable.add(_Chunk(
        index: i,
        lead: m.group(1) ?? '',
        content: m.group(2) ?? '',
        trail: m.group(3) ?? '',
      ));
    }

    // Nothing to translate (e.g. text was only mentions/whitespace): return the
    // ORIGINAL text untouched, like the PWA (`translate.js:309-311`).
    if (translatable.isEmpty) {
      return TranslationResult(translatedText: text, detectedLanguage: 'auto');
    }

    // 4. One ApiClient, reused across every chunk call, disposed once.
    final api = _api ?? ApiClient();
    try {
      final results = await Future.wait(
        translatable.map((c) => _translateChunk(api, c.content, targetLang)),
      );

      // 5. Reassemble, preserving each chunk's edge whitespace; merge the first
      //    non-auto detected language (`translate.js:317-324`).
      var detected = 'auto';
      for (var i = 0; i < translatable.length; i++) {
        final c = translatable[i];
        final res = results[i];
        parts[c.index] = c.lead + res.translatedText + c.trail;
        if (detected == 'auto' &&
            res.detectedLanguage.isNotEmpty &&
            res.detectedLanguage != 'auto') {
          detected = res.detectedLanguage;
        }
      }

      // 6. Re-join and restore the shielded emoji (`translate.js:326`).
      final joined = _restoreEmojis(parts.join(''), shield.emojis);
      return TranslationResult(
        translatedText: joined,
        detectedLanguage: detected,
      );
    } finally {
      if (_api == null) api.dispose();
    }
  }

  /// One upstream translation call for a single text [chunk]
  /// (the PWA's `_doTranslate`, `translate.js:332-359`). The proxy worker
  /// slices to 5000 chars server-side, but mirror the PWA's pre-slice so the
  /// request stays bounded (`translate.js:446`).
  Future<TranslationResult> _translateChunk(
    ApiClient api,
    String chunk,
    String targetLang,
  ) async {
    final body = chunk.length > 5000 ? chunk.substring(0, 5000) : chunk;
    try {
      final res = await api.translate(body, targetLang, source: 'auto');
      return TranslationResult(
        translatedText: res.translatedText,
        detectedLanguage:
            res.detectedLanguage.isEmpty ? 'auto' : res.detectedLanguage,
      );
    } catch (_) {
      // The proxy failed for THIS request. That is not the same as the proxy
      // being down, and it is usually not about this user at all — see the
      // class doc. Try direct rather than failing the translation
      // (`_doTranslate`'s catch, translate.js).
      return translateDirect(body, targetLang, client: _directClient);
    }
  }

  /// Google Translate without the proxy in front. Public so the fallback can be
  /// tested on its own, and injectable for the same reason.
  ///
  /// Sends the request from the caller's own address. Reserved for the case
  /// where the proxy could not answer — see the class doc for why that happens
  /// and what it costs.
  static Future<TranslationResult> translateDirect(
    String text,
    String targetLang, {
    http.Client? client,
  }) async {
    final own = client == null;
    final c = client ?? http.Client();
    try {
      final uri = Uri.parse(_directEndpoint).replace(queryParameters: {
        'client': 'gtx',
        'sl': 'auto',
        'tl': targetLang,
        'dt': 't',
        'q': text.length > 5000 ? text.substring(0, 5000) : text,
      });
      final res = await c.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        throw TranslateException(
            'Translation failed: Google Translate returned ${res.statusCode}');
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
      final parsed = _parseDirect(data);
      if (parsed == null) {
        throw const TranslateException(
            'Translation failed: unrecognised response');
      }
      return parsed;
    } on TranslateException {
      rethrow;
    } on TimeoutException {
      throw const TranslateException('Translation failed: timeout');
    } catch (e) {
      throw TranslateException('Translation failed: $e');
    } finally {
      if (own) c.close();
    }
  }

  /// `[[["translated","original",null,null,10],...],null,"detected"]` — the
  /// same shape the proxy parses server-side (`parseTranslateSingle`,
  /// proxy.js). Returns null for anything else rather than guessing.
  static TranslationResult? _parseDirect(dynamic data) {
    if (data is! List || data.isEmpty || data[0] is! List) return null;
    final segments = data[0] as List;
    final buf = StringBuffer();
    for (final seg in segments) {
      if (seg is List && seg.isNotEmpty && seg[0] is String) {
        buf.write(seg[0] as String);
      }
    }
    final detected =
        data.length > 2 && data[2] is String ? data[2] as String : 'auto';
    return TranslationResult(
      translatedText: buf.toString(),
      detectedLanguage: detected.isEmpty ? 'auto' : detected,
    );
  }

  /// Replaces every emoji unit with an `EMJ<n>EMJ` placeholder so the upstream
  /// translator can't drop or reorder it (the PWA's `_shieldEmojis`,
  /// `translate.js:275-286`). Returns the placeholdered text plus the ordered
  /// list of removed emoji for [_restoreEmojis].
  static _ShieldResult _shieldEmojis(String text) {
    final emojis = <String>[];
    final shielded = text.replaceAllMapped(_rxEmoji, (m) {
      final idx = emojis.length;
      emojis.add(m.group(0)!);
      return 'EMJ${idx}EMJ';
    });
    return _ShieldResult(shielded, emojis);
  }

  /// Restores `EMJ<n>EMJ` placeholders to their original emoji
  /// (the PWA's `_restoreEmojis`, `translate.js:288-290`). An out-of-range
  /// index restores to empty, matching the PWA's `|| ''`.
  static String _restoreEmojis(String text, List<String> emojis) {
    return text.replaceAllMapped(_rxEmojiPlaceholder, (m) {
      final idx = int.parse(m.group(1)!);
      return (idx >= 0 && idx < emojis.length) ? emojis[idx] : '';
    });
  }

  /// Builds an interleaved `parts` list splitting [text] on the preserved tokens
  /// ([_rxPreserve]: URLs, `@mentions`, `:shortcodes:`): even indices are
  /// translatable text (possibly empty), odd indices are the preserved tokens,
  /// in source order — the same shape JS's `text.split(/(token)/)` produces.
  static List<String> _splitOnPreserved(String text) {
    final parts = <String>[];
    var last = 0;
    for (final m in _rxPreserve.allMatches(text)) {
      parts.add(text.substring(last, m.start)); // leading text (may be empty)
      parts.add(m.group(0)!); // the preserved token (URL / @mention / :emoji:)
      last = m.end;
    }
    parts.add(text.substring(last)); // trailing text (may be empty)
    return parts;
  }

  /// Strips quoted lines (`> …` prefixed) so only the user's own reply text is
  /// translated (translate.js `translateMessage`, lines 207-219).
  static String stripQuotes(String content) {
    final lines = content
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('>'))
        .join('\n')
        .trim();
    // Strip a trailing timestamp like "12:34 PM" / "23:59".
    return lines
        .replaceAll(
            RegExp(r'\s*\d{1,2}:\d{2}\s*(AM|PM)?\s*$', caseSensitive: false),
            '')
        .trim();
  }
}

/// A single translatable text chunk plus the edge whitespace to restore after
/// translation (the PWA's `{ index, lead, content, trail }`, `translate.js:306`).
class _Chunk {
  const _Chunk({
    required this.index,
    required this.lead,
    required this.content,
    required this.trail,
  });
  final int index;
  final String lead;
  final String content;
  final String trail;
}

/// Result of [TranslateService._shieldEmojis]: the placeholdered text plus the
/// ordered emoji to restore.
class _ShieldResult {
  const _ShieldResult(this.text, this.emojis);
  final String text;
  final List<String> emojis;
}

class TranslationResult {
  const TranslationResult({
    required this.translatedText,
    required this.detectedLanguage,
  });
  final String translatedText;
  final String detectedLanguage;
}

class TranslateException implements Exception {
  const TranslateException(this.message);
  final String message;
  @override
  String toString() => message;
}
