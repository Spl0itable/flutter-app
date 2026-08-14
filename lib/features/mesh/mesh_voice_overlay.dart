import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../state/app_state.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import 'mesh_bridge.dart';
import 'mesh_controller.dart';
import 'mesh_voice.dart';

/// Opens the push-to-talk voice panel for the active mesh [view]. Half-duplex
/// walkie-talkie over Bluetooth: hold to talk, release to listen. Returns
/// immediately; the panel manages its own audio session lifecycle.
Future<void> showMeshPttOverlay(
  BuildContext context,
  WidgetRef ref,
  ChatView view,
  String title,
) async {
  final bridge = ref.read(meshControllerProvider.notifier).bridge;
  if (bridge == null) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: false,
    backgroundColor: context.nym.bgSecondary,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _MeshPttSheet(bridge: bridge, view: view, title: title),
  );
}

class _MeshPttSheet extends StatefulWidget {
  const _MeshPttSheet({
    required this.bridge,
    required this.view,
    required this.title,
  });

  final MeshBridge bridge;
  final ChatView view;
  final String title;

  @override
  State<_MeshPttSheet> createState() => _MeshPttSheetState();
}

class _MeshPttSheetState extends State<_MeshPttSheet> {
  late final MeshVoiceSession _session =
      MeshVoiceSession(bridge: widget.bridge, view: widget.view)..init();

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                NymSvgIcon(NymIcons.bluetooth, size: 16, color: c.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tr('Push to talk · {name}', {'name': widget.title}),
                    style: TextStyle(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                        fontSize: 15),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: NymSvgIcon(NymIcons.close, size: 16, color: c.textDim),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // "X is speaking" / idle line.
            ValueListenableBuilder<String?>(
              valueListenable: _session.speaker,
              builder: (_, speaker, __) => SizedBox(
                height: 22,
                child: speaker == null
                    ? Text(tr('Hold the button to talk'),
                        style: TextStyle(color: c.textDim, fontSize: 12))
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.graphic_eq, size: 14, color: c.primary),
                          const SizedBox(width: 6),
                          Text(
                            tr('{name} is speaking', {'name': speaker}),
                            style: TextStyle(color: c.primary, fontSize: 12),
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 16),
            // Hold-to-talk button.
            ValueListenableBuilder<bool>(
              valueListenable: _session.transmitting,
              builder: (_, talking, __) => GestureDetector(
                onTapDown: (_) => _session.startTalk(),
                onTapUp: (_) => _session.stopTalk(),
                onTapCancel: () => _session.stopTalk(),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 132,
                  height: 132,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: talking ? c.primary : c.bg,
                    border: Border.all(
                        color: talking ? c.primary : c.border, width: 2),
                    boxShadow: talking
                        ? [BoxShadow(color: c.primaryA(0.4), blurRadius: 24)]
                        : null,
                  ),
                  child: Icon(
                    talking ? Icons.mic : Icons.mic_none,
                    size: 52,
                    color: talking ? c.bg : c.textDim,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            ValueListenableBuilder<bool>(
              valueListenable: _session.transmitting,
              builder: (_, talking, __) => Text(
                talking ? tr('Transmitting…') : tr('Release to listen'),
                style: TextStyle(
                    color: talking ? c.primary : c.textDim, fontSize: 12),
              ),
            ),
            ValueListenableBuilder<String?>(
              valueListenable: _session.error,
              builder: (_, err, __) => err == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(err,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.danger, fontSize: 12)),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
