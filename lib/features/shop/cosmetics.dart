import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import 'shop_catalog.dart';
import 'shop_controller.dart';
import 'shop_models.dart';
import 'shop_widgets.dart';

/// The resolved flair-shop cosmetics that should decorate a user's messages and
/// nym, gathered from the right source for the pubkey:
///
/// * For the SELF pubkey we read the live [shopControllerProvider] active state
///   (the same `{style, flair, supporter}` the PWA's `getUserShopItems` returns
///   for `this.pubkey`).
/// * For everyone else we read the [User] fields populated from presence /
///   shop-status ingestion (`shopStyle`, `shopFlair`, `isSupporter`).
///
/// Mirrors `js/modules/shop.js` `getUserShopItems(pubkey)`.
class UserCosmetics {
  const UserCosmetics({
    this.styleId,
    this.flairId,
    this.supporter = false,
    this.cosmetics = const [],
    this.genesisEdition,
  });

  /// Active message-style item id (e.g. `style-satoshi`), or null.
  final String? styleId;

  /// Active nickname-flair item id (e.g. `flair-crown`), or null.
  final String? flairId;

  /// True when the user owns + has the supporter badge active.
  final bool supporter;

  /// Active special-cosmetic ids (`cosmetic-aura-gold`, `cosmetic-frost`,
  /// `cosmetic-bubble-hologram`, `cosmetic-redacted`, …). Composed onto the
  /// message bubble/row alongside the style. (`shop.js:485-509`.)
  final List<String> cosmetics;

  /// Genesis edition number stamped on the `flair-genesis` badge, if known.
  final int? genesisEdition;

  bool get isEmpty =>
      styleId == null && flairId == null && !supporter && cosmetics.isEmpty;
  bool get isNotEmpty => !isEmpty;

  /// True when the redacted privacy cosmetic is active (blanks content + author
  /// after a delay — `shop.js:498-503`).
  bool get isRedacted => cosmetics.contains('cosmetic-redacted');

  static const UserCosmetics none = UserCosmetics();
}

/// Resolves the [UserCosmetics] for [pubkey]. Reads `shopControllerProvider` for
/// the self pubkey and `usersProvider` for others. Pure with respect to its
/// inputs (no side effects), so it can be called from `build`.
UserCosmetics resolveCosmetics(WidgetRef ref, String pubkey) {
  final selfPubkey = ref.read(nostrControllerProvider).identity?.pubkey;
  if (selfPubkey != null && pubkey == selfPubkey) {
    return _selfCosmetics(ref.read(shopControllerProvider).active);
  }
  final user = ref.read(usersProvider)[pubkey];
  return userCosmeticsFromUser(user);
}

/// Builds [UserCosmetics] from the self pubkey's live shop [active] state
/// (`getUserShopItems(this.pubkey)`), including the cosmetics array + Genesis
/// edition number.
UserCosmetics _selfCosmetics(ActiveItems active) {
  return UserCosmetics(
    styleId: active.style,
    flairId: active.flair.isNotEmpty ? active.flair.last : null,
    supporter: active.supporter,
    cosmetics: active.cosmetics,
    genesisEdition: active.editions['flair-genesis'],
  );
}

/// Builds [UserCosmetics] from a [User]'s presence-broadcast cosmetic fields.
/// Exposed for tests and for the `watch`-based [userCosmeticsProvider].
UserCosmetics userCosmeticsFromUser(User? user) {
  if (user == null) return UserCosmetics.none;
  return UserCosmetics(
    styleId: (user.shopStyle != null && user.shopStyle!.isNotEmpty)
        ? user.shopStyle
        : null,
    flairId: (user.shopFlair != null && user.shopFlair!.isNotEmpty)
        ? user.shopFlair
        : null,
    supporter: user.isSupporter,
    cosmetics: user.shopCosmetics,
    genesisEdition: user.shopEdition,
  );
}

/// Family provider variant of [resolveCosmetics], so widgets can `watch` a
/// pubkey's cosmetics and rebuild when the self shop state or the user's
/// presence-broadcast cosmetics change.
final userCosmeticsProvider =
    Provider.family<UserCosmetics, String>((ref, pubkey) {
  final selfPubkey = ref.watch(nostrControllerProvider).identity?.pubkey;
  if (selfPubkey != null && pubkey == selfPubkey) {
    return _selfCosmetics(ref.watch(shopControllerProvider).active);
  }
  final user = ref.watch(usersProvider)[pubkey];
  return userCosmeticsFromUser(user);
});

/// The inline flair + supporter badges that follow a nym wherever it is
/// rendered (after the `#suffix`, before any friend badge — mirroring
/// `_applyFlairBadgesToMessage`). Reuses the shop's [FlairBadge] /
/// [SupporterBadge] widgets so the glyphs/colours/gradient match the shop 1:1.
///
/// Renders nothing when the user has no active flair and is not a supporter.
class CosmeticNymBadges extends StatelessWidget {
  const CosmeticNymBadges({
    super.key,
    required this.cosmetics,
    this.edition,
    // `.flair-badge { font-size: 20px }` — the PWA-exact glyph size on every nym
    // (styles-features.css:316-320). (Was 16, an under-sized substitute.)
    this.flairSize = 20,
    this.supporterHeight = 18,
  });

  final UserCosmetics cosmetics;

  /// Genesis edition number to stamp on a numbered flair, if known.
  final int? edition;

  final double flairSize;
  final double supporterHeight;

  @override
  Widget build(BuildContext context) {
    final flairId = cosmetics.flairId;
    final supporter = cosmetics.supporter;
    if ((flairId == null || flairId.isEmpty) && !supporter) {
      return const SizedBox.shrink();
    }
    // Stamp the Genesis edition number when the active flair is genesis and an
    // explicit edition wasn't passed (`_flairIconHtml(id, editions[id])`).
    final ed = edition ??
        (flairId == 'flair-genesis' ? cosmetics.genesisEdition : null);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (flairId != null && flairId.isNotEmpty)
          FlairBadge(flairId: flairId, edition: ed, size: flairSize),
        if (supporter) SupporterBadge(height: supporterHeight),
      ],
    );
  }
}

/// True when [cosmetics] should bold the whole author nym — the Genesis holder
/// treatment (`.has-genesis-flair { font-weight: 700 }`, the suffix stays 400).
bool hasGenesisFlair(UserCosmetics cosmetics) =>
    cosmetics.flairId == 'flair-genesis';

/// A faithful Flutter translation of a `.message.style-X` rule from
/// `css/styles-features.css`. Captures the parts we can render natively:
///
/// * [textColor] — the glyph colour (`.message-content { color }`).
/// * [glow] — the text-shadow glow colour (approximated as a [Shadow] on the
///   content text and as a soft box-shadow behind it).
/// * [gradient] — for gradient-text styles (aurora), drawn via a `ShaderMask`.
/// * [contentBackground] — the translucent `.message-content { background-color }`
///   some styles paint behind the text (satoshi / ocean / eclipse / crt / …).
/// * [borderAccent] — a left accent bar painted in IRC layout (supporter-style).
/// * [monospace] — CRT renders in a monospace family.
///
/// The per-glyph repeating SVG watermarks (`--style-pattern`) and the animated
/// effects (prism rotation, glitch offset shadows) are intentionally omitted —
/// see TODO(verify) notes in the task report.
class MessageStyleDecoration {
  const MessageStyleDecoration({
    required this.textColor,
    this.glow,
    this.gradient,
    this.contentBackground,
    this.borderAccent,
    this.monospace = false,
    this.glyphShadows,
    this.watermark,
  });

  final Color textColor;
  final Color? glow;
  final List<Color>? gradient;
  final Color? contentBackground;
  final Color? borderAccent;
  final bool monospace;

  /// Explicit glyph shadows that override the default blurred [glow] — used for
  /// the glitch style's red/-2px + cyan/+2px chromatic split (`.style-glitch`).
  final List<Shadow>? glyphShadows;

  /// The repeating-SVG / scanline texture painted behind the content
  /// (`--style-pattern` / `.message-content::before`), or null.
  final StyleWatermark? watermark;

  /// The glyph [Shadow]s reproducing the CSS `text-shadow` glow. Glitch supplies
  /// its own [glyphShadows]; otherwise a single soft blurred glow.
  List<Shadow>? get textShadows {
    if (glyphShadows != null) return glyphShadows;
    return glow != null ? [Shadow(color: glow!, blurRadius: 10)] : null;
  }
}

/// A repeating texture painted behind a styled message's content. Either a tiled
/// inline SVG (`svg` + the tile [size]) or a programmatic scanline painter
/// ([scanlines] = CRT/eclipse). Mirrors `--style-pattern`.
class StyleWatermark {
  const StyleWatermark.svg(this.svg, this.size)
      : scanline = null,
        scanlineGap = 0,
        scanlineThickness = 0;

  /// A repeating horizontal scanline (CRT): [scanline]-coloured lines of
  /// [scanlineThickness]px every [scanlineGap]px.
  const StyleWatermark.scanlines({
    required Color color,
    required this.scanlineGap,
    required this.scanlineThickness,
  })  : svg = null,
        size = Size.zero,
        scanline = color;

  final String? svg;
  final Size size;
  final Color? scanline;
  final double scanlineGap;
  final double scanlineThickness;

  bool get isScanlines => scanline != null;
}

/// A resolved special-cosmetic aura composed onto a message bubble/row
/// (`.message.cosmetic-X`). Captures the parts we can render natively: an inset
/// + outer glow box-shadow, a left accent bar (IRC), a background gradient, and
/// an optional tiled watermark. (`styles-features.css:1099-1211`.)
class CosmeticAura {
  const CosmeticAura({
    required this.id,
    this.insetColor,
    this.insetWidth = 1,
    this.glowColor,
    this.glowBlur = 0,
    this.borderAccent,
    this.gradient,
    this.background,
    this.watermark,
    this.prismRing = false,
    this.hologram = false,
    this.insetRing = false,
  });

  final String id;

  /// `box-shadow: inset 0 0 0 {insetWidth}px {insetColor}`. Rendered as a true
  /// inner ring (stroked fully INSIDE the bubble edge — not an outset glow) by
  /// [CosmeticOverlayPainter] when [insetRing] is set (which, via [hasOverlay],
  /// is the path `message_row` takes for every inset-ring aura). See the
  /// CROSS-FILE NOTE on [CosmeticOverlayPainter] re: the redundant `Border.all`
  /// `message_row` should drop so the ring isn't drawn twice.
  final Color? insetColor;
  final double insetWidth;

  /// `box-shadow: 0 0 {glowBlur}px {glowColor}`.
  final Color? glowColor;
  final double glowBlur;

  /// `border-left: 3px solid …` (IRC).
  final Color? borderAccent;

  /// 135deg background gradient behind the content.
  final List<Color>? gradient;

  /// A flat background fill (frost icy wash) when there's no gradient.
  final Color? background;

  /// A tiled SVG watermark (frost snowflakes / cosmic starfield).
  final StyleWatermark? watermark;

  /// Render the conic prism ring border (rainbow). Painted via a sweep gradient.
  final bool prismRing;

  /// Render the holographic multi-gradient sheen (hologram).
  final bool hologram;

  /// Render the `inset 0 0 0 {insetWidth}px {insetColor}` box-shadow as a true
  /// inner ring (+ a soft inward feather) via [CosmeticOverlayPainter]. Set for
  /// the aura ids whose CSS box-shadow has an `inset` part
  /// (gold/neon/phoenix/cosmic/frost/hologram). All of these reach the painter
  /// today (via [hasOverlay]); see the CROSS-FILE NOTE on
  /// [CosmeticOverlayPainter] for the `message_row` `Border.all` that must be
  /// suppressed to avoid a double ring.
  final bool insetRing;

  /// True when this aura should be painted by [CosmeticOverlayPainter] (it has a
  /// prism ring, holographic sheen, or a true inset ring to stroke).
  bool get hasOverlay => prismRing || hologram || insetRing;
}

/// Maps a message-style id to its [MessageStyleDecoration], or null for an
/// unknown id (or null). Pure. Sourced from the per-style `styleVisuals` table
/// (`shop_catalog.dart`, ported from `css/styles-features.css`).
MessageStyleDecoration? messageStyleDecoration(String? styleId) {
  if (styleId == null || styleId.isEmpty) return null;
  final v = ShopCatalog.styleVisuals[styleId];
  if (v == null) return null;
  return MessageStyleDecoration(
    textColor: v.color,
    glow: v.glow,
    gradient: v.gradient,
    contentBackground: _styleContentBackground[styleId],
    monospace: v.monospace,
    glyphShadows: _styleGlyphShadows[styleId],
    watermark: styleWatermarks[styleId],
  );
}

/// Explicit glyph shadows for styles whose CSS `text-shadow` is not a single
/// soft glow. Glitch (`.style-glitch`) is a red/-2px + cyan/+2px chromatic split
/// (`styles-features.css:625-628`).
const Map<String, List<Shadow>> _styleGlyphShadows = {
  'style-glitch': [
    Shadow(color: Color(0xFFFF0000), offset: Offset(-2, 0)),
    Shadow(color: Color(0xFF00FFFF), offset: Offset(2, 0)),
  ],
};

/// Per-style repeating-SVG / scanline watermarks (`--style-pattern` /
/// `.message-content::before`), ported verbatim from `styles-features.css`.
/// Every textured `.message.style-X` is covered: the SVG path data, tile sizes
/// and `fill/stroke-opacity` alphas are the exact in-chat `--style-pattern`
/// values (`styles-features.css:593-943,1257,1286`) — NOT the denser
/// `.style-preview-*` alphas (those are a separate, shop-card-only pattern set).
///
/// Each tile is rendered behind `.message-content` via the same flutter_svg
/// tiling mechanism ([StyleWatermarkLayer] / [_TiledSvg]) used for satoshi /
/// matrix. The radial-glow half of the eclipse `--style-pattern` is folded into
/// the glow/background instead (Flutter has no tiled radial-gradient layer here).
final Map<String, StyleWatermark> styleWatermarks = {
  // satoshi: tiled ₿ glyph (styles-features.css:545-566), 50×40 tile.
  'style-satoshi': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='50' height='40'>"
        "<text x='0' y='30' font-size='32' fill='#f7931a' "
        "fill-opacity='0.2'>₿</text></svg>",
    const Size(50, 40),
  ),
  // matrix: falling 10/01/11 monospace code (styles-features.css:593), 36×48.
  'style-matrix': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='36' height='48'>"
        "<g font-family='monospace' font-size='12' fill='#00ff00' "
        "fill-opacity='0.13'><text x='3' y='13'>10</text>"
        "<text x='19' y='27'>01</text><text x='6' y='41'>11</text></g></svg>",
    const Size(36, 48),
  ),
  // eclipse: dim star dots (styles-features.css:1257), 60×60. (The radial glow
  // half of --style-pattern is folded into the glow/background instead.)
  'style-eclipse': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='60' height='60'>"
        "<g fill='#ffd9a0' fill-opacity='0.12'><circle cx='14' cy='12' r='0.9'/>"
        "<circle cx='46' cy='30' r='0.7'/><circle cx='26' cy='48' r='0.8'/>"
        "</g></svg>",
    const Size(60, 60),
  ),
  // crt: amber phosphor scanlines — 1px line every 3px (styles-features.css:1286).
  'style-crt': const StyleWatermark.scanlines(
    color: Color(0x47FFB000), // rgba(255,176,0,0.28)
    scanlineGap: 3,
    scanlineThickness: 1,
  ),
  // fire: two flame teardrops (styles-features.css:610), 46×46.
  'style-fire': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='46' height='46'>"
        "<g fill='#ff6600' fill-opacity='0.12'>"
        "<path d='M11 4C12 7 14.5 8.6 14.5 11.6A3.6 3.6 0 0 1 7.4 11.6C7.4 10 "
        "8.4 9.3 9.2 10.1 8.7 7.8 9.7 5.8 11 4Z'/>"
        "<path d='M32 25C32.8 27.2 34.6 28.4 34.6 30.6A2.7 2.7 0 0 1 29.2 "
        "30.6C29.2 29.4 30 28.9 30.6 29.5 30.2 27.8 30.9 26.3 32 25Z'/>"
        "</g></svg>",
    const Size(46, 46),
  ),
  // ice: two snow-crystals (styles-features.css:616), 44×44.
  'style-ice': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='44' height='44'>"
        "<g stroke='#00ccee' stroke-opacity='0.16' stroke-width='1' "
        "stroke-linecap='round'>"
        "<path d='M11 4v14M4 11h14M6 6l10 10M16 6 6 16'/>"
        "<path d='M11 5.5 9.5 7M11 5.5 12.5 7M11 16.5 9.5 15M11 16.5 12.5 "
        "15M5.5 11 7 9.5M5.5 11 7 12.5M16.5 11 15 9.5M16.5 11 15 12.5'/></g>"
        "<g stroke='#00ccee' stroke-opacity='0.1' stroke-width='1' "
        "stroke-linecap='round' transform='translate(28 26)'>"
        "<path d='M5 0v10M0 5h10M1.5 1.5 8.5 8.5M8.5 1.5 1.5 8.5'/></g></svg>",
    const Size(44, 44),
  ),
  // ghost: two little ghosts (styles-features.css:604), 52×52.
  'style-ghost': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='52' height='52'>"
        "<g fill='#ffffff' fill-opacity='0.08' fill-rule='evenodd'>"
        "<path d='M13 7c-3.3 0-5.5 2.4-5.5 5.5V19l2.2-1.6L12 19l1-1 1 1 2.3-1.6L18.5 "
        "19v-6.5C18.5 9.4 16.3 7 13 7z M10.5 11.5a0.85 0.85 0 1 0 1.7 0 0.85 0.85 "
        "0 1 0 -1.7 0z M13.8 11.5a0.85 0.85 0 1 0 1.7 0 0.85 0.85 0 1 0 -1.7 0z'/>"
        "<path d='M37 29c-2.6 0-4.5 1.9-4.5 4.5V38l1.8-1.3L36 38l.8-.8.8.8 1.7-1.3L41 "
        "38v-4.5C41 30.9 39.1 29 37 29z M35.1 33a0.7 0.7 0 1 0 1.4 0 0.7 0.7 0 1 0 "
        "-1.4 0z M37.7 33a0.7 0.7 0 1 0 1.4 0 0.7 0.7 0 1 0 -1.4 0z'/></g></svg>",
    const Size(52, 52),
  ),
  // ocean: two sine waves (styles-features.css:735), 48×24.
  'style-ocean': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='24'>"
        "<g fill='none' stroke='#38bdf8' stroke-opacity='0.16' stroke-width='1.4'>"
        "<path d='M0 12 Q6 6 12 12 T24 12 T36 12 T48 12'/>"
        "<path d='M0 20 Q6 14 12 20 T24 20 T36 20 T48 20'/></g></svg>",
    const Size(48, 24),
  ),
  // sakura: four rotated petals (styles-features.css:760), 50×50.
  'style-sakura': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='50' height='50'>"
        "<g fill='#ff7eb6' fill-opacity='0.14'>"
        "<ellipse cx='12' cy='12' rx='3' ry='1.6' transform='rotate(30 12 12)'/>"
        "<ellipse cx='36' cy='30' rx='3' ry='1.6' transform='rotate(-20 36 30)'/>"
        "<ellipse cx='42' cy='8' rx='2.5' ry='1.3' transform='rotate(60 42 8)'/>"
        "<ellipse cx='8' cy='40' rx='2.5' ry='1.3' transform='rotate(10 8 40)'/>"
        "</g></svg>",
    const Size(50, 50),
  ),
  // galaxy: star dots + a tiny sparkle cross (styles-features.css:785), 60×60.
  'style-galaxy': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='60' height='60'>"
        "<g fill='#c084fc' fill-opacity='0.2'><circle cx='10' cy='12' r='1.2'/>"
        "<circle cx='40' cy='8' r='0.9'/><circle cx='52' cy='30' r='1.4'/>"
        "<circle cx='24' cy='40' r='1'/><circle cx='8' cy='48' r='0.8'/>"
        "<circle cx='34' cy='52' r='1.1'/></g>"
        "<g stroke='#c084fc' stroke-opacity='0.18' stroke-width='1' "
        "stroke-linecap='round'><path d='M30 22v5M27.5 24.5h5'/></g></svg>",
    const Size(60, 60),
  ),
  // toxic: radiation rings + dots (styles-features.css:810), 48×48.
  'style-toxic': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='48'>"
        "<g fill='none' stroke='#84ff3b' stroke-opacity='0.14' stroke-width='1.2'>"
        "<circle cx='12' cy='12' r='3'/><circle cx='36' cy='34' r='3'/></g>"
        "<g fill='#84ff3b' fill-opacity='0.12'><circle cx='12' cy='12' r='1'/>"
        "<circle cx='36' cy='34' r='1'/></g></svg>",
    const Size(48, 48),
  ),
  // gold: two four-point sparkles (styles-features.css:839), 46×46.
  'style-gold': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='46' height='46'>"
        "<g fill='#ffd700' fill-opacity='0.13'>"
        "<path d='M12 4 13.2 10.8 20 12 13.2 13.2 12 20 10.8 13.2 4 12 10.8 10.8z'/>"
        "<path d='M34 26 34.8 30.2 39 31 34.8 31.8 34 36 33.2 31.8 29 31 33.2 30.2z'/>"
        "</g></svg>",
    const Size(46, 46),
  ),
  // vapor: an angular grid stroke (styles-features.css:868), 24×24.
  'style-vapor': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'>"
        "<g fill='none' stroke='#05d9e8' stroke-opacity='0.14' stroke-width='1'>"
        "<path d='M0 0H24V24'/></g></svg>",
    const Size(24, 24),
  ),
  // blood: two blood drops (styles-features.css:893), 44×44.
  'style-blood': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='44' height='44'>"
        "<g fill='#ff3b3b' fill-opacity='0.12'>"
        "<path d='M11 6c3 4 4.5 6 4.5 8a4.5 4.5 0 0 1-9 0c0-2 1.5-4 4.5-8z'/>"
        "<path d='M33 26c2 2.7 3 4 3 5.3a3 3 0 0 1-6 0c0-1.3 1-2.6 3-5.3z'/>"
        "</g></svg>",
    const Size(44, 44),
  ),
  // royal: a crown diamond + two corner chevrons (styles-features.css:918), 32×32.
  'style-royal': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'>"
        "<g fill='none' stroke='#e8c860' stroke-opacity='0.16' stroke-width='1'>"
        "<path d='M16 4 22 12 16 20 10 12z'/>"
        "<path d='M0 20 6 28 0 36M32 20 26 28 32 36'/></g></svg>",
    const Size(32, 32),
  ),
  // circuit: PCB traces + solder nodes (styles-features.css:943), 48×48.
  'style-circuit': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='48' height='48'>"
        "<g fill='none' stroke='#2dd4bf' stroke-opacity='0.16' stroke-width='1'>"
        "<path d='M6 6h12v12M18 6h12M30 6v10h12M6 24v12h10M16 36h14v8M30 30h12'/></g>"
        "<g fill='#2dd4bf' fill-opacity='0.22'><circle cx='6' cy='6' r='1.5'/>"
        "<circle cx='42' cy='16' r='1.5'/><circle cx='16' cy='36' r='1.5'/>"
        "<circle cx='42' cy='30' r='1.5'/></g></svg>",
    const Size(48, 48),
  ),
  // rainbow: stacked ROYGBIV arc-pairs (styles-features.css:622), 46×46.
  'style-rainbow': StyleWatermark.svg(
    "<svg xmlns='http://www.w3.org/2000/svg' width='46' height='46'>"
        "<g fill='none' stroke-width='1.3' stroke-linecap='round'>"
        "<path d='M6 14a6 6 0 0 1 12 0' stroke='#ff3b3b' stroke-opacity='0.5'/>"
        "<path d='M8.5 14a3.5 3.5 0 0 1 7 0' stroke='#33dd00' stroke-opacity='0.45'/>"
        "<path d='M10.5 14a1.5 1.5 0 0 1 3 0' stroke='#2a5bff' stroke-opacity='0.45'/>"
        "<path d='M27 35a6 6 0 0 1 12 0' stroke='#ff8a00' stroke-opacity='0.5'/>"
        "<path d='M29.5 35a3.5 3.5 0 0 1 7 0' stroke='#00c3ff' stroke-opacity='0.45'/>"
        "<path d='M31.5 35a1.5 1.5 0 0 1 3 0' stroke='#b13bff' stroke-opacity='0.45'/>"
        "</g></svg>",
    const Size(46, 46),
  ),
};

/// Translucent `.message-content { background-color }` painted by the styles
/// that have one (verbatim alpha from `css/styles-features.css`). Styles not
/// listed paint no content background.
const Map<String, Color> _styleContentBackground = {
  // .message.style-satoshi .message-content { background: rgba(247,147,26,.2) }
  'style-satoshi': Color(0x33F7931A),
  // .message.style-eclipse .message-content (the later override) rgba(18,14,28,.72)
  'style-eclipse': Color(0xB8120E1C),
  // .message.style-crt .message-content (the later override) rgba(10,8,2,.82)
  'style-crt': Color(0xD10A0802),
};

/// The supporter-style decoration (`.message.supporter-style`): gold glyphs with
/// a soft gold glow, a gold left accent bar and a faint gold wash behind the
/// bubble (`css/styles-features.css` lines 1084-1092).
const MessageStyleDecoration supporterStyleDecoration = MessageStyleDecoration(
  textColor: Color(0xFFFFD700),
  glow: Color(0x40FFD700), // rgba(255,215,0,.25)
  contentBackground: Color(0x14FFD700), // ~rgba(255,215,0,.08) bubble wash
  borderAccent: Color(0xFFFFD700),
);

// =============================================================================
// Special cosmetics (auras / watermarks / prism / hologram). `.message.cosmetic-X`
// (styles-features.css:1099-1211). Composed onto the bubble/row in message_row.
// =============================================================================

/// Resolves the active special-cosmetic auras for [cosmetics] (in declared
/// order, excluding the redacted privacy item which is handled separately).
List<CosmeticAura> resolveCosmeticAuras(UserCosmetics cosmetics) {
  final out = <CosmeticAura>[];
  for (final id in cosmetics.cosmetics) {
    final aura = _cosmeticAuras[id];
    if (aura != null) out.add(aura);
  }
  return out;
}

const String _frostSnowflakeSvg =
    "<svg xmlns='http://www.w3.org/2000/svg' width='18' height='18'>"
    "<g fill='none' stroke='#68b8e6' stroke-opacity='0.55' stroke-width='1' "
    "stroke-linecap='round'>"
    "<path d='M9 2.5v13M2.5 9h13M4.4 4.4l9.2 9.2M13.6 4.4 4.4 13.6'/>"
    "<path d='M9 4.5 7.5 6M9 4.5 10.5 6M9 13.5 7.5 12M9 13.5 10.5 12M4.5 9 6 "
    "7.5M4.5 9 6 10.5M13.5 9 12 7.5M13.5 9 12 10.5'/></g></svg>";

const String _cosmicStarfieldSvg =
    "<svg xmlns='http://www.w3.org/2000/svg' width='60' height='60'>"
    "<g fill='#cbb8ff'><circle cx='10' cy='12' r='1' fill-opacity='0.5'/>"
    "<circle cx='44' cy='8' r='0.8' fill-opacity='0.4'/>"
    "<circle cx='52' cy='34' r='1.2' fill-opacity='0.55'/>"
    "<circle cx='22' cy='44' r='0.9' fill-opacity='0.45'/>"
    "<circle cx='33' cy='22' r='0.7' fill-opacity='0.4'/>"
    "<circle cx='15' cy='50' r='0.6' fill-opacity='0.35'/></g></svg>";

/// Cosmetic aura table (styles-features.css:1099-1211). Box-shadow inset/glow,
/// border accents, gradients + watermarks captured verbatim.
final Map<String, CosmeticAura> _cosmeticAuras = {
  // cosmetic-aura-gold (:1099-1103)
  'cosmetic-aura-gold': const CosmeticAura(
    id: 'cosmetic-aura-gold',
    insetColor: Color(0x59FFD700), // rgba(255,215,0,.35)
    insetWidth: 1,
    insetRing: true,
    glowColor: Color(0x2EFFD700), // rgba(255,215,0,.18)
    glowBlur: 18,
    borderAccent: Color(0xFFFFD700),
    gradient: [Color(0x0DFFD700), Color(0x05FFD700)],
  ),
  // cosmetic-aura-neon (:1105-1113)
  'cosmetic-aura-neon': const CosmeticAura(
    id: 'cosmetic-aura-neon',
    insetColor: Color(0x8C00E5FF), // rgba(0,229,255,.55)
    insetRing: true,
    glowColor: Color(0x5200E5FF), // rgba(0,229,255,.32)
    glowBlur: 22,
    borderAccent: Color(0xFF00E5FF),
    gradient: [Color(0x0F00E5FF), Color(0x0500E5FF)],
  ),
  // cosmetic-aura-rainbow (:1115-1139) — conic prism ring + soft glow
  'cosmetic-aura-rainbow': const CosmeticAura(
    id: 'cosmetic-aura-rainbow',
    glowColor: Color(0x4D9664FF), // rgba(150,100,255,.3)
    glowBlur: 16,
    prismRing: true,
  ),
  // cosmetic-frost (:1141-1167) — frosted inset + snowflake edges + icy wash
  'cosmetic-frost': CosmeticAura(
    id: 'cosmetic-frost',
    insetColor: const Color(0x8CE1F6FF), // rgba(225,246,255,.55)
    insetRing: true,
    glowColor: const Color(0x3396D2FF), // rgba(150,210,255,.2) — outer glow hue
    glowBlur: 10,
    background: const Color(0x29BEE6FF), // rgba(190,230,255,.16)
    watermark: StyleWatermark.svg(_frostSnowflakeSvg, const Size(18, 18)),
  ),
  // cosmetic-aura-phoenix (:1169-1177)
  'cosmetic-aura-phoenix': const CosmeticAura(
    id: 'cosmetic-aura-phoenix',
    insetColor: Color(0x99FFA000), // rgba(255,160,0,.6)
    insetRing: true,
    glowColor: Color(0x66FF6E00), // rgba(255,110,0,.4)
    glowBlur: 26,
    borderAccent: Color(0xFFFF6A00),
    gradient: [Color(0x12FF6A00), Color(0x08FF0000)],
  ),
  // cosmetic-aura-cosmic (:1179-1195) — purple ring + starfield
  'cosmetic-aura-cosmic': CosmeticAura(
    id: 'cosmetic-aura-cosmic',
    insetColor: const Color(0x99A082FF), // rgba(160,130,255,.6)
    insetRing: true,
    glowColor: const Color(0x738C64FF), // rgba(140,100,255,.45)
    glowBlur: 26,
    borderAccent: const Color(0xFF7C5CFF),
    gradient: const [Color(0x29462D8C), Color(0x0F0F0C23)],
    watermark: StyleWatermark.svg(_cosmicStarfieldSvg, const Size(60, 60)),
  ),
  // cosmetic-bubble-hologram (:1197-1211) — white sheen over multi-gradient
  'cosmetic-bubble-hologram': const CosmeticAura(
    id: 'cosmetic-bubble-hologram',
    insetColor: Color(0x80FFFFFF), // rgba(255,255,255,.5)
    insetRing: true,
    glowColor: Color(0x8096B4FF), // rgba(150,180,255,.5)
    glowBlur: 18,
    hologram: true,
  ),
};

// =============================================================================
// Rendering widgets for the watermark / aura textures.
// =============================================================================

/// Paints a [StyleWatermark] behind a message's content: either a tiled inline
/// SVG or programmatic scanlines (CRT). Returns a fill widget (no [Positioned]),
/// so wrap it in a `Positioned.fill` inside a `Stack` (z-index: -1 in the CSS),
/// clipped to the bubble radius by the caller.
class StyleWatermarkLayer extends StatelessWidget {
  const StyleWatermarkLayer({super.key, required this.watermark});

  final StyleWatermark watermark;

  @override
  Widget build(BuildContext context) {
    if (watermark.isScanlines) {
      return IgnorePointer(
        child: CustomPaint(
          size: Size.infinite,
          painter: _ScanlinePainter(watermark),
        ),
      );
    }
    // Tiled inline SVG. flutter_svg renders a single tile; we repeat it across
    // the content box.
    return IgnorePointer(
      child: ClipRect(
        child: _TiledSvg(svg: watermark.svg!, tile: watermark.size),
      ),
    );
  }
}

class _ScanlinePainter extends CustomPainter {
  _ScanlinePainter(this.w);
  final StyleWatermark w;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = w.scanline!;
    for (var y = 0.0; y < size.height; y += w.scanlineGap) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, w.scanlineThickness), paint);
    }
  }

  @override
  bool shouldRepaint(_ScanlinePainter old) => old.w != w;
}

/// Repeats a small inline SVG [tile] across the available box. Uses
/// [SvgPicture.string] inside an `OverflowBox`-free wrap-grid so it tiles
/// cheaply without rasterisation plumbing.
class _TiledSvg extends StatelessWidget {
  const _TiledSvg({required this.svg, required this.tile});
  final String svg;
  final Size tile;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
        final h = constraints.maxHeight.isFinite ? constraints.maxHeight : 120.0;
        final cols = (w / tile.width).ceil() + 1;
        final rows = (h / tile.height).ceil() + 1;
        // A fresh SvgPicture per cell (a widget can't appear twice in the tree).
        SizedBox cell() => SizedBox(
              width: tile.width,
              height: tile.height,
              child: SvgPicture.string(
                svg,
                width: tile.width,
                height: tile.height,
                fit: BoxFit.fill,
              ),
            );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var r = 0; r < rows; r++)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [for (var col = 0; col < cols; col++) cell()],
              ),
          ],
        );
      },
    );
  }
}

/// Paints the parts of a `.message.cosmetic-X` box-shadow / overlay that a plain
/// [BoxDecoration] can't express, as a `Positioned.fill` layer above the bubble
/// content: the conic prism ring (rainbow), the holographic sheen (hologram),
/// and — for any aura flagged [CosmeticAura.insetRing] — the
/// `box-shadow: inset 0 0 0 {insetWidth}px {insetColor}` rendered as a TRUE
/// inner ring (stroked fully inside the bubble edge) plus a soft inward feather,
/// instead of the outset glow `BoxShadow` can only approximate.
///
/// CROSS-FILE NOTE (needs a one-line `message_row.dart` edit — outside this
/// slice's owned files): `message_row.dart._decorateBubble` now routes
/// `auras.where((a) => a.hasOverlay)` through this painter (its `overlays`
/// filter, ~line 590), and [CosmeticAura.hasOverlay] includes `insetRing`. So
/// every inset-ring aura (gold/neon/phoenix/cosmic/frost + hologram) DOES reach
/// this painter and gets its fully-inset ring drawn here. BUT `_decorateBubble`
/// ALSO still sets `border: Border.all(inset.insetColor, inset.insetWidth)`
/// (~line 605) whenever the last aura carries an `insetColor` — i.e. the same
/// four pure-ring auras now get BOTH a centred `Border.all` AND this painter's
/// inset ring → two overlapping rings of the same hue (a visible double ring).
/// FIX (in `message_row.dart`, not here): suppress that `Border.all` for auras
/// routed through the painter, e.g. guard it with `inset != null &&
/// inset.insetColor != null && !inset.hasOverlay`. Every aura with an
/// `insetColor` today is an `insetRing`/`hasOverlay` aura, so this leaves only
/// the painter's single inset ring. Nothing else needs to change — the painter
/// already strokes the ring for all `insetRing` auras.
class CosmeticOverlayPainter extends CustomPainter {
  CosmeticOverlayPainter({
    required this.aura,
    required this.radius,
  });

  final CosmeticAura aura;
  final BorderRadius radius;

  static const List<Color> _prism = [
    Color(0xFFFF2D2D),
    Color(0xFFFF8A00),
    Color(0xFFFFE600),
    Color(0xFF33DD00),
    Color(0xFF00C3FF),
    Color(0xFF2A5BFF),
    Color(0xFFB13BFF),
    Color(0xFFFF2D2D),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = radius.toRRect(rect);
    if (aura.prismRing) {
      // 3px conic-gradient ring masked to the border.
      final shader = const SweepGradient(colors: _prism).createShader(rect);
      final ring = Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      canvas.drawRRect(rrect.deflate(1.5), ring);
    }
    if (aura.hologram) {
      // 135deg multi-colour gradient + a 115deg white sheen (screen blend).
      final base = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0x66FF00C8),
            Color(0x6600C8FF),
            Color(0x6678FFAA),
            Color(0x66FFE100),
            Color(0x66FF00C8),
          ],
        ).createShader(rect)
        ..blendMode = BlendMode.screen;
      canvas.drawRRect(rrect, base);
      final sheen = Paint()
        ..shader = const LinearGradient(
          begin: Alignment(-1, -0.6),
          end: Alignment(1, 0.6),
          colors: [
            Color(0x00FFFFFF),
            Color(0x47FFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: [0.43, 0.5, 0.57],
        ).createShader(rect)
        ..blendMode = BlendMode.screen;
      canvas.drawRRect(rrect, sheen);
    }
    // True inset ring (`box-shadow: inset 0 0 0 {w}px {c}`). Drawn last so it
    // sits crisply on top of the hologram sheen / prism ring.
    final ringColor = aura.insetColor;
    if (aura.insetRing && ringColor != null) {
      final w = aura.insetWidth;
      // A stroked rounded-rect deflated by half its width keeps the whole stroke
      // INSIDE the bubble edge — matching CSS `inset 0 0 0 {w}px` (which paints
      // the ring entirely within the box) rather than a centred `Border.all`.
      final ringRect = rrect.deflate(w / 2);
      final ring = Paint()
        ..color = ringColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = w;
      canvas.drawRRect(ringRect, ring);
      // The soft inward feather an inset box-shadow casts: the ring colour at a
      // low alpha fading from the edge toward the centre, clipped to the bubble
      // so it never bleeds outside. (CSS inset shadows have 0 blur here, so this
      // is a faint accent, not a heavy halo — a fixed low alpha on the ring hue.)
      final inner = rrect.deflate(w);
      final feather = Paint()
        ..shader = RadialGradient(
          radius: 0.9,
          colors: [
            ringColor.withValues(alpha: 0),
            ringColor.withValues(alpha: 0.10),
          ],
          stops: const [0.72, 1.0],
        ).createShader(inner.outerRect);
      canvas.save();
      canvas.clipRRect(inner);
      canvas.drawRRect(inner, feather);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(CosmeticOverlayPainter old) =>
      old.aura.id != aura.id ||
      old.radius != radius ||
      old.aura.insetColor != aura.insetColor ||
      old.aura.insetWidth != aura.insetWidth ||
      old.aura.insetRing != aura.insetRing;
}
