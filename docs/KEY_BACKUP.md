# Google and Apple key backup

"Continue with Google" / "Continue with Apple" back up the user's locally generated Nostr key, encrypted with a PIN, to their own cloud account, and restore it on another device. The format is `nym-key-backup-v1`, shared byte for byte with Nymbot (web and Flutter) and the Nymchat web app. The canonical test vector is `test/key-backup-vector.json`.

Code: `lib/features/identity/key_backup/`.

Every button stays hidden until its provider is configured, so a build without the settings below behaves exactly as before.

## Build settings (`--dart-define`)

| Define | Value | Needed for |
| --- | --- | --- |
| `GOOGLE_IOS_CLIENT_ID` | the iOS OAuth client id (`<id>.apps.googleusercontent.com`) | Google on iOS |
| `GOOGLE_SERVER_CLIENT_ID` | the Web OAuth client id, shared with the web apps | Google on Android (required there as `serverClientId`), optional on iOS |
| `APPLE_BACKUP` | `true` | Apple on iOS (default off) |
| `APPLE_KEYCHAIN_GROUP` | `<TEAMID>.com.nym.shared` (the full access group, team prefix included) | Apple on iOS, so Nymbot and Nymchat share backups |

Example:

```sh
flutter build ipa \
  --dart-define=GOOGLE_IOS_CLIENT_ID=1234-abc.apps.googleusercontent.com \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=1234-web.apps.googleusercontent.com \
  --dart-define=APPLE_BACKUP=true \
  --dart-define=APPLE_KEYCHAIN_GROUP=ABCDE12345.com.nym.shared
```

## Google Cloud (shared project with Nymbot)

- OAuth consent screen: add the scopes `openid` and `https://www.googleapis.com/auth/drive.appdata`. Nothing broader.
- Enable the Google Drive API.
- Create an **Android** OAuth client for package `com.nym.bar` with the SHA-1 of every signing key in use (the upload key and, for Play, the app signing key). No client id goes into the Android code; Credential Manager matches the package and certificate.
- Create an **iOS** OAuth client for bundle id `com.nym.bar`. Its id is `GOOGLE_IOS_CLIENT_ID`.
- The existing **Web** client (used by the web apps) is `GOOGLE_SERVER_CLIENT_ID`.

## iOS

- `ios/Runner/Info.plist` has a placeholder URL scheme `com.googleusercontent.apps.REPLACE-WITH-GOOGLE-IOS-CLIENT-ID` under `CFBundleURLTypes` (`google-sign-in`). Replace it with the reversed iOS client id (`com.googleusercontent.apps.<id>`) before shipping Google sign-in on iOS.
- Apple backup, only when turning on `APPLE_BACKUP`:
  - Enable **Sign in with Apple** on the App ID `com.nym.bar` (and Nymbot's) in the same team, regenerate the provisioning profile, then add to `ios/Runner/Runner.entitlements` and `RunnerDebug.entitlements`:
    ```xml
    <key>com.apple.developer.applesignin</key>
    <array>
        <string>Default</string>
    </array>
    ```
  - Add the shared keychain group to `keychain-access-groups` in both entitlements files, next to the existing `$(AppIdentifierPrefix)com.nym.bar` (keep that one first so flutter_secure_storage's existing items stay where they are), and add the same group to Nymbot:
    ```xml
    <string>$(AppIdentifierPrefix)com.nym.shared</string>
    ```
  - Backups are iCloud Keychain generic-password items: service `com.nym.apple-backup`, account `nym_bk_<uuid>`, `kSecAttrSynchronizable = true`, `kSecAttrAccessibleAfterFirstUnlock`, in that access group.
- None of these entitlements are in the repo yet, on purpose: adding them before the App ID and profile have the capability makes signing fail.

## Android

Nothing beyond the Google Cloud setup above and `GOOGLE_SERVER_CLIENT_ID`. The Apple option never shows on Android.
