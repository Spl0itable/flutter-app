import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/nym_colors.dart';
import 'cosmetics.dart'
    show StyleWatermarkLayer, messageStyleDecoration, styleWatermarks;
import 'shop_catalog.dart';
import 'shop_models.dart';

/// Renders a catalog item's inline SVG icon, tinted to [color]. The SVGs use
/// `stroke="currentColor"` / `fill="currentColor"`, so we apply a colour filter
/// matching the web's `currentColor` inheritance.
class ShopSvgIcon extends StatelessWidget {
  const ShopSvgIcon({
    super.key,
    required this.svg,
    required this.size,
    required this.color,
  });

  final String svg;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(
      svg,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}

/// A flair's `.flair-X` glow — blurred tinted copies of the glyph painted behind
/// the crisp icon. The CSS expresses this as two SEPARATE properties:
///   * `text-shadow` — declared on every `.flair-X`, BUT the flair glyph is an
///     inline path-only `<svg>` (no `<text>`), and CSS `text-shadow` shadows
///     text runs only, never replaced inline-SVG paths. So the declared halo is
///     INERT in the browser: the PWA renders these copies for NO flair, in
///     either mode. We keep the values recorded for fidelity/reference, but they
///     are never painted.
///   * `filter: drop-shadow(...)` — only on the brighter star/flame/diamond/
///     genesis. `filter` DOES apply to a replaced inline SVG, so this is the
///     only glow the PWA actually renders. The light-mode overrides reset
///     `color`/`text-shadow` but NOT `filter`, so it survives into light mode.
/// Keeping the two lists distinct documents that asymmetry exactly.
class _FlairGlow {
  const _FlairGlow({this.textShadows = const [], this.dropShadows = const []});

  /// `text-shadow` blurs (colour, blurRadius). Recorded for reference only —
  /// inert on a path SVG, so never painted (see class doc).
  final List<(Color, double)> textShadows;

  /// `filter: drop-shadow` blurs (colour, blurRadius) — both modes.
  final List<(Color, double)> dropShadows;

  /// The glow copies to paint. Only the `filter: drop-shadow` copies render in
  /// the PWA — `text-shadow` does not shadow a path SVG — so we paint the
  /// `drop-shadow` set in BOTH modes and ignore the inert `text-shadow` halo.
  List<(Color, double)> shadowsFor({required bool isLight}) => dropShadows;
}

/// The `.flair-badge` — a flair item's SVG tinted to its themed colour, sized
/// like the web (`font-size: 20px`), with the per-flair `.flair-X` glow. Genesis
/// stamps its edition number.
class FlairBadge extends StatelessWidget {
  const FlairBadge({
    super.key,
    required this.flairId,
    this.edition,
    this.size = 20,
  });

  final String flairId;
  final int? edition;
  final double size;

  /// Themed flair colours — the EXACT `.flair-X { color }` CSS hex
  /// (`styles-features.css:323-356, 646-711, 1213`).
  static const Map<String, Color> colors = {
    'flair-crown': Color(0xFFFFD700),
    'flair-diamond': Color(0xFF00FFFF),
    'flair-skull': Color(0xFFFF0000),
    'flair-star': Color(0xFFFFFF00),
    'flair-lightning': Color(0xFFF7931A),
    'flair-heart': Color(0xFFFF1493),
    'flair-mask': Color(0xFFFFFFFF),
    'flair-rocket': Color(0xFFFF6B6B),
    'flair-shield': Color(0xFF52FF9D),
    'flair-flame': Color(0xFFFF7A1A),
    'flair-snowflake': Color(0xFF7FDFFF),
    'flair-moon': Color(0xFFCDD6FF),
    'flair-sun': Color(0xFFFFC93C),
    'flair-leaf': Color(0xFF5FD35F),
    'flair-music': Color(0xFFB388FF),
    'flair-eye': Color(0xFFE0F7FF),
    'flair-anchor': Color(0xFF5B9DFF),
    'flair-gem': Color(0xFFFF3B6B),
    'flair-genesis': Color(0xFFFFDF6B),
  };

  /// Light-mode `.flair-X` colours (`body.light-mode .flair-X`,
  /// styles-themes-responsive.css:765-985) — darker / desaturated for legibility
  /// on a light surface; the CSS also drops the glow (`text-shadow: none`).
  static const Map<String, Color> lightColors = {
    'flair-crown': Color(0xFFB8960A),
    'flair-diamond': Color(0xFF0088AA),
    'flair-skull': Color(0xFFCC0000),
    'flair-star': Color(0xFF8A7200),
    'flair-lightning': Color(0xFFC47A15),
    'flair-heart': Color(0xFFCC0066),
    'flair-mask': Color(0xFF333333),
    'flair-rocket': Color(0xFFCC3333),
    'flair-shield': Color(0xFF228855),
    'flair-flame': Color(0xFFCC5500),
    'flair-snowflake': Color(0xFF0077AA),
    'flair-moon': Color(0xFF4A4FA0),
    'flair-sun': Color(0xFFB8860A),
    'flair-leaf': Color(0xFF2E8B2E),
    'flair-music': Color(0xFF7A3FCC),
    'flair-eye': Color(0xFF1F7A9C),
    'flair-anchor': Color(0xFF2855A3),
    'flair-gem': Color(0xFFCC1F4F),
    'flair-genesis': Color(0xFFB8860A),
  };

  /// The `.flair-X` glow, split into its CSS `text-shadow` halo (dark only) and
  /// `filter: drop-shadow` (both modes — survives `body.light-mode`). Each entry
  /// is a blurred tinted glyph copy; the CSS `0 0 Npx` blur maps directly to a
  /// Gaussian `blurRadius` of N. Values are the exact CSS rgba()s
  /// (`styles-features.css:323-356, 646-711, 1213-1216`).
  static const Map<String, _FlairGlow> _glows = {
    'flair-crown': _FlairGlow(
      textShadows: [(Color(0x80FFD700), 10.0)], // rgba(255,215,0,.5)
    ),
    'flair-diamond': _FlairGlow(
      textShadows: [(Color(0x8000FFFF), 10.0)], // rgba(0,255,255,.5)
      dropShadows: [(Color(0xF2B4FFFF), 7.0)], // rgba(180,255,255,.95)
    ),
    'flair-skull': _FlairGlow(
      textShadows: [(Color(0x80FF0000), 10.0)], // rgba(255,0,0,.5)
    ),
    'flair-star': _FlairGlow(
      textShadows: [(Color(0x80FFFF00), 10.0)], // rgba(255,255,0,.5)
      dropShadows: [(Color(0xE6FFFF00), 6.0)], // rgba(255,255,0,.9)
    ),
    'flair-lightning': _FlairGlow(
      textShadows: [(Color(0x80F7931A), 10.0)], // rgba(247,147,26,.5)
    ),
    'flair-heart': _FlairGlow(
      textShadows: [(Color(0x80FF1493), 10.0)], // rgba(255,20,147,.5)
    ),
    'flair-mask': _FlairGlow(
      textShadows: [(Color(0x80FFFFFF), 10.0)], // rgba(255,255,255,.5)
    ),
    'flair-rocket': _FlairGlow(
      textShadows: [(Color(0x99FF6B6B), 10.0)], // rgba(255,107,107,.6)
    ),
    'flair-shield': _FlairGlow(
      textShadows: [(Color(0x9952FF9D), 10.0)], // rgba(82,255,157,.6)
    ),
    'flair-flame': _FlairGlow(
      textShadows: [(Color(0x99FF7A1A), 10.0)], // rgba(255,122,26,.6)
      dropShadows: [(Color(0xE6FF8C28), 6.0)], // rgba(255,140,40,.9)
    ),
    'flair-snowflake': _FlairGlow(
      textShadows: [(Color(0x997FDFFF), 10.0)], // rgba(127,223,255,.6)
    ),
    'flair-moon': _FlairGlow(
      textShadows: [(Color(0x99CDD6FF), 10.0)], // rgba(205,214,255,.6)
    ),
    'flair-sun': _FlairGlow(
      textShadows: [(Color(0xB3FFC93C), 12.0)], // rgba(255,201,60,.7) 12px
    ),
    'flair-leaf': _FlairGlow(
      textShadows: [(Color(0x995FD35F), 10.0)], // rgba(95,211,95,.6)
    ),
    'flair-music': _FlairGlow(
      textShadows: [(Color(0x99B388FF), 10.0)], // rgba(179,136,255,.6)
    ),
    'flair-eye': _FlairGlow(
      textShadows: [(Color(0x9978DCFF), 10.0)], // rgba(120,220,255,.6)
    ),
    'flair-anchor': _FlairGlow(
      textShadows: [(Color(0x995B9DFF), 10.0)], // rgba(91,157,255,.6)
    ),
    'flair-gem': _FlairGlow(
      textShadows: [(Color(0x99FF3B6B), 10.0)], // rgba(255,59,107,.6)
    ),
    'flair-genesis': _FlairGlow(
      textShadows: [
        (Color(0xB3FFD700), 8.0), // rgba(255,215,0,.7)
        (Color(0x66FFAA00), 16.0), // rgba(255,170,0,.4)
      ],
      dropShadows: [(Color(0xE6FFC800), 7.0)], // rgba(255,200,0,.9)
    ),
  };

  @override
  Widget build(BuildContext context) {
    // Genesis stamps an edition number. The PWA injects it as an SVG `<text>`,
    // but `flutter_svg`/`vector_graphics` silently drops `<text>` elements, so
    // we render the plain icon (NO dead `<text>`) and overlay the number as a
    // real Flutter `Text` below (F2).
    final showGenesisNumber =
        flairId == 'flair-genesis' && edition != null && edition! > 0;
    final svg = showGenesisNumber
        ? ShopCatalog.flairIcon(flairId)
        : ShopCatalog.flairIcon(flairId, edition);
    if (svg.isEmpty) return const SizedBox.shrink();
    final isLight = context.nym.isLight;
    // Light mode swaps to the darker `body.light-mode .flair-X` colour; the
    // `.flair-X` `text-shadow` halo is inert on a path SVG (never painted in
    // either mode), and the `filter: drop-shadow` on star/flame/diamond/genesis
    // is NOT reset by the light-mode rules, so it survives into light mode —
    // `_FlairGlow.shadowsFor` returns exactly those drop-shadow copies.
    final color =
        (isLight ? lightColors[flairId] : colors[flairId]) ?? context.nym.primary;
    final shadows = _glows[flairId]?.shadowsFor(isLight: isLight) ?? const [];
    final icon = ShopSvgIcon(svg: svg, size: size, color: color);
    return Padding(
      padding: const EdgeInsets.only(left: 5),
      child: (shadows.isEmpty && !showGenesisNumber)
          ? icon
          : Stack(
              alignment: Alignment.center,
              children: [
                // Blurred tinted glyph copies (`filter: drop-shadow`).
                for (final (glowColor, blur) in shadows)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ImageFiltered(
                        // Match Flutter's Shadow blur sigma (`Shadow.convertRadius
                        // ToSigma`) so an SVG glow reads like a `text-shadow`/
                        // `drop-shadow` of the same CSS blur radius.
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: Shadow.convertRadiusToSigma(blur),
                          sigmaY: Shadow.convertRadiusToSigma(blur),
                        ),
                        child: ShopSvgIcon(svg: svg, size: size, color: glowColor),
                      ),
                    ),
                  ),
                icon,
                // Genesis edition number, mirroring the PWA's SVG `<text>` at
                // `x=12 y=19.4 font-size=7.5` on the 24-unit viewBox: horizontally
                // centred, sitting near the base of the pyramid. `font-size 7.5`
                // over the 24.1-unit viewBox ≈ 0.31·size; the digit's visual
                // centre falls at ~0.71 of the badge height (Alignment y≈0.42).
                if (showGenesisNumber)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Align(
                        alignment: const Alignment(0, 0.42),
                        child: Text(
                          '$edition',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: color,
                            fontSize: size * 0.31,
                            fontWeight: FontWeight.w700,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// The `.supporter-badge` — gold trophy + "SUPPORTER" pill
/// (`css/styles-features.css` `.supporter-badge`).
class SupporterBadge extends StatelessWidget {
  const SupporterBadge({super.key, this.height = 18});

  final double height;

  static const Color _gold = Color(0xFFFFD700);

  @override
  Widget build(BuildContext context) {
    // Light mode (`body.light-mode .supporter-badge*`): a darker amber pill —
    // bg rgba(180,140,0,.15→.08), border #b8960a, text #7a5c00, icon #9a7800 —
    // so the gold reads on a light surface. Dark mode keeps the bright gold.
    final isLight = context.nym.isLight;
    final gradient = isLight
        ? const [Color(0x26B48C00), Color(0x14B48C00)]
        : const [Color(0x1FFFD700), Color(0x0FFFD700)];
    final border = isLight ? const Color(0xFFB8960A) : const Color(0x4DFFD700);
    final textColor = isLight ? const Color(0xFF7A5C00) : _gold;
    final iconColor = isLight ? const Color(0xFF9A7800) : _gold;
    return Container(
      margin: const EdgeInsets.only(left: 5),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradient,
        ),
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShopSvgIcon(svg: ShopCatalog.trophyIcon, size: 14, color: iconColor),
          const SizedBox(width: 5),
          Text(
            'SUPPORTER',
            style: TextStyle(
              color: textColor,
              fontSize: 11,
              letterSpacing: 1,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// A live message-bubble preview for a message style (F4 / `_shopStyleDemo`):
/// a real `.message-content`-equivalent container rendering "Preview message"
/// in the style's colour + glow ([ShopCatalog.styleVisuals]) with the
/// translucent content background and — for the textured styles — the SAME tiled
/// `--style-pattern` SVG the rendered chat message uses (cosmetics.dart
/// [styleWatermarks] via [StyleWatermarkLayer]), so the card matches the bubble.
class ShopStyleBubblePreview extends StatelessWidget {
  const ShopStyleBubblePreview({
    super.key,
    required this.styleId,
    this.text = 'Preview message',
    this.bubble = true,
    this.sampleIsChild = true,
  });

  final String styleId;
  final String text;

  /// Whether the sample text is an inner `> *` CHILD (the shop item-card demo
  /// wraps "Preview message" in a `<span>`, shop.js `_shopStyleDemo`:724) or a
  /// BARE body text node (the "This is how your messages look." active-items block
  /// puts the text directly in `.message-content`, shop.js:964). It only matters
  /// for the satoshi container/child split: a child shows the orange `#f7931a`,
  /// the bare body shows the white/brown container colour.
  final bool sampleIsChild;

  /// When true (chat-bubbles layout) the demo `.message-content` is the rounded
  /// translucent bubble (`body.chat-bubbles .message-content`); when false (IRC
  /// layout) it is the bare style-coloured glyph line with only `padding: 6px
  /// 10px` (`body:not(.chat-bubbles) .shop-msg-demo .message-content`,
  /// styles-features.css:1415), no bubble background, no radius.
  final bool bubble;

  // NOTE: the shop demo renders `<div class="message style-X">` (shop.js
  // `_shopStyleDemo`, :724), so it is styled by the REAL `.message.style-X
  // .message-content` rules — NOT the `.style-preview-X` classes (which carry a
  // tinted card wash but are never applied by the shop render; the `preview`
  // catalog field is unused). So the wash styles (ocean/sakura/galaxy/toxic/
  // blood/royal/circuit) paint NO content background — only their glowing text +
  // tiled `--style-pattern` watermark — over the layout's default bubble fill.
  // Only satoshi/eclipse/crt carry a real content background (contentBackground).

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Resolve the MODE-AWARE decoration (same source the chat bubble uses), so
    // the card preview switches to the PWA's `body.light-mode` style colours /
    // dropped glow in light mode instead of showing the unreadable dark neons.
    final deco = messageStyleDecoration(styleId, isLight: c.isLight);
    // The same tiled `--style-pattern` SVG the rendered message uses
    // (cosmetics.dart `styleWatermarks`), so the shop card preview matches the
    // chat bubble 1:1 instead of approximating with a single repeating glyph.
    final watermark = styleWatermarks[styleId];
    if (deco == null) {
      return Text(text, style: TextStyle(color: c.text, fontSize: 12));
    }
    // The glyph shadow(s): explicit multi-offset (glitch) or the single glow,
    // already nulled in light mode by `messageStyleDecoration`. fire/ice paint a
    // brighter glyph in the bubble than IRC (`body.chat-bubbles .message.style-X
    // .message-content { color }`), so resolve the colour per the user's layout.
    final base = TextStyle(
      // A wrapped `<span>` sample is an inner `> *` child — for satoshi the bold
      // orange `#f7931a`/`#c47a15`; a bare body node uses the white/brown container
      // colour. `previewColorFor` returns the child colour for the split styles,
      // `textColorFor` the container body colour.
      color: sampleIsChild
          ? deco.previewColorFor(bubble: bubble)
          : deco.textColorFor(bubble: bubble),
      fontSize: 12,
      fontWeight: FontWeight.w600,
      fontFamily: deco.monospace ? 'monospace' : null,
      shadows: deco.textShadows,
    );
    Widget label;
    if (deco.gradient != null) {
      label = ShaderMask(
        shaderCallback: (rect) =>
            LinearGradient(colors: deco.gradient!).createShader(rect),
        child: Text(text, style: base.copyWith(color: Colors.white)),
      );
    } else {
      label = Text(text, style: base);
    }
    // The style's own in-chat `.message-content { background }` (satoshi/eclipse/
    // crt only); null for every other style — they tint via text + watermark, not
    // a content background, exactly as the rendered chat message does.
    final styleBg = deco.contentBackground;
    // IRC layout: `body:not(.chat-bubbles) .shop-msg-demo .message-content` is
    // bare text with only `padding: 6px 10px` — NO rounded bubble, NO default
    // `white@.14` fill. Only the style's own `.message-content { background }`
    // (satoshi/eclipse/crt) still tints it (styleBg), with no radius.
    if (!bubble) {
      // No watermark and no content bg → just the bare padded glyph line.
      if (watermark == null && styleBg == null) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: label,
        );
      }
      // The style still carries its tiled `--style-pattern` watermark (ocean,
      // sakura, …) and/or content bg (satoshi/eclipse/crt) in IRC — just no
      // rounded bubble. The watermark Stack is clipped to the content rect.
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: styleBg),
        clipBehavior: watermark != null ? Clip.antiAlias : Clip.none,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (watermark != null)
              Positioned.fill(child: StyleWatermarkLayer(watermark: watermark)),
            label,
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        // Bubble layout: `body.chat-bubbles .message-content` is the rounded
        // translucent bubble (`background: rgba(255,255,255,.14)`, radius 16 /
        // top-left 4 — styles-features.css:3603-3617). A style with its own
        // content background (satoshi/eclipse/crt) or a card wash paints over it.
        color: styleBg ??
            (c.isLight
                ? const Color(0x1A000000) // light: others → black@.10
                : const Color(0x24FFFFFF)), // dark: white@.14
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(4),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
      ),
      clipBehavior: watermark != null ? Clip.antiAlias : Clip.none,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (watermark != null)
            Positioned.fill(child: StyleWatermarkLayer(watermark: watermark)),
          label,
        ],
      ),
    );
  }
}

/// A live message-bubble preview for a cosmetic aura (F4 / `_shopCosmeticDemo`):
/// composes the exact `box-shadow` ring + glow + border-left + gradient from
/// [ShopCatalog.cosmeticVisuals], plus the legendary prism ring / holographic
/// sheen and the redacted blackout — all locally, no `cosmetics.dart`.
class ShopCosmeticBubblePreview extends StatelessWidget {
  const ShopCosmeticBubblePreview({
    super.key,
    required this.cosmeticId,
    this.text = 'Preview message',
    this.bubble = true,
  });

  final String cosmeticId;
  final String text;

  /// Chat-bubbles vs IRC layout. In bubble mode the aura decorates the rounded
  /// translucent `.message-content` (which carries the default `white@.14` fill);
  /// in IRC mode the aura paints its border-left + glow + gradient wash on the
  /// flat row, with no rounded bubble fill
  /// (`body:not(.chat-bubbles) .message.cosmetic-aura-*`).
  final bool bubble;

  static const _radius = 8.0;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Redacted: the `.cosmetic-redacted-message` blank — a translucent white
    // bar (`background: rgba(255,255,255,.15)`, color transparent, radius xs=8,
    // min-width 120px, min-height 1.2em — styles-features.css:1424-1435). The
    // shop demo applies the class immediately (shop.js:779), so the card always
    // shows the blanked state.
    if (cosmeticId == 'cosmetic-redacted') {
      return Container(
        constraints: const BoxConstraints(minWidth: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0x26FFFFFF), // rgba(255,255,255,.15)
          borderRadius: BorderRadius.circular(_radius),
        ),
        // Transparent text reserves the 1.2em line-height of a real message.
        child: Text(
          text,
          style: const TextStyle(color: Colors.transparent, fontSize: 12),
        ),
      );
    }
    final v = ShopCatalog.cosmeticVisuals[cosmeticId];
    if (v == null) {
      return Text(text, style: TextStyle(color: c.text, fontSize: 12));
    }
    // In chat-bubbles mode the aura sits on the rounded `.message-content`, which
    // carries the default translucent fill (`white@.14` dark / `black@.10` light)
    // unless the aura paints its own gradient. In IRC mode the row is flat — the
    // aura's border-left + glow + gradient wash paint directly, with no bubble fill.
    final Color? defaultFill = (bubble && v.gradient == null)
        ? (c.isLight ? const Color(0x1A000000) : const Color(0x24FFFFFF))
        : null;
    Widget cosmeticBubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: defaultFill,
        gradient: (v.gradient != null && v.sheenGradient == null)
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: v.gradient!,
              )
            : null,
        border: v.borderLeft != null
            ? Border(left: BorderSide(color: v.borderLeft!, width: 3))
            : null,
        borderRadius: BorderRadius.circular(_radius),
        boxShadow: v.boxShadows,
      ),
      child: Text(text, style: TextStyle(color: c.text, fontSize: 12)),
    );
    // Holographic sheen — a screen-blended multi-colour gradient behind the text.
    if (v.sheenGradient != null) {
      cosmeticBubble = ClipRRect(
        borderRadius: BorderRadius.circular(_radius),
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: v.sheenGradient!,
                  ),
                ),
              ),
            ),
            const Positioned.fill(child: _HologramSheen()),
            cosmeticBubble,
          ],
        ),
      );
    }
    // Legendary prism ring — a conic sweep-gradient ring around the bubble.
    if (v.ringGradient != null) {
      cosmeticBubble = CustomPaint(
        foregroundPainter: _PrismRingPainter(
          colors: v.ringGradient!,
          radius: _radius,
        ),
        child: cosmeticBubble,
      );
    }
    return cosmeticBubble;
  }
}

/// Renders the preview region for a single shop item card depending on its type.
/// Styles + cosmetics use the live message-bubble demos (F4); flair shows the
/// nym + badge; supporter shows the badge over a gold demo bubble.
class ShopItemPreview extends StatelessWidget {
  const ShopItemPreview({super.key, required this.item, this.bubble = true});

  final ShopItem item;

  /// The user's current chat layout (chat-bubbles vs IRC). Threaded into the
  /// live message demos so the card preview renders the cosmetic AS IT WOULD
  /// APPEAR in the user's layout — the `.shop-msg-demo` reuses the real
  /// `.message`/`.message-content` classes, which the PWA styles by
  /// `body.chat-bubbles` vs `body:not(.chat-bubbles)`. The flair/supporter-badge
  /// nym rows are identical in both layouts (plain `.shop-item-preview` text).
  final bool bubble;

  @override
  Widget build(BuildContext context) {
    switch (item.type) {
      case 'message-style':
        return ShopStyleBubblePreview(styleId: item.id, bubble: bubble);
      case 'nickname-flair':
        // The Genesis card stamps a sample edition (#69) on the badge, matching
        // `_renderLimitedCard`.
        final sampleEdition = item.id == 'flair-genesis' ? 69 : null;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Your_Nick',
                style: TextStyle(fontWeight: FontWeight.w600)),
            FlairBadge(flairId: item.id, edition: sampleEdition),
          ],
        );
      case 'supporter':
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text('Your_Nick', style: TextStyle(fontWeight: FontWeight.w600)),
                SupporterBadge(),
              ],
            ),
            const SizedBox(height: 8),
            // supporter-style demo bubble (gold text + wash).
            _SupporterStyleBubble(bubble: bubble),
          ],
        );
      case 'cosmetic':
        return ShopCosmeticBubblePreview(cosmeticId: item.id, bubble: bubble);
      default:
        return const SizedBox.shrink();
    }
  }
}

/// The supporter-style demo bubble (`.message.supporter-style`): gold glyphs +
/// soft glow over the layout-appropriate surface.
///
/// * IRC (`body:not(.chat-bubbles) .message.supporter-style`,
///   styles-features.css:1473): a 135° gold wash (`rgba(255,215,0,.05)` →
///   `.02`) + a 3px gold left bar on the flat row, no radius.
/// * Bubble (`body.chat-bubbles .message.supporter-style .message-content`,
///   styles-features.css:3692): a flat `rgba(255,215,0,.12)` fill on the rounded
///   bubble (radius 16 / top-left 4), no left bar.
class _SupporterStyleBubble extends StatelessWidget {
  const _SupporterStyleBubble({this.bubble = true});

  final bool bubble;

  @override
  Widget build(BuildContext context) {
    const text = Text(
      'Preview message',
      style: TextStyle(
        color: Color(0xFFFFD700),
        fontSize: 12,
        fontWeight: FontWeight.w600,
        shadows: [Shadow(color: Color(0x40FFD700), blurRadius: 8)],
      ),
    );
    if (!bubble) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0x0DFFD700), Color(0x05FFD700)], // gold@.05 → @.02
          ),
          border: Border(left: BorderSide(color: Color(0xFFFFD700), width: 3)),
        ),
        child: text,
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: const BoxDecoration(
        color: Color(0x1FFFD700), // gold@.12
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(4),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
      ),
      child: text,
    );
  }
}

/// Paints a conic prism ring around a bubble (F8 — `cosmetic-aura-rainbow`'s
/// masked 3px `conic-gradient`). A `SweepGradient` stroked at the bubble border.
class _PrismRingPainter extends CustomPainter {
  _PrismRingPainter({required this.colors, required this.radius});

  final List<Color> colors;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    const stroke = 3.0;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(stroke / 2),
      Radius.circular(radius),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..shader = SweepGradient(
        colors: colors,
        center: Alignment.center,
      ).createShader(rect);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_PrismRingPainter old) => old.colors != colors;
}

/// The holographic diagonal white sheen band (F8 — `cosmetic-bubble-hologram`'s
/// 115deg `rgba(255,255,255,.28)` sheen, screen-blended).
class _HologramSheen extends StatelessWidget {
  const _HologramSheen();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(-1, -0.6),
          end: Alignment(1, 0.6),
          colors: [
            Colors.transparent,
            Color(0x47FFFFFF),
            Colors.transparent,
          ],
          stops: [0.40, 0.50, 0.60],
        ),
        backgroundBlendMode: BlendMode.screen,
      ),
    );
  }
}

/// The limited-tab supply/availability badge (F5 — `.shop-supply-badge
/// shop-supply-{state}`). Three colour tiers: available green `#52ff9d`, soon
/// blue `#7fdfff`, ended/soldout red `#ff6b6b` (`styles-features.css:1342-1359`).
class ShopSupplyBadge extends StatelessWidget {
  const ShopSupplyBadge({super.key, required this.availability});

  final ShopAvailability availability;

  static const _available = (
    fg: Color(0xFF52FF9D),
    bg: Color(0x1F52FF9D),
    border: Color(0x5952FF9D),
  );
  static const _soon = (
    fg: Color(0xFF7FDFFF),
    bg: Color(0x1F7FDFFF),
    border: Color(0x597FDFFF),
  );
  static const _danger = (
    fg: Color(0xFFFF6B6B),
    bg: Color(0x1FFF6B6B),
    border: Color(0x59FF6B6B),
  );

  @override
  Widget build(BuildContext context) {
    if (availability.label.isEmpty) return const SizedBox.shrink();
    final tier = switch (availability.state) {
      ShopAvailabilityState.available => _available,
      ShopAvailabilityState.soon => _soon,
      ShopAvailabilityState.ended ||
      ShopAvailabilityState.soldout =>
        _danger,
    };
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: tier.bg,
        border: Border.all(color: tier.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        availability.label,
        style: TextStyle(
          color: tier.fg,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// The bundle content chips + savings badge (F6 — `_renderBundleCard`):
/// each component as a `.shop-bundle-chip` (icon + name, capped at 10 with
/// "+N more"), above a "Save X% · N sats value" badge.
class ShopBundlePreview extends StatelessWidget {
  const ShopBundlePreview({super.key, required this.item});

  final ShopItem item;

  static const _chipCap = 10;

  @override
  Widget build(BuildContext context) {
    final all = ShopCatalog.bundleComponents(item.id);
    final shown = all.take(_chipCap).toList();
    final savePct = ShopCatalog.bundleSavePercent(item.id);
    final value = ShopCatalog.bundleValue(item.id);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (savePct > 0)
          ShopSupplyBadge(
            availability: ShopAvailability(
              ShopAvailabilityState.available,
              'Save $savePct% · $value sats value',
            ),
          ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          alignment: WrapAlignment.center,
          children: [
            for (final id in shown) _BundleChip(itemId: id),
            if (all.length > _chipCap)
              _BundleChip.more(all.length - _chipCap),
          ],
        ),
      ],
    );
  }
}

/// A single `.shop-bundle-chip`: the component's SVG icon + name in a rounded
/// secondary-tinted pill (`styles-features.css:1369-1383`).
class _BundleChip extends StatelessWidget {
  const _BundleChip({required this.itemId}) : extra = 0;
  const _BundleChip.more(this.extra) : itemId = null;

  final String? itemId;
  final int extra;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final item = itemId == null ? null : ShopCatalog.byId(itemId!);
    final label = item?.name ?? '+$extra more';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.secondaryA(0.10),
        border: Border.all(color: c.secondaryA(0.30)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (item != null) ...[
            ShopSvgIcon(svg: item.icon, size: 14, color: c.text),
            const SizedBox(width: 4),
          ],
          Text(label, style: TextStyle(color: c.text, fontSize: 11)),
        ],
      ),
    );
  }
}

/// The gold edition-number stamp (`#{n}/{max}`, `.shop-edition-no`,
/// `styles-features.css:1385-1390`): gold `#ffdf6b`, 12px 700, soft gold glow.
class ShopEditionNumber extends StatelessWidget {
  const ShopEditionNumber({super.key, required this.edition, this.editionMax});

  final int edition;
  final int? editionMax;

  @override
  Widget build(BuildContext context) {
    return Text(
      '#$edition${editionMax != null ? '/$editionMax' : ''}',
      style: const TextStyle(
        color: Color(0xFFFFDF6B),
        fontSize: 12,
        fontWeight: FontWeight.w700,
        shadows: [Shadow(color: Color(0x66FFD700), blurRadius: 6)],
      ),
    );
  }
}

/// A click-to-copy recovery-code row (F9/F10 — `.nm-shop-6`/`.nm-shop-7`):
/// a "Recovery code" label over the monospace code; tapping copies it.
class RecoveryCodeRow extends StatelessWidget {
  const RecoveryCodeRow({
    super.key,
    required this.code,
    this.label = 'Recovery code',
  });

  final String code;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child:
                Text(label, style: TextStyle(color: c.textDim, fontSize: 10)),
          ),
        const SizedBox(height: 2),
        InkWell(
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: code));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied recovery code')),
              );
            }
          },
          child: Tooltip(
            message: 'Click to copy',
            child: Text(
              code,
              style: TextStyle(
                color: c.textBright,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The 45deg "LEGENDARY" corner ribbon (F14 — `.shop-legendary-ribbon`):
/// gradient `#ffb340→#ff7ad9`, dark text, 8px 800-weight, rotated 45deg in the
/// top-right corner. Wrap the card in a `Stack` and clip it.
class ShopLegendaryRibbon extends StatelessWidget {
  const ShopLegendaryRibbon({super.key});

  @override
  Widget build(BuildContext context) {
    // top:24px right:-48px width:160px rotate(45deg) (styles-features.css:1312).
    return Positioned(
      top: 24,
      right: -48,
      child: Transform.rotate(
        angle: 45 * math.pi / 180,
        child: Container(
          width: 160,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFFFB340), Color(0xFFFF7AD9)],
            ),
            boxShadow: [BoxShadow(color: Color(0x59000000), blurRadius: 4, offset: Offset(0, 1))],
          ),
          child: const Text(
            'LEGENDARY',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFF1A1320),
              fontSize: 8,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ),
      ),
    );
  }
}
