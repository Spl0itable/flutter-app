// The Bluetooth-mesh emoji / GIF picker.
//
// Over the mesh there is no shared server for peers to fetch an emoji or GIF
// from, so the normal pickers (which insert a remote URL) can't be reused as-is.
// Instead this picker offers ONLY the custom emoji and favourite GIFs whose
// image bytes are already cached locally — the exact caches the display path
// populates: custom-emoji rasters live in [InlineNetworkImage]'s in-memory
// decode cache (the picker/message surfaces render them with `memoryOnly`),
// favourite GIFs live in `flutter_cache_manager`'s disk cache (the GIF grid
// renders them through `CachedNetworkImage`). Picking one ships those cached
// bytes as a mesh file, which the recipient then renders inline like any other
// mesh image. Everything works offline for items the user has already seen.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../features/emoji/custom_emoji.dart';
import '../../features/emoji/gif_picker.dart';
import '../../features/i18n/i18n.dart';
import '../../features/messages/format/message_content.dart' show proxiedMedia;
import '../../features/messages/inline_network_image.dart';
import '../../state/app_state.dart';

/// A locally-cached sticker (custom emoji or favourite GIF) ready to send as a
/// mesh file.
class _Sticker {
  const _Sticker({
    required this.name,
    required this.mime,
    required this.bytes,
    required this.isGif,
  });

  final String name;
  final String mime;
  final Uint8List bytes;
  final bool isGif;
}

String _extFromUrl(String url) {
  final u = url.toLowerCase();
  if (u.contains('.gif')) return 'gif';
  if (u.contains('.webp')) return 'webp';
  if (u.contains('.png')) return 'png';
  if (u.contains('.jpeg') || u.contains('.jpg')) return 'jpg';
  return 'png';
}

String _mimeFromExt(String ext) => ext == 'jpg' ? 'image/jpeg' : 'image/$ext';

/// Reads back every custom emoji + favourite GIF whose bytes are already cached
/// locally, so nothing here requires the network.
Future<List<_Sticker>> _loadCachedStickers(WidgetRef ref) async {
  final out = <_Sticker>[];

  // Custom emoji: raster bytes from the in-memory decode cache.
  final emoji = ref.read(liveCustomEmojiProvider).codeToUrl;
  for (final entry in emoji.entries) {
    final proxied = proxiedMedia(entry.value, emoji: true);
    final bytes =
        await InlineNetworkImage.resolveBytes(proxied, fetchIfMissing: false);
    if (bytes == null || bytes.isEmpty) continue;
    final ext = _extFromUrl(entry.value);
    out.add(_Sticker(
      name: '${entry.key}.$ext',
      mime: _mimeFromExt(ext),
      bytes: bytes,
      isGif: false,
    ));
  }

  // Favourite GIFs: bytes from flutter_cache_manager's disk cache.
  try {
    final prefs = await ref.read(emojiPrefsProvider.future);
    final favs = FavoriteGifsStore(prefs).load();
    for (final gif in favs) {
      final proxied = proxiedMedia(gif.url);
      final info = await DefaultCacheManager().getFileFromCache(proxied);
      if (info == null) continue;
      try {
        final bytes = await info.file.readAsBytes();
        if (bytes.isEmpty) continue;
        out.add(_Sticker(
          name: 'gif-${gif.url.hashCode.toUnsigned(32).toRadixString(16)}.gif',
          mime: 'image/gif',
          bytes: bytes,
          isGif: true,
        ));
      } catch (_) {
        // Unreadable cache entry — skip it.
      }
    }
  } catch (_) {
    // No prefs / cache available — emoji-only result.
  }

  return out;
}

/// Opens the mesh emoji/GIF picker. [startWithGifs] selects which section is
/// shown first (the emoji button vs. the GIF button). [onSend] ships the chosen
/// sticker's cached bytes as a mesh file.
Future<void> showMeshStickerPicker(
  BuildContext context,
  WidgetRef ref, {
  required bool startWithGifs,
  required Future<void> Function(String name, String mime, Uint8List bytes)
      onSend,
}) async {
  final c = context.nym;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.bgSecondary,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _MeshStickerSheet(
      colors: c,
      startWithGifs: startWithGifs,
      loader: () => _loadCachedStickers(ref),
      onSend: onSend,
    ),
  );
}

class _MeshStickerSheet extends StatefulWidget {
  const _MeshStickerSheet({
    required this.colors,
    required this.startWithGifs,
    required this.loader,
    required this.onSend,
  });

  final NymColors colors;
  final bool startWithGifs;
  final Future<List<_Sticker>> Function() loader;
  final Future<void> Function(String name, String mime, Uint8List bytes) onSend;

  @override
  State<_MeshStickerSheet> createState() => _MeshStickerSheetState();
}

class _MeshStickerSheetState extends State<_MeshStickerSheet> {
  late bool _gifs = widget.startWithGifs;
  late final Future<List<_Sticker>> _future = widget.loader();

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Emoji / GIF segment toggle.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _segment(c, label: tr('Emoji'), selected: !_gifs,
                    onTap: () => setState(() => _gifs = false)),
                const SizedBox(width: 8),
                _segment(c, label: 'GIF', selected: _gifs,
                    onTap: () => setState(() => _gifs = true)),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 240,
              child: FutureBuilder<List<_Sticker>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: c.textDim),
                      ),
                    );
                  }
                  final all = snap.data ?? const <_Sticker>[];
                  final items =
                      all.where((s) => s.isGif == _gifs).toList();
                  if (items.isEmpty) {
                    return _empty(c);
                  }
                  return GridView.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _gifs ? 3 : 6,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                    ),
                    itemCount: items.length,
                    itemBuilder: (_, i) => _cell(c, items[i]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _segment(NymColors c,
      {required String label,
      required bool selected,
      required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? c.primaryA(0.15) : c.bg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? c.primary : c.border),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected ? c.primary : c.textDim,
                fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _cell(NymColors c, _Sticker sticker) {
    return GestureDetector(
      onTap: () async {
        Navigator.of(context).maybePop();
        await widget.onSend(sticker.name, sticker.mime, sticker.bytes);
      },
      child: Container(
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.border),
        ),
        clipBehavior: Clip.antiAlias,
        padding: sticker.isGif ? EdgeInsets.zero : const EdgeInsets.all(6),
        child: Image.memory(
          sticker.bytes,
          fit: sticker.isGif ? BoxFit.cover : BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) =>
              Icon(Icons.broken_image, size: 16, color: c.textDim),
        ),
      ),
    );
  }

  Widget _empty(NymColors c) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _gifs
                ? tr('No cached GIFs yet.\nGIFs you have viewed appear here to send over mesh.')
                : tr('No cached custom emoji yet.\nEmoji you have viewed appear here to send over mesh.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textDim, height: 1.5),
          ),
        ),
      );
}
