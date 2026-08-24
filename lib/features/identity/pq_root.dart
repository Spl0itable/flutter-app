/// Custody of the post-quantum root secret: display form, the wraps that move
/// it between devices, the settings record they live in, and the §6 adoption
/// decision. Deriving keys FROM the root is in `lib/core/crypto/pq.dart`.
///
/// Spec: docs/PQ-ROOT-SPEC.md §1, §5, §6.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../core/crypto/bech32_codec.dart';
import '../../core/crypto/keys.dart';
import '../../core/crypto/pq.dart' as pq;

/// The settings category the wraps live in. The ONE category that may never be
/// sealed to the root-derived key — spec §5.1, it would be a circular lock.
const String pqRootCategory = 'nymchat-pq-root';

/// PBKDF2-HMAC-SHA256 iterations for the passphrase wrap (spec §5). Pinned.
const int pqRootPbkdf2Iterations = 310000;

/// Passphrase-wrap salt: 16 random bytes, stored in the clear beside the wrap.
const int pqRootSaltLength = 16;

/// Minimum passphrase length (spec §5.2).
const int pqRootMinPassphraseLength = 12;

/// Wrap-type discriminators inside a [PqRootRecord].
const String pqRootWrapPassphrase = 'passphrase';
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
// Passphrase policy (spec §5.2)
// -----------------------------------------------------------------------------

/// The long-but-guessable tail a length floor alone lets through (spec §5.2).
const List<String> pqRootCommonPassphrases = [
  'password',
  'password1',
  'password123',
  'passw0rd123',
  'passwordpassword',
  '123456789012',
  '1234567890123',
  '12345678901234',
  '123456789012345',
  '1234567890abc',
  'qwertyuiop123',
  'qwertyuiopasdf',
  'qwertyuiop[]\\',
  'letmein123456',
  'iloveyou12345',
  'administrator',
  'trustno1trustno1',
  'welcome123456',
  'monkeymonkey1',
  'football123456',
  'baseball123456',
  'dragondragon1',
  'sunshine12345',
  'princess12345',
  'superman12345',
  'michaeljordan',
  'thisisapassword',
  'correcthorsebatterystaple',
  'abcdefghijkl',
  'abcdefghijklm',
  'aaaaaaaaaaaa',
  'zxcvbnmasdfgh',
  'p@ssw0rd12345',
  'changemenow12',
  'qazwsxedcrfv',
];

/// Why [passphrase] may not wrap the root, or null when it may. User-facing.
String? pqRootPassphraseProblem(String passphrase) {
  if (passphrase.length < pqRootMinPassphraseLength) {
    return 'Use at least $pqRootMinPassphraseLength characters.';
  }
  final lower = passphrase.toLowerCase();
  if (pqRootCommonPassphrases.contains(lower)) {
    return 'That is one of the most common passwords. Choose another.';
  }
  // Long but near-characterless; the common list cannot enumerate these.
  if (passphrase.split('').toSet().length < 4) {
    return 'Too repetitive — use a longer, more varied phrase.';
  }
  return null;
}

/// Coarse 0-4 score for the strength meter. Not a boundary —
/// [pqRootPassphraseProblem] is.
int pqRootPassphraseStrength(String passphrase) {
  if (passphrase.isEmpty) return 0;
  var classes = 0;
  if (RegExp(r'[a-z]').hasMatch(passphrase)) classes++;
  if (RegExp(r'[A-Z]').hasMatch(passphrase)) classes++;
  if (RegExp(r'[0-9]').hasMatch(passphrase)) classes++;
  if (RegExp(r'[^a-zA-Z0-9]').hasMatch(passphrase)) classes++;
  final unique = passphrase.split('').toSet().length;
  var score = 0;
  if (passphrase.length >= 12) score++;
  if (passphrase.length >= 16) score++;
  if (passphrase.length >= 24) score++;
  if (classes >= 3) score++;
  if (unique < 6) score = score > 1 ? 1 : score;
  if (pqRootPassphraseProblem(passphrase) != null) score = 0;
  return score > 4 ? 4 : score;
}

// -----------------------------------------------------------------------------
// Wrap format
// -----------------------------------------------------------------------------

final _pbkdf2 = Pbkdf2(
  macAlgorithm: Hmac.sha256(),
  iterations: pqRootPbkdf2Iterations,
  bits: 256,
);
final _aes = AesGcm.with256bits();

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

  /// [pqRootWrapPassphrase], [pqRootWrapPasskey], or a future type.
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

/// AES-GCM-256 encrypt of [root] under [key], in the shared `enc:v1:` envelope.
Future<String> _sealRoot(SecretKey key, Uint8List root,
    {Uint8List? nonce}) async {
  final iv = nonce ?? _aes.newNonce();
  final box = await _aes.encrypt(root, secretKey: key, nonce: iv);
  final ct = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  return 'enc:v1:${base64.encode(iv)}:${base64.encode(ct)}';
}

/// Inverse of [_sealRoot]. Throws on a wrong key (GCM tag failure) or a
/// malformed envelope.
Future<Uint8List> _openRoot(SecretKey key, String blob) async {
  final parts = blob.split(':');
  if (parts.length != 4 || parts[0] != 'enc' || parts[1] != 'v1') {
    throw const FormatException('bad pq root wrap');
  }
  final iv = base64.decode(parts[2]);
  final all = base64.decode(parts[3]);
  if (all.length <= 16) throw const FormatException('bad pq root wrap');
  final clear = await _aes.decrypt(
    SecretBox(all.sublist(0, all.length - 16),
        nonce: iv, mac: Mac(all.sublist(all.length - 16))),
    secretKey: key,
  );
  return Uint8List.fromList(clear);
}

/// Wraps [root]: PBKDF2-HMAC-SHA256 over a fresh 16-byte salt, then
/// AES-GCM-256. The passphrase only ever wraps, never seeds (spec §5.2).
///
/// Throws [ArgumentError] when the passphrase fails
/// [pqRootPassphraseProblem]. [salt] / [nonce] are for test vectors only.
Future<PqRootWrap> pqRootWrapWithPassphrase(
  Uint8List root,
  String passphrase, {
  Uint8List? salt,
  Uint8List? nonce,
}) async {
  if (root.length != pq.pqRootLength) {
    throw ArgumentError('pq root must be ${pq.pqRootLength} bytes');
  }
  final problem = pqRootPassphraseProblem(passphrase);
  if (problem != null) throw ArgumentError(problem);
  final s = salt ?? randomBytes(pqRootSaltLength);
  final key = await _pbkdf2.deriveKey(
    secretKey: SecretKey(utf8.encode(passphrase)),
    nonce: s,
  );
  return PqRootWrap(
    type: pqRootWrapPassphrase,
    salt: base64.encode(s),
    iterations: pqRootPbkdf2Iterations,
    blob: await _sealRoot(key, root, nonce: nonce),
  );
}

/// Recovers the root, or null on a wrong passphrase or a malformed wrap — the
/// two are deliberately indistinguishable.
Future<Uint8List?> pqRootUnwrapWithPassphrase(
  PqRootWrap wrap,
  String passphrase,
) async {
  if (wrap.type != pqRootWrapPassphrase) return null;
  final saltB64 = wrap.salt;
  if (saltB64 == null) return null;
  try {
    final kdf = wrap.iterations == null ||
            wrap.iterations == pqRootPbkdf2Iterations
        ? _pbkdf2
        : Pbkdf2(
            macAlgorithm: Hmac.sha256(),
            iterations: wrap.iterations!,
            bits: 256,
          );
    final key = await kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: base64.decode(saltB64),
    );
    final root = await _openRoot(key, wrap.blob);
    if (root.length != pq.pqRootLength) return null;
    return root;
  } catch (_) {
    return null;
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
