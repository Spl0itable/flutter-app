// Renders the structured output of [NymFormat.format] as Flutter widgets,
// mirroring the PWA's visual treatment (docs/specs/03 §9): markdown spans,
// code/quote/heading blocks, channel/mention chips, emoji, and media galleries.

import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/nym_colors.dart';
import '../../../core/theme/nym_metrics.dart';
import '../../../core/theme/nym_theme.dart'
    show kEmojiFontFallback, kSansFont, kMonoFont;
import '../../../services/api/api_client.dart';
import '../../../services/platform/deep_links.dart';
import '../../../state/app_state.dart';
import '../../../state/nostr_controller.dart';
import '../../../state/settings_provider.dart';
import '../../../widgets/common/app_dialog.dart';
import '../inline_network_image.dart';
import 'link_preview.dart';
import 'nym_format.dart';
import 'video_message.dart';

/// Shared stateless [ApiClient] for media/emoji proxy URL construction. The
/// builders are pure (no network), so a single instance is fine.
final _proxyApi = ApiClient();

/// Routes a remote media [url] through the backend media proxy
/// (`/api/proxy?url=…`, mirroring the PWA's `proxied`/`getProxiedMediaUrl`),
/// while passing through anything that must NOT be proxied:
///   - empty / relative (no scheme or non-http(s)) URLs,
///   - `data:` and `blob:` URLs,
///   - URLs that are already pointed at the proxy.
/// Set [emoji] for custom-emoji images (long edge-cache TTL, `&emoji=1`).
String proxiedMedia(String url, {bool emoji = false}) {
  if (url.isEmpty) return url;
  final lower = url.toLowerCase();
  if (lower.startsWith('data:') || lower.startsWith('blob:')) return url;
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) return url;
  // Already proxied (e.g. nym_format pre-proxied via proxyBase) — leave as-is.
  if (url.contains('/api/proxy?')) return url;
  return _proxyApi.mediaProxyUrl(url, emoji: emoji);
}

/// Renders a raw message [content] string using [NymFormat].
///
/// Reads `settingsProvider`, `currentViewProvider`, and `nymColorsProvider` to
/// build a [FormatContext] and to style spans with `context.nym` tokens and the
/// user's text size.
class MessageContent extends ConsumerWidget {
  const MessageContent({
    super.key,
    required this.content,
    this.baseColor,
    this.fontSize,
    this.blurImages = false,
    this.glyphShadows,
    this.monospace = false,
  });

  final String content;

  /// Body text color (defaults to `context.nym.text`).
  final Color? baseColor;

  /// Base font size (defaults to settings.textSize).
  final double? fontSize;

  /// Blur inline/gallery images behind a tap-to-reveal (others' images privacy).
  final bool blurImages;

  /// Glyph [Shadow]s carried by the body text — the per-style `text-shadow`
  /// glow (neon/matrix/fire/…) or the glitch chromatic split. (`F11`/`F12`.)
  final List<Shadow>? glyphShadows;

  /// Render the body in a monospace family (the CRT style). (`F13`.)
  final bool monospace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final view = ref.watch(currentViewProvider);
    final c = ref.watch(nymColorsProvider);

    final ctx = FormatContext(
      currentChannel:
          view.kind == ViewKind.channel ? view.id.toLowerCase() : null,
      currentGeohash:
          view.kind == ViewKind.channel ? view.id.toLowerCase() : null,
      // Live NIP-30 custom emoji (kind-30030 packs + 10030 list + inbound
      // `emoji` tags) so `:shortcode:` renders as the custom image in messages,
      // not literal text. Mirrors the PWA's `customEmojis` map.
      customEmojis: ref.watch(liveCustomEmojiProvider).codeToUrl,
    );

    final blocks = NymFormat.format(content, ctx);
    final size = fontSize ?? settings.textSize.toDouble();
    final color = baseColor ?? c.text;

    // Emoji-only messages (1-6 emoji, no other text) render enlarged
    // (`.emoji-only .emoji { font-size: 2.5em }`, `messages.js:922-924`) — for
    // both unicode emoji and custom-emoji-only shortcode messages.
    final emojiOnly =
        isEmojiOnly(content) || isCustomEmojiOnly(content, ctx.customEmojis);

    // Collect bare http(s) links to unfurl below the body (ui-context.js
    // `_attachLinkPreviews`), skipping inline-media URLs (already embedded).
    final previewUrls = _collectPreviewUrls(blocks);

    // Tapping a `#ref` / `app.nym.bar/#…` link switches the active channel
    // (`channelLink` / `channelReference` data-actions).
    void onChannelRef(String name, bool isGeohash) {
      final controller = ref.read(nostrControllerProvider);
      if (isGeohash) {
        controller.switchChannel(name, geohash: name);
      } else {
        controller.switchChannel(name);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: 4),
          _block(context, c, blocks[i], color, size,
              emojiOnly: emojiOnly, onChannelRef: onChannelRef),
        ],
        for (final url in previewUrls) LinkPreviewCard(url: url),
      ],
    );
  }

  /// Walks the formatted [blocks] collecting bare http(s) [LinkNode] URLs for
  /// link-preview cards (de-duplicated, inline-media URLs skipped — those render
  /// as images/videos, mirroring ui-context.js:815).
  List<String> _collectPreviewUrls(List<FormatBlock> blocks) {
    final seen = <String>{};
    final out = <String>[];
    void visitInlines(List<InlineNode> inlines) {
      for (final n in inlines) {
        switch (n) {
          case LinkNode(:final url):
            if (isInlineMediaUrl(url)) break;
            if (seen.add(url)) out.add(url);
          case BoldNode(:final children):
            visitInlines(children);
          case ItalicNode(:final children):
            visitInlines(children);
          case StrikeNode(:final children):
            visitInlines(children);
          default:
            break;
        }
      }
    }

    void visitBlock(FormatBlock b) {
      switch (b) {
        case ParagraphBlock(:final inlines):
          visitInlines(inlines);
        case HeadingBlock(:final inlines):
          visitInlines(inlines);
        case QuoteBlock(:final children):
          for (final ch in children) {
            visitBlock(ch);
          }
        case CodeBlock():
        case MediaBlock():
          break;
      }
    }

    for (final b in blocks) {
      visitBlock(b);
    }
    return out;
  }

  Widget _block(
    BuildContext context,
    NymColors c,
    FormatBlock block,
    Color color,
    double size, {
    bool emojiOnly = false,
    void Function(String name, bool isGeohash)? onChannelRef,
  }) {
    switch (block) {
      case ParagraphBlock(:final inlines):
        return _RichInline(
          inlines: inlines,
          color: color,
          size: size,
          emojiOnly: emojiOnly,
          shadows: glyphShadows,
          monospace: monospace,
          onChannelRef: onChannelRef,
        );
      case HeadingBlock(:final level, :final inlines):
        final scale = level == 1 ? 1.5 : (level == 2 ? 1.3 : 1.15);
        // `h1,h2,h3 { color: var(--primary) }` (styles-chat.css:1312-1317).
        return _RichInline(
          inlines: inlines,
          color: c.primary,
          size: size * scale,
          weight: FontWeight.w700,
          onChannelRef: onChannelRef,
        );
      case CodeBlock(:final code, :final lang):
        return _CodeBox(code: code, lang: lang, size: size);
      case QuoteBlock():
        return _QuoteBox(block: block, color: color, size: size);
      case MediaBlock(:final items):
        return _MediaGallery(items: items, blur: blurImages);
    }
  }
}

/// One emoji "unit" (the PWA's `_EMOJI_UNIT`, `messages.js:8`): a flag pair, a
/// keycap, or a presentation/pictographic glyph with optional VS / skin-tone /
/// ZWJ sequences and tags.
const String _emojiUnit =
    r'(?:[\u{1F1E0}-\u{1F1FF}]{2})|(?:[#*0-9]\u{FE0F}?\u{20E3})|'
    r'(?:(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})'
    r'(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?'
    r'(?:\u{200D}(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})'
    r'(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?)*)'
    r'(?:[\u{E0020}-\u{E007E}]+\u{E007F})?';

final RegExp _rxEmojiOnly = RegExp('^(?:$_emojiUnit){1,6}\$', unicode: true);
final RegExp _rxWhitespace = RegExp(r'\s', unicode: true);

/// True when [content] is 1-6 emoji with optional whitespace and no other text
/// (port of `isEmojiOnly`, `messages.js:1424-1430`).
bool isEmojiOnly(String content) {
  if (content.isEmpty) return false;
  final stripped = content.replaceAll(_rxWhitespace, '');
  if (stripped.isEmpty) return false;
  return _rxEmojiOnly.hasMatch(stripped);
}

final RegExp _rxCustomEmojiToken = RegExp(r'^:([a-zA-Z0-9_]+):$');

/// True when [content] is 1-6 whitespace-separated custom-emoji shortcodes,
/// every one a known [customEmojis] code (port of `isCustomEmojiOnly`,
/// emoji.js:331). Drives the same `.emoji-only` 2.75em enlarge as a
/// unicode-emoji-only message.
bool isCustomEmojiOnly(String content, Map<String, String> customEmojis) {
  if (content.isEmpty || customEmojis.isEmpty) return false;
  final tokens = content.trim().split(RegExp(r'\s+'));
  if (tokens.isEmpty || tokens.length > 6) return false;
  for (final tok in tokens) {
    final m = _rxCustomEmojiToken.firstMatch(tok);
    if (m == null || !customEmojis.containsKey(m.group(1))) return false;
  }
  return true;
}

/// Renders a list of inline nodes as a single [Text.rich] (with [WidgetSpan]s
/// for chips, emoji images, and mentions).
class _RichInline extends StatelessWidget {
  const _RichInline({
    required this.inlines,
    required this.color,
    required this.size,
    this.weight,
    this.emojiOnly = false,
    this.shadows,
    this.monospace = false,
    this.onChannelRef,
  });

  final List<InlineNode> inlines;
  final Color color;
  final double size;
  final FontWeight? weight;

  /// Whole message is 1-6 emoji → enlarge emoji glyphs/images.
  final bool emojiOnly;

  /// Per-style glyph shadows (glow / glitch chromatic split).
  final List<Shadow>? shadows;

  /// Render glyphs in a monospace family (CRT).
  final bool monospace;

  /// Switches the active channel when a `#ref` / `app.nym.bar/#…` link is tapped.
  final void Function(String name, bool isGeohash)? onChannelRef;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final base = TextStyle(
      color: color,
      fontSize: size,
      fontWeight: weight,
      height: 1.4,
      shadows: shadows,
      // Bundled [kSansFont] primary drives the (correct) line strut; the
      // emoji/symbol [kEmojiFontFallback] resolves emoji + enclosed letters in
      // body text per-glyph without touching Latin metrics. Mono bodies (CRT
      // style) keep the monospace family and skip the fallback.
      fontFamily: monospace ? kMonoFont : kSansFont,
      fontFamilyFallback: monospace ? null : kEmojiFontFallback,
    );
    return Text.rich(
      TextSpan(
        children: [
          for (final n in inlines) _span(context, c, n, base),
        ],
      ),
    );
  }

  InlineSpan _span(
    BuildContext context,
    NymColors c,
    InlineNode node,
    TextStyle base,
  ) {
    switch (node) {
      case TextSpanNode(:final text):
        return TextSpan(text: text, style: base);
      case BoldNode(:final children):
        // `strong { color: var(--text-bright); font-weight:bold }`
        // (styles-chat.css:1074-1077).
        return TextSpan(children: [
          for (final ch in children)
            _span(context, c, ch,
                base.merge(TextStyle(fontWeight: FontWeight.w700, color: c.textBright))),
        ]);
      case ItalicNode(:final children):
        return TextSpan(children: [
          for (final ch in children)
            _span(context, c, ch, base.merge(const TextStyle(fontStyle: FontStyle.italic))),
        ]);
      case StrikeNode(:final children):
        // `del { text-decoration:line-through; color: var(--text-dim) }`
        // (styles-chat.css:1325-1328).
        return TextSpan(children: [
          for (final ch in children)
            _span(context, c, ch,
                base.merge(TextStyle(
                    decoration: TextDecoration.lineThrough, color: c.textDim))),
        ]);
      case InlineCodeNode(:final code):
        // `code { background: rgba(255,255,255,0.06); padding:2px 6px;
        //  border-radius:5px; font-family:mono; color: var(--secondary);
        //  font-size:0.9em }` (styles-chat.css:1084-1092) — a rounded inline
        //  pill, so a WidgetSpan carries the padding + radius the CSS needs.
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              code,
              style: base.merge(TextStyle(
                fontFamily: 'monospace',
                color: c.secondary,
                fontSize: size * 0.9,
                shadows: const [],
              )),
            ),
          ),
        );
      case LinkNode(:final url):
        return TextSpan(
          text: url,
          style: base.merge(TextStyle(
            color: c.secondary,
            decoration: TextDecoration.underline,
          )),
          recognizer: _LinkTap(url),
        );
      case EmojiNode(:final unicode):
        // `.emoji` has no font-size (inherits 1em); only `.emoji-only .emoji` is
        // 2.5em (styles-chat.css:824-837). The emoji/symbol fallback already
        // rides on [base], so the glyph resolves to Noto Color Emoji here.
        return TextSpan(
          text: unicode,
          style: base.merge(TextStyle(fontSize: size * (emojiOnly ? 2.5 : 1.0))),
        );
      case MentionNode():
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _MentionChip(node: node, size: size),
        );
      case ChannelRefNode(:final name, :final isGeohash):
        // `.channel-reference`: underlined, inherits BODY text color (no tint),
        // no background/box, no active-state fill (styles-chat.css:933-939).
        // Hover→primary is desktop-only and omitted on touch.
        return TextSpan(
          text: '#$name',
          style: base.merge(const TextStyle(decoration: TextDecoration.underline)),
          recognizer: onChannelRef == null
              ? null
              : _ChannelRefTap(name, isGeohash, onChannelRef!),
        );
      case CustomEmojiNode(:final url, :final shortcode):
        // `.custom-emoji { width/height: 1.75em }`; emoji-only `2.75em`
        // (styles-chat.css:839-852). The HTML `width=30` attr is overridden by
        // the CSS, so inline is `1.75em` (≈26px at 15), not 22px.
        final side = emojiOnly ? size * 2.75 : size * 1.75;
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            // Many NIP-30 custom emoji are SVG (and some hosts serve formats the
            // raster decoder can't handle); InlineNetworkImage renders SVG via
            // flutter_svg and otherwise falls back to the `:shortcode:` text so a
            // broken/undecodable emoji never throws. (BUG: custom emoji + decode.)
            child: InlineNetworkImage(
              url: proxiedMedia(url, emoji: true),
              width: side,
              height: side,
              fit: BoxFit.contain,
              // Disk-cached (CachedNetworkImage): body emoji are sparse — only a
              // few per visible message — so they don't storm the cache DB, and
              // the disk cache lets them persist across restarts. (The high-volume
              // emoji PICKER grid uses memoryOnly to avoid the lock storm.)
              errorChild: Text(':$shortcode:', style: base),
            ),
          ),
        );
      case ChannelLinkChip(:final ref, :final label):
        // `.channel-link`: plain underlined secondary text (full URL label),
        // no background/border/padding (styles-chat.css:895-903). Hover→primary
        // is desktop-only.
        return TextSpan(
          text: label,
          style: base.merge(TextStyle(
            color: c.secondary,
            decoration: TextDecoration.underline,
          )),
          recognizer:
              onChannelRef == null ? null : _ChannelLinkTap(ref, onChannelRef!),
        );
      case GroupInviteChip(:final name, :final token):
        // The chip renders to spec; tapping to JOIN needs the group-invite
        // decode that lives in NostrController (cross-file) — left inert here.
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _InviteChip(name: name, token: token, size: size),
        );
      default:
        // _MediaInline is flattened to blocks and never reaches here.
        return const TextSpan(text: '');
    }
  }
}

/// A tap recognizer that opens a URL via url_launcher.
class _LinkTap extends TapGestureRecognizer {
  _LinkTap(String url) {
    onTap = () {
      final uri = Uri.tryParse(url);
      if (uri != null) {
        launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    };
  }
}

class _MentionChip extends StatelessWidget {
  const _MentionChip({required this.node, required this.size});
  final MentionNode node;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: node.base,
            style: TextStyle(
              color: c.primary,
              fontSize: size,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (node.suffix != null)
            // `.nym-suffix`: opacity 0.7, 0.9em, weight 100 (inherits primary).
            TextSpan(
              text: '#${node.suffix}',
              style: TextStyle(
                color: c.primaryA(0.7),
                fontSize: size * 0.9,
                fontWeight: FontWeight.w100,
              ),
            ),
        ],
      ),
    );
  }
}

/// Taps a `#channel` reference → switch to that channel (geohash or named).
class _ChannelRefTap extends TapGestureRecognizer {
  _ChannelRefTap(
      String name, bool isGeohash, void Function(String name, bool isGeohash) cb) {
    onTap = () => cb(name, isGeohash);
  }
}

/// Taps an `app.nym.bar/#…` channel link → switch to the referenced channel.
/// [ref] is `g:<geohash>` or `c:<name>` (the PWA `data-channel-ref`).
class _ChannelLinkTap extends TapGestureRecognizer {
  _ChannelLinkTap(String ref, void Function(String name, bool isGeohash) cb) {
    onTap = () {
      final colon = ref.indexOf(':');
      final prefix = colon > 0 ? ref.substring(0, colon) : '';
      final id = colon > 0 ? ref.substring(colon + 1) : ref;
      cb(id, prefix == 'g');
    };
  }
}

/// `.group-invite-chip` (`styles-chat.css:905-919`): a no-fill pill with a
/// solid 1px `--secondary` border, radius 12, padding `2px 8px`, a 1em stroked
/// group glyph, and secondary text at body size. Tapping confirms, then sends a
/// `group-join-request` to the link's sharer (groups.js `requestJoinGroupViaInvite`).
class _InviteChip extends ConsumerWidget {
  const _InviteChip(
      {required this.name, required this.token, required this.size});
  final String name;
  final String token;
  final double size;

  /// Decode the token, confirm, then hand off to the controller's joiner-side
  /// flow (mirrors the PWA's `Join "<name>"?` confirm before `_sendGiftWraps`).
  Future<void> _join(BuildContext context, WidgetRef ref) async {
    final parsed = parseGroupInvite(token);
    if (parsed == null) return;
    final controller = ref.read(nostrControllerProvider);
    final ok = await showAppConfirm(
      context,
      'Join "$name"? A join request will be sent to a group member.',
      title: 'Join Group',
      okLabel: 'Join',
    );
    if (!ok) return;
    await controller.joinGroupViaInvite(parsed);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    return GestureDetector(
      onTap: () => _join(context, ref),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          // No background fill; solid full-opacity secondary 1px border, r12.
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          border: Border.all(color: c.secondary),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // `.inline-group-ico` ≈ 1em multi-person outline.
            SizedBox(
              width: size,
              height: size,
              child: CustomPaint(painter: _GroupIcoPainter(c.secondary)),
            ),
            SizedBox(width: size * 0.35),
            Text(
              'Join $name',
              style: TextStyle(color: c.secondary, fontSize: size),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small multi-person ("group") outline glyph, ≈ the PWA `inlineGroupSvg`.
class _GroupIcoPainter extends CustomPainter {
  _GroupIcoPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Authored in a 24×24 box; scale to [size].
    final s = size.width / 24.0;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    // Front person: head + shoulders.
    canvas.drawCircle(Offset(9 * s, 8 * s), 3.2 * s, stroke);
    final body = Path()
      ..moveTo(3.5 * s, 19 * s)
      ..cubicTo(3.5 * s, 14.5 * s, 6 * s, 13 * s, 9 * s, 13 * s)
      ..cubicTo(12 * s, 13 * s, 14.5 * s, 14.5 * s, 14.5 * s, 19 * s);
    canvas.drawPath(body, stroke);
    // Back person: partial head + shoulder behind/right.
    final back = Path()
      ..moveTo(15.5 * s, 5.2 * s)
      ..cubicTo(17.4 * s, 5.6 * s, 18.6 * s, 7.2 * s, 18.3 * s, 9.1 * s)
      ..cubicTo(18.1 * s, 10.3 * s, 17.3 * s, 11.2 * s, 16.3 * s, 11.7 * s);
    canvas.drawPath(back, stroke);
    final backBody = Path()
      ..moveTo(17 * s, 13.2 * s)
      ..cubicTo(19 * s, 13.6 * s, 20.5 * s, 15.3 * s, 20.5 * s, 19 * s);
    canvas.drawPath(backBody, stroke);
  }

  @override
  bool shouldRepaint(covariant _GroupIcoPainter old) => old.color != color;
}

/// Monospace code box with an optional language label and a copy affordance.
class _CodeBox extends StatelessWidget {
  const _CodeBox({required this.code, required this.lang, required this.size});
  final String code;
  final String? lang;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `pre` radius is `--radius-sm` (=12), wrapper `padding-top:22px`
    // (styles-chat.css:1097, 1141-1143). The lang label + Copy pill are
    // absolutely positioned (top-left / top-right), so we Stack them over the
    // top-padded code body.
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 22, 10, 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                code,
                style: TextStyle(
                  color: c.textBright,
                  fontSize: size - 1,
                  fontFamily: 'monospace',
                  height: 1.4,
                ),
              ),
            ),
          ),
          // `.code-lang-label`: top:4 left:8, 0.7em, UPPERCASE, `text@0.55`.
          if (lang != null && lang!.isNotEmpty)
            Positioned(
              top: 4,
              left: 8,
              child: Text(
                lang!.toUpperCase(),
                style: TextStyle(
                  color: c.text.withValues(alpha: 0.55),
                  fontSize: size * 0.7,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          // `.code-copy-btn`: top:6 right:6, primary@0.15 bg / primary@0.3
          // border / radius-xs(8), "Copy" text 0.75em in `--primary`.
          Positioned(
            top: 6,
            right: 6,
            child: GestureDetector(
              onTap: () => Clipboard.setData(ClipboardData(text: code)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: c.primaryA(0.15),
                  borderRadius: NymRadius.rxs,
                  border: Border.all(color: c.primaryA(0.3)),
                ),
                child: Text(
                  'Copy',
                  style: TextStyle(color: c.primary, fontSize: size * 0.75),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Left-bordered quote block, with an optional author header.
class _QuoteBox extends StatelessWidget {
  const _QuoteBox({required this.block, required this.color, required this.size});
  final QuoteBlock block;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `blockquote`: border-left 3px primary@0.4, padding-left 12, bg
    // secondary@0.1, radius `0 8 8 0` (styles-chat.css:1270-1283).
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      decoration: BoxDecoration(
        color: c.secondaryA(0.1),
        border: Border(left: BorderSide(color: c.primaryA(0.4), width: 3)),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(8),
          bottomRight: Radius.circular(8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (block.author != null) _quoteAuthor(c, block.author!),
          for (final child in block.children)
            _quoteChild(context, c, child),
        ],
      ),
    );
  }

  /// The `<span class="quote-author">author#suffix:</span>` header, splitting
  /// the base nym (secondary 600) from a dimmed `.nym-suffix` (`#xxxx`).
  Widget _quoteAuthor(NymColors c, String author) {
    final hash = author.indexOf('#');
    final base = hash > 0 ? author.substring(0, hash) : author;
    final suffix = hash > 0 ? author.substring(hash) : null;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: base,
            style: TextStyle(
              color: c.secondary,
              fontSize: size - 1,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (suffix != null)
            TextSpan(
              text: suffix,
              style: TextStyle(
                color: c.secondaryA(0.7),
                fontSize: (size - 1) * 0.9,
                fontWeight: FontWeight.w100,
              ),
            ),
          TextSpan(
            text: ':',
            style: TextStyle(
              color: c.secondary,
              fontSize: size - 1,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _quoteChild(BuildContext context, NymColors c, FormatBlock child) {
    final dim = c.textDim;
    switch (child) {
      case ParagraphBlock(:final inlines):
        return _RichInline(inlines: inlines, color: dim, size: size - 1);
      case HeadingBlock(:final inlines):
        return _RichInline(
            inlines: inlines, color: dim, size: size, weight: FontWeight.w700);
      case CodeBlock(:final code, :final lang):
        return _CodeBox(code: code, lang: lang, size: size - 1);
      case QuoteBlock():
        return _QuoteBox(block: child, color: dim, size: size);
      case MediaBlock(:final items):
        return _MediaGallery(items: items);
    }
  }
}

/// A 1/2/3/4-up media grid. Images are tappable (expand placeholder); videos
/// render as an inline [VideoMessage] (tap-to-play, fullscreen expand).
class _MediaGallery extends StatelessWidget {
  const _MediaGallery({required this.items, this.blur = false});
  final List<MediaItem> items;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    // Single image/video: max 300×300, min-height 80 (`styles-chat.css:1029`).
    if (items.length == 1) {
      return _MediaTile(
          item: items.first, maxSize: 300, blur: blur, gallery: items);
    }
    // The grid is ALWAYS 2 columns, gap 4, max-width 420, radius sm
    // (`styles-chat.css:987-1023`). 3 items = a tall left hero + two stacked
    // right; 2 / 4+ = a 2-column wrap. Tiles cap at 220px tall.
    const gap = 4.0;
    Widget tile(MediaItem m) => _MediaTile(
        item: m, maxSize: 220, blur: blur, inGallery: true, gallery: items);
    Widget body;
    if (items.length == 3) {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: tile(items[0])),
          const SizedBox(width: gap),
          Expanded(
            child: Column(
              children: [
                Expanded(child: tile(items[1])),
                const SizedBox(height: gap),
                Expanded(child: tile(items[2])),
              ],
            ),
          ),
        ],
      );
    } else {
      body = GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: gap,
        crossAxisSpacing: gap,
        children: [for (final item in items) tile(item)],
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420, maxHeight: 444),
      child: body,
    );
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({
    required this.item,
    required this.maxSize,
    this.blur = false,
    this.inGallery = false,
    this.gallery,
  });
  final MediaItem item;
  final double maxSize;

  /// The sibling media of this tile's message — lets a tap open the fullscreen
  /// viewer with prev/next paging across the message's images (`expandImage` /
  /// `_imageModalGallery`). Null/single → a one-image viewer.
  final List<MediaItem>? gallery;

  /// Opens [item] (and its image siblings) in the fullscreen viewer.
  void _openFullscreen(BuildContext context) {
    final urls = (gallery ?? [item])
        .where((m) => !m.isVideo)
        .map((m) => m.url)
        .toList();
    if (urls.isEmpty) return;
    final idx = urls.indexOf(item.url);
    _FullscreenImageViewer.open(context, urls, idx < 0 ? 0 : idx);
  }

  /// Apply the privacy blur (others' images), revealed on tap (`.blurred`).
  final bool blur;

  /// This tile sits inside a multi-up gallery grid — videos drop their border
  /// and corner radius (the grid clips), matching `.message-gallery video`.
  final bool inGallery;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Single image: radius `--radius-sm` (=12); gallery cell: square (radius 0,
    // the grid clips). (styles-chat.css:941-950, 1012-1023.)
    final radius =
        inGallery ? BorderRadius.zero : NymRadius.rsm;

    if (item.isVideo) {
      // Inline playable video (`F16`): single → bordered max-300 radius-sm;
      // gallery cell → borderless, square corners, filling the tile.
      return VideoMessage(
        url: item.url,
        maxSize: maxSize,
        bordered: !inGallery,
        borderRadius: inGallery ? BorderRadius.zero : null,
      );
    }

    // SVG-aware + decode-safe: SVG images render via flutter_svg, and any
    // undecodable image (`ImageDecoder unimplemented`, broken URL) shows the
    // broken-image placeholder instead of throwing. (BUG: image decode failures.)
    final image = InlineNetworkImage(
      url: proxiedMedia(item.url),
      fit: BoxFit.cover,
      width: maxSize,
      placeholder: Container(
        width: maxSize,
        height: maxSize,
        color: Colors.white.withValues(alpha: 0.05),
      ),
      errorChild: Container(
        width: maxSize,
        height: 80,
        color: Colors.white.withValues(alpha: 0.05),
        alignment: Alignment.center,
        child: Icon(Icons.broken_image, color: c.textDim),
      ),
    );

    // Tapping an image opens it fullscreen (after the privacy blur is first
    // revealed, when blurred) — `data-action="expandImageFromData"`.
    final tappableImage = blur
        ? _BlurReveal(
            onRevealedTap: () => _openFullscreen(context),
            child: image,
          )
        : GestureDetector(
            onTap: () => _openFullscreen(context),
            child: image,
          );
    final clipped = ClipRRect(
      borderRadius: radius,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxSize, maxHeight: maxSize),
        child: tappableImage,
      ),
    );
    // A lone image carries a 1px glass border (`.message-content img`); gallery
    // cells have none.
    if (inGallery) return clipped;
    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: c.glassBorder),
      ),
      child: clipped,
    );
  }
}

/// Fullscreen image viewer (`expandImage` + `_imageModalGallery`,
/// messages.js:1432-1483): pinch-zoom via [InteractiveViewer], prev/next paging
/// across a message's images, tap the backdrop or the ✕ to close.
class _FullscreenImageViewer extends StatefulWidget {
  const _FullscreenImageViewer(
      {required this.urls, required this.initialIndex});
  final List<String> urls;
  final int initialIndex;

  static Future<void> open(
      BuildContext context, List<String> urls, int index) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.92),
        pageBuilder: (_, __, ___) =>
            _FullscreenImageViewer(urls: urls, initialIndex: index),
      ),
    );
  }

  @override
  State<_FullscreenImageViewer> createState() => _FullscreenImageViewerState();
}

class _FullscreenImageViewerState extends State<_FullscreenImageViewer> {
  late int _index = widget.initialIndex;

  void _step(int delta) => setState(() =>
      _index = (_index + delta + widget.urls.length) % widget.urls.length);

  @override
  Widget build(BuildContext context) {
    final multi = widget.urls.length > 1;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Tap the backdrop to dismiss.
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          Center(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Image.network(
                proxiedMedia(widget.urls[_index]),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(Icons.broken_image,
                    color: Colors.white54, size: 48),
              ),
            ),
          ),
          if (multi) ...[
            Positioned(
              left: 4,
              top: 0,
              bottom: 0,
              child: Center(child: _btn(Icons.chevron_left, () => _step(-1))),
            ),
            Positioned(
              right: 4,
              top: 0,
              bottom: 0,
              child: Center(child: _btn(Icons.chevron_right, () => _step(1))),
            ),
            Positioned(
              bottom: 28,
              left: 0,
              right: 0,
              child: Center(
                child: Text('${_index + 1} / ${widget.urls.length}',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 13)),
              ),
            ),
          ],
          Positioned(
            top: 4,
            right: 4,
            child: SafeArea(
              child: _btn(Icons.close, () => Navigator.of(context).maybePop()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _btn(IconData icon, VoidCallback onTap) => Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child:
            IconButton(icon: Icon(icon, color: Colors.white), onPressed: onTap),
      );
}

/// Wraps an image in a gaussian blur revealed on tap (`.blurred`,
/// `messages.js:1267-1274` — the PWA clears the blur class on tap).
class _BlurReveal extends StatefulWidget {
  const _BlurReveal({required this.child, this.onRevealedTap});
  final Widget child;

  /// Tapped once the blur is cleared (e.g. to open the fullscreen viewer).
  final VoidCallback? onRevealedTap;

  @override
  State<_BlurReveal> createState() => _BlurRevealState();
}

class _BlurRevealState extends State<_BlurReveal> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    if (_revealed) {
      return GestureDetector(
        onTap: widget.onRevealedTap,
        child: widget.child,
      );
    }
    return GestureDetector(
      onTap: () => setState(() => _revealed = true),
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: widget.child,
      ),
    );
  }
}

/// Renders a short string inline while resolving NIP-30 custom emoji: any
/// `:shortcode:` known to [liveCustomEmojiProvider] (and bare http(s) custom-
/// emoji URLs) becomes an inline image; everything else is plain styled text.
///
/// This is the lightweight counterpart to [MessageContent] for surfaces that
/// show a reaction emoji or a short notification line — reaction badges, the
/// reactors sheet, the notifications panel — where a full formatted block is too
/// heavy and where, until now, `:shortcode:` reactions showed as literal text.
///
/// Text runs keep the caller's [style] verbatim (no colour-emoji fallback is
/// forced onto them, which would wreck Latin metrics/glyphs the same way the old
/// global theme fallback did); unicode emoji render via the platform font.
class InlineEmojiText extends ConsumerWidget {
  const InlineEmojiText({
    super.key,
    required this.text,
    required this.style,
    this.emojiSize,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String text;
  final TextStyle style;

  /// Side length for an inline custom-emoji image. Defaults to ~1.2× the font
  /// size so the glyph sits a touch above the cap height like the PWA's emoji.
  final double? emojiSize;

  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  /// `:shortcode:` token (NIP-30 codes are `[a-zA-Z0-9_]+`, emoji.js).
  static final RegExp _rxToken = RegExp(r':([a-zA-Z0-9_]+):');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final codeToUrl = ref.watch(liveCustomEmojiProvider).codeToUrl;

    // Fast path: nothing to substitute → a single styled Text (keeps these
    // surfaces find-by-text friendly and avoids a needless RichText).
    if (codeToUrl.isEmpty || !_rxToken.hasMatch(text)) {
      return Text(text,
          style: style,
          maxLines: maxLines,
          overflow: overflow,
          textAlign: textAlign);
    }

    final side = (emojiSize ?? (style.fontSize ?? 14)) * 1.2;
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _rxToken.allMatches(text)) {
      final url = codeToUrl[m.group(1)];
      if (url == null) continue; // unknown code → leave the literal `:code:`
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start), style: style));
      }
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: InlineNetworkImage(
            url: proxiedMedia(url, emoji: true),
            width: side,
            height: side,
            fit: BoxFit.contain,
            // Disk-cached (sparse: a reaction badge / a notification line shows
            // one emoji). Only the picker grid uses memoryOnly.
            errorChild: Text(':${m.group(1)}:', style: style),
          ),
        ),
      ));
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: style));
    }
    return Text.rich(
      TextSpan(children: spans),
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
}
