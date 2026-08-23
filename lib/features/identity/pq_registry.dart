/// Hybrid post-quantum key announcement, discovery, and policy, ported 1:1 from
/// the PWA's `js/modules/pq.js`.
///
/// The crypto lives in `lib/core/crypto/pq.dart`; this file decides WHO gets it.
///
/// ## Discovery
/// Each client publishes its ML-KEM-768 public key as a signed, replaceable
/// kind-30078 bundle (`['d','nym-pq'],['t','nym-pq']`), the same machinery the
/// `nym-vouches` web of trust already uses. Holding a peer's valid announcement
/// IS the negotiation: there is no in-band capability exchange, so there is no
/// downgrade surface. Peers without one — Bitchat users, other Nostr clients,
/// older Nymchat builds — keep receiving classical NIP-17 unchanged.
///
/// ## Why the key derives from the nsec
/// ML-KEM keygen is a pure function of a 64-byte seed, so deriving that seed
/// from the identity key means every device sharing an nsec derives the SAME
/// ML-KEM key. That is what makes one replaceable announcement per identity
/// correct — two devices can never fight over it — and there is no new secret
/// to back up.
///
/// ## Why it is opt-in
/// A post-quantum wrap is readable only by a build that has ML-KEM. Sending a
/// classical copy alongside would defeat the point entirely (an attacker just
/// breaks the classical copy), so enabling is necessarily all-or-nothing per
/// identity. An older device on the same nsec cannot be detected — it publishes
/// no announcement — so the switch is an explicit, informed choice. Fresh
/// installs default on; upgrades default off.
///
/// Socket-free and UI-free so the ingest, expiry and policy rules are
/// unit-testable in isolation (mirrors `trust_graph.dart`).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../core/crypto/ml_kem.dart';
import '../../core/crypto/pq.dart' as pq;

/// The `d`/`t` tag identifying a post-quantum key announcement.
const String pqDTag = 'nym-pq';

/// The only algorithm this version understands.
const String pqAlgorithm = 'mlkem768';

/// Announcements expire so a downgraded or abandoned device stops attracting
/// post-quantum messages it cannot read.
const Duration pqTtl = Duration(days: 7);

/// Republish cadence, comfortably inside [pqTtl].
const Duration pqRepublishInterval = Duration(hours: 24);

/// Devices unseen this long drop off the roster shown in settings.
const Duration pqDeviceStale = Duration(days: 30);

/// How many previous key epochs stay decryptable after a rotation.
const int pqPreviousEpochs = 3;

/// Whether this identity sends post-quantum and advertises itself as able to
/// receive it. Mirrors the PWA's `_pqMode`.
enum PqMode { on, off }

/// One device listed in our own announcement. Informational only — it never
/// gates decryption; it exists so the settings screen can say which devices
/// have actually been seen running a post-quantum-capable build.
class PqDevice {
  const PqDevice({required this.id, required this.version, required this.seenAt});

  final String id;
  final String version;
  final int seenAt;

  Map<String, dynamic> toJson() => {'id': id, 'ver': version, 'ts': seenAt};

  static PqDevice? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    return PqDevice(
      id: id,
      version: raw['ver'] is String ? raw['ver'] as String : '',
      seenAt: raw['ts'] is int ? raw['ts'] as int : 0,
    );
  }
}

/// A parsed kind-30078 `nym-pq` announcement.
class PqAnnouncement {
  const PqAnnouncement({
    required this.publicKey,
    required this.expiresAt,
    required this.epoch,
    this.devices = const [],
    this.retracted = false,
  });

  /// Null when [retracted].
  final Uint8List? publicKey;
  final int expiresAt;
  final int epoch;
  final List<PqDevice> devices;

  /// A replaceable event cannot be unpublished, so turning post-quantum off
  /// supersedes the announcement with a retracted, already-expired one.
  final bool retracted;

  /// Parses an announcement's `content`. Returns null for anything malformed,
  /// wrong-algorithm, or carrying a wrong-length key — a bad announcement must
  /// leave the peer classical rather than half-configured.
  ///
  /// Note this does NOT check the event signature: that happens upstream, and
  /// it is what binds the ML-KEM key to the Nostr identity. An attacker cannot
  /// substitute their own KEM key without also forging a secp256k1 signature.
  static PqAnnouncement? parse(String content) {
    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    if (decoded['alg'] != pqAlgorithm) return null;

    final exp = decoded['exp'];
    if (exp is! int) return null;

    if (decoded['retracted'] == true || decoded['pk'] == null) {
      return PqAnnouncement(
          publicKey: null, expiresAt: exp, epoch: 0, retracted: true);
    }

    final pkRaw = decoded['pk'];
    if (pkRaw is! String) return null;
    Uint8List pk;
    try {
      pk = pq.b64uDecode(pkRaw);
    } catch (_) {
      return null;
    }
    if (pk.length != mlKemPublicKeyLength) return null;

    final devices = <PqDevice>[];
    final rawDevices = decoded['devices'];
    if (rawDevices is List) {
      for (final d in rawDevices) {
        final parsed = PqDevice.fromJson(d);
        if (parsed != null) devices.add(parsed);
      }
    }

    return PqAnnouncement(
      publicKey: pk,
      expiresAt: exp,
      epoch: decoded['epoch'] is int ? decoded['epoch'] as int : 0,
      devices: devices,
    );
  }

  /// Builds the `content` payload for our own announcement.
  static String encode({
    required Uint8List publicKey,
    required int expiresAt,
    required int epoch,
    required List<PqDevice> devices,
  }) =>
      jsonEncode({
        'v': 1,
        'alg': pqAlgorithm,
        'epoch': epoch,
        'pk': pq.b64uEncode(publicKey),
        'exp': expiresAt,
        'devices': [for (final d in devices) d.toJson()],
      });

  /// The payload that retracts our announcement.
  static String encodeRetraction(int nowSec) => jsonEncode({
        'v': 1,
        'alg': pqAlgorithm,
        'retracted': true,
        'exp': nowSec,
      });
}

/// The pubkey -> announced ML-KEM key map, with expiry.
///
/// Holding an entry for a peer is exactly what makes them post-quantum capable,
/// so [keyFor] returning null is the signal to send classical NIP-17. Every
/// caller treats it that way, which is what makes a missing or expired
/// announcement degrade cleanly instead of failing a send.
class PqRegistry {
  PqRegistry({this.maxEntries = 5000});

  final int maxEntries;
  final Map<String, ({Uint8List pk, int exp, int epoch})> _keys = {};

  /// Ingests a peer's announcement. [content] is the event content; [pubkey]
  /// its (already signature-verified) author.
  void ingest(String pubkey, String content, {required int nowSec}) {
    final ann = PqAnnouncement.parse(content);
    if (ann == null) return;
    if (ann.retracted || ann.publicKey == null || ann.expiresAt <= nowSec) {
      _keys.remove(pubkey);
      return;
    }
    record(pubkey, ann.publicKey!, ann.expiresAt, ann.epoch);
  }

  /// Records a key. Also the path our own key takes, so self-addressed wraps
  /// resolve through the same lookup as everyone else's.
  ///
  /// The cap is enforced here rather than in [ingest] so every write goes
  /// through one bound (Dart's Map preserves insertion order, so the evicted
  /// entry is the earliest-recorded one).
  void record(String pubkey, Uint8List pk, int exp, int epoch) {
    _keys[pubkey] = (pk: pk, exp: exp, epoch: epoch);
    while (_keys.length > maxEntries) {
      _keys.remove(_keys.keys.first);
    }
  }

  void forget(String pubkey) => _keys.remove(pubkey);

  void clear() => _keys.clear();

  /// A peer's usable ML-KEM public key, or null when we have none, it expired,
  /// or post-quantum is off for this identity.
  Uint8List? keyFor(String pubkey, {required int nowSec, required bool enabled}) {
    if (!enabled) return null;
    final rec = _keys[pubkey];
    if (rec == null) return null;
    if (rec.exp <= nowSec) {
      _keys.remove(pubkey);
      return null;
    }
    return rec.pk;
  }

  /// Pubkeys we hold live keys for — used to size the group coverage readout
  /// and to decide whether a self-archive can be post-quantum.
  List<String> knownPeers({required int nowSec}) => [
        for (final e in _keys.entries)
          if (e.value.exp > nowSec) e.key
      ];
}

/// Policy: whether this identity is capable of, and configured for,
/// post-quantum messaging.
class PqPolicy {
  const PqPolicy._();

  /// Post-quantum requires sealing with our own secret key. Extension and
  /// NIP-46 signers hand back a finished NIP-44 payload rather than a
  /// conversation key, so there is no way to inject a hybrid one — those logins
  /// stay classical by construction, not by choice.
  static bool capable({required Uint8List? privkey}) => privkey != null;

  static bool enabled({required Uint8List? privkey, required PqMode mode}) =>
      capable(privkey: privkey) && mode == PqMode.on;

  /// The default mode on first boot of a post-quantum-capable build.
  ///
  /// A fresh install can turn it on safely because no older device can exist
  /// yet; an upgrade cannot, because one might. [seenBefore] is the PWA's
  /// `nym_last_online_ts` check — any prior version wrote it.
  static PqMode initialMode({required bool seenBefore}) =>
      seenBefore ? PqMode.off : PqMode.on;

  /// Merges [deviceId] into [previous], dropping entries not seen for
  /// [pqDeviceStale] and capping the list. Newest first.
  static List<PqDevice> mergeDeviceRoster(
    List<PqDevice> previous,
    String deviceId,
    String version, {
    required int nowSec,
    int max = 16,
  }) {
    final out = [
      for (final d in previous)
        if (d.id != deviceId && (nowSec - d.seenAt) < pqDeviceStale.inSeconds) d,
      PqDevice(id: deviceId, version: version, seenAt: nowSec),
    ];
    out.sort((a, b) => b.seenAt.compareTo(a.seenAt));
    return out.length > max ? out.sublist(0, max) : out;
  }
}

/// Our own ML-KEM keys for the current epoch plus a bounded window of previous
/// ones, so a wrap sent just before a rotation still opens. Ordered
/// newest-first, matching the PWA's `pqSelfCandidates`.
List<({Uint8List kemSk, Uint8List kemPk})> pqSelfCandidates(
    Uint8List privkey, int epoch) {
  final out = <({Uint8List kemSk, Uint8List kemPk})>[];
  for (var e = epoch; e >= 0 && e > epoch - 1 - pqPreviousEpochs; e--) {
    final kp = pq.pqKeypairFromPrivkey(privkey, e);
    out.add((kemSk: kp.secretKey, kemPk: kp.publicKey));
  }
  return out;
}
