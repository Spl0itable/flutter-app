import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../models/message.dart';
import '../../models/settings.dart';
import '../../services/mesh/mesh_peer.dart';
import '../../services/mesh/transport/mesh_transport.dart';
import '../../state/settings_provider.dart';
import '../../widgets/chat/message_row.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/nym_icons.dart';
import 'mesh_controller.dart';

/// The Bluetooth-mesh surface: radio status, an enable toggle, the nearby
/// (public broadcast) feed, and the list of discovered peers. Tapping a peer
/// opens an end-to-end-encrypted mesh direct message thread.
///
/// Chat renders through the app's canonical [MessageGroup]/[MessageRow], so mesh
/// messages are visually identical to a normal channel or PM — same bubbles,
/// avatars, author colours, grouping, emoji/mention formatting, delivery
/// receipts and theme.
class MeshScreen extends ConsumerWidget {
  const MeshScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final mesh = ref.watch(meshControllerProvider);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: c.bg,
        appBar: AppBar(
          backgroundColor: c.bgSecondary,
          foregroundColor: c.text,
          title: Row(
            children: [
              NymSvgIcon(NymIcons.bluetooth, size: 18, color: c.primary),
              const SizedBox(width: 8),
              const Text('Bluetooth Mesh'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Join a group',
              icon: NymSvgIcon(NymIcons.groupGlyph, size: 18, color: c.primary),
              onPressed: () => showJoinMeshGroupDialog(context, ref),
            ),
          ],
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
            _StatusBar(mesh: mesh, colors: c),
            Expanded(
              child: TabBarView(
                children: [
                  _NearbyTab(mesh: mesh, colors: c),
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
                        color: colors.text, fontWeight: FontWeight.w600, fontSize: 13)),
                if (mesh.myPeerID != null)
                  Text('You: ${mesh.myPeerID}  •  ${mesh.linkCount} link(s)',
                      style: TextStyle(
                          color: colors.textDim, fontSize: 11, fontFamily: 'monospace')),
              ],
            ),
          ),
          if (needsPermission)
            TextButton(
              onPressed: () =>
                  ref.read(meshControllerProvider.notifier).openSystemSettings(),
              child: Text('Enable', style: TextStyle(color: colors.primary)),
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

class _NearbyTab extends ConsumerWidget {
  const _NearbyTab({required this.mesh, required this.colors});
  final MeshUiState mesh;
  final NymColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final messages = [
      for (final m in mesh.nearby)
        Message(
          id: m.messageId,
          author: m.senderNickname,
          pubkey: mesh.peerById(m.senderPeerID)?.nostrPubkey ?? m.senderPeerID,
          content: m.content,
          createdAt: m.timestampMs ~/ 1000,
          ms: m.timestampMs,
          isOwn: m.senderPeerID == mesh.myPeerID,
          channel: '#mesh',
          eventKind: 20000,
          deliveryStatus: DeliveryStatus.sent,
        ),
    ];
    return Column(
      children: [
        Expanded(
          child: messages.isEmpty
              ? _empty(colors, 'No nearby messages yet.\nSay hi to everyone in range.')
              : _CanonicalMessageList(messages: messages, settings: settings),
        ),
        _Composer(
          colors: colors,
          enabled: mesh.running,
          hint: 'Message everyone nearby',
          onSend: (text) =>
              ref.read(meshControllerProvider.notifier).sendNearby(text),
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
            style: TextStyle(color: colors.textDim, fontSize: 11, fontFamily: 'monospace'),
          ),
          trailing: NymSvgIcon(NymIcons.lock, size: 16, color: colors.purple),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => MeshPmScreen(peer: peer),
          )),
        );
      },
    );
  }
}

/// A mesh group channel — an open or password-encrypted broadcast room. Renders
/// through the same canonical message list as Nearby/DMs.
class MeshChannelScreen extends ConsumerWidget {
  const MeshChannelScreen({super.key, required this.channel, this.encrypted = false});
  final String channel;
  final bool encrypted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final settings = ref.watch(settingsProvider);
    final mesh = ref.watch(meshControllerProvider);
    final msgs = mesh.channelMessages[channel] ?? const [];
    final messages = [
      for (final m in msgs)
        Message(
          id: m.messageId,
          author: m.senderNickname,
          pubkey: mesh.peerById(m.senderPeerID)?.nostrPubkey ?? m.senderPeerID,
          content: m.content,
          createdAt: m.timestampMs ~/ 1000,
          ms: m.timestampMs,
          isOwn: m.senderPeerID == mesh.myPeerID,
          channel: channel,
          eventKind: 20000,
          deliveryStatus: DeliveryStatus.sent,
        ),
    ];
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.bgSecondary,
        foregroundColor: c.text,
        title: Row(
          children: [
            if (encrypted) ...[
              NymSvgIcon(NymIcons.lock, size: 15, color: c.purple),
              const SizedBox(width: 8),
            ],
            Expanded(child: Text(channel, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Leave group',
            icon: NymSvgIcon(NymIcons.close, size: 16, color: c.textDim),
            onPressed: () {
              ref.read(meshControllerProvider.notifier).leaveChannel(channel);
              Navigator.of(context).maybePop();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? _empty(
                    c,
                    encrypted
                        ? 'Encrypted group.\nMessages are sealed with the shared password.'
                        : 'Open mesh group.\nEveryone in range with this channel can read it.')
                : _CanonicalMessageList(messages: messages, settings: settings),
          ),
          _Composer(
            colors: c,
            enabled: mesh.running,
            hint: encrypted ? 'Encrypted group message' : 'Message $channel',
            onSend: (text) => ref
                .read(meshControllerProvider.notifier)
                .sendChannelMessage(channel, text),
          ),
        ],
      ),
    );
  }
}

/// Prompts for a mesh group name + optional password, joins it, and opens it.
Future<void> showJoinMeshGroupDialog(BuildContext context, WidgetRef ref) async {
  final c = context.nym;
  final nameCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  final joined = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.bgSecondary,
      title: Text('Join a mesh group', style: TextStyle(color: c.text)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameCtrl,
            autofocus: true,
            style: TextStyle(color: c.text),
            decoration: InputDecoration(
              labelText: 'Group name (e.g. crew)',
              labelStyle: TextStyle(color: c.textDim),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: passCtrl,
            obscureText: true,
            style: TextStyle(color: c.text),
            decoration: InputDecoration(
              labelText: 'Password (optional — encrypts the group)',
              labelStyle: TextStyle(color: c.textDim),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text('Cancel', style: TextStyle(color: c.textDim)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text('Join', style: TextStyle(color: c.primary)),
        ),
      ],
    ),
  );
  final name = nameCtrl.text.trim();
  final pass = passCtrl.text;
  nameCtrl.dispose();
  passCtrl.dispose();
  if (joined != true || name.isEmpty || !context.mounted) return;
  await ref.read(meshControllerProvider.notifier).joinChannel(name, password: pass);
  final channel = name.startsWith('#') ? name : '#$name';
  if (!context.mounted) return;
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => MeshChannelScreen(channel: channel, encrypted: pass.isNotEmpty),
  ));
}

/// An end-to-end-encrypted mesh DM thread with one [peer].
class MeshPmScreen extends ConsumerStatefulWidget {
  const MeshPmScreen({super.key, required this.peer});
  final MeshPeer peer;

  @override
  ConsumerState<MeshPmScreen> createState() => _MeshPmScreenState();
}

class _MeshPmScreenState extends ConsumerState<MeshPmScreen> {
  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final settings = ref.watch(settingsProvider);
    final mesh = ref.watch(meshControllerProvider);
    final thread = mesh.threads[widget.peer.peerID] ?? const [];
    // Mark unread inbound as read (fires read receipts back over the session).
    // Deferred to after the frame so it never mutates provider state mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(meshControllerProvider.notifier).markThreadRead(widget.peer.peerID);
      }
    });

    final pubkey = widget.peer.nostrPubkey ?? widget.peer.peerID;
    final messages = [
      for (final m in thread)
        Message(
          id: m.messageId,
          author: widget.peer.displayName,
          pubkey: pubkey,
          content: m.content,
          createdAt: m.timestampMs ~/ 1000,
          ms: m.timestampMs,
          isOwn: m.fromMe,
          isPM: true,
          conversationKey: 'mesh:${widget.peer.peerID}',
          conversationPubkey: pubkey,
          eventKind: 14,
          senderVerified: m.fromMe ? null : (widget.peer.isVerified ? true : null),
          deliveryStatus: _mapStatus(m.status),
        ),
    ];

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.bgSecondary,
        foregroundColor: c.text,
        title: Row(
          children: [
            NymSvgIcon(NymIcons.lock, size: 15, color: c.purple),
            const SizedBox(width: 8),
            Expanded(child: Text(widget.peer.displayName, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? _empty(c, 'Encrypted mesh chat.\nMessages are sealed with Noise (XX).')
                : _CanonicalMessageList(messages: messages, settings: settings),
          ),
          _Composer(
            colors: c,
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

  DeliveryStatus _mapStatus(MeshDeliveryStatus s) {
    switch (s) {
      case MeshDeliveryStatus.sending:
        return DeliveryStatus.sending;
      case MeshDeliveryStatus.delivered:
        return DeliveryStatus.delivered;
      case MeshDeliveryStatus.read:
        return DeliveryStatus.read;
    }
  }
}

/// Renders a list of [Message]s through the app's canonical [MessageGroup],
/// folding consecutive same-author messages into groups exactly like the main
/// chat list — so mesh chat is visually identical to a channel/PM.
class _CanonicalMessageList extends ConsumerWidget {
  const _CanonicalMessageList({required this.messages, required this.settings});
  final List<Message> messages;
  final Settings settings;

  static const int _groupWindowSec = 300;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final units = <List<MessageGroupEntry>>[];
    for (final m in messages) {
      final entry =
          MessageGroupEntry(message: m, reactions: const [], mentioned: false);
      if (settings.useBubbles &&
          units.isNotEmpty &&
          _groupsWith(units.last.last.message, m)) {
        units.last.add(entry);
      } else {
        units.add([entry]);
      }
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      itemCount: units.length,
      itemBuilder: (_, i) => MessageGroup(
        key: ValueKey('meshgroup_${units[i].first.message.id}'),
        entries: units[i],
        settings: settings,
      ),
    );
  }

  bool _groupsWith(Message prev, Message cur) =>
      !prev.isSystemRow &&
      !cur.isSystemRow &&
      !prev.isMeAction &&
      !cur.isMeAction &&
      prev.pubkey == cur.pubkey &&
      (cur.createdAt - prev.createdAt).abs() <= _groupWindowSec;
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.colors,
    required this.enabled,
    required this.hint,
    required this.onSend,
  });

  final NymColors colors;
  final bool enabled;
  final String hint;
  final void Function(String text) onSend;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return Container(
      color: colors.bgSecondary,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              enabled: widget.enabled,
              style: TextStyle(color: colors.text),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: widget.enabled ? widget.hint : 'Mesh is off',
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
            icon: NymSvgIcon(NymIcons.send,
                size: 20, color: widget.enabled ? colors.primary : colors.textDim),
            onPressed: widget.enabled ? _submit : null,
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
