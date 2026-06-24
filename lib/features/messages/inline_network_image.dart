// Robust inline network-image rendering for message bodies.
//
// `cached_network_image` (and the underlying `ImageDecoder`) can only decode
// the raster formats Skia/Impeller support (PNG/JPEG/GIF/WebP/BMP). NIP-30
// custom emoji and inline media URLs in the wild are frequently **SVG** (and
// occasionally AVIF / animated-WebP), which surface as
// `ImageDecoder unimplemented` / `Failed to decode image` exceptions when fed
// to `Image.network`/`CachedNetworkImage` with no error handling.
//
// This widget:
//   * detects SVG by URL extension / `image/svg` content and renders it via
//     `flutter_svg`'s `SvgPicture.network`,
//   * otherwise uses `CachedNetworkImage`,
//   * always supplies a graceful error fallback so an undecodable image shows a
//     small placeholder instead of throwing.
//
// URLs are expected to be ALREADY proxied by the caller (the same media proxy
// every other image goes through) — this widget does not proxy.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// True when [url] looks like an SVG (by extension, ignoring any query string).
/// The media proxy preserves the original path, so the `.svg` extension still
/// shows through `…/api/proxy?url=<encoded …/foo.svg>` — check the decoded
/// query payload too.
bool isSvgUrl(String url) {
  if (url.isEmpty) return false;
  final lower = url.toLowerCase();
  // Fast path: a literal `.svg` (optionally followed by `?`/`#`) anywhere.
  if (RegExp(r'\.svg(\?|#|$)').hasMatch(lower)) return true;
  // Proxied form: the real URL sits in the `url=` query component.
  final q = Uri.tryParse(url)?.queryParameters['url'];
  if (q != null && RegExp(r'\.svg(\?|#|$)').hasMatch(q.toLowerCase())) {
    return true;
  }
  return false;
}

/// A network image that transparently handles SVG and degrades to [errorChild]
/// (or a sensible default) when the bytes can't be decoded.
class InlineNetworkImage extends StatelessWidget {
  const InlineNetworkImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.placeholder,
    this.errorChild,
  });

  /// Already-proxied image URL.
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// Shown while a raster image loads (SVGs render synchronously once fetched).
  final Widget? placeholder;

  /// Shown when the image fails to load/decode. Defaults to a muted broken-image
  /// glyph sized to [width]/[height].
  final Widget? errorChild;

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
    if (isSvgUrl(url)) {
      return SvgPicture.network(
        url,
        width: width,
        height: height,
        fit: fit,
        // flutter_svg shows this until the SVG is fetched + parsed, and also if
        // the document is empty/unparseable (it won't throw to the framework).
        placeholderBuilder: (ctx) => placeholder ?? _fallback(ctx),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      width: width,
      height: height,
      fit: fit,
      placeholder:
          placeholder == null ? null : (_, __) => placeholder!,
      // Any decode failure (`ImageDecoder unimplemented`, network 4xx/5xx,
      // truncated bytes) lands here instead of throwing.
      errorWidget: (ctx, _, __) => _fallback(ctx),
    );
  }
}
