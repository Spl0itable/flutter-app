import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/nym_colors.dart';
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

/// The `.flair-badge` — a flair item's SVG tinted to its themed colour, sized
/// like the web (`font-size: 20px`). Genesis stamps its edition number.
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

  /// Themed flair colours, mirroring the `.flair-X` CSS rules.
  static const Map<String, Color> colors = {
    'flair-crown': Color(0xFFFFD700),
    'flair-diamond': Color(0xFF00FFFF),
    'flair-skull': Color(0xFFFF0000),
    'flair-star': Color(0xFFFFFF00),
    'flair-lightning': Color(0xFFF7931A),
    'flair-heart': Color(0xFFFF5577),
    'flair-mask': Color(0xFFCFCFCF),
    'flair-rocket': Color(0xFFFF6B6B),
    'flair-shield': Color(0xFF4ADE80),
    'flair-flame': Color(0xFFFF8C00),
    'flair-snowflake': Color(0xFF7DD3FC),
    'flair-moon': Color(0xFFFFE066),
    'flair-sun': Color(0xFFFFC300),
    'flair-leaf': Color(0xFF4ADE80),
    'flair-music': Color(0xFFA78BFA),
    'flair-eye': Color(0xFFD4C5F9),
    'flair-anchor': Color(0xFF93C5FD),
    'flair-gem': Color(0xFFFF4D6D),
    'flair-genesis': Color(0xFFFFC440),
  };

  @override
  Widget build(BuildContext context) {
    final svg = ShopCatalog.flairIcon(flairId, edition);
    if (svg.isEmpty) return const SizedBox.shrink();
    final color = colors[flairId] ?? context.nym.primary;
    return Padding(
      padding: const EdgeInsets.only(left: 5),
      child: ShopSvgIcon(svg: svg, size: size, color: color),
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
    return Container(
      margin: const EdgeInsets.only(left: 5),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x1FFFD700), Color(0x0FFFD700)],
        ),
        border: Border.all(color: const Color(0x4DFFD700)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShopSvgIcon(svg: ShopCatalog.trophyIcon, size: 14, color: _gold),
          const SizedBox(width: 5),
          const Text(
            'SUPPORTER',
            style: TextStyle(
              color: _gold,
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
/// in the style's colour + glow, with the translucent content background and
/// (for the textured styles) a tiled glyph watermark — built locally from
/// [ShopCatalog.styleVisuals]/[stylePatternGlyph] so it doesn't depend on
/// `cosmetics.dart`.
class ShopStyleBubblePreview extends StatelessWidget {
  const ShopStyleBubblePreview({
    super.key,
    required this.styleId,
    this.text = 'Preview message',
  });

  final String styleId;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final v = ShopCatalog.styleVisuals[styleId];
    final glyph = ShopCatalog.stylePatternGlyph(styleId);
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
        color: v.contentBackground,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: glyph != null ? Clip.antiAlias : Clip.none,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (glyph != null)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _GlyphWatermarkPainter(
                    glyph: glyph,
                    color: v.color,
                    monospace: v.monospace,
                  ),
                ),
              ),
            ),
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
    // Redacted: blanked-out content (cosmetic-redacted-message).
    if (cosmeticId == 'cosmetic-redacted') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(_radius),
        ),
        child: const Text(
          '████████',
          style: TextStyle(color: Color(0xFF1A1A1A), fontSize: 12),
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

/// Paints a tiled glyph watermark behind a style's preview text (F3/F7): the
/// style's defining repeating character (`₿`, `10`, etc.) drawn faintly across
/// the bubble. A lightweight stand-in for the PWA's repeating-SVG `--style-pattern`.
class _GlyphWatermarkPainter extends CustomPainter {
  _GlyphWatermarkPainter({
    required this.glyph,
    required this.color,
    required this.monospace,
  });

  final String glyph;
  final Color color;
  final bool monospace;

  @override
  void paint(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: glyph,
        style: TextStyle(
          color: color.withValues(alpha: 0.14),
          fontSize: 10,
          fontFamily: monospace ? 'monospace' : null,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const stepX = 18.0;
    const stepY = 14.0;
    var rowIndex = 0;
    for (var y = 0.0; y < size.height + stepY; y += stepY) {
      // Offset alternate rows for a staggered tiled look.
      final offset = rowIndex.isOdd ? stepX / 2 : 0.0;
      for (var x = -offset; x < size.width + stepX; x += stepX) {
        tp.paint(canvas, Offset(x, y));
      }
      rowIndex++;
    }
  }

  @override
  bool shouldRepaint(_GlyphWatermarkPainter old) =>
      old.glyph != glyph || old.color != color || old.monospace != monospace;
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
