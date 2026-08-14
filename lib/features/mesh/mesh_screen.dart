import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../services/mesh/mesh_peer.dart';
import '../../services/mesh/transport/mesh_transport.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/nym_icons.dart';
import '../i18n/i18n.dart';
import 'mesh_bridge.dart' show kMeshNearbyChannel;
import 'mesh_controller.dart';

/// Bluetooth-mesh status + discovery surface. Conversations themselves live in
/// the normal Channels / Private Messages lists and open in the canonical
/// ChatPane — this screen only shows radio status and the peers in range, and
/// lets you start (or jump into) a mesh DM with a nearby peer or the public
/// `#mesh` channel.
class MeshScreen extends ConsumerWidget {
  const MeshScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final mesh = ref.watch(meshControllerProvider);

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.bgSecondary,
        foregroundColor: c.text,
        title: Row(
          children: [
            NymSvgIcon(NymIcons.bluetooth, size: 18, color: c.primary),
            const SizedBox(width: 8),
            Text(tr('Bluetooth Mesh')),
          ],
        ),
      ),
      body: Column(
        children: [
          _StatusBar(mesh: mesh, colors: c),
          // The public #mesh channel — opens in the normal chat view, where it
          // weaves together Nostr (kind-20000) and Bluetooth-mesh messages.
          ListTile(
            leading: Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Text('#',
                  style: TextStyle(
                      color: c.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 18)),
            ),
            title: Text('#mesh', style: TextStyle(color: c.text)),
            subtitle: Text(tr('Public channel · everyone in range'),
                style: TextStyle(color: c.textDim, fontSize: 12)),
            trailing:
                NymSvgIcon(NymIcons.bluetooth, size: 16, color: c.primary),
            onTap: () {
              ref
                  .read(appStateProvider.notifier)
                  .switchChannel(kMeshNearbyChannel);
              Navigator.of(context).maybePop();
            },
          ),
          Divider(height: 1, color: c.border),
          Expanded(child: _PeersList(mesh: mesh, colors: c)),
        ],
      ),
    );
  }
}

class _StatusBar extends ConsumerWidget {
  const _StatusBar({required this.mesh, required this.colors});
  final MeshUiState mesh;
  final NymColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(settingsProvider.select((s) => s.meshEnabled));
    final active = enabled && mesh.running;
    final needsPermission =
        enabled && mesh.availability == MeshTransportAvailability.unauthorized;
    return Container(
      color: colors.bgSecondary,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Opacity(
            opacity: active ? 1 : 0.5,
            child: NymSvgIcon(NymIcons.bluetooth,
                size: 20, color: active ? colors.primary : colors.textDim),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_statusLabel(enabled),
                    style: TextStyle(
                        color: colors.text,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
                if (mesh.myPeerID != null)
                  Text('You: ${mesh.myPeerID}  •  ${mesh.linkCount} link(s)',
                      style: TextStyle(
                          color: colors.textDim,
                          fontSize: 11,
                          fontFamily: 'monospace')),
              ],
            ),
          ),
          if (needsPermission)
            TextButton(
              onPressed: () =>
                  ref.read(meshControllerProvider.notifier).openSystemSettings(),
              child: Text(tr('Enable'), style: TextStyle(color: colors.primary)),
            ),
          Switch(
            value: enabled,
            activeThumbColor: colors.primary,
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).setMeshEnabled(v),
          ),
        ],
      ),
    );
  }

  String _statusLabel(bool enabled) {
    if (!enabled) return tr('Mesh off');
    if (mesh.error != null) return tr('Mesh error');
    switch (mesh.availability) {
      case MeshTransportAvailability.ready:
        return mesh.running ? tr('Mesh active') : tr('Starting…');
      case MeshTransportAvailability.poweredOff:
        return tr('Turn on Bluetooth');
      case MeshTransportAvailability.unauthorized:
        return tr('Bluetooth permission needed');
      case MeshTransportAvailability.unsupported:
        return tr('Mesh not supported on this device');
      case MeshTransportAvailability.unknown:
        return tr('Starting…');
    }
  }
}

class _PeersList extends ConsumerWidget {
  const _PeersList({required this.mesh, required this.colors});
  final MeshUiState mesh;
  final NymColors colors;

  void _openPeer(BuildContext context, WidgetRef ref, MeshPeer peer) {
    final pubkey =
        ref.read(meshControllerProvider.notifier).bridge?.openPeerDm(peer);
    if (pubkey == null) return;
    ref.read(appStateProvider.notifier).switchView(ChatView.pm(pubkey));
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (mesh.peers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            tr('No peers discovered yet.\nMake sure Bluetooth is on.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textDim, height: 1.5),
          ),
        ),
      );
    }
    final peers = [...mesh.peers]
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return ListView.separated(
      itemCount: peers.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: colors.border),
      itemBuilder: (_, i) {
        final peer = peers[i];
        final seed = peer.nostrPubkey ?? peer.peerID;
        return ListTile(
          leading: NymAvatar(
            seed: seed,
            size: 38,
            imageUrl: peer.avatarUrl,
            label: peer.displayName,
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(peer.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.text)),
              ),
              if (peer.isVerified) ...[
                const SizedBox(width: 6),
                NymSvgIcon(NymIcons.friendBadge, size: 13, color: colors.primary),
              ],
            ],
          ),
          subtitle: Text(
            peer.peerID + (peer.nostrLinkVerified ? '  • linked' : ''),
            style: TextStyle(
                color: colors.textDim, fontSize: 11, fontFamily: 'monospace'),
          ),
          trailing: NymSvgIcon(NymIcons.lock, size: 16, color: colors.purple),
          onTap: () => _openPeer(context, ref, peer),
        );
      },
    );
  }
}
