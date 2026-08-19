import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/keys.dart';
import '../../services/mesh/noise/noise_identity.dart';
import '../../state/nostr_controller.dart';
import 'mesh_controller.dart';

/// One Ghost Mode epoch: the throwaway identity advertised on the mesh for a
/// single rotation window.
///
/// Every identifier a mesh announce carries is regenerated together — the Noise
/// static key (which the peerID and fingerprint derive from), the Ed25519
/// signing key, the nickname, and the Nostr key the `nostrLink` is built from.
/// Rotating only the peerID would be pointless: a tracker would just follow the
/// nostrLink or the nickname instead.
class GhostEpoch {
  GhostEpoch({
    required this.meshIdentity,
    required this.privkey,
    required this.pubkey,
    required this.nickname,
    required this.startedAt,
  });

  final NoiseIdentity meshIdentity;
  final Uint8List privkey;
  final String pubkey;
  final String nickname;
  final DateTime startedAt;
}

class GhostState {
  const GhostState({this.enabled = false, this.epochs = const []});

  final bool enabled;

  /// Newest first. Older epochs are retained so gift wraps addressed to a
  /// pubkey we have already rotated away from still decrypt.
  final List<GhostEpoch> epochs;

  GhostEpoch? get current => epochs.isEmpty ? null : epochs.first;

  /// Every pubkey this session has presented, for the gift-wrap `#p` filter.
  List<String> get pubkeys => [for (final e in epochs) e.pubkey];

  /// Every secret key this session has held, for unwrap candidates.
  List<Uint8List> get secretKeys => [for (final e in epochs) e.privkey];

  GhostState copyWith({bool? enabled, List<GhostEpoch>? epochs}) => GhostState(
        enabled: enabled ?? this.enabled,
        epochs: epochs ?? this.epochs,
      );
}

/// Ghost Mode: decouples this device's mesh presence from its real identity.
///
/// While active the mesh advertises a throwaway identity that is replaced on
/// [rotateEvery]. Messages still flow — peers can still reach the ghost
/// identity over Nostr, because the announce carries a real (ephemeral)
/// nostrLink — but nothing in the announce links back to the user's npub, and
/// nothing links one epoch to the next.
///
/// Retired epochs stay in [GhostState.epochs] up to [maxEpochs] so replies sent
/// to an older pubkey are still received and decrypted; nothing is persisted,
/// so the whole trail dies with the process.
class GhostModeController extends StateNotifier<GhostState> {
  GhostModeController({this.onRotate}) : super(const GhostState());

  /// How long one identity is presented before it is replaced.
  static const Duration rotateEvery = Duration(minutes: 15);

  /// How many retired epochs stay decryptable (~2h of reply window).
  static const int maxEpochs = 8;

  /// Invoked after the identity changes so the mesh can be restarted onto it
  /// and the Nostr subscriptions re-pointed.
  final Future<void> Function()? onRotate;

  Timer? _timer;
  final Random _random = Random.secure();

  Future<void> enable() async {
    if (state.enabled) return;
    state = state.copyWith(enabled: true);
    await _newEpoch();
    _arm();
  }

  Future<void> disable() async {
    _timer?.cancel();
    _timer = null;
    // Drop every key with the mode: the point is that it leaves no trail.
    state = const GhostState();
    await onRotate?.call();
  }

  /// Forces a rotation now (used by tests and by a manual "new identity" tap).
  Future<void> rotateNow() async {
    if (!state.enabled) return;
    await _newEpoch();
    _arm();
  }

  Future<void> _newEpoch() async {
    final priv = generatePrivateKey();
    final epoch = GhostEpoch(
      meshIdentity: await NoiseIdentity.ephemeral(),
      privkey: priv,
      pubkey: getPublicKeyHex(priv),
      nickname: _pseudonym(),
      startedAt: DateTime.now(),
    );
    final next = [epoch, ...state.epochs];
    if (next.length > maxEpochs) next.removeRange(maxEpochs, next.length);
    state = state.copyWith(epochs: next);
    await onRotate?.call();
  }

  /// A nickname that carries no information: `ghost#` plus four random hex.
  /// Deriving it from the pubkey would make the two linkable if either leaks.
  String _pseudonym() {
    const hex = '0123456789abcdef';
    final b = StringBuffer('ghost#');
    for (var i = 0; i < 4; i++) {
      b.write(hex[_random.nextInt(16)]);
    }
    return b.toString();
  }

  /// Jittered so a rotation cannot be recognised by its regular period.
  void _arm() {
    _timer?.cancel();
    final jitterMs = _random.nextInt(rotateEvery.inMilliseconds ~/ 4);
    _timer = Timer(rotateEvery + Duration(milliseconds: jitterMs), () async {
      if (!state.enabled) return;
      await _newEpoch();
      _arm();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// Explicitly typed: this provider and meshControllerProvider reference each
// other, so inference cannot resolve either without a written type.
final StateNotifierProvider<GhostModeController, GhostState> ghostModeProvider =
    StateNotifierProvider<GhostModeController, GhostState>((ref) {
  return GhostModeController(onRotate: () async {
    // Re-point the gift-wrap subscriptions at the new key BEFORE the mesh comes
    // back up, so a peer that reads the fresh announce can be answered.
    ref.read(nostrControllerProvider).refreshEphemeralSubscriptions();
    await ref.read(meshControllerProvider.notifier).restart();
  });
});
