// Renders the structured output of [NymFormat.format] as Flutter widgets,
// mirroring the PWA's visual treatment (docs/specs/03 §9): markdown spans,
// code/quote/heading blocks, channel/mention chips, emoji, and media galleries.

import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/nym_colors.dart';
import '../../../services/api/api_client.dart';
import '../../../state/app_state.dart';
import '../../../state/settings_provider.dart';
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
      customEmojis: const {},
    );

    final blocks = NymFormat.format(content, ctx);
    final size = fontSize ?? settings.textSize.toDouble();
    final color = baseColor ?? c.text;

    // Emoji-only messages (1-6 emoji, no other text) render enlarged
    // (`.emoji-only .emoji { font-size: 2.5em }`, `messages.js:922-924`).
    final emojiOnly = isEmojiOnly(content);

    // Collect bare http(s) links to unfurl below the body (ui-context.js
    // `_attachLinkPreviews`), skipping inline-media URLs (already embedded).
    final previewUrls = _collectPreviewUrls(blocks);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: 4),
          _block(context, c, blocks[i], color, size, emojiOnly: emojiOnly),
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
        );
      case HeadingBlock(:final level, :final inlines):
        final scale = level == 1 ? 1.5 : (level == 2 ? 1.3 : 1.15);
        return _RichInline(
          inlines: inlines,
          color: c.textBright,
          size: size * scale,
          weight: FontWeight.w700,
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
/// (port of `isEmojiOnly`, `messages.js:1424-1430`). Custom-emoji-only messages
/// (e.g. `:shrug:`) are out of scope here — those are detected by the formatter.
bool isEmojiOnly(String content) {
  if (content.isEmpty) return false;
  final stripped = content.replaceAll(_rxWhitespace, '');
  if (stripped.isEmpty) return false;
  return _rxEmojiOnly.hasMatch(stripped);
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

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final base = TextStyle(
      color: color,
      fontSize: size,
      fontWeight: weight,
      height: 1.4,
      shadows: shadows,
      fontFamily: monospace ? 'monospace' : null,
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
        return TextSpan(children: [
          for (final ch in children)
            _span(context, c, ch, base.merge(const TextStyle(fontWeight: FontWeight.w700))),
        ]);
      case ItalicNode(:final children):
        return TextSpan(children: [
          for (final ch in children)
            _span(context, c, ch, base.merge(const TextStyle(fontStyle: FontStyle.italic))),
        ]);
      case StrikeNode(:final children):
        return TextSpan(children: [
          for (final ch in children)
            _span(context, c, ch,
                base.merge(const TextStyle(decoration: TextDecoration.lineThrough))),
        ]);
      case InlineCodeNode(:final code):
        return TextSpan(
          text: code,
          style: base.merge(TextStyle(
            fontFamily: 'monospace',
            color: c.textBright,
            backgroundColor: Colors.white.withValues(alpha: 0.08),
          )),
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
        // `.emoji-only .emoji { font-size: 2.5em }`, else inline `1.25em`.
        return TextSpan(
          text: unicode,
          style: base.merge(TextStyle(fontSize: size * (emojiOnly ? 2.5 : 1.25))),
        );
      case MentionNode():
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _MentionChip(node: node, size: size),
        );
      case ChannelRefNode():
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _ChannelChip(node: node, size: size),
        );
      case CustomEmojiNode(:final url, :final shortcode):
        // `.emoji-only .custom-emoji { width/height: 2.75em }`, else 22px.
        final side = emojiOnly ? size * 2.75 : 22.0;
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: CachedNetworkImage(
              imageUrl: proxiedMedia(url, emoji: true),
              width: side,
              height: side,
              fit: BoxFit.contain,
              errorWidget: (_, __, ___) =>
                  Text(':$shortcode:', style: base),
            ),
          ),
        );
      case ChannelLinkChip(:final ref, :final label):
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _LinkChip(label: label, ref: ref, size: size),
        );
      case GroupInviteChip(:final name):
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _InviteChip(name: name, size: size),
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

class _ChannelChip extends StatelessWidget {
  const _ChannelChip({required this.node, required this.size});
  final ChannelRefNode node;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final fg = node.isGeohash ? c.warning : c.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: node.isActive ? fg.withValues(alpha: 0.18) : null,
        borderRadius: const BorderRadius.all(Radius.circular(4)),
      ),
      child: Text(
        '#${node.name}',
        style: TextStyle(
          color: fg,
          fontSize: size,
          fontWeight: FontWeight.w500,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }
}

class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.label, required this.ref, required this.size});
  final String label;
  final String ref;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.secondaryA(0.12),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        border: Border.all(color: c.secondaryA(0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(color: c.secondary, fontSize: size * 0.92),
      ),
    );
  }
}

class _InviteChip extends StatelessWidget {
  const _InviteChip({required this.name, required this.size});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.secondaryA(0.12),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        border: Border.all(color: c.secondaryA(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.group, size: size, color: c.secondary),
          const SizedBox(width: 4),
          Text(
            'Join $name',
            style: TextStyle(color: c.secondary, fontSize: size * 0.92),
          ),
        ],
      ),
    );
  }
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
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (lang != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 0, 0),
                  child: Text(
                    lang!,
                    style: TextStyle(color: c.textDim, fontSize: 11),
                  ),
                ),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(),
                tooltip: 'Copy',
                color: c.textDim,
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: code)),
                icon: const Icon(Icons.copy),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
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
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: c.secondaryA(0.05),
        border: Border(left: BorderSide(color: c.secondaryA(0.6), width: 2)),
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
      return _MediaTile(item: items.first, maxSize: 300, blur: blur);
    }
    // The grid is ALWAYS 2 columns, gap 4, max-width 420, radius sm
    // (`styles-chat.css:987-1023`). 3 items = a tall left hero + two stacked
    // right; 2 / 4+ = a 2-column wrap. Tiles cap at 220px tall.
    const gap = 4.0;
    Widget tile(MediaItem m) =>
        _MediaTile(item: m, maxSize: 220, blur: blur, inGallery: true);
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
  });
  final MediaItem item;
  final double maxSize;

  /// Apply the privacy blur (others' images), revealed on tap (`.blurred`).
  final bool blur;

  /// This tile sits inside a multi-up gallery grid — videos drop their border
  /// and corner radius (the grid clips), matching `.message-gallery video`.
  final bool inGallery;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final radius = const BorderRadius.all(Radius.circular(8));

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

    final image = CachedNetworkImage(
      imageUrl: proxiedMedia(item.url),
      fit: BoxFit.cover,
      width: maxSize,
      placeholder: (_, __) => Container(
        width: maxSize,
        height: maxSize,
        color: Colors.white.withValues(alpha: 0.05),
      ),
      errorWidget: (_, __, ___) => Container(
        width: maxSize,
        height: 80,
        color: Colors.white.withValues(alpha: 0.05),
        alignment: Alignment.center,
        child: Icon(Icons.broken_image, color: c.textDim),
      ),
    );

    return ClipRRect(
      borderRadius: radius,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxSize, maxHeight: maxSize),
        child: blur ? _BlurReveal(child: image) : image,
      ),
    );
  }
}

/// Wraps an image in a gaussian blur revealed on tap (`.blurred`,
/// `messages.js:1267-1274` — the PWA clears the blur class on tap).
class _BlurReveal extends StatefulWidget {
  const _BlurReveal({required this.child});
  final Widget child;

  @override
  State<_BlurReveal> createState() => _BlurRevealState();
}

class _BlurRevealState extends State<_BlurReveal> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    if (_revealed) return widget.child;
    return GestureDetector(
      onTap: () => setState(() => _revealed = true),
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: widget.child,
      ),
    );
  }
}
