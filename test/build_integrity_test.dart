// The Android build-integrity check: hash the installed APK, compare against
// the developer's signed release manifest.
//
// The states that must NOT read as failures are the point of these tests. A
// Play install can never match a published hash — Play re-signs the upload and
// builds a separate APK per device — and an unreachable manifest establishes
// nothing either way. Both were easy to render as "unverified" and scare every
// ordinary user, so each has its own state and its own copy.
//
// Everything here drives the pure verdict function and the manifest parser
// directly; no device, no channel.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/schnorr.dart' as schnorr;
import 'package:nym_bar/features/i18n/app_strings_catalog.dart';
import 'package:nym_bar/features/settings/about_screen.dart';
import 'package:nym_bar/features/settings/build_integrity.dart';
import 'package:nym_bar/models/nostr_event.dart';

const _apkHash =
    'aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899';
const _otherHash =
    '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
const _signer =
    'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';

NativeBuildInfo _sideload({
  String? apk = _apkHash,
  String version = '3.74.533',
  int code = 238,
}) =>
    NativeBuildInfo(
      packageName: 'com.nym.bar',
      apkSha256: apk,
      splitCount: 0,
      signerSha256: _signer,
      installer: 'com.nymchat.sideload',
      versionName: version,
      versionCode: code,
    );

const _published = PublishedBuild(
  version: '3.74.533',
  versionCode: 238,
  apkSha256: [_apkHash],
  signerSha256: _signer,
);

void main() {
  group('verdict', () {
    test('a published hash that matches verifies', () {
      final r = describeBuildIntegrity(
          info: _sideload(), manifestOk: true, builds: const [_published]);
      expect(r.state, BuildIntegrityState.verified);
      expect(r.isVerified, isTrue);
      expect(r.published?.version, '3.74.533');
    });

    test('a hash the manifest does not publish is a mismatch', () {
      final r = describeBuildIntegrity(
          info: _sideload(apk: _otherHash),
          manifestOk: true,
          builds: const [_published]);
      expect(r.state, BuildIntegrityState.mismatch);
    });

    test('any of several per-ABI hashes counts', () {
      // `--split-per-abi` publishes one APK per ABI and any is legitimate.
      const multi = PublishedBuild(
        version: '3.74.533',
        versionCode: 238,
        apkSha256: [_otherHash, _apkHash],
      );
      final r = describeBuildIntegrity(
          info: _sideload(), manifestOk: true, builds: const [multi]);
      expect(r.state, BuildIntegrityState.verified);
    });

    test('a version the manifest has not published yet is its own state', () {
      final r = describeBuildIntegrity(
          info: _sideload(version: '9.9.9', code: 999),
          manifestOk: true,
          builds: const [_published]);
      expect(r.state, BuildIntegrityState.notPublished);
    });

    test('a matching versionCode is enough when the name differs', () {
      final r = describeBuildIntegrity(
          info: _sideload(version: 'v3.74.533'),
          manifestOk: true,
          builds: const [_published]);
      expect(r.state, BuildIntegrityState.verified);
    });

    test('an unreachable manifest is not a failure', () {
      final r = describeBuildIntegrity(
          info: _sideload(), manifestOk: false, builds: const []);
      expect(r.state, BuildIntegrityState.provenanceUnreachable);
    });

    test('nothing measured is unsupported, not a mismatch', () {
      expect(
        describeBuildIntegrity(
                info: null, manifestOk: true, builds: const [_published])
            .state,
        BuildIntegrityState.unsupported,
      );
      expect(
        describeBuildIntegrity(
                info: _sideload(apk: null),
                manifestOk: true,
                builds: const [_published])
            .state,
        BuildIntegrityState.unsupported,
      );
    });
  });

  group('Google Play', () {
    test('an install by Play is never a mismatch', () {
      // The bytes on the device are not the published file, so a hash that
      // fails to match says nothing about tampering.
      const play = NativeBuildInfo(
        apkSha256: _otherHash,
        installer: kPlayInstaller,
        versionName: '3.74.533',
        versionCode: 238,
      );
      final r = describeBuildIntegrity(
          info: play, manifestOk: true, builds: const [_published]);
      expect(r.state, BuildIntegrityState.storeRepackaged);
    });

    test('split APKs alone mark a store install', () {
      // Play delivers per-ABI/density/language splits even where the installer
      // package is missing (restored backups, some OEM flows).
      const split = NativeBuildInfo(
        apkSha256: _otherHash,
        splitCount: 3,
        versionName: '3.74.533',
      );
      expect(split.isStoreRepackaged, isTrue);
      expect(
        describeBuildIntegrity(
                info: split, manifestOk: true, builds: const [_published])
            .state,
        BuildIntegrityState.storeRepackaged,
      );
    });

    test('a store install reports the same way when the manifest is down', () {
      // The network could not have changed the answer, so saying "provenance
      // unreachable" would imply a check that was never going to run.
      const play = NativeBuildInfo(
          apkSha256: _otherHash, installer: kPlayInstaller, splitCount: 4);
      expect(
        describeBuildIntegrity(info: play, manifestOk: false, builds: const [])
            .state,
        BuildIntegrityState.storeRepackaged,
      );
    });

    test('a direct install is not treated as a store one', () {
      expect(_sideload().isStoreRepackaged, isFalse);
    });
  });

  group('manifest', () {
    // A real signed event, so the parser is exercised against the same
    // verification path the app uses rather than a stub.
    ({String body, String pubkey}) signedManifest(Object content) {
      final sk = randomBytes(32);
      final pk = getPublicKeyHex(sk);
      final event = schnorr.finalizeEvent(
        UnsignedEvent(
          pubkey: pk,
          createdAt: 1735689600,
          kind: 30078,
          tags: const [
            ['d', 'nym-releases']
          ],
          content: jsonEncode(content),
        ),
        sk,
      );
      return (body: jsonEncode(event.toJson()), pubkey: pk);
    }

    test('a correctly signed manifest parses', () {
      final m = signedManifest({
        'app': 'com.nym.bar',
        'builds': [
          {
            'version': '3.74.533',
            'versionCode': 238,
            'apkSha256': [_apkHash],
            'signerSha256': _signer,
          }
        ],
      });
      final builds = parseReleaseManifest(m.body, m.pubkey);
      expect(builds, isNotNull);
      expect(builds!.single.version, '3.74.533');
      expect(builds.single.apkSha256, [_apkHash]);
    });

    test('a manifest signed by anyone else is refused', () {
      // Otherwise a hostile mirror of the repository could vouch for its own
      // APK by publishing a manifest of its own.
      final m = signedManifest({'builds': const []});
      final other = getPublicKeyHex(randomBytes(32));
      expect(parseReleaseManifest(m.body, other), isNull);
    });

    test('a tampered manifest is refused', () {
      final m = signedManifest({
        'builds': [
          {
            'version': '3.74.533',
            'apkSha256': [_apkHash]
          }
        ],
      });
      final doc = jsonDecode(m.body) as Map<String, dynamic>;
      doc['content'] = jsonEncode({
        'builds': [
          {
            'version': '3.74.533',
            'apkSha256': [_otherHash]
          }
        ],
      });
      expect(parseReleaseManifest(jsonEncode(doc), m.pubkey), isNull);
    });

    test('nothing published yet is not a mismatch', () {
      // Until the first release is signed the manifest 404s, which must read
      // as "no hash to compare against", never as "this build is wrong".
      final r = describeBuildIntegrity(
          info: _sideload(), manifestOk: true, builds: const []);
      expect(r.state, BuildIntegrityState.notPublished);
    });

    test('garbage is refused rather than thrown', () {
      expect(parseReleaseManifest('not json', 'deadbeef'), isNull);
      expect(parseReleaseManifest('{}', 'deadbeef'), isNull);
    });

    test('an unverifiable manifest reads as unreachable, not as a pass', () {
      // The two are one state on purpose: a manifest that cannot be checked is
      // worth exactly as much as one that never arrived.
      final r = describeBuildIntegrity(
          info: _sideload(), manifestOk: false, builds: const []);
      expect(r.state, BuildIntegrityState.provenanceUnreachable);
      expect(r.isVerified, isFalse);
    });

    test('hex case does not matter', () {
      final info = NativeBuildInfo.fromMap({
        'apkSha256': _apkHash.toUpperCase(),
        'signerSha256': _signer.toUpperCase(),
        'splitCount': 0,
        'versionName': '3.74.533',
        'versionCode': 238,
      });
      expect(
        describeBuildIntegrity(
                info: info, manifestOk: true, builds: const [_published])
            .state,
        BuildIntegrityState.verified,
      );
    });
  });

  group('copy', () {
    test('every state has its own status and note', () {
      final seen = <String>{};
      for (final state in BuildIntegrityState.values) {
        final (status, note) = buildIntegrityCopy(state);
        expect(status, isNotEmpty, reason: '$state');
        expect(note, isNotEmpty, reason: '$state');
        expect(seen.add(status), isTrue, reason: 'duplicate status for $state');
      }
    });

    test('every literal is in the sweep catalog', () {
      for (final s in kBuildIntegrityStrings) {
        expect(kAppStringsCatalog, contains(s), reason: s);
      }
    });

    test('only a real check claims a verdict', () {
      // The states that compared nothing must not say "verified" or imply the
      // app was found wanting.
      for (final state in [
        BuildIntegrityState.storeRepackaged,
        BuildIntegrityState.provenanceUnreachable,
        BuildIntegrityState.notPublished,
        BuildIntegrityState.unsupported,
      ]) {
        final (status, _) = buildIntegrityCopy(state);
        expect(status.toLowerCase(), isNot(contains('verified official')));
      }
    });
  });
}
