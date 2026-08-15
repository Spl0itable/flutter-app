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

  // Mesh PMs are keyed by the peer's real 64-hex Noise static key (see
  // MeshBridge.pubkeyForPeer / MeshService.noiseKeyHexForPeer), which both the
  // inbound-message path and the open-DM path resolve from the SAME source, so
  // they always key the identical pm-<pubkey> thread. The padded-peerID
  // pseudo-pubkey is only a transient last resort before the Noise key is
  // known; it must never be the permanent identity (it renders as a #0000
  // suffix because the trailing zeros aren't real key bytes).
  group('meshPeerIdPseudoPubkey — transient fallback keying', () {
    test('is a stable, lowercase, 64-hex key derived only from the peerID', () {
      const peerId = 'A1B2C3D4E5F60718';
      final k = meshPeerIdPseudoPubkey(peerId);
      expect(k.length, 64);
      expect(k, equals(k.toLowerCase()));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(k), isTrue);
      // The real key bytes lead; the padding is trailing zeros.
      expect(k.startsWith('a1b2c3d4e5f60718'), isTrue);
      // Same peerID → same key on every call.
      expect(meshPeerIdPseudoPubkey(peerId), equals(k));
      // Case-insensitive on the peerID (senderID hex casing must not fork it).
      expect(meshPeerIdPseudoPubkey(peerId.toLowerCase()), equals(k));
    });

    test('distinct peers get distinct keys', () {
      expect(meshPeerIdPseudoPubkey('1111111111111111'),
          isNot(equals(meshPeerIdPseudoPubkey('2222222222222222'))));
    });
  });
}
