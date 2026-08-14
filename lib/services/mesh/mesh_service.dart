import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'dedup.dart';
import 'fragmentation.dart';
import 'mesh_constants.dart';
import 'mesh_events.dart';
import 'mesh_peer.dart';
import 'noise/noise_identity.dart';
import 'noise/noise_session_manager.dart';
import 'protocol/bitchat_message.dart';
import 'protocol/bitchat_packet.dart';
import 'protocol/fragment_payload.dart';
import 'protocol/identity_announcement.dart';
import 'protocol/mesh_message_type.dart';
import 'protocol/noise_payload.dart';
import 'transport/mesh_transport.dart';

/// The heart of the Bluetooth mesh: it owns the radio [MeshTransport], the Noise
/// sessions, peer tracking, deduplication, TTL relay and fragmentation, and
/// turns raw frames into the high-level [MeshPublicMessage] / [MeshPrivateMessage]
/// / [MeshReceipt] events the app consumes — and the reverse for sending.
///
/// Everything on the wire is byte-compatible with bitchat, so a Nymchat device
/// running this service participates in the same mesh as real bitchat devices.
class MeshService {
  MeshService({
    required this.identity,
    required MeshTransport transport,
    required String Function() nicknameProvider,
  })  : _transport = transport,
        _nicknameProvider = nicknameProvider;

  final NoiseIdentity identity;
  final MeshTransport _transport;
  final String Function() _nicknameProvider;

  late final NoiseSessionManager _noise = NoiseSessionManager(identity);
  final SeenPackets _seen = SeenPackets();
  final FragmentReassembler _reassembler = FragmentReassembler();
  final _uuid = const Uuid();
  final _random = Random();

  final Map<String, MeshPeer> _peers = {};

  /// Plaintext we owe a peer, queued until the Noise session establishes.
  final Map<String, List<Uint8List>> _pendingPlaintext = {};

  /// Encrypted transport payloads that arrived before our session with the peer
  /// finished establishing (the initiator sends data the instant it completes
  /// the handshake, which can outrace our own completion). Drained on establish.
  final Map<String, List<Uint8List>> _pendingEncrypted = {};

  final _publicMessages = StreamController<MeshPublicMessage>.broadcast();
  final _privateMessages = StreamController<MeshPrivateMessage>.broadcast();
  final _receipts = StreamController<MeshReceipt>.broadcast();
  final _peersChanged = StreamController<List<MeshPeer>>.broadcast();

  StreamSubscription<MeshInboundFrame>? _inboundSub;
  StreamSubscription<MeshLinkEvent>? _linkSub;
  Timer? _announceTimer;
  Timer? _cleanupTimer;
  bool _running = false;

  // ---- Public API -----------------------------------------------------------

  String get myPeerID => identity.peerID;
  bool get isRunning => _running;
  int get connectedLinkCount => _transport.connectedLinkCount;
  MeshTransportAvailability get availability => _transport.availability;

  List<MeshPeer> get peers => _peers.values.toList(growable: false);
  Stream<List<MeshPeer>> get peersStream => _peersChanged.stream;
  Stream<MeshPublicMessage> get onPublicMessage => _publicMessages.stream;
  Stream<MeshPrivateMessage> get onPrivateMessage => _privateMessages.stream;
  Stream<MeshReceipt> get onReceipt => _receipts.stream;

  /// Powers up the radio and joins the mesh. Returns radio availability.
  Future<MeshTransportAvailability> start() async {
    if (_running) return _transport.availability;
    // Subscribe before powering up the radio so no early frame or link event
    // (e.g. a peer that links during startup) is missed.
    _running = true;
    _inboundSub = _transport.inbound.listen(_onFrame);
    _linkSub = _transport.links.listen(_onLink);
    final availability = await _transport.start();
    _announceTimer =
        Timer.periodic(MeshConstants.announceInterval, (_) => _broadcastAnnounce());
    _cleanupTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _cleanupStalePeers());
    await _broadcastAnnounce();
    return availability;
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    // Best-effort LEAVE so peers drop us promptly.
    await _sendPacket(await _buildPacket(
      type: MeshMessageType.leave,
      payload: Uint8List.fromList(identity.peerID.codeUnits),
    ));
    _announceTimer?.cancel();
    _cleanupTimer?.cancel();
    await _inboundSub?.cancel();
    await _linkSub?.cancel();
    await _transport.stop();
    _noise.clear();
    _seen.clear();
    _reassembler.clear();
    _peers.clear();
    _pendingPlaintext.clear();
    _pendingEncrypted.clear();
  }

  /// Broadcasts a public [content] message (optionally to a [channel]).
  /// Returns the generated message id.
  Future<String> sendPublicMessage(
    String content, {
    String? channel,
    List<String>? mentions,
  }) async {
    final messageId = _uuid.v4();
    final msg = BitchatMessage(
      id: messageId,
      sender: _nicknameProvider(),
      content: content,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      senderPeerID: identity.peerID,
      channel: channel,
      mentions: mentions,
    );
    final packet = await _buildPacket(
      type: MeshMessageType.message,
      payload: msg.toBinaryPayload(),
      sign: true,
    );
    await _sendPacket(packet);
    return messageId;
  }

  /// Sends a private [content] message to [peerID], performing a Noise handshake
  /// first if needed (the message is queued and flushed on establishment).
  /// Long content is chunked into 255-byte private-message packets. Returns the
  /// message id of the first chunk.
  Future<String> sendPrivateMessage(String peerID, String content) async {
    final chunks = _chunkContent(content);
    String? firstId;
    for (final chunk in chunks) {
      final messageId = _uuid.v4();
      firstId ??= messageId;
      final pm = PrivateMessagePacket(messageID: messageId, content: chunk);
      final encoded = pm.encode();
      if (encoded == null) continue;
      final plaintext =
          NoisePayload(NoisePayloadType.privateMessage, encoded).encode();
      await _sendOrQueueEncrypted(peerID, plaintext);
    }
    return firstId ?? '';
  }

  /// Sends a read receipt for [messageId] to [peerID].
  Future<void> sendReadReceipt(String peerID, String messageId) async {
    await _sendOrQueueEncrypted(
        peerID, NoisePayload.readReceipt(messageId).encode());
  }

  void dispose() {
    _publicMessages.close();
    _privateMessages.close();
    _receipts.close();
    _peersChanged.close();
  }

  // ---- Inbound handling -----------------------------------------------------

  Future<void> _onFrame(MeshInboundFrame frame) async {
    final packet = BinaryProtocol.decode(frame.data);
    if (packet == null) return;
    await _processPacket(packet, frame.linkId, frame.rssi);
  }

  Future<void> _processPacket(
      BitchatPacket packet, String linkId, int rssi) async {
    final senderPeerID = _hex(packet.senderID);
    // Ignore our own echoes.
    if (senderPeerID == identity.peerID) return;

    // Deduplicate the controlled flood.
    final key = SeenPackets.keyFor(
      type: packet.type,
      senderID: packet.senderID,
      timestamp: packet.timestamp,
      payload: packet.payload,
    );
    if (!_seen.checkAndAdd(key)) return;

    final forUs = packet.recipientID == null ||
        packet.isBroadcast ||
        _hex(packet.recipientID!) == identity.peerID;

    switch (packet.type) {
      case MeshMessageType.announce:
        await _handleAnnounce(packet, senderPeerID, rssi);
        break;
      case MeshMessageType.message:
        _handlePublicMessage(packet, senderPeerID);
        break;
      case MeshMessageType.leave:
        _removePeer(senderPeerID);
        break;
      case MeshMessageType.noiseHandshake:
        if (forUs) await _handleHandshake(senderPeerID, packet.payload);
        break;
      case MeshMessageType.noiseEncrypted:
        if (forUs) await _handleEncrypted(senderPeerID, packet.payload);
        break;
      case MeshMessageType.fragment:
        await _handleFragment(packet, linkId, rssi);
        break;
      default:
        break;
    }

    // Relay the controlled flood (never relay packets addressed solely to us,
    // and never relay a directed packet we just consumed as recipient).
    final directedToUs = packet.recipientID != null &&
        !packet.isBroadcast &&
        _hex(packet.recipientID!) == identity.peerID;
    if (!directedToUs && packet.ttl > 1 && packet.type != MeshMessageType.leave) {
      _scheduleRelay(packet);
    }
  }

  Future<void> _handleAnnounce(
      BitchatPacket packet, String senderPeerID, int rssi) async {
    final announcement = IdentityAnnouncement.decode(packet.payload);
    if (announcement == null) return;

    var verified = false;
    // The peerID must be the fingerprint of the announced Noise key…
    if (NoiseIdentity.matchesClaimedPeerID(
        senderPeerID, announcement.noisePublicKey)) {
      // …and, when the announcement is signed, the signature must check out.
      if (packet.signature != null) {
        final signable = packet.toBytesForSigning();
        verified = signable != null &&
            await NoiseIdentity.verify(
              signable,
              packet.signature!,
              announcement.signingPublicKey,
            );
      }
    }

    final peer = _peers.putIfAbsent(
        senderPeerID, () => MeshPeer(peerID: senderPeerID));
    peer.nickname = announcement.nickname;
    peer.noisePublicKey = announcement.noisePublicKey;
    peer.signingPublicKey = announcement.signingPublicKey;
    peer.isVerified = verified;
    peer.rssi = rssi;
    peer.touch();
    _emitPeers();
  }

  void _handlePublicMessage(BitchatPacket packet, String senderPeerID) {
    final msg = BitchatMessage.fromBinaryPayload(packet.payload);
    if (msg == null || msg.isEncrypted) return;
    _touchPeer(senderPeerID, nickname: msg.sender);
    _publicMessages.add(MeshPublicMessage(
      senderPeerID: msg.senderPeerID ?? senderPeerID,
      senderNickname: msg.sender,
      content: msg.content,
      messageId: msg.id,
      timestampMs: msg.timestampMs,
      channel: msg.channel,
      mentions: msg.mentions ?? const [],
      isRelay: msg.isRelay,
    ));
  }

  Future<void> _handleHandshake(String senderPeerID, Uint8List payload) async {
    try {
      final response = await _noise.handleHandshake(senderPeerID, payload);
      if (response != null) {
        await _sendPacket(await _buildPacket(
          type: MeshMessageType.noiseHandshake,
          payload: response,
          recipientID: _peerIdBytes(senderPeerID),
        ));
      }
      if (_noise.isEstablished(senderPeerID)) {
        await _flushPending(senderPeerID);
        await _drainPendingEncrypted(senderPeerID);
      }
    } catch (_) {
      // Handshake failed or peerID binding rejected; drop silently.
    }
  }

  Future<void> _handleEncrypted(String senderPeerID, Uint8List payload) async {
    if (!_noise.isEstablished(senderPeerID)) {
      // Session still handshaking — hold the frame and process it on establish
      // rather than dropping it (fixes the initiator-sends-immediately race).
      _pendingEncrypted.putIfAbsent(senderPeerID, () => []).add(payload);
      return;
    }
    Uint8List plaintext;
    try {
      plaintext = await _noise.decrypt(senderPeerID, payload);
    } catch (_) {
      return;
    }
    final noisePayload = NoisePayload.decode(plaintext);
    if (noisePayload == null) return;

    switch (noisePayload.type) {
      case NoisePayloadType.privateMessage:
        final pm = PrivateMessagePacket.decode(noisePayload.data);
        if (pm == null) return;
        _touchPeer(senderPeerID);
        _privateMessages.add(MeshPrivateMessage(
          senderPeerID: senderPeerID,
          messageId: pm.messageID,
          content: pm.content,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
        ));
        // Auto-acknowledge delivery.
        await _sendOrQueueEncrypted(
            senderPeerID, NoisePayload.delivered(pm.messageID).encode());
        break;
      case NoisePayloadType.delivered:
        _receipts.add(MeshReceipt(
          fromPeerID: senderPeerID,
          messageId: noisePayload.receiptMessageId(),
          isRead: false,
        ));
        break;
      case NoisePayloadType.readReceipt:
        _receipts.add(MeshReceipt(
          fromPeerID: senderPeerID,
          messageId: noisePayload.receiptMessageId(),
          isRead: true,
        ));
        break;
      default:
        break;
    }
  }

  Future<void> _handleFragment(
      BitchatPacket packet, String linkId, int rssi) async {
    final fragment = FragmentPayload.decode(packet.payload);
    if (fragment == null) return;
    final reassembled = _reassembler.accept(fragment);
    if (reassembled == null) return;
    final inner = BinaryProtocol.decode(reassembled);
    if (inner != null) {
      await _processPacket(inner, linkId, rssi);
    }
  }

  void _onLink(MeshLinkEvent event) {
    // A new direct link is a good moment to (re)announce so the peer learns us
    // immediately rather than waiting for the periodic beacon.
    if (event.change == MeshLinkChange.connected) {
      unawaited(_broadcastAnnounce());
    }
  }

  // ---- Outbound helpers -----------------------------------------------------

  Future<void> _sendOrQueueEncrypted(String peerID, Uint8List plaintext) async {
    if (_noise.isEstablished(peerID)) {
      final ciphertext = await _noise.encrypt(peerID, plaintext);
      await _sendPacket(await _buildPacket(
        type: MeshMessageType.noiseEncrypted,
        payload: ciphertext,
        recipientID: _peerIdBytes(peerID),
      ));
      return;
    }
    _pendingPlaintext.putIfAbsent(peerID, () => []).add(plaintext);
    if (!_noise.isHandshaking(peerID)) {
      final msg1 = await _noise.initiateHandshake(peerID);
      await _sendPacket(await _buildPacket(
        type: MeshMessageType.noiseHandshake,
        payload: msg1,
        recipientID: _peerIdBytes(peerID),
      ));
    }
  }

  /// Re-processes encrypted frames that arrived before the session existed.
  Future<void> _drainPendingEncrypted(String peerID) async {
    final queued = _pendingEncrypted.remove(peerID);
    if (queued == null) return;
    for (final payload in queued) {
      await _handleEncrypted(peerID, payload);
    }
  }

  Future<void> _flushPending(String peerID) async {
    final queued = _pendingPlaintext.remove(peerID);
    if (queued == null) return;
    for (final plaintext in queued) {
      try {
        final ciphertext = await _noise.encrypt(peerID, plaintext);
        await _sendPacket(await _buildPacket(
          type: MeshMessageType.noiseEncrypted,
          payload: ciphertext,
          recipientID: _peerIdBytes(peerID),
        ));
      } catch (_) {}
    }
  }

  Future<void> _broadcastAnnounce() async {
    if (!_running) return;
    final announcement = IdentityAnnouncement(
      nickname: _nicknameProvider(),
      noisePublicKey: identity.staticPublic,
      signingPublicKey: identity.signingPublic,
    );
    final payload = announcement.encode();
    if (payload == null) return;
    final packet = await _buildPacket(
      type: MeshMessageType.announce,
      payload: payload,
      sign: true,
    );
    await _sendPacket(packet);
  }

  /// Builds a packet from us with the standard TTL, optionally Ed25519-signed.
  Future<BitchatPacket> _buildPacket({
    required int type,
    required Uint8List payload,
    Uint8List? recipientID,
    bool sign = false,
  }) async {
    final packet = BitchatPacket(
      type: type,
      senderID: identity.peerIdBytes,
      recipientID: recipientID,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: payload,
      ttl: MeshConstants.messageTtl,
    );
    if (sign) {
      final signable = packet.toBytesForSigning();
      if (signable != null) {
        packet.signature = await identity.sign(signable);
      }
    }
    return packet;
  }

  /// Serializes, fragments if needed, and broadcasts a packet.
  Future<void> _sendPacket(BitchatPacket packet) async {
    final fragments = PacketFragmenter.fragment(packet);
    for (final f in fragments) {
      final bytes = f.toBytes();
      if (bytes != null) await _broadcast(bytes);
    }
  }

  Future<void> _broadcast(Uint8List? bytes) async {
    if (bytes == null) return;
    await _transport.broadcast(bytes);
  }

  void _scheduleRelay(BitchatPacket packet) {
    final relayed = packet.copyWith(ttl: packet.ttl - 1);
    final jitter = MeshConstants.relayJitterMinMs +
        _random.nextInt(
            MeshConstants.relayJitterMaxMs - MeshConstants.relayJitterMinMs);
    Timer(Duration(milliseconds: jitter), () {
      if (_running) unawaited(_sendPacket(relayed));
    });
  }

  // ---- Peer bookkeeping -----------------------------------------------------

  void _touchPeer(String peerID, {String? nickname}) {
    final peer =
        _peers.putIfAbsent(peerID, () => MeshPeer(peerID: peerID));
    if (nickname != null && nickname.isNotEmpty) peer.nickname = nickname;
    peer.touch();
    _emitPeers();
  }

  void _removePeer(String peerID) {
    if (_peers.remove(peerID) != null) {
      _noise.remove(peerID);
      _emitPeers();
    }
  }

  void _cleanupStalePeers() {
    final now = DateTime.now();
    final removed = <String>[];
    _peers.removeWhere((id, peer) {
      final stale = now.difference(peer.lastSeen) > MeshConstants.stalePeerTimeout;
      if (stale) removed.add(id);
      return stale;
    });
    for (final id in removed) {
      _noise.remove(id);
    }
    if (removed.isNotEmpty) _emitPeers();
  }

  void _emitPeers() {
    if (!_peersChanged.isClosed) _peersChanged.add(peers);
  }

  // ---- Utilities ------------------------------------------------------------

  List<String> _chunkContent(String content) {
    // Chunk on UTF-8 byte boundaries to respect the 255-byte PM content cap
    // while never splitting a multi-byte rune.
    final chunks = <String>[];
    final buffer = StringBuffer();
    var byteCount = 0;
    for (final rune in content.runes) {
      final ch = String.fromCharCode(rune);
      final len = ch.codeUnits.fold<int>(
          0, (n, u) => n + (u <= 0x7F ? 1 : (u <= 0x7FF ? 2 : 3)));
      if (byteCount + len > PrivateMessagePacket.maxContentBytes) {
        chunks.add(buffer.toString());
        buffer.clear();
        byteCount = 0;
      }
      buffer.write(ch);
      byteCount += len;
    }
    if (buffer.isNotEmpty || chunks.isEmpty) chunks.add(buffer.toString());
    return chunks;
  }

  Uint8List _peerIdBytes(String peerID) {
    final out = Uint8List(8);
    for (var i = 0; i < 8 && i * 2 + 1 < peerID.length; i++) {
      out[i] = int.parse(peerID.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
