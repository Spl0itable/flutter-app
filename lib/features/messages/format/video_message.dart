// Inline video player for message media (gap report 02 §F16). Mirrors the PWA's
// inline `<video controls playsinline preload="metadata">` with a fullscreen
// expand button (`message-format.js:152-166`, `messages.js:1457-1509`) and the
// `video.message-video` / `.video-container` sizing from
// `styles-chat.css:980-1072`:
//   * single video — max 300x300, min-height 80, 1px glass border,
//     border-radius var(--radius-sm) (12);
//   * gallery cell — fills the tile, max-height 220, object-fit cover, no border,
//     radius 0 (the grid clips its own corners).
//
// Initial state is a poster/tap-to-play tile (metadata-only preload analogue):
// the controller initialises lazily on first tap. If initialisation fails we
// fall back to a tap-to-open affordance that launches the URL externally
// (`url_launcher`), so a broken/unsupported source is never a dead tile.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../../core/theme/nym_colors.dart';

/// `--radius-sm` (`styles-core.css:87`).
const double _kVideoRadius = 12;

/// An inline, tap-to-play video tile backed by [VideoPlayerController].
///
/// [url] should already be a directly-playable media URL (the formatter proxies
/// it). [maxSize] caps both dimensions (300 for a single video, 220 for a gallery
/// cell). Pass [borderRadius] to override the default `--radius-sm` (gallery cells
/// pass `BorderRadius.zero` and let the grid clip). [bordered] draws the 1px glass
/// border for the single-video case.
class VideoMessage extends StatefulWidget {
  const VideoMessage({
    super.key,
    required this.url,
    this.maxSize = 300,
    this.borderRadius,
    this.bordered = true,
  });

  final String url;
  final double maxSize;
  final BorderRadius? borderRadius;
  final bool bordered;

  @override
  State<VideoMessage> createState() => _VideoMessageState();
}

class _VideoMessageState extends State<VideoMessage> {
  VideoPlayerController? _controller;

  /// Lazily initialising the controller after the first tap.
  bool _initializing = false;

  /// Initialisation failed → fall back to tap-to-open.
  bool _failed = false;

  @override
  void dispose() {
    _controller?.removeListener(_onValue);
    _controller?.dispose();
    super.dispose();
  }

  void _onValue() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    if (_initializing || _controller != null) return;
    final uri = Uri.tryParse(widget.url);
    if (uri == null) {
      setState(() => _failed = true);
      return;
    }
    setState(() => _initializing = true);
    final controller = VideoPlayerController.networkUrl(uri);
    try {
      await controller.initialize();
      controller.addListener(_onValue);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _initializing = false;
      });
      await controller.play();
    } catch (_) {
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _failed = true;
      });
    }
  }

  Future<void> _openExternally() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _togglePlayback() {
    final c = _controller;
    if (c == null) return;
    setState(() {
      if (c.value.isPlaying) {
        c.pause();
      } else {
        c.play();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final radius = widget.borderRadius ??
        const BorderRadius.all(Radius.circular(_kVideoRadius));

    Widget body;
    if (_failed) {
      body = _fallbackTile(c);
    } else if (_controller != null && _controller!.value.isInitialized) {
      body = _playerTile(c);
    } else {
      body = _posterTile(c);
    }

    final clipped = ClipRRect(borderRadius: radius, child: body);

    if (!widget.bordered) return clipped;
    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: c.glassBorder),
      ),
      child: clipped,
    );
  }

  /// The constraints shared by every state (`max-width/height`, `min-height:80`).
  BoxConstraints get _constraints => BoxConstraints(
        maxWidth: widget.maxSize,
        maxHeight: widget.maxSize,
        minHeight: 80,
      );

  /// Initial poster / tap-to-play state (also shows a spinner while initialising).
  Widget _posterTile(NymColors c) {
    return GestureDetector(
      onTap: _start,
      child: Container(
        constraints: _constraints,
        // A 16:9 poster footprint before we know the real aspect ratio.
        width: widget.maxSize,
        height: widget.maxSize * 9 / 16,
        color: Colors.black.withValues(alpha: 0.4),
        alignment: Alignment.center,
        child: _initializing
            ? SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation(c.text),
                ),
              )
            : Icon(Icons.play_circle_fill, size: 48, color: c.text),
      ),
    );
  }

  /// The live player with a play/pause overlay, a scrubber, and a fullscreen
  /// expand button (mirrors `.video-expand-btn`).
  Widget _playerTile(NymColors c) {
    final controller = _controller!;
    final value = controller.value;
    return ConstrainedBox(
      constraints: _constraints,
      child: AspectRatio(
        aspectRatio: value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(controller),
            // Tap anywhere to toggle play/pause.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _togglePlayback,
                child: AnimatedOpacity(
                  opacity: value.isPlaying ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.25),
                    alignment: Alignment.center,
                    child: Icon(
                      value.isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill,
                      size: 48,
                      color: c.text,
                    ),
                  ),
                ),
              ),
            ),
            // Scrubber pinned to the bottom edge.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoProgressIndicator(
                controller,
                allowScrubbing: true,
                colors: VideoProgressColors(
                  playedColor: c.primary,
                  bufferedColor: Colors.white.withValues(alpha: 0.3),
                  backgroundColor: Colors.white.withValues(alpha: 0.12),
                ),
              ),
            ),
            // `.video-expand-btn` — fullscreen open (top-right, dark pill).
            Positioned(
              top: 8,
              right: 8,
              child: _ExpandButton(onTap: _openFullscreen),
            ),
          ],
        ),
      ),
    );
  }

  /// Init-failed fallback: a dark tile that opens the URL externally on tap
  /// (`url_launcher`), never a dead end.
  Widget _fallbackTile(NymColors c) {
    return GestureDetector(
      onTap: _openExternally,
      child: Container(
        constraints: _constraints,
        width: widget.maxSize,
        height: widget.maxSize * 9 / 16,
        color: Colors.black.withValues(alpha: 0.4),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.open_in_new, size: 32, color: c.text),
            const SizedBox(height: 6),
            Text(
              'Open video',
              style: TextStyle(color: c.textDim, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  /// Opens the video full-screen in a dialog route (the PWA's expand-to-modal,
  /// `expandVideo`). The same controller is reused so playback continues.
  void _openFullscreen() {
    final controller = _controller;
    if (controller == null) return;
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.9),
        pageBuilder: (_, __, ___) => _FullscreenVideo(controller: controller),
      ),
    );
  }
}

/// The `.video-expand-btn` fullscreen affordance (a 30x30 dark rounded button).
class _ExpandButton extends StatelessWidget {
  const _ExpandButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        ),
        child: const Icon(Icons.fullscreen, size: 18, color: Colors.white),
      ),
    );
  }
}

/// A full-screen video overlay reusing an already-initialised [controller]
/// (mirrors the PWA's image/video expand modal). Tapping the backdrop or the
/// close button dismisses; tapping the video toggles play/pause.
class _FullscreenVideo extends StatefulWidget {
  const _FullscreenVideo({required this.controller});
  final VideoPlayerController controller;

  @override
  State<_FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<_FullscreenVideo> {
  void _onValue() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onValue);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onValue);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final value = controller.value;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () => Navigator.of(context).maybePop(),
        child: Stack(
          children: [
            Center(
              child: GestureDetector(
                onTap: () => setState(() {
                  if (value.isPlaying) {
                    controller.pause();
                  } else {
                    controller.play();
                  }
                }),
                child: AspectRatio(
                  aspectRatio:
                      value.isInitialized ? value.aspectRatio : 16 / 9,
                  child: VideoPlayer(controller),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoProgressIndicator(
                controller,
                allowScrubbing: true,
                colors: const VideoProgressColors(
                  playedColor: Colors.white,
                  bufferedColor: Colors.white30,
                  backgroundColor: Colors.white12,
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: SafeArea(
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
