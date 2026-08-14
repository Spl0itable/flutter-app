import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart' show randomBytes;
import 'package:nym_bar/services/mesh/mesh_service.dart';
import 'package:nym_bar/services/mesh/noise/noise_identity.dart';
import 'package:nym_bar/services/mesh/protocol/mesh_profile.dart';
import 'package:nym_bar/services/mesh/transport/mesh_transport.dart';

/// An in-memory radio bus: every [FakeMeshTransport] attached to it delivers its
/// broadcasts to all the others, standing in for BLE so the full mesh stack can
/// be exercised without hardware.
class RadioBus {
  final List<FakeMeshTransport> _nodes = [];
  final Set<FakeMeshTransport> _started = {};
  void attach(FakeMeshTransport node) => _nodes.add(node);

  /// Marks [node] started and raises a mutual "connected" link event with every
  /// other started node — exactly what BLE surfaces when two devices link, and
  /// what drives the re-announce that seeds identity on both sides.
  void markStarted(FakeMeshTransport node) {
    for (final other in _started) {
      if (other == node) continue;
      node._link(other.id);
      other._link(node.id);
    }
    _started.add(node);
  }

  void broadcastFrom(FakeMeshTransport sender, Uint8List frame) {
    for (final node in _nodes) {
      if (node == sender || !_started.contains(node)) continue;
      node._deliver(Uint8List.fromList(frame), sender.id);
    }
  }
}

class FakeMeshTransport implements MeshTransport {
  FakeMeshTransport(this.bus, this.id) {
    bus.attach(this);
  }
  final RadioBus bus;
  final String id;
  final _inbound = StreamController<MeshInboundFrame>.broadcast();
  final _links = StreamController<MeshLinkEvent>.broadcast();

  void _deliver(Uint8List frame, String fromId) {
    _inbound.add(MeshInboundFrame(data: frame, linkId: fromId));
  }

  void _link(String peerId) {
    _links.add(MeshLinkEvent(peerId, MeshLinkChange.connected));
  }

  @override
  MeshTransportAvailability get availability => MeshTransportAvailability.ready;
  @override
  int get connectedLinkCount => bus._nodes.length - 1;
  @override
  Stream<MeshInboundFrame> get inbound => _inbound.stream;
  @override
  Stream<MeshLinkEvent> get links => _links.stream;
  @override
  Future<void> broadcast(Uint8List frame) async => bus.broadcastFrom(this, frame);
  @override
  Future<MeshTransportAvailability> start() async {
    bus.markStarted(this);
    return MeshTransportAvailability.ready;
  }
  @override
  Future<void> stop() async {}
  @override
  Future<void> openSystemSettings() async {}
}

Future<T> _firstEvent<T>(Stream<T> stream,
    {Duration timeout = const Duration(seconds: 5)}) {
  return stream.first.timeout(timeout);
}

void main() {
  late RadioBus bus;
  late MeshService alice;
  late MeshService bob;

  setUp(() async {
    bus = RadioBus();
    final aliceId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));
    final bobId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));
    alice = MeshService(
      identity: aliceId,
      transport: FakeMeshTransport(bus, 'alice'),
      nicknameProvider: () => 'alice',
    );
    bob = MeshService(
      identity: bobId,
      transport: FakeMeshTransport(bus, 'bob'),
      nicknameProvider: () => 'bob',
      profileProvider: (request) async => MeshProfile(
        nickname: 'bob',
        avatar: request.wantAvatar
            ? Uint8List.fromList(List.generate(3000, (i) => i & 0xFF))
            : null,
        avatarMime: 'image/webp',
      ),
    );
  });

  tearDown(() async {
    await alice.stop();
    await bob.stop();
    alice.dispose();
    bob.dispose();
  });

  test('peers discover each other via signed announcements', () async {
    final bobSeesAlice = _firstEvent(bob.peersStream);
    await alice.start();
    await bob.start();
    final peers = await bobSeesAlice;
    final alicePeer = peers.firstWhere((p) => p.peerID == alice.myPeerID);
    expect(alicePeer.nickname, 'alice');
    expect(alicePeer.isVerified, isTrue,
        reason: 'signed announcement with matching peerID must verify');
  });

  test('public broadcast message is delivered', () async {
    await alice.start();
    await bob.start();
    final received = _firstEvent(bob.onPublicMessage);
    await alice.sendPublicMessage('gm mesh', channel: '#bitchat');
    final msg = await received;
    expect(msg.content, 'gm mesh');
    expect(msg.channel, '#bitchat');
    expect(msg.senderPeerID, alice.myPeerID);
  });

  test('private message completes a Noise handshake and delivers + acks',
      () async {
    await alice.start();
    await bob.start();
    // Let announcements propagate so peers are known.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final bobReceives = _firstEvent(bob.onPrivateMessage);
    final aliceGetsAck = _firstEvent(alice.onReceipt);

    final messageId = await alice.sendPrivateMessage(bob.myPeerID, 'secret hi');

    final pm = await bobReceives;
    expect(pm.content, 'secret hi');
    expect(pm.messageId, messageId);
    expect(pm.senderPeerID, alice.myPeerID);

    // Bob auto-sends a delivery ack back to Alice over the same session.
    final ack = await aliceGetsAck;
    expect(ack.messageId, messageId);
    expect(ack.isRead, isFalse);
  });

  test('long private message is chunked and fully reassembled in order',
      () async {
    await alice.start();
    await bob.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // 600 bytes forces 3 chunks (255-byte PM content cap).
    final long = List.generate(600, (i) => String.fromCharCode(97 + i % 26))
        .join();

    final chunks = <String>[];
    final done = Completer<void>();
    final sub = bob.onPrivateMessage.listen((m) {
      chunks.add(m.content);
      if (chunks.join().length >= long.length) done.complete();
    });

    await alice.sendPrivateMessage(bob.myPeerID, long);
    await done.future.timeout(const Duration(seconds: 5));
    await sub.cancel();
    expect(chunks.join(), long);
  });

  test('encrypted group message is readable only by members with the password',
      () async {
    await alice.start();
    await bob.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await alice.setChannelPassword('#crew', 'sharedpass');
    await bob.setChannelPassword('#crew', 'sharedpass');

    final bobGets = _firstEvent(bob.onPublicMessage);
    await alice.sendPublicMessage('meet at 8', channel: '#crew');

    final msg = await bobGets;
    expect(msg.channel, '#crew');
    expect(msg.content, 'meet at 8'); // decrypted with the shared key
    expect(msg.senderPeerID, alice.myPeerID);
  });

  test('encrypted group message is dropped by a non-member', () async {
    await alice.start();
    await bob.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Only alice has the key; bob never joins the channel.
    await alice.setChannelPassword('#secret', 'pw');
    var received = false;
    final sub = bob.onPublicMessage.listen((_) => received = true);
    await alice.sendPublicMessage('classified', channel: '#secret');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sub.cancel();
    expect(received, isFalse); // undecryptable → not surfaced
  });

  test('a file/media DM transfers encrypted and fragmented to the peer',
      () async {
    await alice.start();
    await bob.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final bobGetsFile = _firstEvent(bob.onFile);
    final bytes =
        Uint8List.fromList(List.generate(5000, (i) => (i * 3) & 0xFF));
    await alice.sendFileToPeer(bob.myPeerID, 'photo.webp', 'image/webp', bytes);

    final file = await bobGetsFile;
    expect(file.fromPeerID, alice.myPeerID);
    expect(file.fileName, 'photo.webp');
    expect(file.mimeType, 'image/webp');
    expect(file.isImage, isTrue);
    expect(file.bytes, equals(bytes)); // encrypted + fragmented, then rejoined
  });

  test('a broadcast file is delivered to nearby peers as a public attachment',
      () async {
    await alice.start();
    await bob.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final bobGetsFile = _firstEvent(bob.onFile);
    final bytes =
        Uint8List.fromList(List.generate(4096, (i) => (i * 7) & 0xFF));
    await alice.sendFileBroadcast('meme.gif', 'image/gif', bytes);

    final file = await bobGetsFile;
    expect(file.fromPeerID, alice.myPeerID);
    expect(file.fileName, 'meme.gif');
    expect(file.mimeType, 'image/gif');
    expect(file.isDirect, isFalse); // public/broadcast, not a DM
    expect(file.bytes, equals(bytes));
  });

  test('profile request transfers a fragmented avatar back to the requester',
      () async {
    await alice.start();
    await bob.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final received = _firstEvent(alice.onProfile);
    await alice.requestProfile(bob.myPeerID);

    final event = await received;
    expect(event.peerID, bob.myPeerID);
    expect(event.profile.nickname, 'bob');
    // 3000-byte avatar exceeds the 512-byte fragment threshold, so this also
    // proves fragmentation + reassembly end to end.
    expect(event.profile.avatar, isNotNull);
    expect(event.profile.avatar!.length, 3000);
    expect(event.profile.avatarMime, 'image/webp');
  });
}
