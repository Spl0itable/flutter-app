import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../state/settings_provider.dart';
import '../common/nym_avatar.dart' show proxiedAvatarUrl;

/// The kind of fill a wallpaper pattern produces. Mirrors the CSS techniques in
/// `styles-features.css`: `gradient` patterns paint stacked CSS gradients with
/// no mask; `svgMask` patterns paint a solid tint clipped through a repeating
/// SVG stroke shape; `none` paints nothing; `custom` is a user image.
enum WallpaperFill { none, gradient, svgMask, custom }

/// A pure, theme-independent description of one wallpaper pattern. Resolved from
/// a `wallpaperType` string by [WallpaperPattern.forType]. The tile size and
/// per-layer alphas match the live `#wallpaperLayer.wallpaper-pattern-*` rules
/// in `css/styles-features.css` (lines 3250–3304).
@immutable
class WallpaperPattern {
  const WallpaperPattern({
    required this.type,
    required this.fill,
    this.tile = Size.zero,
    this.baseAlpha = 0,
    double? lightAlpha,
  }) : lightAlpha = lightAlpha ?? baseAlpha;

  /// The canonical type string (one of the 9 PWA `data-wallpaper` values).
  final String type;
  final WallpaperFill fill;

  /// Repeat tile size in logical px (the CSS `background-size` / `mask-size`).
  final Size tile;

  /// The dominant tint alpha (the SVG-mask `background-color` alpha, or the
  /// primary gradient-stop alpha). Used by previews and the painter.
  final double baseAlpha;

  /// Light-mode tint alpha. `body.light-mode` boosts the masked patterns'
  /// `background-color` alpha to 0.45 and the dots gradient alpha to 0.4
  /// (`styles-themes-responsive.css:1368-1378`); geometric keeps its dark
  /// values, so it defaults to [baseAlpha].
  final double lightAlpha;

  /// The tint alpha to paint for the given theme brightness.
  double alphaFor({required bool isLight}) => isLight ? lightAlpha : baseAlpha;

  bool get paints => fill != WallpaperFill.none;

  /// Pure mapping from the persisted `nym_wallpaper_type` value to a pattern
  /// descriptor. Unknown values (and `'none'`) resolve to the transparent
  /// [none] pattern, mirroring `applyWallpaper`'s "no class → transparent" path.
  static WallpaperPattern forType(String? type) {
    switch (type) {
      case 'geometric':
        return const WallpaperPattern(
          type: 'geometric',
          fill: WallpaperFill.gradient,
          tile: Size(80, 140),
          baseAlpha: 0.08,
        );
      case 'circuit':
        return const WallpaperPattern(
          type: 'circuit',
          fill: WallpaperFill.svgMask,
          tile: Size(80, 80),
          baseAlpha: 0.10,
          lightAlpha: 0.45,
        );
      case 'dots':
        return const WallpaperPattern(
          type: 'dots',
          fill: WallpaperFill.gradient,
          tile: Size(24, 24),
          baseAlpha: 0.10,
          lightAlpha: 0.4,
        );
      case 'waves':
        return const WallpaperPattern(
          type: 'waves',
          fill: WallpaperFill.svgMask,
          tile: Size(120, 24),
          baseAlpha: 0.08,
          lightAlpha: 0.45,
        );
      case 'topography':
        return const WallpaperPattern(
          type: 'topography',
          fill: WallpaperFill.svgMask,
          tile: Size(120, 120),
          baseAlpha: 0.08,
          lightAlpha: 0.45,
        );
      case 'hexagons':
        return const WallpaperPattern(
          type: 'hexagons',
          fill: WallpaperFill.svgMask,
          tile: Size(56, 100),
          baseAlpha: 0.08,
          lightAlpha: 0.45,
        );
      case 'diamonds':
        return const WallpaperPattern(
          type: 'diamonds',
          fill: WallpaperFill.svgMask,
          tile: Size(48, 48),
          baseAlpha: 0.08,
          lightAlpha: 0.45,
        );
      case 'custom':
        return const WallpaperPattern(type: 'custom', fill: WallpaperFill.custom);
      case 'none':
      case null:
      default:
        return const WallpaperPattern(type: 'none', fill: WallpaperFill.none);
    }
  }

  /// The 7 selectable preset pattern names (excludes `none` and `custom`).
  static const List<String> presets = [
    'geometric',
    'circuit',
    'dots',
    'waves',
    'topography',
    'hexagons',
    'diamonds',
  ];
}

/// The fixed full-bleed wallpaper layer (`#wallpaperLayer`: fixed, inset 0,
/// `z-index:0`, `pointer-events:none`). Mounts beneath the chat content and is
/// tinted by the active `--primary` (`context.nym.primary`). Driven by
/// `settings.wallpaperType`; supports a custom uploaded image
/// (`nym_wallpaper_custom_url`) overlaid by a dark/light scrim.
class WallpaperLayer extends ConsumerWidget {
  const WallpaperLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = ref.watch(settingsProvider.select((s) => s.wallpaperType));
    final pattern = WallpaperPattern.forType(type);
    if (!pattern.paints) return const SizedBox.shrink();

    final c = context.nym;

    if (pattern.fill == WallpaperFill.custom) {
      final kv = ref.watch(keyValueStoreProvider);
      final url = kv.getString(StorageKeys.wallpaperCustomUrl);
      if (url == null || url.isEmpty) return const SizedBox.shrink();
      // Scrim mirrors users.js applyWallpaper: rgba(10,10,15,0.82) dark /
      // rgba(245,245,242,0.85) light layered over the image.
      final scrim = c.isLight
          ? const Color(0xD9F5F5F2)
          : const Color(0xD10A0A0F);
      // The PWA only ever stores a remote upload URL; the Flutter upload flow
      // (settings `_WallpaperPicker`) persists a locally-picked file's absolute
      // path instead, so a value that isn't an http(s) URL is an on-device file.
      final isRemote = url.startsWith('http://') || url.startsWith('https://');
      final ImageProvider image = isRemote
          // Route the remote custom wallpaper through the media proxy (hide IP /
          // bypass hotlink-403), like every other remote image.
          ? NetworkImage(proxiedAvatarUrl(url) ?? url)
          : FileImage(File(url));
      return IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            image: DecorationImage(
              image: image,
              fit: BoxFit.cover,
              colorFilter: ColorFilter.mode(scrim, BlendMode.srcOver),
            ),
          ),
        ),
      );
    }

    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _WallpaperPainter(
          pattern: pattern,
          primary: c.primary,
          isLight: c.isLight,
        ),
      ),
    );
  }
}

/// Paints the tiled vector patterns. Strokes/fills are the primary color at the
/// pattern's tint alpha (CSS `rgba(--wp-r,--wp-g,--wp-b, a)`); geometry mirrors
/// the SVG data-URIs / CSS gradients one-for-one.
class _WallpaperPainter extends CustomPainter {
  _WallpaperPainter({
    required this.pattern,
    required this.primary,
    required this.isLight,
  });

  final WallpaperPattern pattern;
  final Color primary;
  final bool isLight;

  /// The theme-resolved dominant tint alpha: light mode boosts the masked
  /// patterns to 0.45 and dots to 0.4 (`styles-themes-responsive.css:1368-1378`).
  double get _alpha => pattern.alphaFor(isLight: isLight);

  Color _tint(double a) => primary.withValues(alpha: a);

  @override
  void paint(Canvas canvas, Size size) {
    switch (pattern.type) {
      case 'geometric':
        _paintGeometric(canvas, size);
      case 'dots':
        _paintDots(canvas, size);
      case 'circuit':
        _tiled(canvas, size, _circuitTile);
      case 'waves':
        _tiled(canvas, size, _wavesTile);
      case 'topography':
        _tiled(canvas, size, _topographyTile);
      case 'hexagons':
        _tiled(canvas, size, _hexagonsTile);
      case 'diamonds':
        _tiled(canvas, size, _diamondsTile);
    }
  }

  /// Tiles a per-cell painter across [size] using the pattern tile dimensions.
  void _tiled(Canvas canvas, Size size, void Function(Canvas, Size) cell) {
    final tw = pattern.tile.width, th = pattern.tile.height;
    for (double y = 0; y < size.height; y += th) {
      for (double x = 0; x < size.width; x += tw) {
        canvas.save();
        canvas.translate(x, y);
        canvas.clipRect(Rect.fromLTWH(0, 0, tw, th));
        cell(canvas, pattern.tile);
        canvas.restore();
      }
    }
  }

  // dots: radial 1px tinted dot per 24×24 tile.
  void _paintDots(Canvas canvas, Size size) {
    final p = Paint()..color = _tint(_alpha);
    const step = 24.0;
    for (double y = 0; y < size.height; y += step) {
      for (double x = 0; x < size.width; x += step) {
        canvas.drawCircle(Offset(x + 1, y + 1), 1, p);
      }
    }
  }

  // geometric: a 1:1 port of `#wallpaperLayer.wallpaper-pattern-geometric`
  // (styles-features.css:3250-3258) — FIVE stacked repeating `linear-gradient`s
  // over an 80×140 tile, NOT a plain even-spaced crosshatch. Each gradient paints
  // a pair of hard-edged diagonal stripes (CSS stops `c 12%, transparent 12.5%,
  // transparent 87%, c 87.5%` → a band at each END of the gradient line); the
  // four 30°/150° layers (two at offset 0,0 and two at 40,70) interleave into the
  // argyle lattice, and a fainter 60° layer (`c 25% … c 75%`) overlays it.
  // We reproduce each CSS gradient EXACTLY by tiling the same multi-stop
  // `LinearGradient` per 80×140 cell, with begin/end at the cell corners for the
  // CSS angle, so Flutter rasterises the identical stripes.
  void _paintGeometric(Canvas canvas, Size size) {
    const tw = 80.0, th = 140.0;
    final a08 = _tint(0.08);
    final a06 = _tint(0.06);
    const clear = Colors.transparent;

    // One CSS gradient layer: angle (CSS deg), color, the 4 stop positions, and
    // the tile-phase offset (`background-position`). Painted tiled over [size].
    void layer(
      double degrees,
      Color color,
      List<double> stops,
      double offX,
      double offY,
    ) {
      // CSS angle → screen direction (0deg = up): d = (sinθ, -cosθ). The 0%/100%
      // ends sit at the cell corners furthest along ∓d / ±d.
      final rad = degrees * math.pi / 180;
      final dxSign = math.sin(rad) >= 0 ? 1.0 : -1.0;
      final dySign = -math.cos(rad) >= 0 ? 1.0 : -1.0;
      final gradient = LinearGradient(
        begin: Alignment(-dxSign, -dySign),
        end: Alignment(dxSign, dySign),
        colors: [color, clear, clear, color],
        stops: stops,
      );
      final paint = Paint();
      // Tile cells across the canvas, phase-shifted by the CSS background-position.
      for (double y = -th + (offY % th); y < size.height; y += th) {
        for (double x = -tw + (offX % tw); x < size.width; x += tw) {
          final cell = Rect.fromLTWH(x, y, tw, th);
          paint.shader = gradient.createShader(cell);
          canvas.save();
          canvas.clipRect(cell);
          canvas.drawRect(cell, paint);
          canvas.restore();
        }
      }
    }

    const s08 = [0.12, 0.125, 0.87, 0.875];
    const s06 = [0.25, 0.255, 0.75, 0.75];
    layer(30, a08, s08, 0, 0);
    layer(150, a08, s08, 0, 0);
    layer(30, a08, s08, 40, 70);
    layer(150, a08, s08, 40, 70);
    layer(60, a06, s06, 0, 0);
  }

  void _strokeShape(Canvas canvas, Path path, double alpha, double width) {
    canvas.drawPath(
      path,
      Paint()
        ..color = _tint(alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width,
    );
  }

  // circuit (80×80): inset square, 4 corner dots, 4 center stubs, center ring.
  void _circuitTile(Canvas canvas, Size t) {
    final a = _alpha;
    _strokeShape(canvas, Path()..addRect(const Rect.fromLTWH(10, 10, 60, 60)), a, 0.5);
    final dot = Paint()..color = _tint(a);
    for (final c in const [Offset(10, 10), Offset(70, 10), Offset(10, 70), Offset(70, 70)]) {
      canvas.drawCircle(c, 2.5, dot);
    }
    final stubs = Path()
      ..moveTo(40, 10)..lineTo(40, 30)
      ..moveTo(10, 40)..lineTo(30, 40)
      ..moveTo(40, 70)..lineTo(40, 50)
      ..moveTo(70, 40)..lineTo(50, 40);
    _strokeShape(canvas, stubs, a * 0.85, 0.5);
    _strokeShape(canvas, Path()..addOval(Rect.fromCircle(center: const Offset(40, 40), radius: 4)), a, 0.5);
  }

  // waves (120×24): one quadratic sine ridge.
  void _wavesTile(Canvas canvas, Size t) {
    final p = Path()
      ..moveTo(0, 12)
      ..quadraticBezierTo(30, 0, 60, 12)
      ..quadraticBezierTo(90, 24, 120, 12);
    _strokeShape(canvas, p, _alpha, 0.8);
  }

  // topography (120×120): 4 nested contour lines with descending opacity.
  void _topographyTile(Canvas canvas, Size t) {
    final a = _alpha;
    Path line(List<double> v) => Path()
      ..moveTo(v[0], v[1])
      ..quadraticBezierTo(v[2], v[3], v[4], v[5])
      ..quadraticBezierTo(v[6], v[7], v[8], v[9]);
    _strokeShape(canvas, line([20, 100, 40, 75, 60, 80, 80, 85, 100, 60]), a, 0.7);
    _strokeShape(canvas, line([10, 70, 35, 45, 60, 50, 85, 55, 110, 35]), a * 0.85, 0.7);
    _strokeShape(canvas, line([5, 45, 30, 22, 55, 28, 80, 34, 105, 12]), a * 0.7, 0.7);
    _strokeShape(canvas, line([15, 115, 45, 100, 65, 105, 85, 110, 105, 90]), a * 0.7, 0.7);
  }

  // hexagons (56×100): two interlocking honeycomb polylines.
  void _hexagonsTile(Canvas canvas, Size t) {
    final a = _alpha;
    Path poly(List<Offset> pts) {
      final p = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final pt in pts.skip(1)) {
        p.lineTo(pt.dx, pt.dy);
      }
      return p;
    }

    _strokeShape(
      canvas,
      poly(const [
        Offset(28, 66), Offset(0, 50), Offset(0, 16), Offset(28, 0),
        Offset(56, 16), Offset(56, 50), Offset(28, 66), Offset(28, 100),
      ]),
      a,
      0.5,
    );
    _strokeShape(
      canvas,
      poly(const [
        Offset(28, 0), Offset(28, 34), Offset(0, 50), Offset(0, 84),
        Offset(28, 100), Offset(56, 84), Offset(56, 50), Offset(28, 34),
      ]),
      a * 0.55,
      0.5,
    );
  }

  // diamonds (48×48): outer + concentric inner diamond.
  void _diamondsTile(Canvas canvas, Size t) {
    final a = _alpha;
    Path diamond(double cx, double cy, double r) => Path()
      ..moveTo(cx, cy - r)
      ..lineTo(cx + r, cy)
      ..lineTo(cx, cy + r)
      ..lineTo(cx - r, cy)
      ..close();
    _strokeShape(canvas, diamond(24, 24, 24), a, 0.5);
    _strokeShape(canvas, diamond(24, 24, 12), a * 0.55, 0.5);
  }

  @override
  bool shouldRepaint(_WallpaperPainter old) =>
      old.pattern.type != pattern.type ||
      old.primary != primary ||
      old.isLight != isLight;
}
