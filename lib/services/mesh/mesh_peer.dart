import 'dart:typed_data';

/// A peer discovered on the Bluetooth mesh. Identity is established from a
/// signed announcement; [isVerified] is true once the peerID has been
/// cryptographically bound to the announced Noise static key (and, after a Noise
/// handshake, to a live session).
class MeshPeer {
  MeshPeer({
    required this.peerID,
    this.nickname,
    this.noisePublicKey,
    this.signingPublicKey,
    this.rssi = 0,
    this.isDirectLink = false,
    this.isVerified = false,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  /// 16-hex-char mesh identifier (first 8 bytes of SHA-256(noise pubkey)).
  final String peerID;

  String? nickname;

  /// Curve25519 static key from the peer's announcement (Noise identity).
  Uint8List? noisePublicKey;

  /// Ed25519 signing key from the peer's announcement.
  Uint8List? signingPublicKey;

  int rssi;

  /// True when we hold a direct BLE link to this peer (vs. reached via relay).
  bool isDirectLink;

  /// True once the announcement signature verified and the peerID matched the
  /// announced Noise key.
  bool isVerified;

  DateTime lastSeen;

  /// Display label — the announced nickname, or a short peerID fallback.
  String get displayName =>
      (nickname != null && nickname!.isNotEmpty) ? nickname! : peerID;

  void touch() => lastSeen = DateTime.now();
}
