// High-level events emitted by MeshService for the app layer to consume.

/// A public broadcast message received over the mesh (nearby / channel chat).
class MeshPublicMessage {
  MeshPublicMessage({
    required this.senderPeerID,
    required this.senderNickname,
    required this.content,
    required this.messageId,
    required this.timestampMs,
    this.channel,
    this.mentions = const [],
    this.isRelay = false,
  });

  final String senderPeerID;
  final String senderNickname;
  final String content;
  final String messageId;
  final int timestampMs;
  final String? channel;
  final List<String> mentions;
  final bool isRelay;
}

/// A private (Noise-encrypted) message received over the mesh.
class MeshPrivateMessage {
  MeshPrivateMessage({
    required this.senderPeerID,
    required this.messageId,
    required this.content,
    required this.timestampMs,
  });

  final String senderPeerID;
  final String messageId;
  final String content;
  final int timestampMs;
}

/// A delivery/read acknowledgement received for one of our sent messages.
class MeshReceipt {
  MeshReceipt({
    required this.fromPeerID,
    required this.messageId,
    required this.isRead,
  });

  final String fromPeerID;
  final String messageId;

  /// True for a read receipt, false for a delivery ack.
  final bool isRead;
}
