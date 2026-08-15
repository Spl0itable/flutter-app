import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/mesh/mesh_bridge.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/state/app_state.dart';

/// Reproduces exactly how MeshBridge builds and ingests an inbound 1:1 mesh PM
/// (an unlinked peer, so the pubkey is a 64-hex Noise-key pseudo-pubkey), then
/// asserts it is visible in that PM view — the "PM shows in the notification
/// modal but not in the chat" bug.
void main() {
  test('an inbound mesh PM is visible in its pm-<pubkey> view', () {
    final n = AppStateNotifier()
      ..goLive(
          '0000000000000000000000000000000000000000000000000000000000000001',
          'me#0001');

    // A Noise-static-key pseudo-pubkey (not a real Nostr key) for an unlinked
    // mesh peer.
    final peer =
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
    final key = 'pm-$peer';

    final m = Message(
      id: 'mesh-msg-1',
      author: 'bob',
      pubkey: peer,
      content: 'hi over the mesh',
      createdAt: 1700000000,
      ms: 1700000000123,
      isOwn: false,
      isPM: true,
      conversationKey: key,
      conversationPubkey: peer,
      nymMessageId: 'mesh-msg-1',
      eventKind: 1059,
      senderVerified: true,
      deliveryStatus: DeliveryStatus.delivered,
      viaMesh: true,
    );
    n.ingestPMMessage(m);

    // Stored under the pm-<pubkey> key…
    expect(n.state.messages[key], isNotNull,
        reason: 'message must be stored under the pm-<pubkey> key');
    expect(n.state.messages[key]!.map((e) => e.content),
        contains('hi over the mesh'));

    // …and visible (not spam/WoT-filtered) when that PM view is active.
    final visible = visibleMessagesFor(n.state, key);
    expect(visible.map((e) => e.content), contains('hi over the mesh'),
        reason: 'inbound mesh PM must render in the chat, not be filtered out');

    // A conversation row must exist for the sidebar.
    expect(n.state.pmConversations.any((c) => c.pubkey == peer), isTrue);
  });

  // The root cause of "PM shows in the notification modal but not in the chat"
  // was that the inbound-message path and the open-DM path resolved a peer to
  // DIFFERENT conversation pubkeys (one via the Noise key, one peerID-derived),
  // so they keyed two different pm-<pubkey> threads. Both paths now route
  // through meshPubkeyForPeerId, which is a pure, deterministic function of the
  // 16-hex peerID — guaranteeing they always agree.
  group('meshPubkeyForPeerId — deterministic PM keying', () {
    test('is a stable, lowercase, 64-hex key derived only from the peerID', () {
      const peerId = 'A1B2C3D4E5F60718';
      final k = meshPubkeyForPeerId(peerId);
      expect(k.length, 64);
      expect(k, equals(k.toLowerCase()));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(k), isTrue);
      // Same peerID → same key on every call (inbound == open-DM == notify).
      expect(meshPubkeyForPeerId(peerId), equals(k));
      // Case-insensitive on the peerID (senderID hex casing must not fork it).
      expect(meshPubkeyForPeerId(peerId.toLowerCase()), equals(k));
    });

    test('distinct peers get distinct keys', () {
      expect(meshPubkeyForPeerId('1111111111111111'),
          isNot(equals(meshPubkeyForPeerId('2222222222222222'))));
    });
  });
}
