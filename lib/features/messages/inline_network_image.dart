// Robust inline network-image rendering for message bodies + emoji.
//
// `cached_network_image` (and the underlying `ImageDecoder`) can only decode the
// raster formats Skia/Impeller support (PNG/JPEG/GIF/WebP/BMP). NIP-30 custom
// emoji and inline media URLs in the wild are frequently **SVG** (and
// occasionally AVIF / animated-WebP), which surface as `ImageDecoder
// unimplemented` when fed to `Image.network`/`CachedNetworkImage`.
//
// CRITICAL: flutter_svg's network/memory widgets do NOT route a *parse/compile*
// failure to `placeholderBuilder` — a non-SVG response (a proxy 403/404 HTML
// page) OR an SVG whose features its strict compiler rejects (browsers render
// the same file leniently) throws an UNHANDLED async `Bad state: Invalid SVG
// data`. Multiplied across a gridful of emoji (the picker) those repeated
// failures exhaust the heap and CRASH the app. So for SVG-looking URLs we fetch
// the bytes, then PRE-COMPILE them through `vg.loadPicture` inside a try/catch
// (caching the result): only a successfully-compiled picture is ever drawn, a
// misadvertised raster falls back to `Image.memory`, and anything else degrades
// to [errorChild]. No bad data ever reaches the parser at paint time.
//
// URLs are expected to be ALREADY proxied by the caller.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;

/// True when [url] looks like an SVG (by extension, ignoring any query string),
/// including the proxied form `…/api/proxy?url=<encoded …/foo.svg>`.
bool isSvgUrl(String url) {
  if (url.isEmpty) return false;
  final lower = url.toLowerCase();
  if (RegExp(r'\.svg(\?|#|$)').hasMatch(lower)) return true;
  final q = Uri.tryParse(url)?.queryParameters['url'];
  if (q != null && RegExp(r'\.svg(\?|#|$)').hasMatch(q.toLowerCase())) {
    return true;
  }
  return false;
}

/// The decoded result for an SVG-looking URL: a compiled vector [picture] (+ its
/// intrinsic [size]) when it parsed, or raw [raster] bytes when the response was
/// actually a raster image. Null overall ⇒ fetch failed / undecodable.
class _Decoded {
  const _Decoded.svg(this.picture, this.size) : raster = null;
  const _Decoded.raster(this.raster)
      : picture = null,
        size = ui.Size.zero;
  final ui.Picture? picture;
  final ui.Size size;
  final Uint8List? raster;
}

/// A network image that transparently handles SVG and degrades to [errorChild]
/// (or a sensible default) when the bytes can't be fetched or decoded — without
/// ever throwing to the framework.
class InlineNetworkImage extends StatelessWidget {
  const InlineNetworkImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.placeholder,
    this.errorChild,
    this.memoryOnly = false,
  });

  /// Already-proxied image URL.
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorChild;

  /// Skip the `cached_network_image` / `flutter_cache_manager` disk cache and
  /// render through the in-memory `http` + `Image.memory` path instead. Set this
  /// for EMOJI: a gridful of custom-emoji cells (the picker) or an emoji-heavy
  /// conversation would otherwise fire dozens of concurrent writes at
  /// flutter_cache_manager's sqflite DB, which serialises them behind a
  /// transaction and floods the log with "database has been locked for
  /// 0:00:10.000000" warnings (and can wedge the app). Emoji are small and
  /// repeat heavily, so the in-memory [_cache] + framework image cache covers
  /// them with zero disk I/O. Leave false for large one-off media, which benefit
  /// from the on-disk cache.
  final bool memoryOnly;

  /// URL → decoded SVG/raster (cached so a grid of repeats + rebuilds share one
  /// fetch+compile and bad URLs aren't retried into a crash loop).
  static final Map<String, Future<_Decoded?>> _cache = {};

  static Future<_Decoded?> _decode(String url) {
    return _cache.putIfAbsent(url, () async {
      Uint8List bytes;
      try {
        final resp =
            await http.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
        if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return null;
        bytes = resp.bodyBytes;
      } catch (_) {
        return null;
      }
      if (_looksLikeSvg(bytes)) {
        try {
          final info = await vg.loadPicture(SvgBytesLoader(bytes), null);
          return _Decoded.svg(info.picture, info.size);
        } catch (_) {
          return null; // strict compiler rejected it — never paint it
        }
      }
      return _Decoded.raster(bytes);
    }).then((v) {
      if (_cache.length > 1024) _cache.remove(_cache.keys.first);
      return v;
    });
  }

  /// True when [bytes] begin with an SVG/XML document head (guards the parser
  /// against an HTML error page or a raster blob).
  static bool _looksLikeSvg(Uint8List bytes) {
    final head =
        String.fromCharCodes(bytes.take(512).where((b) => b != 0))
            .trimLeft()
            .toLowerCase();
    return head.startsWith('<svg') ||
        head.startsWith('<?xml') ||
        head.startsWith('<!doctype svg') ||
        (head.startsWith('<!--') && head.contains('<svg'));
  }

  Widget _fallback(BuildContext context) {
    if (errorChild != null) return errorChild!;
    return SizedBox(
      width: width,
      height: height,
      child: Icon(
        Icons.broken_image_outlined,
        size: (width ?? height ?? 16) * 0.8,
        color: Theme.of(context).disabledColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The in-memory http path handles BOTH svg and raster (and never touches the
    // sqflite-backed disk cache). Use it for SVG-looking URLs and whenever the
    // caller opts out of the disk cache ([memoryOnly], i.e. emoji).
    if (memoryOnly || isSvgUrl(url)) {
      return FutureBuilder<_Decoded?>(
        future: _decode(url),
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return placeholder ?? SizedBox(width: width, height: height);
          }
          final d = snap.data;
          if (d == null) return _fallback(ctx);
          if (d.picture != null && d.size.width > 0 && d.size.height > 0) {
            return SizedBox(
              width: width,
              height: height,
              child: FittedBox(
                fit: fit,
                child: SizedBox(
                  width: d.size.width,
                  height: d.size.height,
                  child: CustomPaint(painter: _PicturePainter(d.picture!)),
                ),
              ),
            );
          }
          if (d.raster != null) {
            return Image.memory(
              d.raster!,
              width: width,
              height: height,
              fit: fit,
              gaplessPlayback: true,
              errorBuilder: (ctx, _, __) => _fallback(ctx),
            );
          }
          return _fallback(ctx);
        },
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      width: width,
      height: height,
      fit: fit,
      placeholder: placeholder == null ? null : (_, __) => placeholder!,
      errorWidget: (ctx, _, __) => _fallback(ctx),
    );
  }
}

/// Paints a pre-compiled SVG [ui.Picture] (sized to its intrinsic viewport; the
/// caller scales it with a [FittedBox]).
class _PicturePainter extends CustomPainter {
  _PicturePainter(this.picture);
  final ui.Picture picture;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawPicture(picture);
  @override
  bool shouldRepaint(_PicturePainter old) => old.picture != picture;
}
