import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/services/mesh/protocol/bitchat_file_packet.dart';

Uint8List _bytes(int n, [int start = 0]) =>
    Uint8List.fromList(List.generate(n, (i) => (start + i) & 0xFF));

void main() {
  group('BitchatFilePacket', () {
    test('round-trips a small file', () {
      final pkt = BitchatFilePacket(
        fileName: 'photo.webp',
        mimeType: 'image/webp',
        content: _bytes(500, 3),
      );
      final decoded = BitchatFilePacket.decode(pkt.encode()!)!;
      expect(decoded.fileName, 'photo.webp');
      expect(decoded.mimeType, 'image/webp');
      expect(decoded.content, equals(_bytes(500, 3)));
      expect(decoded.fileSize, 500);
    });

    test('content over 64 KiB is chunked into multiple CONTENT TLVs and rejoined',
        () {
      final big = _bytes(150000, 1); // > 2 * 65535 → 3 CONTENT TLVs
      final decoded = BitchatFilePacket.decode(
          BitchatFilePacket(fileName: 'clip.mp4', mimeType: 'video/mp4', content: big)
              .encode()!)!;
      expect(decoded.content.length, 150000);
      expect(decoded.content, equals(big));
      expect(decoded.mimeType, 'video/mp4');
    });

    test('unknown TLV types are skipped', () {
      final base = BitchatFilePacket(
              fileName: 'a.txt', mimeType: 'text/plain', content: _bytes(4))
          .encode()!;
      // Prepend an unknown TLV (type 0x7F, len 2).
      final withUnknown =
          Uint8List.fromList([0x7F, 0x00, 0x02, 0xAA, 0xBB, ...base]);
      final decoded = BitchatFilePacket.decode(withUnknown)!;
      expect(decoded.fileName, 'a.txt');
      expect(decoded.content, equals(_bytes(4)));
    });

    test('decode fails without required fields', () {
      expect(BitchatFilePacket.decode(Uint8List(0)), isNull);
    });
  });
}
