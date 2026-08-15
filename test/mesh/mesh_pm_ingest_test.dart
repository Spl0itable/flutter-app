import 'package:flutter_test/flutter_test.dart';
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
}
