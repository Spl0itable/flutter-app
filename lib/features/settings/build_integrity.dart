// build_integrity.dart — whether this install is the build the developer
// published.
//
// The web app re-hashes every file it is running and looks the result up in the
// repository's signed build attestations, so its About panel reports a real
// verdict. A native build cannot do the same thing with its own source: what
// runs on the device is AOT machine code, not the Dart in `android-ios-app/`,
// and no computation available on the device relates one to the other.
//
// What Android does offer is the installed APK, readable by the app at
// `ApplicationInfo.sourceDir`. That makes the same SHAPE of proof available:
// hash the artifact here, compare against a hash the developer published and
// signed, and let neither half vouch for the other. Anyone else can repeat both
// steps — download the published APK, hash it, verify the manifest's signature
// — which is what makes the result worth anything.
//
// It does NOT make the app self-certifying. Whoever modifies an app can delete
// the check along with everything else, so a green verdict proves nothing to
// someone holding a tampered build. What it proves is the ordinary case: that
// the copy you installed is bit-for-bit the copy that was published.
//
// iOS is out of reach entirely. App Store binaries are FairPlay-encrypted per
// download and re-signed per install, so a hash computed on the device is
// device-specific and matches nothing publishable.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../core/crypto/schnorr.dart' as schnorr;
import '../../models/nostr_event.dart';

/// The signed release manifest: the developer's published hashes for each
/// build, as a Nostr event whose `content` is the manifest JSON.
///
/// Served over HTTPS from the repository and verified against the same pinned
/// developer pubkey the warrant canary uses, so it inherits a key the app
/// already trusts and a publishing step the developer already performs. Being a
/// signed event rather than a plain file is what stops a hostile mirror of the
/// repository from vouching for its own APK.
const String kReleaseManifestUrl =
    'https://raw.githubusercontent.com/Spl0itable/NYM/main/android-ios-app/releases.json';

/// Play's own package name — an install it made is not the published artifact.
const String kPlayInstaller = 'com.android.vending';

/// What the app could establish about the copy of itself that is running.
enum BuildIntegrityState {
  /// The installed APK matches a hash in the signed manifest.
  verified,

  /// The APK hashes cleanly but matches nothing the manifest publishes for
  /// this version. Either it was modified, or it was built by someone else.
  mismatch,

  /// Installed from Google Play, which re-signs the upload and delivers
  /// per-device splits — the bytes on the device are not the published file,
  /// so there is nothing to compare. Not a failure.
  storeRepackaged,

  /// The manifest could not be fetched, or its signature did not check out.
  provenanceUnreachable,

  /// The manifest publishes nothing for this version yet.
  notPublished,

  /// This platform cannot measure itself (iOS, web, desktop).
  unsupported,
}

/// What the native side measured about the install.
@immutable
class NativeBuildInfo {
  const NativeBuildInfo({
    this.packageName,
    this.apkSha256,
    this.splitCount = 0,
    this.signerSha256,
    this.installer,
    this.versionName,
    this.versionCode,
  });

  factory NativeBuildInfo.fromMap(Map<Object?, Object?> map) {
    String? str(String key) {
      final v = map[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    final code = map['versionCode'];
    return NativeBuildInfo(
      packageName: str('packageName'),
      apkSha256: str('apkSha256')?.toLowerCase(),
      splitCount: map['splitCount'] is int ? map['splitCount'] as int : 0,
      signerSha256: str('signerSha256')?.toLowerCase(),
      installer: str('installer'),
      versionName: str('versionName'),
      versionCode: code is int ? code : (code is num ? code.toInt() : null),
    );
  }

  final String? packageName;

  /// Hex SHA-256 of the base APK on disk.
  final String? apkSha256;

  /// Split APKs alongside the base one. A universal sideloaded APK has none.
  final int splitCount;

  /// Hex SHA-256 of the signing certificate.
  final String? signerSha256;

  /// Package that performed the install, e.g. `com.android.vending` for Play.
  final String? installer;

  final String? versionName;
  final int? versionCode;

  /// True when the bytes on this device cannot be the published artifact:
  /// Play re-signs the App Bundle and generates splits per device.
  bool get isStoreRepackaged =>
      installer == kPlayInstaller || splitCount > 0;
}

/// One published build from the signed manifest.
@immutable
class PublishedBuild {
  const PublishedBuild({
    required this.version,
    this.versionCode,
    this.apkSha256 = const [],
    this.signerSha256,
  });

  factory PublishedBuild.fromJson(Map<String, dynamic> json) {
    final hashes = json['apkSha256'];
    return PublishedBuild(
      version: (json['version'] ?? '').toString(),
      versionCode: json['versionCode'] is num
          ? (json['versionCode'] as num).toInt()
          : null,
      // A list, because `--split-per-abi` publishes one APK per ABI and any of
      // them is a legitimate install.
      apkSha256: hashes is List
          ? hashes.map((h) => h.toString().toLowerCase()).toList()
          : hashes is String
              ? [hashes.toLowerCase()]
              : const [],
      signerSha256: json['signerSha256']?.toString().toLowerCase(),
    );
  }

  final String version;
  final int? versionCode;
  final List<String> apkSha256;
  final String? signerSha256;
}

/// The verdict, plus the values a reader needs to check it off-device.
@immutable
class BuildIntegrityResult {
  const BuildIntegrityResult({
    required this.state,
    this.info,
    this.published,
  });

  final BuildIntegrityState state;
  final NativeBuildInfo? info;
  final PublishedBuild? published;

  bool get isVerified => state == BuildIntegrityState.verified;
}

/// The verdict for one measurement, as a pure function so every branch is
/// testable without a device.
///
/// [manifestOk] is false when the manifest could not be fetched OR its
/// signature failed — the two are deliberately one state, because an
/// unverifiable manifest is worth exactly as much as a missing one.
BuildIntegrityResult describeBuildIntegrity({
  required NativeBuildInfo? info,
  required bool manifestOk,
  required List<PublishedBuild> builds,
}) {
  if (info == null || info.apkSha256 == null) {
    return const BuildIntegrityResult(state: BuildIntegrityState.unsupported);
  }
  // Checked BEFORE the manifest: on a Play install the answer is the same
  // whether or not the manifest loaded, and reporting a network problem would
  // imply a check that was never going to run.
  if (info.isStoreRepackaged) {
    return BuildIntegrityResult(
        state: BuildIntegrityState.storeRepackaged, info: info);
  }
  if (!manifestOk) {
    return BuildIntegrityResult(
        state: BuildIntegrityState.provenanceUnreachable, info: info);
  }
  final match = builds.where((b) =>
      b.version == info.versionName ||
      (b.versionCode != null && b.versionCode == info.versionCode));
  if (match.isEmpty) {
    return BuildIntegrityResult(
        state: BuildIntegrityState.notPublished, info: info);
  }
  for (final build in match) {
    if (build.apkSha256.contains(info.apkSha256)) {
      return BuildIntegrityResult(
        state: BuildIntegrityState.verified,
        info: info,
        published: build,
      );
    }
  }
  return BuildIntegrityResult(
    state: BuildIntegrityState.mismatch,
    info: info,
    published: match.first,
  );
}

/// Parses and verifies the signed release manifest.
///
/// Returns null when the event does not verify against [pubkey] — a manifest
/// that cannot be checked is treated exactly like one that never arrived,
/// rather than being read anyway.
List<PublishedBuild>? parseReleaseManifest(String body, String pubkey) {
  try {
    final doc = jsonDecode(body) as Map<String, dynamic>;
    final event = NostrEvent.fromJson(doc);
    if (!schnorr.verifyEvent(event) || event.pubkey != pubkey) return null;
    final content = jsonDecode(event.content) as Map<String, dynamic>;
    final builds = content['builds'];
    if (builds is! List) return const [];
    return builds
        .whereType<Map<String, dynamic>>()
        .map(PublishedBuild.fromJson)
        .toList();
  } catch (_) {
    return null;
  }
}

/// Measures the install and checks it against the published manifest.
class BuildIntegrityService {
  BuildIntegrityService({
    MethodChannel? channel,
    http.Client? client,
    this.manifestUrl = kReleaseManifestUrl,
    required this.developerPubkey,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _client = client;

  /// Shared with `MainActivity.kt`.
  static const String channelName = 'app.nymchat/build_integrity';

  final MethodChannel _channel;
  final http.Client? _client;
  final String manifestUrl;

  /// The pinned key the manifest must be signed with.
  final String developerPubkey;

  /// Only Android can read and hash its own installed artifact.
  static bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  Future<NativeBuildInfo?> measure() async {
    if (!isSupported) return null;
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('inspect');
      return raw == null ? null : NativeBuildInfo.fromMap(raw);
    } catch (_) {
      return null;
    }
  }

  Future<List<PublishedBuild>?> fetchManifest() async {
    try {
      final client = _client ?? http.Client();
      final res = await client.get(Uri.parse(manifestUrl));
      // No manifest published yet is not the same as one we couldn't reach:
      // an empty build list lands on `notPublished`, which says so.
      if (res.statusCode == 404) return const [];
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      // Charset-less application/json would decode as Latin-1 and mangle any
      // non-ASCII content, breaking the re-hashed event id.
      return parseReleaseManifest(
          utf8.decode(res.bodyBytes, allowMalformed: true), developerPubkey);
    } catch (_) {
      return null;
    }
  }

  Future<BuildIntegrityResult> run() async {
    if (!isSupported) {
      return const BuildIntegrityResult(state: BuildIntegrityState.unsupported);
    }
    final info = await measure();
    // Skip the network entirely on a Play install: nothing it returned could
    // change the answer.
    if (info != null && info.isStoreRepackaged) {
      return BuildIntegrityResult(
          state: BuildIntegrityState.storeRepackaged, info: info);
    }
    final builds = await fetchManifest();
    return describeBuildIntegrity(
      info: info,
      manifestOk: builds != null,
      builds: builds ?? const [],
    );
  }
}
