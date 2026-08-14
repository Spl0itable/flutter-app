import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/services/mesh/protocol/mulaw.dart';

Uint8List _pcm16(List<int> samples) {
  final out = Uint8List(samples.length * 2);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < samples.length; i++) {
    bd.setInt16(i * 2, samples[i], Endian.little);
  }
  return out;
}

List<int> _samples(Uint8List pcm16) {
  final bd = ByteData.sublistView(pcm16);
  return [for (var i = 0; i < pcm16.length; i += 2) bd.getInt16(i, Endian.little)];
}

void main() {
  group('MuLaw', () {
    test('halves the byte count (1 byte per PCM16 sample)', () {
      final pcm = _pcm16(List.filled(320, 0));
      final mu = MuLaw.encode(pcm);
      expect(mu.length, 320);
      expect(MuLaw.decode(mu).length, pcm.length);
    });

    test('silence round-trips to silence', () {
      final pcm = _pcm16(List.filled(160, 0));
      final back = _samples(MuLaw.decode(MuLaw.encode(pcm)));
      for (final s in back) {
        expect(s.abs(), lessThan(64)); // µ-law zero maps within the lowest step
      }
    });

    test('a sweep round-trips within µ-law quantisation error', () {
      final input = [
        for (var i = 0; i < 256; i++) (i * 257 - 32768).clamp(-32768, 32767)
      ];
      final back = _samples(MuLaw.decode(MuLaw.encode(_pcm16(input))));
      expect(back.length, input.length);
      for (var i = 0; i < input.length; i++) {
        final v = input[i];
        // µ-law is logarithmic: error grows with magnitude but stays bounded to
        // ~a few percent of full scale. Sign must be preserved for non-tiny
        // samples.
        final tol = 256 + (v.abs() >> 3);
        expect((back[i] - v).abs(), lessThanOrEqualTo(tol),
            reason: 'sample $i: in=$v out=${back[i]}');
        if (v.abs() > 1024) {
          expect(back[i].sign, v.sign, reason: 'sign flip at sample $i');
        }
      }
    });
  });
}
