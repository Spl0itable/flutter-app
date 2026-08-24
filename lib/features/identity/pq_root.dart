/// Custody of the post-quantum root secret: display form, the wraps that move
/// it between devices, the settings record they live in, and the §6 adoption
/// decision. Deriving keys FROM the root is in `lib/core/crypto/pq.dart`.
///
/// Spec: docs/PQ-ROOT-SPEC.md §1, §5, §6.
library;

import 'dart:convert';
import 'dart:typed_data';


import '../../core/crypto/bech32_codec.dart';
import '../../core/crypto/pq.dart' as pq;

/// The settings category the wraps live in. The ONE category that may never be
/// sealed to the root-derived key — spec §5.1, it would be a circular lock.
const String pqRootCategory = 'nymchat-pq-root';

/// Wrap salt: 16 random bytes, stored in the clear beside the wrap.
const int pqRootSaltLength = 16;

// Only the manual code path is implemented on mobile; a passkey wrap needs
// platform PRF APIs. Records carrying one are parsed and ignored.
const String pqRootWrapPasskey = 'passkey';

/// The root as its `nympq1…` display / clipboard / QR form (spec §1). Key
/// material: treat it exactly as the nsec is treated.
String pqRootToCode(Uint8List root) => encodeNymPq(root);

/// Parses a pasted `nympq1…` code, or null on a wrong HRP, bad checksum or
/// wrong length. Adopting a wrong root is worse than adopting none.
Uint8List? pqRootFromCode(String code) {
  try {
    final bytes = decodeNymPq(code);
    if (bytes.length != pq.pqRootLength) return null;
    return bytes;
  } catch (_) {
    return null;
  }
}

/// Whether [root] reproduces the identity's announced key at [epoch] or one of
/// the three before it. Verifies a pasted code against signed data.
bool pqRootMatchesAnnouncedKey(
  Uint8List root,
  Uint8List announcedKemPublicKey,
  int epoch,
) {
  for (var e = epoch; e >= 0 && e > epoch - 4; e--) {
    final pk = pq.pqKeypairFromRoot(root, e).publicKey;
    if (pk.length != announcedKemPublicKey.length) continue;
    var same = true;
    for (var i = 0; i < pk.length; i++) {
      if (pk[i] != announcedKemPublicKey[i]) {
        same = false;
        break;
      }
    }
    if (same) return true;
  }
  return false;
}

// -----------------------------------------------------------------------------
// Wrap format
// -----------------------------------------------------------------------------

/// One recovery path for the root: an AES-GCM-256 ciphertext plus its public
/// KDF parameters. [blob] reuses the identity vault's `enc:v1:` envelope.
class PqRootWrap {
  const PqRootWrap({
    required this.type,
    required this.blob,
    this.salt,
    this.iterations,
    this.extra = const {},
  });

  /// [pqRootWrapPasskey], or a future type.
  final String type;

  /// `enc:v1:<b64 iv>:<b64 ciphertext||tag>`.
  final String blob;

  /// Base64 of the 16 random KDF salt bytes. Public (spec §5).
  final String? salt;

  /// Explicit so a future raise stays readable by an older build.
  final int? iterations;

  /// Unknown fields, kept so a rewrite cannot drop another client's path.
  final Map<String, dynamic> extra;

  Map<String, dynamic> toJson() => {
        ...extra,
        'type': type,
        if (salt != null) 'salt': salt,
        if (iterations != null) 'iter': iterations,
        'blob': blob,
      };

  static PqRootWrap? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final type = raw['type'];
    final blob = raw['blob'];
    if (type is! String || type.isEmpty) return null;
    if (blob is! String || blob.isEmpty) return null;
    final extra = <String, dynamic>{
      for (final e in raw.entries)
        if (e.key != 'type' && e.key != 'salt' && e.key != 'iter' &&
            e.key != 'blob')
          e.key.toString(): e.value,
    };
    return PqRootWrap(
      type: type,
      blob: blob,
      salt: raw['salt'] is String ? raw['salt'] as String : null,
      iterations: raw['iter'] is int ? raw['iter'] as int : null,
      extra: extra,
    );
  }
}

/// The `nymchat-pq-root` payload. Its EXISTENCE is what stops a second device
/// generating a rival root (spec §6), so an empty [wraps] is still valid.
class PqRootRecord {
  const PqRootRecord({this.wraps = const [], this.version = 2});

  final List<PqRootWrap> wraps;
  final int version;

  bool get isEmpty => wraps.isEmpty;

  PqRootWrap? wrapOfType(String type) {
    for (final w in wraps) {
      if (w.type == type) return w;
    }
    return null;
  }

  /// Replaces any wrap of the same type, keeping every other path.
  PqRootRecord withWrap(PqRootWrap wrap) => PqRootRecord(
        version: version,
        wraps: [
          for (final w in wraps)
            if (w.type != wrap.type) w,
          wrap,
        ],
      );

  Map<String, dynamic> toJson() => {
        'v': version,
        'wraps': [for (final w in wraps) w.toJson()],
      };

  /// Null only when the payload is not a record at all — a record with no
  /// usable wraps still parses, since its existence is what matters.
  static PqRootRecord? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final rawWraps = raw['wraps'];
    if (rawWraps != null && rawWraps is! List) return null;
    if (raw['v'] == null && rawWraps == null) return null;
    final wraps = <PqRootWrap>[];
    if (rawWraps is List) {
      for (final w in rawWraps) {
        final parsed = PqRootWrap.fromJson(w);
        if (parsed != null) wraps.add(parsed);
      }
    }
    return PqRootRecord(
      wraps: wraps,
      version: raw['v'] is int ? raw['v'] as int : 2,
    );
  }

  String encode() => jsonEncode(toJson());

  static PqRootRecord? decode(String json) {
    try {
      return fromJson(jsonDecode(json));
    } catch (_) {
      return null;
    }
  }
}

// -----------------------------------------------------------------------------
// Generation and adoption (spec §6)
// -----------------------------------------------------------------------------

/// What a booting device should do about the root (spec §6).
enum PqRootAction {
  /// Nothing, and specifically NOT generate.
  wait,

  /// We hold the root and the record is in place.
  ready,

  /// We hold the root but no record exists — republish it.
  publishRecord,

  /// A record exists and nothing we hold opens it: stay silent (§7), prompt.
  awaitLink,

  /// No record exists: generate, publish, adopt, announce.
  generate,
}

/// The §6 decision. Pure and separate because the ORDER of these questions is
/// the whole safety property.
PqRootAction pqRootDecide({
  required bool durableIdentity,
  required bool hasLocalKey,
  required bool recordLoadSucceeded,
  required bool recordPresent,
  required bool holdRoot,
}) {
  // No local nsec means no hybrid at all; ephemeral has nothing to protect.
  if (!durableIdentity || !hasLocalKey) return PqRootAction.wait;
  // A read that did not complete proves nothing either way.
  if (!recordLoadSucceeded) return PqRootAction.wait;
  if (holdRoot) {
    return recordPresent ? PqRootAction.ready : PqRootAction.publishRecord;
  }
  // §6.3: a record we cannot open is still a record.
  if (recordPresent) return PqRootAction.awaitLink;
  return PqRootAction.generate;
}
