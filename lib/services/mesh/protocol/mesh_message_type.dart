/// Bitchat mesh packet types — byte-for-byte compatible with the reference
/// bitchat iOS/Android clients (`BinaryProtocol.MessageType`).
///
/// These are the `type` byte of a [BitchatPacket]. Interop with the real
/// bitchat app depends on these exact values, so they are frozen here and must
/// not be renumbered.
class MeshMessageType {
  const MeshMessageType._();

  /// Signed identity announcement (TLV [IdentityAnnouncement] payload).
  static const int announce = 0x01;

  /// User message — public/broadcast chat (TLV [BitchatMessage] payload).
  static const int message = 0x02;

  /// Peer is leaving the mesh (payload = sender peerID string).
  static const int leave = 0x03;

  /// Noise XX handshake message (payloads are the 32/96/48-byte XX messages).
  static const int noiseHandshake = 0x10;

  /// Noise-encrypted transport message (payload = Noise ciphertext).
  static const int noiseEncrypted = 0x11;

  /// A single fragment of a larger packet (payload = [FragmentPayload]).
  static const int fragment = 0x20;

  /// GCS-based gossip sync request.
  static const int requestSync = 0x21;

  /// File transfer packet (BLE media / voice notes).
  static const int fileTransfer = 0x22;

  /// Ephemeral live push-to-talk audio frame (never gossip-synced).
  static const int voiceFrame = 0x29;

  // --- Nymchat extensions (unknown to bitchat, which ignores them) ----------

  /// Request a peer's rich profile (avatar/banner) over the mesh.
  static const int nymProfileRequest = 0x50;

  /// Deliver a rich profile in response to [nymProfileRequest].
  static const int nymProfileResponse = 0x51;

  /// True when [type] is a value this client knows how to handle.
  static bool isKnown(int type) => const {
        announce,
        message,
        leave,
        noiseHandshake,
        noiseEncrypted,
        fragment,
        requestSync,
        fileTransfer,
        voiceFrame,
      }.contains(type);

  static String name(int type) {
    switch (type) {
      case announce:
        return 'ANNOUNCE';
      case message:
        return 'MESSAGE';
      case leave:
        return 'LEAVE';
      case noiseHandshake:
        return 'NOISE_HANDSHAKE';
      case noiseEncrypted:
        return 'NOISE_ENCRYPTED';
      case fragment:
        return 'FRAGMENT';
      case requestSync:
        return 'REQUEST_SYNC';
      case fileTransfer:
        return 'FILE_TRANSFER';
      case voiceFrame:
        return 'VOICE_FRAME';
      default:
        return 'UNKNOWN(0x${type.toRadixString(16)})';
    }
  }
}

/// The inner Noise-plaintext payload discriminator carried by a
/// [MeshMessageType.noiseEncrypted] packet after the session is established.
///
/// Mirrors bitchat's `NoisePayloadType`: the first byte of the decrypted
/// plaintext selects how the remainder is parsed.
class NoisePayloadType {
  const NoisePayloadType._();

  /// A private text message (TLV: MESSAGE_ID + CONTENT).
  static const int privateMessage = 0x01;

  /// A read receipt (payload identifies the original message id).
  static const int readReceipt = 0x02;

  /// A delivery acknowledgement (payload identifies the original message id).
  static const int delivered = 0x03;
}
