import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/mesh/mesh_events.dart';
import '../../services/mesh/mesh_peer.dart';
import '../../services/mesh/mesh_service.dart';
import '../../services/mesh/noise/noise_identity.dart';
import '../../services/mesh/transport/ble_mesh_transport.dart';
import '../../services/mesh/transport/mesh_transport.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';

/// A single message in a mesh private conversation, including our own sent
/// messages and their delivery state.
class MeshPrivateEntry {
  MeshPrivateEntry({
    required this.messageId,
    required this.content,
    required this.fromMe,
    required this.timestampMs,
    this.status = MeshDeliveryStatus.sending,
  });

  final String messageId;
  final String content;
  final bool fromMe;
  final int timestampMs;
  MeshDeliveryStatus status;
}

enum MeshDeliveryStatus { sending, delivered, read }

/// Immutable UI snapshot of the mesh for widgets to render.
@immutable
class MeshUiState {
  const MeshUiState({
    this.enabled = false,
    this.running = false,
    this.availability = MeshTransportAvailability.unknown,
    this.myPeerID,
    this.linkCount = 0,
    this.peers = const [],
    this.nearby = const [],
    this.threads = const {},
    this.error,
  });

  final bool enabled;
  final bool running;
  final MeshTransportAvailability availability;
  final String? myPeerID;
  final int linkCount;
  final List<MeshPeer> peers;
  final List<MeshPublicMessage> nearby;
  final Map<String, List<MeshPrivateEntry>> threads;
  final String? error;

  MeshUiState copyWith({
    bool? enabled,
    bool? running,
    MeshTransportAvailability? availability,
    String? myPeerID,
    int? linkCount,
    List<MeshPeer>? peers,
    List<MeshPublicMessage>? nearby,
    Map<String, List<MeshPrivateEntry>>? threads,
    String? error,
    bool clearError = false,
  }) {
    return MeshUiState(
      enabled: enabled ?? this.enabled,
      running: running ?? this.running,
      availability: availability ?? this.availability,
      myPeerID: myPeerID ?? this.myPeerID,
      linkCount: linkCount ?? this.linkCount,
      peers: peers ?? this.peers,
      nearby: nearby ?? this.nearby,
      threads: threads ?? this.threads,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Owns the [MeshService] lifecycle and bridges its events into an observable
/// [MeshUiState]. Reacts to the `meshEnabled` setting to power the radio on/off.
class MeshController extends StateNotifier<MeshUiState> {
  MeshController({required String Function() nickname})
      : _nickname = nickname,
        super(const MeshUiState());

  final String Function() _nickname;

  MeshService? _service;
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _busy = false;

  /// Mesh runs only where BLE central+peripheral are available.
  static bool get isSupportedPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> setEnabled(bool enabled) async {
    if (enabled == state.enabled && (!enabled || _service != null)) return;
    state = state.copyWith(enabled: enabled, clearError: true);
    if (enabled) {
      await _start();
    } else {
      await _stop();
    }
  }

  Future<void> _start() async {
    if (_busy || _service != null) return;
    _busy = true;
    try {
      if (!isSupportedPlatform) {
        state = state.copyWith(
          availability: MeshTransportAvailability.unsupported,
          running: false,
        );
        return;
      }
      final identity = await NoiseIdentity.loadOrCreate();
      final transport = BleMeshTransport(identity.peerID);
      final service = MeshService(
        identity: identity,
        transport: transport,
        nicknameProvider: _nickname,
      );
      _service = service;

      _subs.add(service.peersStream.listen((peers) {
        state = state.copyWith(
          peers: List.of(peers),
          linkCount: service.connectedLinkCount,
        );
      }));
      _subs.add(service.onPublicMessage.listen(_onPublic));
      _subs.add(service.onPrivateMessage.listen(_onPrivate));
      _subs.add(service.onReceipt.listen(_onReceipt));

      final availability = await service.start();
      state = state.copyWith(
        running: true,
        availability: availability,
        myPeerID: service.myPeerID,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(error: '$e', running: false);
      await _teardown();
    } finally {
      _busy = false;
    }
  }

  Future<void> _stop() async {
    if (_busy) return;
    _busy = true;
    try {
      await _teardown();
      state = state.copyWith(running: false, linkCount: 0, peers: const []);
    } finally {
      _busy = false;
    }
  }

  Future<void> _teardown() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final service = _service;
    _service = null;
    if (service != null) {
      await service.stop();
      service.dispose();
    }
  }

  // ---- Sending --------------------------------------------------------------

  Future<void> sendNearby(String content, {String? channel}) async {
    final service = _service;
    if (service == null || content.trim().isEmpty) return;
    await service.sendPublicMessage(content, channel: channel);
    // Echo our own message into the nearby feed.
    _onPublic(MeshPublicMessage(
      senderPeerID: service.myPeerID,
      senderNickname: _nickname(),
      content: content,
      messageId: 'self-${DateTime.now().microsecondsSinceEpoch}',
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      channel: channel,
    ));
  }

  Future<void> sendPrivate(String peerID, String content) async {
    final service = _service;
    if (service == null || content.trim().isEmpty) return;
    final messageId = await service.sendPrivateMessage(peerID, content);
    final entry = MeshPrivateEntry(
      messageId: messageId,
      content: content,
      fromMe: true,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );
    _appendThread(peerID, entry);
  }

  Future<void> markRead(String peerID, String messageId) async {
    await _service?.sendReadReceipt(peerID, messageId);
  }

  // ---- Event bridges --------------------------------------------------------

  void _onPublic(MeshPublicMessage msg) {
    final nearby = List.of(state.nearby)..add(msg);
    if (nearby.length > 500) nearby.removeRange(0, nearby.length - 500);
    state = state.copyWith(nearby: nearby);
  }

  void _onPrivate(MeshPrivateMessage msg) {
    _appendThread(
      msg.senderPeerID,
      MeshPrivateEntry(
        messageId: msg.messageId,
        content: msg.content,
        fromMe: false,
        timestampMs: msg.timestampMs,
      ),
    );
  }

  void _onReceipt(MeshReceipt receipt) {
    final thread = state.threads[receipt.fromPeerID];
    if (thread == null) return;
    final updated = List.of(thread);
    for (var i = 0; i < updated.length; i++) {
      if (updated[i].messageId == receipt.messageId && updated[i].fromMe) {
        updated[i].status =
            receipt.isRead ? MeshDeliveryStatus.read : MeshDeliveryStatus.delivered;
      }
    }
    final threads = Map<String, List<MeshPrivateEntry>>.of(state.threads);
    threads[receipt.fromPeerID] = updated;
    state = state.copyWith(threads: threads);
  }

  void _appendThread(String peerID, MeshPrivateEntry entry) {
    final threads = Map<String, List<MeshPrivateEntry>>.of(state.threads);
    final list = List.of(threads[peerID] ?? const <MeshPrivateEntry>[])..add(entry);
    threads[peerID] = list;
    state = state.copyWith(threads: threads);
  }

  Future<void> shutdown() async => _teardown();
}

/// The mesh controller, reacting to the `meshEnabled` setting.
final meshControllerProvider =
    StateNotifierProvider<MeshController, MeshUiState>((ref) {
  final controller = MeshController(
    nickname: () {
      final nym = ref.read(appStateProvider).selfNym;
      return nym.isNotEmpty ? nym : 'nym';
    },
  );
  ref.listen<bool>(
    settingsProvider.select((s) => s.meshEnabled),
    (_, next) => controller.setEnabled(next),
    fireImmediately: true,
  );
  ref.onDispose(controller.shutdown);
  return controller;
});
