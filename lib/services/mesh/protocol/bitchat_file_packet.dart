import 'dart:convert';
import 'dart:typed_data';

/// A TLV-encoded file transfer payload for the mesh — a byte-for-byte port of
/// bitchat's `BitchatFilePacket`. Used to send images, videos and files over
/// Bluetooth (inside a Noise-encrypted DM, or as a public/channel broadcast).
///
/// TLVs (2-byte big-endian length each):
/// * `0x01` filename (UTF-8)
/// * `0x02` file size (8-byte u64)
/// * `0x03` mime type (UTF-8)
/// * `0x04` content — may repeat; each chunk ≤ 65535 bytes (so a file > 64 KiB
///   is carried as multiple CONTENT TLVs). Unknown TLV types are skipped.
class BitchatFilePacket {
  BitchatFilePacket({
    required this.fileName,
    required this.mimeType,
    required this.content,
  }) : fileSize = content.length;

  final String fileName;
  final String mimeType;
  final Uint8List content;
  final int fileSize;

  static const int _tName = 0x01;
  static const int _tSize = 0x02;
  static const int _tMime = 0x03;
  static const int _tContent = 0x04;
  static const int _maxTlv = 0xFFFF;

  Uint8List? encode() {
    final nameBytes = utf8.encode(fileName);
    final mimeBytes = utf8.encode(mimeType);
    if (nameBytes.length > _maxTlv || mimeBytes.length > _maxTlv) return null;

    final out = BytesBuilder();
    void tlv(int type, List<int> value) {
      out.addByte(type);
      out.addByte((value.length >> 8) & 0xFF);
      out.addByte(value.length & 0xFF);
      out.add(value);
    }

    tlv(_tName, nameBytes);
    // 8-byte big-endian size.
    final size = BigInt.from(content.length);
    tlv(_tSize, [
      for (var i = 7; i >= 0; i--) ((size >> (i * 8)) & BigInt.from(0xFF)).toInt()
    ]);
    tlv(_tMime, mimeBytes);
    // CONTENT, chunked to fit the 2-byte length field.
    for (var off = 0; off < content.length; off += _maxTlv) {
      final end = (off + _maxTlv < content.length) ? off + _maxTlv : content.length;
      tlv(_tContent, Uint8List.sublistView(content, off, end));
    }
    if (content.isEmpty) tlv(_tContent, const []);
    return out.toBytes();
  }

  static BitchatFilePacket? decode(Uint8List data) {
    var offset = 0;
    String? fileName;
    String? mimeType;
    final content = BytesBuilder();
    var sawContent = false;

    while (offset + 3 <= data.length) {
      final type = data[offset];
      final len = (data[offset + 1] << 8) | data[offset + 2];
      offset += 3;
      if (offset + len > data.length) return null;
      final value = Uint8List.sublistView(data, offset, offset + len);
      offset += len;
      switch (type) {
        case _tName:
          fileName = utf8.decode(value, allowMalformed: true);
          break;
        case _tMime:
          mimeType = utf8.decode(value, allowMalformed: true);
          break;
        case _tContent:
          content.add(value);
          sawContent = true;
          break;
        case _tSize:
          break; // informational; recomputed from content
        default:
          break; // unknown TLV — skip
      }
    }
    if (fileName == null || mimeType == null || !sawContent) return null;
    return BitchatFilePacket(
      fileName: fileName,
      mimeType: mimeType,
      content: content.toBytes(),
    );
  }
}
