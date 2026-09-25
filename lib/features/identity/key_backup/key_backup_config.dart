import 'package:flutter/foundation.dart';

class KeyBackupConfig {
  const KeyBackupConfig({
    this.googleIosClientId = '',
    this.googleServerClientId = '',
    this.appleBackup = false,
    this.appleKeychainGroup = '',
  });

  static const KeyBackupConfig environment = KeyBackupConfig(
    googleIosClientId: String.fromEnvironment('GOOGLE_IOS_CLIENT_ID'),
    googleServerClientId: String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID'),
    appleBackup: String.fromEnvironment('APPLE_BACKUP') == 'true',
    appleKeychainGroup: String.fromEnvironment('APPLE_KEYCHAIN_GROUP'),
  );

  final String googleIosClientId;
  final String googleServerClientId;
  final bool appleBackup;
  final String appleKeychainGroup;

  bool googleEnabledOn(TargetPlatform platform, {bool web = kIsWeb}) {
    if (web) return false;
    switch (platform) {
      case TargetPlatform.android:
        return googleServerClientId.isNotEmpty;
      case TargetPlatform.iOS:
        return googleIosClientId.isNotEmpty;
      default:
        return false;
    }
  }

  bool appleEnabledOn(TargetPlatform platform, {bool web = kIsWeb}) =>
      !web && appleBackup && platform == TargetPlatform.iOS;

  String? get googleClientIdForIos =>
      googleIosClientId.isEmpty ? null : googleIosClientId;

  String? get googleServerClientIdOrNull =>
      googleServerClientId.isEmpty ? null : googleServerClientId;

  String? get appleKeychainGroupOrNull =>
      appleKeychainGroup.isEmpty ? null : appleKeychainGroup;
}
