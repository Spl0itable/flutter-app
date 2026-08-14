import 'dart:typed_data';

/// G.711 µ-law companding (pure Dart) — halves the bandwidth of a 16-bit PCM
/// voice stream to 8 bits/sample with graceful, telephony-grade quality. Used
/// for push-to-talk voice over the Bluetooth mesh, where an 8 kHz mono stream
/// companded to µ-law is ~8 KB/s — comfortably inside BLE's practical budget.
class MuLaw {
  const MuLaw._();

  static const int _bias = 0x84;
  static const int _clip = 32635;

  /// Encodes a little-endian PCM16 buffer to µ-law bytes (one byte per sample).
  static Uint8List encode(Uint8List pcm16le) {
    final samples = pcm16le.length ~/ 2;
    final out = Uint8List(samples);
    final view = ByteData.sublistView(pcm16le);
    for (var i = 0; i < samples; i++) {
      out[i] = _encodeSample(view.getInt16(i * 2, Endian.little));
    }
    return out;
  }

  /// Decodes µ-law bytes back to a little-endian PCM16 buffer.
  static Uint8List decode(Uint8List mulaw) {
    final out = Uint8List(mulaw.length * 2);
    final view = ByteData.sublistView(out);
    for (var i = 0; i < mulaw.length; i++) {
      view.setInt16(i * 2, _decodeSample(mulaw[i]), Endian.little);
    }
    return out;
  }

  static int _encodeSample(int sample) {
    var sign = (sample >> 8) & 0x80;
    if (sign != 0) sample = -sample;
    if (sample > _clip) sample = _clip;
    sample += _bias;
    var exponent = _exponentTable[(sample >> 7) & 0xFF];
    var mantissa = (sample >> (exponent + 3)) & 0x0F;
    var value = ~(sign | (exponent << 4) | mantissa) & 0xFF;
    return value;
  }

  static int _decodeSample(int muByte) {
    final u = ~muByte & 0xFF;
    final sign = u & 0x80;
    final exponent = (u >> 4) & 0x07;
    final mantissa = u & 0x0F;
    var sample = ((mantissa << 3) + _bias) << exponent;
    sample -= _bias;
    return sign != 0 ? -sample : sample;
  }

  /// Lookup for the µ-law exponent segment (standard G.711 table).
  static const List<int> _exponentTable = [
    0, 0, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, //
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
  ];
}
