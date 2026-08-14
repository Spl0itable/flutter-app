import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../services/mesh/mesh_peer.dart';
import '../../services/mesh/transport/mesh_transport.dart';
import '../../state/settings_provider.dart';
import 'mesh_controller.dart';

/// The Bluetooth-mesh surface: radio status, an enable toggle, the nearby
/// (public broadcast) feed, and the list of discovered peers. Tapping a peer
/// opens an end-to-end-encrypted mesh direct message thread.
class MeshScreen extends ConsumerWidget {
  const MeshScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final mesh = ref.watch(meshControllerProvider);
    final enabled = ref.watch(settingsProvider.select((s) => s.meshEnabled));

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: c.bg,
        appBar: AppBar(
          backgroundColor: c.bgSecondary,
          foregroundColor: c.text,
          title: const Text('Bluetooth Mesh'),
          bottom: TabBar(
            labelColor: c.primary,
            unselectedLabelColor: c.textDim,
            indicatorColor: c.primary,
            tabs: [
              const Tab(text: 'Nearby'),
              Tab(text: 'Peers (${mesh.peers.length})'),
            ],
          ),
        ),
        body: Column(
          children: [
            _StatusBar(mesh: mesh, enabled: enabled, colors: c, ref: ref),
            Expanded(
              child: TabBarView(
                children: [
                  _NearbyTab(mesh: mesh, colors: c, ref: ref),
                  _PeersTab(mesh: mesh, colors: c),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar(
      {required this.mesh, required this.enabled, required this.colors, required this.ref});
  final MeshUiState mesh;
  final bool enabled;
  final NymColors colors;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final status = _statusLabel(mesh);
    return Container(
      color: colors.bgSecondary,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            enabled && mesh.running ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            color: enabled && mesh.running ? colors.primary : colors.textDim,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(status,
                    style: TextStyle(color: colors.text, fontWeight: FontWeight.w600, fontSize: 13)),
                if (mesh.myPeerID != null)
                  Text('You: ${mesh.myPeerID}  •  ${mesh.linkCount} link(s)',
                      style: TextStyle(color: colors.textDim, fontSize: 11)),
              ],
            ),
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

  String _statusLabel(MeshUiState mesh) {
    if (!enabled) return 'Mesh off';
    if (mesh.error != null) return 'Mesh error';
    switch (mesh.availability) {
      case MeshTransportAvailability.ready:
        return mesh.running ? 'Mesh active' : 'Starting…';
      case MeshTransportAvailability.poweredOff:
        return 'Turn on Bluetooth';
      case MeshTransportAvailability.unauthorized:
        return 'Bluetooth permission needed';
      case MeshTransportAvailability.unsupported:
        return 'Mesh not supported on this device';
      case MeshTransportAvailability.unknown:
        return 'Starting…';
    }
  }
}

class _NearbyTab extends StatefulWidget {
  const _NearbyTab({required this.mesh, required this.colors, required this.ref});
  final MeshUiState mesh;
  final NymColors colors;
  final WidgetRef ref;

  @override
  State<_NearbyTab> createState() => _NearbyTabState();
}

class _NearbyTabState extends State<_NearbyTab> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final messages = widget.mesh.nearby;
    return Column(
      children: [
        Expanded(
          child: messages.isEmpty
              ? _empty(c, 'No nearby messages yet.\nSay hi to everyone in range.')
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  itemBuilder: (_, i) {
                    final m = messages[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: RichText(
                        text: TextSpan(children: [
                          TextSpan(
                            text: '${m.senderNickname}: ',
                            style: TextStyle(
                                color: c.secondary, fontWeight: FontWeight.w600),
                          ),
                          TextSpan(text: m.content, style: TextStyle(color: c.text)),
                        ]),
                      ),
                    );
                  },
                ),
        ),
        _Composer(
          colors: c,
          controller: _controller,
          enabled: widget.mesh.running,
          hint: 'Message everyone nearby',
          onSend: (text) => widget.ref
              .read(meshControllerProvider.notifier)
              .sendNearby(text),
        ),
      ],
    );
  }
}

class _PeersTab extends StatelessWidget {
  const _PeersTab({required this.mesh, required this.colors});
  final MeshUiState mesh;
  final NymColors colors;

  @override
  Widget build(BuildContext context) {
    if (mesh.peers.isEmpty) {
      return _empty(colors, 'No peers discovered yet.\nMake sure Bluetooth is on.');
    }
    final peers = [...mesh.peers]..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return ListView.separated(
      itemCount: peers.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: colors.border),
      itemBuilder: (_, i) {
        final peer = peers[i];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: colors.bgTertiary,
            child: Icon(
              peer.isVerified ? Icons.verified_user : Icons.person,
              color: peer.isVerified ? colors.primary : colors.textDim,
              size: 20,
            ),
          ),
          title: Text(peer.displayName, style: TextStyle(color: colors.text)),
          subtitle: Text(
            peer.peerID + (peer.isVerified ? '  • verified' : ''),
            style: TextStyle(color: colors.textDim, fontSize: 11),
          ),
          trailing: Icon(Icons.lock_outline, color: colors.purple, size: 18),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => MeshPmScreen(peer: peer),
          )),
        );
      },
    );
  }
}

/// An end-to-end-encrypted mesh DM thread with one [peer].
class MeshPmScreen extends ConsumerStatefulWidget {
  const MeshPmScreen({super.key, required this.peer});
  final MeshPeer peer;

  @override
  ConsumerState<MeshPmScreen> createState() => _MeshPmScreenState();
}

class _MeshPmScreenState extends ConsumerState<MeshPmScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final mesh = ref.watch(meshControllerProvider);
    final thread = mesh.threads[widget.peer.peerID] ?? const [];

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.bgSecondary,
        foregroundColor: c.text,
        title: Row(
          children: [
            Icon(Icons.lock_outline, size: 16, color: c.purple),
            const SizedBox(width: 8),
            Expanded(child: Text(widget.peer.displayName, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: thread.isEmpty
                ? _empty(c, 'Encrypted mesh chat.\nMessages are sealed with Noise (XX).')
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: thread.length,
                    itemBuilder: (_, i) {
                      final m = thread[i];
                      return Align(
                        alignment:
                            m.fromMe ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          constraints: BoxConstraints(
                              maxWidth: MediaQuery.of(context).size.width * 0.72),
                          decoration: BoxDecoration(
                            color: m.fromMe ? c.primary.withValues(alpha: 0.18) : c.bgSecondary,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(m.content, style: TextStyle(color: c.text)),
                              if (m.fromMe)
                                Text(
                                  _statusText(m.status),
                                  style: TextStyle(color: c.textDim, fontSize: 10),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          _Composer(
            colors: c,
            controller: _controller,
            enabled: mesh.running,
            hint: 'Encrypted message',
            onSend: (text) => ref
                .read(meshControllerProvider.notifier)
                .sendPrivate(widget.peer.peerID, text),
          ),
        ],
      ),
    );
  }

  String _statusText(MeshDeliveryStatus s) {
    switch (s) {
      case MeshDeliveryStatus.sending:
        return 'sending…';
      case MeshDeliveryStatus.delivered:
        return 'delivered';
      case MeshDeliveryStatus.read:
        return 'read';
    }
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.colors,
    required this.controller,
    required this.enabled,
    required this.hint,
    required this.onSend,
  });

  final NymColors colors;
  final TextEditingController controller;
  final bool enabled;
  final String hint;
  final void Function(String text) onSend;

  @override
  Widget build(BuildContext context) {
    void submit() {
      final text = controller.text.trim();
      if (text.isEmpty) return;
      onSend(text);
      controller.clear();
    }

    return Container(
      color: colors.bgSecondary,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              style: TextStyle(color: colors.text),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => submit(),
              decoration: InputDecoration(
                hintText: enabled ? hint : 'Mesh is off',
                hintStyle: TextStyle(color: colors.textDim),
                filled: true,
                fillColor: colors.bg,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide(color: colors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide(color: colors.border),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.send, color: enabled ? colors.primary : colors.textDim),
            onPressed: enabled ? submit : null,
          ),
        ],
      ),
    );
  }
}

Widget _empty(NymColors c, String text) => Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: c.textDim, height: 1.5),
        ),
      ),
    );
