import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart'
    show HMac, KeyDerivator, PBKDF2KeyDerivator, Pbkdf2Parameters, SHA256Digest;

import '../../../core/crypto/keys.dart';
import '../../../core/crypto/nip44.dart' as nip44;

const String kKeyBackupFormat = 'nym-key-backup-v1';
const int kKeyBackupIterations = 600000;
const int kKeyBackupKeyBytes = 32;

enum BackupCloud {
  google('nym-google-backup', 'Google'),
  apple('nym-apple-backup', 'Apple');

  const BackupCloud(this.context, this.label);

  final String context;
  final String label;
}

typedef BackupKeyDeriver = Future<Uint8List> Function(
    String pin, Uint8List salt);

final RegExp _pinPattern = RegExp(r'^[0-9]{4,8}$');
final RegExp _secretPattern = RegExp(r'^[0-9a-f]{64}$');

bool isValidBackupPin(String pin) => _pinPattern.hasMatch(pin);

Uint8List backupSalt(BackupCloud cloud, String accountId) =>
    backupSaltFor(cloud.context, accountId);

Uint8List backupSaltFor(String context, String accountId) {
  final mac = crypto.Hmac(crypto.sha256, utf8.encode(context));
  return Uint8List.fromList(mac.convert(utf8.encode(accountId)).bytes);
}

Uint8List deriveBackupKeySync(String pin, Uint8List salt) {
  if (!isValidBackupPin(pin)) {
    throw ArgumentError('PIN must be 4 to 8 digits');
  }
  final KeyDerivator derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, kKeyBackupIterations, kKeyBackupKeyBytes));
  return derivator.process(Uint8List.fromList(utf8.encode(pin)));
}

Uint8List _deriveInIsolate(List<Object> args) =>
    deriveBackupKeySync(args[0] as String, args[1] as Uint8List);

Future<Uint8List> deriveBackupKey(String pin, Uint8List salt) {
  if (!isValidBackupPin(pin)) {
    return Future.error(ArgumentError('PIN must be 4 to 8 digits'));
  }
  return compute(_deriveInIsolate, <Object>[pin, Uint8List.fromList(salt)]);
}

String encryptBackupSecret(String secretHex, Uint8List key,
    {Uint8List? nonce}) {
  final normalized = secretHex.toLowerCase();
  if (!_secretPattern.hasMatch(normalized)) {
    throw ArgumentError('secret must be 64 hex characters');
  }
  return nip44.encrypt(normalized, key, nonce: nonce);
}

String? decryptBackupSecret(String payload, Uint8List key) {
  try {
    final plain = nip44.decrypt(payload.trim(), key);
    if (!_secretPattern.hasMatch(plain)) return null;
    if (hexToBytes(plain).length != 32) return null;
    return plain;
  } catch (_) {
    return null;
  }
}

void wipeBytes(Uint8List? bytes) {
  if (bytes == null) return;
  bytes.fillRange(0, bytes.length, 0);
}
