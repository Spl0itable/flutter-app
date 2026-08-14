// Bridges the Bluetooth mesh into the app's normal chat stores.
//
// Rather than a parallel UI, mesh is just another transport: received mesh
// messages are ingested into [AppState] exactly like Nostr ones (channels via
// [ingestMeshChannelMessage], DMs via [ingestPMMessage]), so they render through
// the canonical ChatPane — same header, composer, message rows, reactions,
// unread badges, and notifications. Outgoing sends from the composer are routed
// back over the mesh when the active conversation is mesh-backed.
//
// Identity mapping: a mesh peer is keyed by a 64-hex pubkey so it slots into the
// PM store. A cryptographically npub-linked peer uses its REAL Nostr pubkey (so
// its Bluetooth DM shares the one thread with its internet DM); an unlinked peer
// uses its 32-byte Noise static key as a stable pseudo-pubkey.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../features/pms/pm_logic.dart' show ReceiptInfo;
import '../../models/message.dart';
import '../../services/mesh/mesh_events.dart';
import '../../services/mesh/mesh_peer.dart';
import '../../services/mesh/mesh_service.dart';
import '../../services/mesh/protocol/mesh_profile.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import 'mesh_controller.dart';

/// The bare storage key of the mesh "Nearby" public channel (renders as
/// `#mesh` — an ordinary channel in the sidebar's Channels list).
const String kMeshNearbyChannel = 'mesh';

String _hex(Uint8List b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

class MeshBridge {
  MeshBridge({
    required Ref ref,
    required MeshService service,
    required String Function() selfNym,
  })  : _ref = ref,
        _service = service,
        _selfNym = selfNym;

  final Ref _ref;
  final MeshService _service;
  final String Function() _selfNym;

  final List<StreamSubscription<dynamic>> _subs = [];

  /// peerID (16-hex) → 64-hex pubkey used as the PM store key.
  final Map<String, String> _pubkeyByPeerId = {};

  /// pubkey → peerID, for routing an outgoing DM back to the right radio peer.
  final Map<String, String> _peerIdByPubkey = {};

  /// Nym for a peer's pubkey, for building inbound message authors.
  final Map<String, String> _nymByPubkey = {};

  /// Bare channel keys (lowercase) that are mesh-backed — drives the sidebar
  /// Bluetooth glyph and send routing.
  final Set<String> _meshChannelKeys = {kMeshNearbyChannel};

  /// Pubkeys whose PM conversation is mesh-backed.
  final Set<String> _meshPmPubkeys = {};

  AppStateNotifier get _app => _ref.read(appStateProvider.notifier);
  AppState get _appState => _ref.read(appStateProvider);

  // ---- Markers consulted by the sidebar + send router ----------------------

  bool isMeshChannelKey(String key) => _meshChannelKeys.contains(key.toLowerCase());
  bool isMeshPmPubkey(String pubkey) => _meshPmPubkeys.contains(pubkey.toLowerCase());

  Set<String> get meshChannelKeys => _meshChannelKeys;
  Set<String> get meshPmPubkeys => _meshPmPubkeys;

  /// True when [view] is a conversation this bridge should send over the mesh.
  bool isMeshView(ChatView view) {
    if (view.kind == ViewKind.channel) return isMeshChannelKey(view.id);
    if (view.kind == ViewKind.pm) return isMeshPmPubkey(view.id);
    return false;
  }

  // ---- Lifecycle -----------------------------------------------------------

  ProviderSubscription<ChatView>? _viewSub;

  void start() {
    _subs.add(_service.peersStream.listen(_onPeers));
    _subs.add(_service.onPublicMessage.listen(_onPublic));
    _subs.add(_service.onPrivateMessage.listen(_onPrivate));
    _subs.add(_service.onReceipt.listen(_onReceipt));
    _subs.add(_service.onFile.listen(_onFile));
    _subs.add(_service.onTyping.listen(_onTyping));
    _subs.add(_service.onReaction.listen(_onReaction));
    // Register the always-present Nearby channel so it appears immediately.
    _app.addChannel(kMeshNearbyChannel);
    // Send read receipts over the mesh whenever a mesh DM becomes the active
    // conversation (the canonical read-on-open behaviour, restored for mesh).
    _viewSub = _ref.listen<ChatView>(
      appStateProvider.select((s) => s.view),
      (_, view) {
        if (view.kind == ViewKind.pm && isMeshPmPubkey(view.id)) {
          markMeshPmRead(view.id);
        }
      },
      fireImmediately: true,
    );
  }

  Future<void> dispose() async {
    _viewSub?.close();
    _viewSub = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  /// Read receipts we've already sent, keyed by the message id, so we ack each
  /// inbound mesh DM exactly once.
  final Set<String> _readAcked = {};

  /// Sends a read receipt over the mesh for every not-yet-acked inbound message
  /// in [pubkey]'s thread. Idempotent — safe to call on every open/new message.
  void markMeshPmRead(String pubkey) {
    final peerId = peerIdForPubkey(pubkey);
    if (peerId == null) return;
    final list = _appState.messages['pm-${pubkey.toLowerCase()}'];
    if (list == null) return;
    for (final m in list) {
      if (m.isOwn) continue;
      final id = m.nymMessageId ?? m.id;
      if (id.isEmpty || !_readAcked.add(id)) continue;
      unawaited(_service.sendReadReceipt(peerId, id));
    }
  }

  /// Registers a joined mesh group [channel] (e.g. `#crew`) as an app channel.
  void registerChannel(String channel) {
    final name = channel.startsWith('#') ? channel.substring(1) : channel;
    if (name.isEmpty) return;
    _meshChannelKeys.add(name.toLowerCase());
    _app.addChannel(name);
  }

  // ---- Identity mapping ----------------------------------------------------

  /// The 64-hex pubkey used to key [peer]'s PM conversation.
  String pubkeyForPeer(MeshPeer peer) {
    if (peer.nostrLinkVerified &&
        peer.nostrPubkey != null &&
        peer.nostrPubkey!.length == 64) {
      return peer.nostrPubkey!.toLowerCase();
    }
    final k = peer.noisePublicKey;
    if (k != null && k.length == 32) return _hex(k);
    return peer.peerID.toLowerCase().padRight(64, '0').substring(0, 64);
  }

  String _pubkeyForPeerId(String peerID) {
    return _pubkeyByPeerId[peerID] ??
        peerID.toLowerCase().padRight(64, '0').substring(0, 64);
  }

  /// Resolves the radio peerID for an outgoing DM to [pubkey].
  String? peerIdForPubkey(String pubkey) => _peerIdByPubkey[pubkey.toLowerCase()];

  /// Proactively opens a mesh DM with [peer] (from the peers list): registers
  /// the routing, marks the conversation mesh-backed, and ensures the PM row
  /// exists. Returns the pubkey to `switchView(ChatView.pm(pubkey))` to.
  String openPeerDm(MeshPeer peer) {
    final pubkey = pubkeyForPeer(peer);
    _pubkeyByPeerId[peer.peerID] = pubkey;
    _peerIdByPubkey[pubkey] = peer.peerID;
    _nymByPubkey[pubkey] = peer.displayName;
    if (_meshPmPubkeys.add(pubkey)) _refreshMarkers();
    _app.ensurePMConversation(pubkey, nym: peer.displayName);
    return pubkey;
  }

  // ---- Inbound -------------------------------------------------------------

  void _onPeers(List<MeshPeer> peers) {
    for (final p in peers) {
      final pubkey = pubkeyForPeer(p);
      _pubkeyByPeerId[p.peerID] = pubkey;
      _peerIdByPubkey[pubkey] = p.peerID;
      _nymByPubkey[pubkey] = p.displayName;
    }
  }

  void _onPublic(MeshPublicMessage msg) {
    final channelName = (msg.channel == null || msg.channel!.isEmpty)
        ? kMeshNearbyChannel
        : (msg.channel!.startsWith('#')
            ? msg.channel!.substring(1)
            : msg.channel!);
    final key = channelName.toLowerCase();
    if (_meshChannelKeys.add(key)) _refreshMarkers();
    final storageKey = '#$key';
    final isOwn = msg.senderPeerID == _service.myPeerID;
    final pubkey =
        isOwn ? _appState.selfPubkey : _pubkeyForPeerId(msg.senderPeerID);
    final m = Message(
      id: msg.messageId,
      author: isOwn ? _selfNym() : msg.senderNickname,
      pubkey: pubkey,
      content: msg.content,
      createdAt: msg.timestampMs ~/ 1000,
      ms: msg.timestampMs,
      isOwn: isOwn,
      channel: channelName,
      eventKind: 20000,
      deliveryStatus: DeliveryStatus.sent,
      viaMesh: true,
    );
    final landed = _app.ingestMeshChannelMessage(m, channelKey: storageKey);
    if (landed && !isOwn) _maybeNotifyChannelMention(m, channelName);
  }

  void _onPrivate(MeshPrivateMessage msg) {
    final pubkey = _pubkeyForPeerId(msg.senderPeerID);
    if (_meshPmPubkeys.add(pubkey)) _refreshMarkers();
    final nym = _nymByPubkey[pubkey] ?? 'nym';
    _app.ensurePMConversation(pubkey, nym: nym);
    final m = _pmMessage(
      id: msg.messageId,
      pubkey: pubkey,
      author: nym,
      content: msg.content,
      timestampMs: msg.timestampMs,
      isOwn: false,
    );
    _app.ingestPMMessage(m);
    _notifyPm(pubkey: pubkey, nym: nym, body: msg.content, ts: msg.timestampMs);
    // If this thread is already on-screen, ack it immediately.
    final view = _appState.view;
    if (view.kind == ViewKind.pm && view.id.toLowerCase() == pubkey) {
      markMeshPmRead(pubkey);
    }
  }

  void _onReceipt(MeshReceipt receipt) {
    _app.applyReceipt(ReceiptInfo(
      messageId: receipt.messageId,
      receiptType: receipt.isRead ? 'read' : 'delivered',
    ));
  }

  void _onTyping(MeshTypingEvent e) {
    final pubkey = _pubkeyForPeerId(e.senderPeerID);
    final String storageKey;
    if (e.isDirect) {
      storageKey = 'pm-$pubkey';
    } else {
      final ch = (e.channel == null || e.channel!.isEmpty)
          ? kMeshNearbyChannel
          : (e.channel!.startsWith('#')
              ? e.channel!.substring(1)
              : e.channel!);
      storageKey = '#${ch.toLowerCase()}';
    }
    _app.setTyping(
      storageKey: storageKey,
      pubkey: pubkey,
      typing: e.isStart,
      nym: e.nickname,
    );
  }

  void _onReaction(MeshReactionEvent e) {
    final pubkey = _pubkeyForPeerId(e.senderPeerID);
    // Canonicalize the target to the stored Message.id (a DM reaction targets
    // the shared id, which is indexed as the message's nymMessageId).
    final target = _app.messageById(e.targetId)?.id ?? e.targetId;
    _app.applyReaction(
      messageId: target,
      emoji: e.emoji,
      reactor: pubkey,
      removed: e.isRemove,
      reactorNym: e.reactorNick,
    );
  }

  /// Sends an emoji reaction to [targetId] over the mesh for the active [view].
  void sendReaction(ChatView view, String targetId, String emoji,
      {required bool remove}) {
    if (view.kind == ViewKind.channel) {
      unawaited(_service.sendChannelReaction(targetId, emoji, remove));
    } else if (view.kind == ViewKind.pm) {
      final peerId = peerIdForPubkey(view.id);
      if (peerId != null) {
        unawaited(_service.sendPrivateReaction(peerId, targetId, emoji, remove));
      }
    }
  }

  /// Sends a typing indicator for the active mesh [view] (throttled by the
  /// composer, and auto-expiring after ~5s on the receiver).
  void sendTyping(ChatView view, bool start) {
    if (view.kind == ViewKind.channel) {
      final ch = view.id.toLowerCase();
      unawaited(_service.sendTyping(
        channel: ch == kMeshNearbyChannel ? null : '#$ch',
        start: start,
      ));
    } else if (view.kind == ViewKind.pm) {
      final peerId = peerIdForPubkey(view.id);
      if (peerId != null) {
        unawaited(_service.sendTyping(toPeerID: peerId, start: start));
      }
    }
  }

  Future<void> _onFile(MeshFileReceived event) async {
    final path = await _saveFile(event.fileName, event.bytes);
    if (path == null) return;
    if (event.isDirect) {
      final pubkey = _pubkeyForPeerId(event.fromPeerID);
      _meshPmPubkeys.add(pubkey);
      final nym = _nymByPubkey[pubkey] ?? 'nym';
      _app.ensurePMConversation(pubkey, nym: nym);
      final m = _pmMessage(
        id: 'file-${DateTime.now().microsecondsSinceEpoch}',
        pubkey: pubkey,
        author: nym,
        content: '',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        isOwn: false,
      )
        ..localMediaPath = path
        ..localMediaMime = event.mimeType
        ..localMediaName = event.fileName;
      _app.ingestPMMessage(m);
      _notifyPm(
          pubkey: pubkey,
          nym: nym,
          body: event.isImage ? '📷 Photo' : '📎 ${event.fileName}',
          ts: m.timestamp);
    } else {
      final channelName = (event.channel == null || event.channel!.isEmpty)
          ? kMeshNearbyChannel
          : (event.channel!.startsWith('#')
              ? event.channel!.substring(1)
              : event.channel!);
      final key = channelName.toLowerCase();
      _meshChannelKeys.add(key);
      final pubkey = _pubkeyForPeerId(event.fromPeerID);
      final m = Message(
        id: 'file-${DateTime.now().microsecondsSinceEpoch}',
        author: event.senderNickname.isNotEmpty ? event.senderNickname : 'nym',
        pubkey: pubkey,
        content: '',
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ms: DateTime.now().millisecondsSinceEpoch,
        isOwn: false,
        channel: channelName,
        eventKind: 20000,
        deliveryStatus: DeliveryStatus.sent,
        viaMesh: true,
      )
        ..localMediaPath = path
        ..localMediaMime = event.mimeType
        ..localMediaName = event.fileName;
      _app.ingestMeshChannelMessage(m, channelKey: '#$key');
    }
  }

  Message _pmMessage({
    required String id,
    required String pubkey,
    required String author,
    required String content,
    required int timestampMs,
    required bool isOwn,
  }) {
    return Message(
      id: id,
      author: author,
      pubkey: pubkey,
      content: content,
      createdAt: timestampMs ~/ 1000,
      ms: timestampMs,
      isOwn: isOwn,
      isPM: true,
      conversationKey: 'pm-$pubkey',
      conversationPubkey: pubkey,
      nymMessageId: id,
      eventKind: 1059,
      senderVerified: isOwn ? null : true,
      deliveryStatus: isOwn ? DeliveryStatus.sent : DeliveryStatus.delivered,
      viaMesh: true,
    );
  }

  void _refreshMarkers() {
    _ref.read(meshControllerProvider.notifier).refreshMarkers();
  }

  // ---- Outbound (from the canonical composer) ------------------------------

  /// Routes a composer send for the active mesh [view].
  Future<void> sendFromComposer(ChatView view, String content) async {
    if (view.kind == ViewKind.channel) {
      _app.sendLocal(content)?.viaMesh = true;
      final channel = '#${view.id.toLowerCase()}';
      await _service.sendPublicMessage(
        content,
        channel: view.id.toLowerCase() == kMeshNearbyChannel ? null : channel,
      );
      // The echo stays; the round-trip is deduped in ingestMeshChannelMessage.
    } else if (view.kind == ViewKind.pm) {
      final peerId = peerIdForPubkey(view.id);
      if (peerId == null) {
        _app.sendLocal(content)?.viaMesh = true;
        return;
      }
      final id = await _service.sendPrivateMessage(peerId, content);
      _app.sendLocal(content, nymMessageId: id)?.viaMesh = true;
    }
  }

  /// Sends a file/media attachment over the mesh for the active [view].
  Future<void> sendFileFromComposer(
    ChatView view,
    String fileName,
    String mimeType,
    Uint8List bytes,
  ) async {
    final path = await _saveFile(fileName, bytes);
    if (view.kind == ViewKind.channel) {
      final name = view.id.toLowerCase();
      await _service.sendFileBroadcast(fileName, mimeType, bytes);
      final m = Message(
        id: 'file-${DateTime.now().microsecondsSinceEpoch}',
        author: _selfNym(),
        pubkey: _appState.selfPubkey,
        content: '',
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ms: DateTime.now().millisecondsSinceEpoch,
        isOwn: true,
        channel: name,
        eventKind: 20000,
        deliveryStatus: DeliveryStatus.sent,
        viaMesh: true,
      )
        ..localMediaPath = path
        ..localMediaMime = mimeType
        ..localMediaName = fileName;
      _app.ingestMeshChannelMessage(m, channelKey: '#$name');
    } else if (view.kind == ViewKind.pm) {
      final peerId = peerIdForPubkey(view.id);
      if (peerId != null) {
        await _service.sendFileToPeer(peerId, fileName, mimeType, bytes);
      }
      final m = _pmMessage(
        id: 'file-${DateTime.now().microsecondsSinceEpoch}',
        pubkey: view.id,
        author: _selfNym(),
        content: '',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        isOwn: true,
      )
        ..localMediaPath = path
        ..localMediaMime = mimeType
        ..localMediaName = fileName;
      _app.ingestPMMessage(m);
    }
  }

  // ---- Notifications -------------------------------------------------------

  void _notifyPm({
    required String pubkey,
    required String nym,
    required String body,
    required int ts,
  }) {
    _ref.read(nostrControllerProvider).dispatchMeshNotification(
          title: nym,
          body: body,
          senderPubkey: pubkey,
          isMention: false,
          historyType: 'pm',
          route: pubkey,
          tsMs: ts,
          eventId: 'mesh-pm-$ts-$pubkey',
        );
  }

  void _maybeNotifyChannelMention(Message m, String channelName) {
    final nym = _selfNym().toLowerCase();
    if (nym.isEmpty) return;
    final body = m.content.toLowerCase();
    if (!body.contains('@$nym') && !body.contains(nym)) return;
    _ref.read(nostrControllerProvider).dispatchMeshNotification(
          title: '#$channelName',
          body: m.content,
          senderPubkey: m.pubkey,
          isMention: true,
          historyType: 'mention',
          route: channelName,
          tsMs: m.timestamp,
          eventId: 'mesh-mention-${m.id}',
          contextLabel: '#$channelName',
        );
  }

  // ---- Disk ----------------------------------------------------------------

  Future<String?> _saveFile(String fileName, Uint8List bytes) async {
    try {
      final dir = Directory(
          '${(await getApplicationDocumentsDirectory()).path}/mesh_files');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final safe = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final path = '${dir.path}/${stamp}_$safe';
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    } catch (_) {
      return null;
    }
  }
}

/// Exposes a peer's rich profile to the bridge/registry (avatar bytes) — reused
/// by the controller's profile-transfer path.
typedef MeshProfileSink = void Function(String peerID, MeshProfile profile);
