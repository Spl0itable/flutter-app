import 'at_rest_cipher.dart';
import 'key_value_store.dart';

class SealedKeyValue {
  SealedKeyValue(this.kv, {AtRestCipher? cipher, bool Function()? blocked})
      : _cipher = cipher,
        _blocked = blocked ?? _never;

  static bool _never() => false;

  final KeyValueStore kv;
  final AtRestCipher? _cipher;
  final bool Function() _blocked;
  Future<void> _writes = Future<void>.value();

  AtRestCipher get _crypto => _cipher ?? AtRestCipher.instance;

  Future<void> get idle => _writes;

  void write(String key, String plain) {
    _enqueue(() async {
      final sealed = await _crypto.encryptString(plain);
      if (_blocked()) return;
      await kv.setString(key, sealed);
    });
  }

  Future<String?> read(String key) async {
    await _writes;
    final stored = kv.getString(key);
    if (stored == null || stored.isEmpty) return stored;
    if (AtRestCipher.isEncryptedString(stored)) {
      try {
        return await _crypto.decryptString(stored);
      } catch (_) {
        return null;
      }
    }
    _enqueue(() async {
      final sealed = await _crypto.encryptString(stored);
      if (_blocked() || kv.getString(key) != stored) return;
      await kv.setString(key, sealed);
    });
    return stored;
  }

  void _enqueue(Future<void> Function() job) {
    _writes = _writes.then((_) async {
      if (_blocked()) return;
      try {
        await job();
      } catch (_) {}
    });
  }
}
