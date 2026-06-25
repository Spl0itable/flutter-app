import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/nym_colors.dart';
import 'cosmetics.dart' show StyleWatermarkLayer, styleWatermarks;
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
///   * `text-shadow` — the soft coloured halo. `body.light-mode .flair-X` sets
///     `text-shadow: none`, so these copies are dropped in light mode.
///   * `filter: drop-shadow(...)` — only on the brighter star/flame/diamond/
///     genesis. The light-mode overrides reset `color`/`text-shadow` but NOT
///     `filter`, so this copy SURVIVES into light mode (per the cascade).
/// Keeping the two lists distinct lets us reproduce that asymmetry exactly.
class _FlairGlow {
  const _FlairGlow({this.textShadows = const [], this.dropShadows = const []});

  /// `text-shadow` blurs (colour, blurRadius) — dark mode only.
  final List<(Color, double)> textShadows;

  /// `filter: drop-shadow` blurs (colour, blurRadius) — both modes.
  final List<(Color, double)> dropShadows;

  /// The glow copies to paint for the given theme: in dark mode both the
  /// `text-shadow` and `drop-shadow` copies; in light mode only the surviving
  /// `drop-shadow` copies (`text-shadow: none`).
  List<(Color, double)> shadowsFor({required bool isLight}) =>
      isLight ? dropShadows : [...textShadows, ...dropShadows];
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
    final svg = ShopCatalog.flairIcon(flairId, edition);
    if (svg.isEmpty) return const SizedBox.shrink();
    final isLight = context.nym.isLight;
    // Light mode swaps to the darker `body.light-mode .flair-X` colour and drops
    // the `text-shadow` halo (`text-shadow: none`); dark mode keeps the bright
    // colour + full glow. The `filter: drop-shadow` on star/flame/diamond/
    // genesis is NOT reset by the light-mode rules, so it survives into light
    // mode — `_FlairGlow.shadowsFor` keeps exactly those copies.
    final color =
        (isLight ? lightColors[flairId] : colors[flairId]) ?? context.nym.primary;
    final shadows = _glows[flairId]?.shadowsFor(isLight: isLight) ?? const [];
    final icon = ShopSvgIcon(svg: svg, size: size, color: color);
    return Padding(
      padding: const EdgeInsets.only(left: 5),
      child: shadows.isEmpty
          ? icon
          : Stack(
              alignment: Alignment.center,
              children: [
                // Blurred tinted glyph copies (`text-shadow`/`drop-shadow`).
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
  });

  final String styleId;
  final String text;

  /// Shop-card-only `.style-preview-*` translucent wash backgrounds
  /// (styles-features.css:713-936). These 8 wash styles paint a denser tint
  /// behind the CARD preview that the in-chat `.message-content` does NOT (so
  /// `styleVisuals.contentBackground` is null for them — the rendered message is
  /// correctly bg-less). Preview-only.
  static const Map<String, Color> _previewWash = {
    'style-ocean': Color(0x2938BDF8), // rgba(56,189,248,.16)
    'style-sakura': Color(0x24FF7EB6), // rgba(255,126,182,.14)
    'style-galaxy': Color(0x2EA855F7), // rgba(168,85,247,.18)
    'style-toxic': Color(0x2484FF3B), // rgba(132,255,59,.14)
    'style-blood': Color(0x33780000), // rgba(120,0,0,.2)
    'style-royal': Color(0x2E8B5CF6), // rgba(139,92,246,.18)
    'style-circuit': Color(0x242DD4BF), // rgba(45,212,191,.14)
    // vapor uses background-clip:text (gradient glyphs), no solid card wash.
  };

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final v = ShopCatalog.styleVisuals[styleId];
    // The same tiled `--style-pattern` SVG the rendered message uses
    // (cosmetics.dart `styleWatermarks`), so the shop card preview matches the
    // chat bubble 1:1 instead of approximating with a single repeating glyph.
    final watermark = styleWatermarks[styleId];
    if (v == null) {
      return Text(text, style: TextStyle(color: c.text, fontSize: 12));
    }
    // The glyph shadow(s): explicit multi-offset (glitch) or the single glow.
    final shadows = v.glyphShadows ??
        (v.glow != null ? [Shadow(color: v.glow!, blurRadius: 10)] : null);
    final base = TextStyle(
      color: v.color,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      fontFamily: v.monospace ? 'monospace' : null,
      shadows: shadows,
    );
    Widget label;
    if (v.gradient != null) {
      label = ShaderMask(
        shaderCallback: (rect) =>
            LinearGradient(colors: v.gradient!).createShader(rect),
        child: Text(text, style: base.copyWith(color: Colors.white)),
      );
    } else {
      label = Text(text, style: base);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        // Prefer the shop-card wash for the 8 preview styles; else the in-chat
        // content background (satoshi/eclipse/crt).
        color: _previewWash[styleId] ?? v.contentBackground,
        borderRadius: BorderRadius.circular(8),
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
  });

  final String cosmeticId;
  final String text;

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
    Widget bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
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
      bubble = ClipRRect(
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
            bubble,
          ],
        ),
      );
    }
    // Legendary prism ring — a conic sweep-gradient ring around the bubble.
    if (v.ringGradient != null) {
      bubble = CustomPaint(
        foregroundPainter: _PrismRingPainter(
          colors: v.ringGradient!,
          radius: _radius,
        ),
        child: bubble,
      );
    }
    return bubble;
  }
}

/// Renders the preview region for a single shop item card depending on its type.
/// Styles + cosmetics use the live message-bubble demos (F4); flair shows the
/// nym + badge; supporter shows the badge over a gold demo bubble.
class ShopItemPreview extends StatelessWidget {
  const ShopItemPreview({super.key, required this.item});

  final ShopItem item;

  @override
  Widget build(BuildContext context) {
    switch (item.type) {
      case 'message-style':
        return ShopStyleBubblePreview(styleId: item.id);
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
            const _SupporterStyleBubble(),
          ],
        );
      case 'cosmetic':
        return ShopCosmeticBubblePreview(cosmeticId: item.id);
      default:
        return const SizedBox.shrink();
    }
  }
}

/// The supporter-style demo bubble (`.message.supporter-style`): gold glyphs +
/// soft glow + faint gold wash + gold left bar.
class _SupporterStyleBubble extends StatelessWidget {
  const _SupporterStyleBubble();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x14FFD700),
        border: const Border(left: BorderSide(color: Color(0xFFFFD700), width: 3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        'Preview message',
        style: TextStyle(
          color: Color(0xFFFFD700),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          shadows: [Shadow(color: Color(0x40FFD700), blurRadius: 8)],
        ),
      ),
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
