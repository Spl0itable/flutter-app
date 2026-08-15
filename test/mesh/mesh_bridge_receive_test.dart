import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nym_bar/core/crypto/keys.dart' show randomBytes;
import 'package:nym_bar/features/mesh/mesh_bridge.dart';
import 'package:nym_bar/services/mesh/mesh_service.dart';
import 'package:nym_bar/services/mesh/noise/noise_identity.dart';
import 'package:nym_bar/services/mesh/transport/mesh_transport.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/settings_provider.dart';

/// In-memory radio bus (a trimmed copy of the one in mesh_service_test) so two
/// real MeshServices can exchange frames without hardware.
class RadioBus {
  final List<FakeMeshTransport> _nodes = [];
  final Set<FakeMeshTransport> _started = {};
  void attach(FakeMeshTransport node) => _nodes.add(node);

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

  void _deliver(Uint8List frame, String fromId) =>
      _inbound.add(MeshInboundFrame(data: frame, linkId: fromId));
  void _link(String peerId) =>
      _links.add(MeshLinkEvent(peerId, MeshLinkChange.connected));

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

/// Builds the MeshBridge inside the container so it gets a real Ref.
final _bridgeServiceProvider = Provider<MeshService>((ref) => throw UnimplementedError());
final _bridgeProvider = Provider<MeshBridge>((ref) => MeshBridge(
      ref: ref,
      service: ref.read(_bridgeServiceProvider),
      selfNym: () => 'bob',
    ));

Future<bool> _waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 3)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return cond();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The PM notification path plays a sound / posts a local notification, whose
  // plugins have no implementation under `flutter test`. Swallow those platform
  // channel calls so the async fire-and-forget doesn't error after a test ends.
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final name in const [
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
    'dexterous.com/flutter/local_notifications',
    'flutter.baseflow.com/permissions/methods',
  ]) {
    messenger.setMockMethodCallHandler(MethodChannel(name), (call) async => null);
  }

  test('an inbound #mesh message from a peer lands in the #mesh channel view',
      () async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{'flutter.nym_notifications_enabled': 'false'});
    final kv = await KeyValueStore.open();
    final bus = RadioBus();
    final aliceId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));
    final bobId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));

    final alice = MeshService(
      identity: aliceId,
      transport: FakeMeshTransport(bus, 'alice'),
      nicknameProvider: () => 'alice',
    );
    final bobService = MeshService(
      identity: bobId,
      transport: FakeMeshTransport(bus, 'bob'),
      nicknameProvider: () => 'bob',
    );

    final container = ProviderContainer(overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      _bridgeServiceProvider.overrideWithValue(bobService),
    ]);
    addTearDown(container.dispose);

    final app = container.read(appStateProvider.notifier);
    app.goLive(bobId.fingerprint.padRight(64, '0').substring(0, 64), 'bob#0000');

    final bridge = container.read(_bridgeProvider);
    bridge.start();

    await alice.start();
    await bobService.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await alice.sendPublicMessage('gm from alice');

    final landed = await _waitFor(() =>
        (container.read(appStateProvider).messages['#mesh'] ?? const [])
            .any((m) => m.content == 'gm from alice'));

    expect(landed, isTrue,
        reason: 'the #mesh channel store must contain the received message');

    // Open the #mesh channel the way the UI does, and read the EXACT provider
    // the message list widget watches.
    app.switchView(const ChatView.channel('mesh'));
    final shown = container.read(messagesForCurrentViewProvider);
    expect(shown.map((e) => e.content), contains('gm from alice'),
        reason:
            'the received #mesh message must render via messagesForCurrentViewProvider');

    // Let any in-flight delivery-ack / receipt async settle before teardown so
    // it can't complete against a disposed container and cross-fail a sibling.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await bridge.dispose();
    await alice.stop();
    await bobService.stop();
  });

  test('an inbound mesh PM from a peer lands in its pm-<pubkey> view', () async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{'flutter.nym_notifications_enabled': 'false'});
    final kv = await KeyValueStore.open();
    final bus = RadioBus();
    final aliceId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));
    final bobId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));

    final alice = MeshService(
      identity: aliceId,
      transport: FakeMeshTransport(bus, 'alice'),
      nicknameProvider: () => 'alice',
    );
    final bobService = MeshService(
      identity: bobId,
      transport: FakeMeshTransport(bus, 'bob'),
      nicknameProvider: () => 'bob',
    );

    final container = ProviderContainer(overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      _bridgeServiceProvider.overrideWithValue(bobService),
    ]);
    addTearDown(container.dispose);

    final app = container.read(appStateProvider.notifier);
    app.goLive(bobId.fingerprint.padRight(64, '0').substring(0, 64), 'bob#0000');

    final bridge = container.read(_bridgeProvider);
    bridge.start();

    await alice.start();
    await bobService.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await alice.sendPrivateMessage(bobService.myPeerID, 'secret from alice');

    // alice's real Noise-key hex is the conversation pubkey both sides resolve.
    String hex(Uint8List b) =>
        b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    final pmKey = 'pm-${hex(aliceId.staticPublic)}';

    final landed = await _waitFor(() =>
        (container.read(appStateProvider).messages[pmKey] ?? const [])
            .any((m) => m.content == 'secret from alice'));

    expect(landed, isTrue,
        reason: 'the mesh PM must be stored under pm-<alice-noise-key>');

    // Open the DM the way openPeerDm → switchView does, and read the EXACT
    // provider the message list widget watches.
    app.switchView(ChatView.pm(hex(aliceId.staticPublic)));
    final shown = container.read(messagesForCurrentViewProvider);
    expect(shown.map((e) => e.content), contains('secret from alice'),
        reason:
            'the received mesh PM must render via messagesForCurrentViewProvider');

    // Let any in-flight delivery-ack / receipt async settle before teardown so
    // it can't complete against a disposed container and cross-fail a sibling.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await bridge.dispose();
    await alice.stop();
    await bobService.stop();
  });

  test('a PM arriving before the sender announce still keys the real Noise key',
      () async {
    // Reproduces the runtime "notification but not chat" + #0000 bug: when a
    // PM decrypts before the sender's announce is processed, the peer record
    // has no noisePublicKey yet. The bridge must still key the thread by the
    // real Noise static key (from the live session), NOT the padded pseudo —
    // otherwise the notification opens pm-<pseudo> while the later open-DM
    // opens pm-<realkey>, and the message is invisible.
    SharedPreferences.setMockInitialValues(
        <String, Object>{'flutter.nym_notifications_enabled': 'false'});
    final kv = await KeyValueStore.open();
    final bus = RadioBus();
    final aliceId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));
    final bobId = await NoiseIdentity.fromSeeds(
        staticPrivate: randomBytes(32), signingSeed: randomBytes(32));

    final alice = MeshService(
      identity: aliceId,
      transport: FakeMeshTransport(bus, 'alice'),
      nicknameProvider: () => 'alice',
    );
    final bobService = MeshService(
      identity: bobId,
      transport: FakeMeshTransport(bus, 'bob'),
      nicknameProvider: () => 'bob',
    );

    final container = ProviderContainer(overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      _bridgeServiceProvider.overrideWithValue(bobService),
    ]);
    addTearDown(container.dispose);

    final app = container.read(appStateProvider.notifier);
    app.goLive(bobId.fingerprint.padRight(64, '0').substring(0, 64), 'bob#0000');
    final bridge = container.read(_bridgeProvider);
    bridge.start();

    await alice.start();
    await bobService.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Force the pre-announce condition: the peer record exists (from the
    // connection) but has NOT captured alice's announced Noise key yet, so the
    // ONLY surviving identity source is the established Noise session.
    bobService.peerById(alice.myPeerID)!.noisePublicKey = null;

    await alice.sendPrivateMessage(bobService.myPeerID, 'early bird');

    String hex(Uint8List b) =>
        b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    final realKey = 'pm-${hex(aliceId.staticPublic)}';
    final pseudoKey =
        'pm-${alice.myPeerID.toLowerCase().padRight(64, '0').substring(0, 64)}';

    final landed = await _waitFor(() =>
        (container.read(appStateProvider).messages[realKey] ?? const [])
            .any((m) => m.content == 'early bird'));

    expect(landed, isTrue,
        reason: 'PM must key the REAL Noise-key thread even pre-announce');
    expect(container.read(appStateProvider).messages[pseudoKey], isNull,
        reason: 'must NOT land in a pm-<pseudo> (#0000) thread');

    // Let any in-flight delivery-ack / receipt async settle before teardown so
    // it can't complete against a disposed container and cross-fail a sibling.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await bridge.dispose();
    await alice.stop();
    await bobService.stop();
  });
}
