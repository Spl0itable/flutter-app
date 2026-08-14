import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/crypto/schnorr.dart' show signId;
import '../../services/mesh/mesh_avatar_registry.dart';
import '../../services/mesh/mesh_events.dart';
import '../../services/mesh/mesh_peer.dart';
import '../../services/mesh/mesh_service.dart';
import '../../services/mesh/noise/noise_identity.dart';
import '../../services/mesh/noise/nostr_link.dart';
import '../../services/mesh/protocol/mesh_profile.dart';
import '../../services/mesh/transport/ble_mesh_transport.dart';
import '../../services/mesh/transport/mesh_transport.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
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

/// A mesh group channel the user has joined. [encrypted] is true for a
/// password-protected (AES-GCM) group; false for an open named channel.
class MeshChannel {
  const MeshChannel({required this.name, required this.encrypted});
  final String name;
  final bool encrypted;
}

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
    this.channels = const [],
    this.channelMessages = const {},
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

  /// Joined mesh group channels.
  final List<MeshChannel> channels;

  /// Messages per joined group channel (keyed by channel name).
  final Map<String, List<MeshPublicMessage>> channelMessages;

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
    List<MeshChannel>? channels,
    Map<String, List<MeshPublicMessage>>? channelMessages,
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
      channels: channels ?? this.channels,
      channelMessages: channelMessages ?? this.channelMessages,
      error: clearError ? null : (error ?? this.error),
    );
  }

  MeshPeer? peerById(String peerID) {
    for (final p in peers) {
      if (p.peerID == peerID) return p;
    }
    return null;
  }
}

/// Owns the [MeshService] lifecycle and bridges its events into an observable
/// [MeshUiState]. Reacts to the `meshEnabled` setting to power the radio on/off.
class MeshController extends StateNotifier<MeshUiState> {
  MeshController({
    required String Function() nickname,
    String? Function()? nostrPubkey,
    String? Function(String messageHex)? signSchnorr,
    String? Function(String pubkey)? avatarUrlOf,
    String? Function(String pubkey)? bannerUrlOf,
  })  : _nickname = nickname,
        _nostrPubkey = nostrPubkey,
        _signSchnorr = signSchnorr,
        _avatarUrlOf = avatarUrlOf,
        _bannerUrlOf = bannerUrlOf,
        super(const MeshUiState());

  final String Function() _nickname;
  final String? Function()? _nostrPubkey;
  final String? Function(String messageHex)? _signSchnorr;
  final String? Function(String pubkey)? _avatarUrlOf;
  final String? Function(String pubkey)? _bannerUrlOf;

  /// Our precomputed Nostr-identity link (stable per session), advertised in
  /// announcements. Null when there is no local Nostr key to sign it.
  Uint8List? _nostrLink;

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
      _nostrLink = _computeNostrLink(identity);
      final transport = BleMeshTransport(identity.peerID);
      final service = MeshService(
        identity: identity,
        transport: transport,
        nicknameProvider: _nickname,
        nostrLinkProvider: () => _nostrLink,
        profileProvider: _buildMyProfile,
      );
      _service = service;

      _subs.add(service.peersStream.listen((peers) {
        for (final p in peers) {
          final pubkey = p.nostrPubkey;
          if (pubkey != null) {
            p.avatarUrl ??= _avatarUrlOf?.call(pubkey);
            p.bannerUrl ??= _bannerUrlOf?.call(pubkey);
          }
          unawaited(_hydratePeerAvatar(service, p));
        }
        state = state.copyWith(
          peers: List.of(peers),
          linkCount: service.connectedLinkCount,
        );
      }));
      _subs.add(service.onPublicMessage.listen(_onPublic));
      _subs.add(service.onPrivateMessage.listen(_onPrivate));
      _subs.add(service.onReceipt.listen(_onReceipt));
      _subs.add(service.onProfile.listen(_onProfile));

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

  /// Builds our signed Nostr-identity link, or null when we have no local Nostr
  /// key (e.g. NIP-46 remote signer) to bind the mesh key with.
  Uint8List? _computeNostrLink(NoiseIdentity identity) {
    final pubkey = _nostrPubkey?.call();
    final signer = _signSchnorr;
    if (pubkey == null || pubkey.length != 64 || signer == null) return null;
    final sigHex = signer(NostrLink.messageHex(identity.staticPublic));
    if (sigHex == null || sigHex.isEmpty) return null;
    return NostrLink.build(pubkey, sigHex);
  }

  // ---- Mesh profile (avatar/banner) transfer --------------------------------

  static const int _maxAvatarBytes = 96 * 1024;
  static const int _maxBannerBytes = 384 * 1024;

  final Set<String> _profileAsked = {};

  /// Answers an inbound profile request with our own avatar/banner bytes,
  /// fetched (and size-capped) from our Nostr profile image URLs.
  Future<MeshProfile?> _buildMyProfile(MeshProfileRequest request) async {
    final pubkey = _nostrPubkey?.call();
    (Uint8List, String?)? avatar;
    (Uint8List, String?)? banner;
    if (request.wantAvatar && pubkey != null) {
      avatar = await _fetchCapped(_avatarUrlOf?.call(pubkey), _maxAvatarBytes);
    }
    if (request.wantBanner && pubkey != null) {
      banner = await _fetchCapped(_bannerUrlOf?.call(pubkey), _maxBannerBytes);
    }
    return MeshProfile(
      nickname: _nickname(),
      nostrPubkey: pubkey,
      avatar: avatar?.$1,
      avatarMime: avatar?.$2,
      banner: banner?.$1,
      bannerMime: banner?.$2,
    );
  }

  /// GETs [url] and returns its bytes + content-type, or null when missing,
  /// unreachable, or larger than [maxBytes] (we never ship oversized images).
  Future<(Uint8List, String?)?> _fetchCapped(String? url, int maxBytes) async {
    if (url == null || url.isEmpty) return null;
    try {
      final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200 || resp.bodyBytes.length > maxBytes) return null;
      return (resp.bodyBytes, resp.headers['content-type']);
    } catch (_) {
      return null;
    }
  }

  /// Caches a transferred avatar to disk, registers its bytes so it renders in
  /// canonical message rows, and points the peer at it.
  Future<void> _onProfile(MeshProfileReceived event) async {
    final profile = event.profile;
    final avatar = profile.avatar;
    if (avatar == null || avatar.isEmpty) return;
    _publishAvatar(event.peerID, avatar);
    try {
      final dir = Directory('${(await getApplicationDocumentsDirectory()).path}'
          '/mesh_avatars');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('${dir.path}/${event.peerID}.img');
      await file.writeAsBytes(avatar, flush: true);
      final peers = List.of(state.peers);
      for (final p in peers) {
        if (p.peerID == event.peerID) p.avatarFilePath = file.path;
      }
      state = state.copyWith(peers: peers);
    } catch (_) {
      // Non-fatal: the registry still holds the in-memory bytes.
    }
  }

  /// Registers avatar [bytes] under every seed a message row / avatar might use
  /// for this peer: its mesh peerID always, and its Nostr pubkey only when the
  /// pubkey↔mesh-key link is cryptographically verified (never for an
  /// unverified claim, to prevent avatar spoofing of a Nostr identity).
  void _publishAvatar(String peerID, Uint8List bytes) {
    final seeds = <String>[peerID];
    final peer = state.peerById(peerID);
    if (peer != null && peer.nostrLinkVerified && peer.nostrPubkey != null) {
      seeds.add(peer.nostrPubkey!);
    }
    MeshAvatarRegistry.instance.register(seeds, bytes);
  }

  /// On first sight of a peer, reload a previously-cached avatar from disk (so
  /// it survives restarts) or, if none, request one over the mesh.
  Future<void> _hydratePeerAvatar(MeshService service, MeshPeer peer) async {
    if (peer.avatarUrl != null ||
        peer.avatarFilePath != null ||
        _profileAsked.contains(peer.peerID)) {
      return;
    }
    _profileAsked.add(peer.peerID);
    try {
      final path = '${(await getApplicationDocumentsDirectory()).path}'
          '/mesh_avatars/${peer.peerID}.img';
      final file = File(path);
      if (file.existsSync()) {
        final bytes = await file.readAsBytes();
        _publishAvatar(peer.peerID, bytes);
        final peers = List.of(state.peers);
        for (final p in peers) {
          if (p.peerID == peer.peerID) p.avatarFilePath = path;
        }
        state = state.copyWith(peers: peers);
        return;
      }
    } catch (_) {
      // fall through to a fresh request
    }
    unawaited(service.requestProfile(peer.peerID));
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
    _profileAsked.clear();
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

  /// Joins/creates a mesh group [name]. A non-empty [password] makes it an
  /// encrypted group (only members with the same password can read it).
  Future<void> joinChannel(String name, {String password = ''}) async {
    final channel = name.startsWith('#') ? name : '#$name';
    if (password.isNotEmpty) {
      await _service?.setChannelPassword(channel, password);
    }
    if (state.channels.any((c) => c.name == channel)) return;
    final channels = [...state.channels,
      MeshChannel(name: channel, encrypted: password.isNotEmpty)];
    state = state.copyWith(channels: channels);
  }

  void leaveChannel(String name) {
    _service?.leaveChannel(name);
    final channels = state.channels.where((c) => c.name != name).toList();
    final msgs = Map<String, List<MeshPublicMessage>>.of(state.channelMessages)
      ..remove(name);
    state = state.copyWith(channels: channels, channelMessages: msgs);
  }

  Future<void> sendChannelMessage(String channel, String content) async {
    final service = _service;
    if (service == null || content.trim().isEmpty) return;
    await service.sendPublicMessage(content, channel: channel);
    _appendChannel(MeshPublicMessage(
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

  final Set<String> _readAcked = {};

  /// Sends read receipts for any inbound messages in [peerID]'s thread we
  /// haven't acked yet. Idempotent — safe to call on every open/rebuild.
  Future<void> markThreadRead(String peerID) async {
    final service = _service;
    if (service == null) return;
    final thread = state.threads[peerID];
    if (thread == null) return;
    for (final entry in thread) {
      if (entry.fromMe || _readAcked.contains(entry.messageId)) continue;
      _readAcked.add(entry.messageId);
      await service.sendReadReceipt(peerID, entry.messageId);
    }
  }

  /// Opens the OS settings page so the user can grant Bluetooth permission
  /// after denying it.
  Future<void> openSystemSettings() async => _service?.openSystemSettings();

  // ---- Event bridges --------------------------------------------------------

  void _onPublic(MeshPublicMessage msg) {
    // A message tagged with a group we've joined goes to that group's thread;
    // everything else is the open Nearby feed.
    final channel = msg.channel;
    if (channel != null && state.channels.any((c) => c.name == channel)) {
      _appendChannel(msg);
      return;
    }
    final nearby = List.of(state.nearby)..add(msg);
    if (nearby.length > 500) nearby.removeRange(0, nearby.length - 500);
    state = state.copyWith(nearby: nearby);
  }

  void _appendChannel(MeshPublicMessage msg) {
    final channel = msg.channel;
    if (channel == null) return;
    final map = Map<String, List<MeshPublicMessage>>.of(state.channelMessages);
    final list = List.of(map[channel] ?? const <MeshPublicMessage>[])..add(msg);
    if (list.length > 500) list.removeRange(0, list.length - 500);
    map[channel] = list;
    state = state.copyWith(channelMessages: map);
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
    nostrPubkey: () => ref.read(nostrControllerProvider).identity?.pubkey,
    // Sign the mesh↔Nostr binding with the local key, when there is one. NIP-46
    // remote signers have no local privkey → returns null → no link advertised.
    signSchnorr: (messageHex) {
      final priv = ref.read(nostrControllerProvider).identity?.privkey;
      return priv == null ? null : signId(messageHex, priv);
    },
    avatarUrlOf: (pubkey) =>
        ref.read(appStateProvider).users[pubkey]?.profile?.picture,
    bannerUrlOf: (pubkey) =>
        ref.read(appStateProvider).users[pubkey]?.profile?.banner,
  );
  ref.listen<bool>(
    settingsProvider.select((s) => s.meshEnabled),
    (_, next) => controller.setEnabled(next),
    fireImmediately: true,
  );
  ref.onDispose(controller.shutdown);
  return controller;
});
