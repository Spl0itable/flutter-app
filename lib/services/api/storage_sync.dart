import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

import '../../models/settings.dart';
import '../nostr/event_signer.dart';
import 'api_client.dart';
import 'api_config.dart';

/// Cross-device storage sync against the Cloudflare `/api/storage` worker
/// (`functions/api/storage.js`). Mirrors the PWA's three storage paths:
///
///  1. **Encrypted settings sync** — `settings-set`/`settings-get` with the
///     synced settings categories encrypted to self via NIP-44, keyed by the
///     real category embedded in the blob (`__cat`). Mirrors `settings.js`
///     `_saveSettingsBlobToD1` / `settingsLoadFromD1` (the section-blob form).
///  2. **D1-first profile mirror** — `profile-get` (public batch read) and
///     `profile-set` (own kind-0 mirror). Mirrors `nostr-core.js`
///     `_fetchProfilesFromD1` / `_saveProfileToD1`.
///  3. **PM gift-wrap archive** — `pm-put` (own inbox), `pm-deposit` (recipient
///     inbox), `pm-get` (restore). Mirrors `pms.js` `_archivePMEvent` /
///     `_depositPMEvent` / `pmRestoreFromD1` / `pmLoadOlderFromD1`.
///
/// Every call is lazy and failure-tolerant: the live host is unreachable from
/// some environments, so transport errors are swallowed (the PWA wraps every
/// path in `try/catch` and treats failures as best-effort). Construction does NO
/// network. The [ApiClient] + [EventSigner] are injected so tests can drive it
/// with a MockClient and a deterministic local key.
class StorageSync {
  StorageSync({
    required ApiClient api,
    required EventSigner signer,
    required String pubkey,
    required bool durableIdentity,
  })  : _api = api,
        _signer = signer,
        _pubkey = pubkey.toLowerCase(),
        _durable = durableIdentity;

  final ApiClient _api;
  final EventSigner _signer;
  final String _pubkey;

  /// True for a logged-in (nsec/nip46/extension) identity — `isNostrLoggedIn()`
  /// in the PWA (`loginMethod != null`). Ephemeral identities skip the durable
  /// PM archive entirely (pms.js `_pmArchiveAllowed`).
  final bool _durable;

  bool get durableIdentity => _durable;

  // ===========================================================================
  // Settings categories that sync vs stay device-local.
  // ===========================================================================

  /// The settings-modal section -> core-key map the PWA splits the synced
  /// payload into (`NYM_SETTINGS_SECTION_KEYS`, settings.js:8). Each section is
  /// published as its own encrypted category `nymchat-settings-<section>` so a
  /// single change is a small write. Keys NOT in any list fall into `misc`.
  ///
  /// Only the keys the native [Settings] model actually carries are listed here
  /// (the PWA syncs many more localStorage-backed prefs; the native model is a
  /// subset). Each value is the JSON key written into the blob, matching the
  /// PWA payload field name (`_buildSettingsPayload`).
  static const Map<String, List<String>> syncedSectionKeys = {
    'appearance': [
      'theme',
      'sound',
      'autoscroll',
      'showTimestamps',
      'timeFormat',
      'dateFormat',
      'chatLayout',
      'chatViewMode',
      'columnsLayout', // carried for parity; native columns layout is empty
      'columnsWallpaper',
      'nickStyle',
      'colorMode',
      'wallpaperType',
      'textSize',
      'transparencyEnabled',
    ],
    'privacy': [
      'dmForwardSecrecyEnabled',
      'dmTTLSeconds',
      'readReceiptsEnabled',
      'readReceiptsScope',
      'typingIndicatorsEnabled',
      'typingIndicatorsScope',
      'acceptPMs',
      'acceptCalls',
      'showStatus',
    ],
    'messaging': [
      'groupChatPMOnlyMode',
      'translateLanguage',
      'gesturesEnabled',
      'swipeLeftAction',
      'swipeRightAction',
      'swipeThreshold',
      'swipeReactEmoji',
      'notificationsEnabled',
      'syncMLSHistory',
    ],
    'channels': [
      'sortByProximity',
      'pinnedLandingChannel', // default landing channel ({type,geohash} object)
    ],
    'data': [
      'lowDataMode',
      'cachePMs',
    ],
  };

  /// Settings that stay DEVICE-LOCAL and are never published (verified against
  /// settings.js): the keypair mode and identity factors (`keypairMode`,
  /// `encryptAtRestPreferred` are sync'd by the PWA but are device-setup hints,
  /// and the native model doesn't expose them), the at-rest vault, and
  /// `textSize` is treated by the native model as appearance — but `blurImages`
  /// (image blur) and `powDifficulty` are stored purely in KV and not part of
  /// the typed [Settings] sync surface here. Exposed for tests/documentation.
  ///
  /// NOTE: the PWA *does* sync `textSize`; we include it under `appearance`
  /// above for parity. The genuinely-local set below is what we deliberately
  /// exclude from the sync blob.
  static const Set<String> deviceLocalKeys = {
    'keypairMode', // identity behavior, set per-device
    'powDifficulty', // KV-only, not in typed Settings sync surface
    'blurImages', // image-blur, KV-only (nym_blur_others_images)
    'hideNonPinned', // KV-only sidebar pref
    'encryptAtRestPreferred', // per-device at-rest factor hint
    'vault', // keypair/secret material never leaves the device
  };

  /// The category name for a section, matching the PWA's d-tag form
  /// `nymchat-settings-<section>` (settings.js:566). The PWA further hashes this
  /// into an opaque per-account D1 column (`_d1Category`) and rides the real
  /// name inside the encrypted blob as `__cat`; we keep the same blob shape but
  /// use the cleartext category as the column (the worker accepts any
  /// `nymchat-[a-z0-9-]{1,120}` category, storage.js:493) so a fresh native
  /// install and the PWA can both read each other's rows.
  // TODO(verify): the PWA uses the *hashed* opaque category as the D1 column
  // (`_d1Category` = `nymchat-<sha256(pubkey:d1:dTag)>`). Using the cleartext
  // category here is simpler and still valid per the worker regex, but does NOT
  // byte-match the PWA's column name, so PWA<->native settings rows won't
  // cross-read until the hashed-category scheme is mirrored. Settings still sync
  // across native devices. Confirm whether cross-client read is required.
  static String sectionCategory(String section) => 'nymchat-settings-$section';

  // ===========================================================================
  // Encrypted settings sync.
  // ===========================================================================

  /// Builds the per-section settings payloads from a [Settings] snapshot,
  /// matching the PWA field names (`_buildSettingsPayload` +
  /// `_splitSettingsBySection`). Each section carries `v: 2` like the PWA.
  /// Returns `{ '<section>': { ...fields } }`.
  ///
  /// [pinnedLandingChannelJson] is the default-landing-channel choice
  /// (`nym_pinned_landing_channel`, the `{"type":"geohash","geohash":"…"}` JSON
  /// the PWA stores) read from KV by the caller. It is NOT a typed [Settings]
  /// field, so it is threaded in separately; when non-null and parseable it is
  /// emitted into the `channels` section as the same `{type,geohash}` OBJECT the
  /// PWA syncs (`pinnedLandingChannel`, settings.js:21,116). A null/blank/invalid
  /// value omits it (the section then only carries the other channels keys),
  /// keeping every existing caller (which passes nothing) byte-identical.
  static Map<String, Map<String, dynamic>> buildSectionPayloads(
    Settings s, {
    String? pinnedLandingChannelJson,
  }) {
    // The flat synced payload (PWA `_buildSettingsPayload`, subset the native
    // model owns). Booleans/strings/ints map 1:1 to the PWA field names.
    final flat = <String, dynamic>{
      'theme': s.theme.id,
      'sound': s.sound,
      'autoscroll': s.autoscroll,
      'showTimestamps': s.showTimestamps,
      'timeFormat': s.timeFormat,
      'dateFormat': s.dateFormat,
      'chatLayout': s.chatLayout,
      'chatViewMode': s.chatViewMode,
      'columnsLayout': const <dynamic>[],
      'columnsWallpaper': s.columnsWallpaper,
      'nickStyle': s.nickStyle,
      'colorMode': s.colorMode.name,
      'wallpaperType': s.wallpaperType,
      'textSize': s.textSize,
      'transparencyEnabled': s.transparencyEnabled,
      'dmForwardSecrecyEnabled': s.dmForwardSecrecyEnabled,
      'dmTTLSeconds': s.dmTtlSeconds,
      'readReceiptsEnabled': s.readReceiptsScope != 'disabled',
      'readReceiptsScope': s.readReceiptsScope,
      'typingIndicatorsEnabled': s.typingIndicatorsScope != 'disabled',
      'typingIndicatorsScope': s.typingIndicatorsScope,
      'acceptPMs': s.acceptPMs,
      'acceptCalls': s.acceptCalls,
      'showStatus': _showStatusForSync(s.showStatus),
      'groupChatPMOnlyMode': s.groupChatPMOnlyMode,
      'translateLanguage': s.translateLanguage,
      'gesturesEnabled': s.gesturesEnabled,
      'swipeLeftAction': s.swipeLeftAction,
      'swipeRightAction': s.swipeRightAction,
      'swipeThreshold': s.swipeThreshold,
      'swipeReactEmoji': s.swipeReactEmoji,
      'notificationsEnabled': s.notificationsEnabled,
      'syncMLSHistory': s.syncMLSHistory,
      'sortByProximity': s.sortByProximity,
      'lowDataMode': s.lowDataMode,
      'cachePMs': s.cachePMs,
    };

    // Default landing channel: not a typed [Settings] field (KV-only), threaded
    // in by the caller as JSON. Emit the same `{type,geohash}` OBJECT the PWA
    // syncs (`pinnedLandingChannel`, settings.js:116) so the inbound apply on
    // another device restores it. Drop a blank/invalid value (boot then defaults
    // to `nymchat`); the `lookup` below routes it into the `channels` section.
    final landing = _parsePinnedLandingChannel(pinnedLandingChannelJson);
    if (landing != null) {
      flat['pinnedLandingChannel'] = landing;
    }

    final lookup = <String, String>{};
    syncedSectionKeys.forEach((section, keys) {
      for (final k in keys) {
        lookup[k] = section;
      }
    });

    final out = <String, Map<String, dynamic>>{};
    flat.forEach((key, value) {
      final section = lookup[key] ?? 'misc';
      (out[section] ??= <String, dynamic>{'v': 2})[key] = value;
    });
    return out;
  }

  /// `showStatus` is normalized to `true | false | 'friends'` for the wire
  /// (settings.js:154).
  static dynamic _showStatusForSync(String showStatus) {
    if (showStatus == 'false') return false;
    if (showStatus == 'friends') return 'friends';
    return true;
  }

  /// Parses the persisted landing-channel JSON
  /// (`{"type":"geohash","geohash":"…"}`) into the normalized `{type,geohash}`
  /// Map the PWA syncs (`pinnedLandingChannel`, settings.js:116). Returns null
  /// when [raw] is null/blank, isn't a JSON object, or lacks a non-empty
  /// `geohash` string (so an absent/corrupt value is simply omitted from the
  /// payload). Mirrors `LandingChannel.tryParse` in settings_helpers.dart: a
  /// missing `type` defaults to `'geohash'`.
  static Map<String, dynamic>? _parsePinnedLandingChannel(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final m = jsonDecode(trimmed);
      if (m is Map && m['geohash'] is String && (m['geohash'] as String).isNotEmpty) {
        final type = m['type'] is String ? m['type'] as String : 'geohash';
        return {'type': type, 'geohash': m['geohash'] as String};
      }
    } catch (_) {
      // Corrupt JSON — omit rather than poison the channels section.
    }
    return null;
  }

  /// Publishes the synced settings sections to D1. For each section it encrypts
  /// the blob (NIP-44 to self) with the real category embedded as `__cat`,
  /// computes the `contentHash` (sha256 of `pubkey|blob-plaintext`) the worker
  /// uses to no-op unchanged writes, and POSTs `settings-set`.
  ///
  /// Returns the set of section names that were sent (changed since last call).
  /// All failures are swallowed; an unchanged section (same content hash) is
  /// skipped without a network call. Mirrors `_saveSettingsBlobToD1`.
  ///
  /// [pinnedLandingChannelJson] is the KV-stored default-landing-channel choice
  /// (not a typed [Settings] field); the caller reads it via
  /// `SettingsController.pinnedLandingChannelJson` and passes it so it rides the
  /// `channels` section like the PWA (settings.js:21,116). Omitting it (the
  /// current callers) leaves the `channels` section landing-channel-free.
  Future<Set<String>> settingsSet(
    Settings settings, {
    String? pinnedLandingChannelJson,
  }) async {
    final sent = <String>{};
    final sections = buildSectionPayloads(
      settings,
      pinnedLandingChannelJson: pinnedLandingChannelJson,
    );
    for (final entry in sections.entries) {
      final category = sectionCategory(entry.key);
      final ok = await _setSettingsCategory(category, jsonEncode(_withCat(
        entry.value,
        category,
      )));
      if (ok) sent.add(entry.key);
    }
    return sent;
  }

  /// Embeds the real category into the (to-be-encrypted) blob as `__cat`
  /// (settings.js:720) so the cleartext D1 column can stay opaque.
  Map<String, dynamic> _withCat(Map<String, dynamic> payload, String category) {
    return {...payload, '__cat': category};
  }

  /// In-memory content-hash cache so an unchanged section skips the write
  /// (the PWA persists this in localStorage as `nym_settings_hash_*`).
  final Map<String, String> _lastSettingsHash = {};

  Future<bool> _setSettingsCategory(String category, String plaintext) async {
    try {
      final hash = _sha256Hex('$_pubkey|$plaintext');
      final hashKey = '${_pubkey}_$category';
      if (_lastSettingsHash[hashKey] == hash) return false; // unchanged

      final blob = await _encryptToSelf(plaintext);
      if (blob == null) return false;

      final body = <String, dynamic>{
        'action': 'settings-set',
        'pubkey': _pubkey,
        'category': category,
        'blob': blob,
        'contentHash': hash,
        'auth': await _auth('settings-set'),
      };
      await _api.storageAction(body);
      _lastSettingsHash[hashKey] = hash;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Loads encrypted settings categories from D1 and decodes them into a merged
  /// payload + the newest `updatedAt` (ms) across the applied core sections.
  ///
  /// Mirrors `settingsLoadFromD1`: each category's blob is decrypted, the real
  /// category recovered from `__cat`, the section blobs applied oldest-to-newest
  /// (newest values win). Returns null on any failure / no record so the caller
  /// keeps the device-local settings. The caller is responsible for honoring
  /// `nym_last_settings_sync_ts` (only apply when [SettingsLoadResult.newestTs]
  /// exceeds the stored sync ts).
  Future<SettingsLoadResult?> settingsGet() async {
    Map<String, dynamic> data;
    try {
      data = await _api.storageAction({
        'action': 'settings-get',
        'pubkey': _pubkey,
        'auth': await _auth('settings-get'),
      });
    } catch (_) {
      return null;
    }
    final cats = data['categories'];
    if (cats is! Map) return null;

    final decoded = <_DecodedCategory>[];
    for (final e in cats.entries) {
      final entry = e.value;
      if (entry is! Map) continue;
      final blob = entry['blob'];
      if (blob is! String || blob.isEmpty) continue;
      final updatedAt = (entry['updatedAt'] as num?)?.toInt() ?? 0;
      try {
        final plain = await _decryptFromSelf(blob);
        if (plain == null) continue;
        final payload = jsonDecode(plain);
        if (payload is! Map<String, dynamic>) continue;
        final realCat =
            payload['__cat'] is String ? payload['__cat'] as String : e.key.toString();
        payload.remove('__cat');
        decoded.add(_DecodedCategory(
          category: realCat,
          payload: payload,
          updatedAt: updatedAt,
        ));
      } catch (_) {
        // Skip an undecryptable/corrupt category.
      }
    }
    if (decoded.isEmpty) return null;

    bool isCore(String c) =>
        c == 'nymchat-settings' || c.startsWith('nymchat-settings-');

    // Section blobs are authoritative: apply oldest-to-newest so the most
    // recently saved value wins; fall back to the legacy monolithic blob only
    // when no section blobs exist (settings.js:824).
    final core = decoded.where((d) => isCore(d.category)).toList();
    final sections = core.where((d) => d.category != 'nymchat-settings').toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final toApply = sections.isNotEmpty
        ? sections
        : core.where((d) => d.category == 'nymchat-settings').toList();
    if (toApply.isEmpty) return null;

    final merged = <String, dynamic>{};
    var newestTs = 0;
    for (final d in toApply) {
      merged.addAll(d.payload);
      if (d.updatedAt > newestTs) newestTs = d.updatedAt;
    }
    return SettingsLoadResult(payload: merged, newestTs: newestTs);
  }

  /// Fetches inbound settings-transfer offers: the per-section encrypted
  /// settings categories in D1 whose `updatedAt` is newer than [sinceMs] (the
  /// stored `nym_last_settings_sync_ts`, in ms). These are settings another of
  /// the user's devices published that this device hasn't applied yet — the
  /// inbound side of the cross-device settings sync (settings.js
  /// `settingsLoadFromD1`, surfaced here as discrete accept/decline offers rather
  /// than auto-applied).
  ///
  /// Each offer carries the real section name, the decrypted payload (PWA field
  /// names, `__cat` stripped) and its `updatedAt` (ms), newest-first. Returns an
  /// empty list on any failure / when nothing is newer than [sinceMs]. The
  /// legacy monolithic `nymchat-settings` blob is included as a single offer
  /// only when no section blobs exist (mirroring `settingsGet`'s fallback).
  Future<List<SettingsTransferOffer>> settingsTransfersSince(int sinceMs) async {
    Map<String, dynamic> data;
    try {
      data = await _api.storageAction({
        'action': 'settings-get',
        'pubkey': _pubkey,
        'auth': await _auth('settings-get'),
      });
    } catch (_) {
      return const [];
    }
    final cats = data['categories'];
    if (cats is! Map) return const [];

    final decoded = <_DecodedCategory>[];
    for (final e in cats.entries) {
      final entry = e.value;
      if (entry is! Map) continue;
      final blob = entry['blob'];
      if (blob is! String || blob.isEmpty) continue;
      final updatedAt = (entry['updatedAt'] as num?)?.toInt() ?? 0;
      try {
        final plain = await _decryptFromSelf(blob);
        if (plain == null) continue;
        final payload = jsonDecode(plain);
        if (payload is! Map<String, dynamic>) continue;
        final realCat = payload['__cat'] is String
            ? payload['__cat'] as String
            : e.key.toString();
        payload.remove('__cat');
        decoded.add(_DecodedCategory(
          category: realCat,
          payload: payload,
          updatedAt: updatedAt,
        ));
      } catch (_) {
        // Skip an undecryptable/corrupt category.
      }
    }
    if (decoded.isEmpty) return const [];

    bool isCore(String c) =>
        c == 'nymchat-settings' || c.startsWith('nymchat-settings-');
    final core = decoded.where((d) => isCore(d.category)).toList();
    final sections =
        core.where((d) => d.category != 'nymchat-settings').toList();
    final source = sections.isNotEmpty
        ? sections
        : core.where((d) => d.category == 'nymchat-settings').toList();

    final offers = <SettingsTransferOffer>[];
    for (final d in source) {
      if (d.updatedAt <= sinceMs) continue;
      final section = d.category.startsWith('nymchat-settings-')
          ? d.category.substring('nymchat-settings-'.length)
          : d.category;
      offers.add(SettingsTransferOffer(
        id: d.category,
        section: section,
        payload: d.payload,
        updatedAt: d.updatedAt,
      ));
    }
    offers.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return offers;
  }

  // ===========================================================================
  // D1-first profile mirror.
  // ===========================================================================

  /// Per-pubkey TTL cache of profiles already served from D1 so repeat lookups
  /// skip the round-trip (`_d1ProfileCache`, nostr-core.js:210). Value is the ms
  /// timestamp it was cached at.
  final Map<String, int> _profileCacheAt = {};
  static const int _profileCacheTtlMs = 5 * 60 * 1000;

  /// Batch-reads kind-0 profiles from D1 for [pubkeys] (public, unauthenticated
  /// `profile-get`, up to 100 per request). Returns the signed kind-0 events
  /// keyed by pubkey for the ones D1 had — the caller routes each through the
  /// normal kind-0 ingest path so the `kind0Ts` dedup keeps relay updates
  /// authoritative, then falls back to a relay REQ for the missing pubkeys
  /// (`_flushProfileBatch`, nostr-core.js:1784).
  ///
  /// Honors the in-memory TTL cache: already-fresh pubkeys are reported as
  /// "found" (so the caller won't re-REQ them) but are not re-fetched. Failures
  /// resolve to an empty map (caller falls back to relays).
  Future<Map<String, Map<String, dynamic>>> profileGet(
    List<String> pubkeys,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final toFetch = <String>[];
    final foundFromCache = <String>{};
    for (final raw in pubkeys) {
      final pk = raw.toLowerCase();
      if (!_isHex64(pk)) continue;
      final at = _profileCacheAt[pk];
      if (at != null && now - at < _profileCacheTtlMs) {
        foundFromCache.add(pk);
        continue;
      }
      toFetch.add(pk);
    }
    final batch = toFetch.take(100).toList();
    final out = <String, Map<String, dynamic>>{};
    // Report cache hits so the caller skips them; no event to return for those.
    for (final pk in foundFromCache) {
      out.putIfAbsent(pk, () => const {});
    }
    if (batch.isEmpty) return out;

    StorageStream stream;
    try {
      // profile-get is a PUBLIC read (no auth, storage.js:589).
      stream = await _api.storageStream({
        'action': 'profile-get',
        'pubkeys': batch,
      });
    } catch (_) {
      return out;
    }
    for (final item in stream.items) {
      // Each line is `[pubkey, rec]` where rec is `{event, updatedAt}` or null.
      if (item is! List || item.length < 2) continue;
      final pk = item[0];
      final rec = item[1];
      if (pk is! String) continue;
      if (rec is! Map) continue;
      final event = rec['event'];
      if (event is! Map) continue;
      out[pk.toLowerCase()] = Map<String, dynamic>.from(event);
      _profileCacheAt[pk.toLowerCase()] = now;
    }
    return out;
  }

  /// Marks [pubkey] as freshly cached (called after a relay/own kind-0 arrives
  /// so a D1 read isn't issued for a profile we already have).
  void markProfileCached(String pubkey) {
    _profileCacheAt[pubkey.toLowerCase()] =
        DateTime.now().millisecondsSinceEpoch;
  }

  /// Mirrors a signed own kind-0 profile event to D1 (`profile-set`) in addition
  /// to the relay publish, so other clients get a fast public read
  /// (`_saveProfileToD1`, nostr-core.js:194). [signedEvent] is the full signed
  /// kind-0 event JSON. Best-effort; failures are swallowed.
  Future<void> profileSet(Map<String, dynamic> signedEvent) async {
    try {
      await _api.storageAction({
        'action': 'profile-set',
        'pubkey': _pubkey,
        'event': signedEvent,
        'auth': await _auth('profile-set'),
      });
      final id = signedEvent['id'];
      if (id is String) markProfileCached(_pubkey);
    } catch (_) {
      // Best-effort mirror.
    }
  }

  // ===========================================================================
  // PM gift-wrap archive (durable identities only).
  // ===========================================================================

  /// Processed wrap-id set so a wrap is uploaded at most once per session
  /// (`_pmArchivedIds`, pms.js:1415). Capped like the PWA (6000 → trim to 4000).
  final Set<String> _archivedIds = {};
  final Set<String> _depositedIds = {};

  /// Uploads gift wraps addressed to us into our own D1 inbox (`pm-put`) so a
  /// new device can restore them. No-op for ephemeral identities. [wraps] are
  /// full signed kind-1059 events; only wraps p-tagged to us and not already
  /// uploaded this session are sent. Returns the count actually sent.
  Future<int> pmPut(List<Map<String, dynamic>> wraps) async {
    if (!_durable) return 0;
    final batch = <Map<String, dynamic>>[];
    for (final w in wraps) {
      final id = w['id'];
      if (id is! String || id.isEmpty) continue;
      if (!_addressedTo(w, _pubkey)) continue;
      if (_archivedIds.contains(id)) continue;
      _archivedIds.add(id);
      batch.add(w);
    }
    _trim(_archivedIds);
    if (batch.isEmpty) return 0;
    try {
      await _api.storageAction({
        'action': 'pm-put',
        'pubkey': _pubkey,
        'events': batch.take(100).toList(),
        'auth': await _auth('pm-put'),
      });
      return batch.length;
    } catch (_) {
      return 0;
    }
  }

  /// Deposits a recipient-addressed wrap into the *recipient's* inbox
  /// (`pm-deposit`) so they can restore it even if they were offline when we
  /// sent it (`_depositPMEvent`, pms.js:1449). Skips wraps addressed to
  /// ourselves. No-op for ephemeral identities. Returns the count sent.
  Future<int> pmDeposit(List<Map<String, dynamic>> wraps) async {
    if (!_durable) return 0;
    final batch = <Map<String, dynamic>>[];
    for (final w in wraps) {
      final id = w['id'];
      if (id is! String || id.isEmpty) continue;
      final recipient = _recipientOf(w);
      if (recipient == null || recipient == _pubkey) continue;
      if (_depositedIds.contains(id)) continue;
      _depositedIds.add(id);
      batch.add(w);
    }
    _trim(_depositedIds);
    if (batch.isEmpty) return 0;
    try {
      await _api.storageAction({
        'action': 'pm-deposit',
        'pubkey': _pubkey,
        'events': batch.take(100).toList(),
        'auth': await _auth('pm-deposit'),
      });
      return batch.length;
    } catch (_) {
      return 0;
    }
  }

  /// Oldest restored wrap ts (`_pmD1OldestTs`) + an end-of-history flag
  /// (`_pmD1NoMore`) driving the pager (pms.js:1502).
  int? _pmOldestTs;
  bool _pmNoMore = false;

  /// Restores archived gift wraps from our D1 inbox (`pm-get`), newest first.
  /// Returns the parsed wrap events sorted oldest-to-newest, deduped against the
  /// session's processed-id set so the same wrap isn't re-applied. No-op (empty
  /// list) for ephemeral identities. Updates the pager state so
  /// [pmLoadOlderFromD1] can continue. Mirrors `_pmRestoreD1Page`.
  Future<List<Map<String, dynamic>>> pmGet({
    int since = 0,
    int before = 0,
    int limit = 200,
  }) async {
    if (!_durable) return const [];
    StorageStream stream;
    try {
      stream = await _api.storageStream({
        'action': 'pm-get',
        'pubkey': _pubkey,
        'since': since,
        if (before > 0) 'before': before,
        'limit': limit,
        'auth': await _auth('pm-get'),
      });
    } catch (_) {
      return const [];
    }
    final events = <Map<String, dynamic>>[];
    for (final item in stream.items) {
      if (item is! Map) continue;
      final id = item['id'];
      if (id is! String || id.isEmpty) continue;
      if (_archivedIds.contains(id)) continue;
      _archivedIds.add(id);
      events.add(Map<String, dynamic>.from(item));
    }
    _trim(_archivedIds);
    // End-of-history when the worker says no more OR the page was short.
    if (!stream.hasMore || events.length < limit) _pmNoMore = true;
    events.sort((a, b) => _createdAt(a).compareTo(_createdAt(b)));
    if (events.isNotEmpty) {
      final oldest = _createdAt(events.first);
      if (oldest > 0 && (_pmOldestTs == null || oldest < _pmOldestTs!)) {
        _pmOldestTs = oldest;
      }
    }
    return events;
  }

  /// Restores the initial backlog (up to 5 pages of 200, newest first), the
  /// boot-time `pmRestoreFromD1` (pms.js:1500). Returns the combined wraps
  /// (oldest-to-newest). Resets the pager state.
  Future<List<Map<String, dynamic>>> pmRestoreFromD1() async {
    if (!_durable) return const [];
    _pmOldestTs = null;
    _pmNoMore = false;
    const maxPages = 5;
    var before = 0;
    final all = <Map<String, dynamic>>[];
    for (var page = 0; page < maxPages; page++) {
      final got = await pmGet(before: before, limit: 200);
      all.addAll(got);
      if (got.isEmpty || _pmNoMore || _pmOldestTs == null) break;
      before = _pmOldestTs!;
    }
    return all;
  }

  /// Loads the next older page when a conversation is scrolled back
  /// (`pmLoadOlderFromD1`, pms.js:1514). Returns an empty list when there's no
  /// more history.
  Future<List<Map<String, dynamic>>> pmLoadOlderFromD1() async {
    if (_pmNoMore || _pmOldestTs == null) return const [];
    return pmGet(before: _pmOldestTs!, limit: 200);
  }

  /// Restores group history from the *ephemeral-key* D1 inbox: group messages
  /// other members sent are gift-wrapped to our per-group ephemeral keys and
  /// deposited under those keys, so they only rehydrate via a `pm-get` keyed by
  /// `pubkeys` (NOT our real pubkey). Mirrors `_recoverEphemeralHistory`
  /// (relays.js:2631): a PUBLIC read (no `since` gate — gift-wrap `created_at`
  /// is randomized per NIP-59 so a floor would drop most wraps), chunked to the
  /// server's 200-pubkey cap.
  ///
  /// Returns the parsed wrap events sorted oldest-to-newest, deduped against the
  /// session's processed-id set so a wrap already restored (e.g. via `pm-get`
  /// for wraps addressed to us) isn't re-applied. Unlike the other PM-archive
  /// reads this runs for ephemeral identities too — the `pubkeys` form is an
  /// unauthenticated public read and group ephemeral keys exist regardless of
  /// the login method.
  Future<List<Map<String, dynamic>>> pmGetByPubkeys(
    List<String> pubkeys,
  ) async {
    final keys = <String>[];
    final seen = <String>{};
    for (final raw in pubkeys) {
      final pk = raw.toLowerCase();
      if (!_isHex64(pk) || !seen.add(pk)) continue;
      keys.add(pk);
    }
    if (keys.isEmpty) return const [];
    final events = <Map<String, dynamic>>[];
    for (var i = 0; i < keys.length; i += 200) {
      final end = (i + 200) < keys.length ? i + 200 : keys.length;
      final chunk = keys.sublist(i, end);
      StorageStream stream;
      try {
        // Public read (withAuth === false in the PWA): no `pubkey`/`auth`.
        stream = await _api.storageStream({
          'action': 'pm-get',
          'pubkeys': chunk,
        });
      } catch (_) {
        continue;
      }
      for (final item in stream.items) {
        if (item is! Map) continue;
        final id = item['id'];
        if (id is! String || id.isEmpty) continue;
        if (_archivedIds.contains(id)) continue;
        _archivedIds.add(id);
        events.add(Map<String, dynamic>.from(item));
      }
    }
    _trim(_archivedIds);
    events.sort((a, b) => _createdAt(a).compareTo(_createdAt(b)));
    return events;
  }

  // ===========================================================================
  // Channel archive (D1 `channel-get`) — public read, no auth.
  // ===========================================================================

  /// Per-channel "last fetched" wall-clock (ms), keyed by lowercased channel
  /// name (`_channelD1FetchedAt`, channels.js:1118). Throttles re-fetches.
  final Map<String, int> _channelFetchedAt = {};

  /// Restores recent channel history from the D1 archive (`channel-get`) for
  /// [channelNames] (geohash or named-channel keys, the PWA's `geohash ||
  /// channel`). Mirrors `channelRestoreManyFromD1` (channels.js:1115):
  ///   - lowercases + de-dups the names,
  ///   - skips any fetched within the last 60s unless [force],
  ///   - caps the batch at 50 channels,
  ///   - issues one `_storageApiStream('channel-get', { channels }, false)`
  ///     (a PUBLIC read — no `pubkey`/`auth`).
  ///
  /// Returns the parsed archived events (channel messages, reactions, edits) in
  /// the order the worker streamed them. The caller replays each through the
  /// same ingest pipeline live relay events use (so dedup by id, ordering, and
  /// cosmetics all apply). Failures resolve to an empty list (best-effort; the
  /// live subscription still backfills).
  Future<List<Map<String, dynamic>>> channelGet(
    List<String> channelNames, {
    bool force = false,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final names = <String>[];
    final seen = <String>{};
    for (final raw in channelNames) {
      if (raw.isEmpty) continue;
      final name = raw.toLowerCase();
      if (!seen.add(name)) continue;
      if (!force && (_channelFetchedAt[name] ?? 0) > now - 60000) continue;
      _channelFetchedAt[name] = now;
      names.add(name);
      if (names.length >= 50) break;
    }
    if (names.isEmpty) return const [];
    StorageStream stream;
    try {
      // channel-get is a PUBLIC read (withAuth === false, channels.js:1136).
      stream = await _api.storageStream({
        'action': 'channel-get',
        'channels': names,
      });
    } catch (_) {
      return const [];
    }
    final events = <Map<String, dynamic>>[];
    for (final item in stream.items) {
      if (item is! Map) continue;
      events.add(Map<String, dynamic>.from(item));
    }
    return events;
  }

  // ===========================================================================
  // Channel activity discovery (D1 `channel-active`/`channel-active-named` +
  // `channel-activity`) — all PUBLIC reads, no auth. Mirrors channels.js
  // `fetchGeohashActivityFromD1` / `fetchNamedChannelActivityFromD1`.
  // ===========================================================================

  /// A `{ activity, last }` channel-activity result: `activity` maps a channel
  /// name → 24 hourly buckets (index 0 = current hour), `last` maps a channel
  /// name → its last-activity unix-seconds timestamp. The shape is shared by
  /// `channel-active`, `channel-active-named` and `channel-activity`
  /// (storage.js:1086/1102/1118).
  final Map<String, List<int>> _emptyActivity = const {};

  /// Discovers recently-active GEOHASH channels (kind 20000) from D1
  /// (`channel-active`, storage.js:1092) so the sidebar/explorer can surface
  /// channels the client has never opened. PUBLIC read (`withAuth === false`,
  /// channels.js:150) — no `pubkey`/`auth`. Returns `{activity, last}`; failures
  /// resolve to empty maps (best-effort, like the PWA's `.catch(() => null)`).
  Future<ChannelActivityResult> channelActive() =>
      _channelDiscover('channel-active');

  /// Discovers recently-active NAMED channels (kind 23333) from D1
  /// (`channel-active-named`, storage.js:1108). PUBLIC read (channels.js:305).
  /// Same `{activity, last}` shape as [channelActive].
  Future<ChannelActivityResult> channelActiveNamed() =>
      _channelDiscover('channel-active-named');

  Future<ChannelActivityResult> _channelDiscover(String action) async {
    Map<String, dynamic> data;
    try {
      // Public read: no pubkey/auth (channels.js passes withAuth === false).
      data = await _api.storageAction({'action': action});
    } catch (_) {
      return ChannelActivityResult(activity: _emptyActivity, last: const {});
    }
    return _parseActivity(data);
  }

  /// Per-name "last fetched" wall-clock (ms) for the spam-aware activity probe,
  /// mirroring the PWA's 30s throttle on `fetchGeohashActivityFromD1` /
  /// `fetchNamedChannelActivityFromD1`. The discovery calls themselves are
  /// edge-cached server-side so only the batched `channel-activity` lookup is
  /// throttled here, against the union of requested names.
  int _activityFetchedAt = 0;

  /// Fetches lightweight recent-activity counts for many [channelNames] at once
  /// (`channel-activity`, storage.js:1048) so the sidebar can seed unread badges
  /// from the D1 archive. PUBLIC read (channels.js:151) — no `pubkey`/`auth`.
  /// Lowercases + de-dups the names and caps the batch at the server's 200-name
  /// limit. Throttled to one fetch per 30s unless [force]. Returns
  /// `{activity, last}` (empty on failure / empty input).
  Future<ChannelActivityResult> channelActivity(
    List<String> channelNames, {
    bool force = false,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && _activityFetchedAt != 0 && now - _activityFetchedAt < 30000) {
      return ChannelActivityResult(activity: _emptyActivity, last: const {});
    }
    final names = <String>[];
    final seen = <String>{};
    for (final raw in channelNames) {
      if (raw.isEmpty) continue;
      final name = raw.toLowerCase();
      if (!seen.add(name)) continue;
      names.add(name);
      if (names.length >= 200) break; // server caps at 200 (storage.js:1052)
    }
    if (names.isEmpty) {
      return ChannelActivityResult(activity: _emptyActivity, last: const {});
    }
    _activityFetchedAt = now;
    Map<String, dynamic> data;
    try {
      data = await _api.storageAction({
        'action': 'channel-activity',
        'channels': names,
      });
    } catch (_) {
      _activityFetchedAt = 0; // allow a retry on transport failure
      return ChannelActivityResult(activity: _emptyActivity, last: const {});
    }
    return _parseActivity(data);
  }

  /// Parses a `{activity:{name:[24]}, last:{name:tsSec}}` channel-activity
  /// response into a [ChannelActivityResult]. Lowercases names; coerces bucket
  /// entries + last timestamps to ints; tolerates a malformed/absent field.
  static ChannelActivityResult _parseActivity(Map<String, dynamic> data) {
    final activity = <String, List<int>>{};
    final rawAct = data['activity'];
    if (rawAct is Map) {
      rawAct.forEach((name, buckets) {
        if (buckets is! List) return;
        activity[name.toString().toLowerCase()] = [
          for (final b in buckets) (b is num) ? b.toInt() : 0,
        ];
      });
    }
    final last = <String, int>{};
    final rawLast = data['last'];
    if (rawLast is Map) {
      rawLast.forEach((name, ts) {
        if (ts is num && ts > 0) last[name.toString().toLowerCase()] = ts.toInt();
      });
    }
    return ChannelActivityResult(activity: activity, last: last);
  }

  // ===========================================================================
  // Other users' active shop items (D1 `shop-status`) — PUBLIC read, no auth.
  // Mirrors shop.js `_flushShopStatusQueue` (the batched cosmetics lookup that
  // backs `getUserShopItems(pubkey)` / `getFlairForUser(pubkey)`).
  // ===========================================================================

  /// Batch-reads other users' active shop items from D1 (`shop-status`,
  /// storage.js:206). PUBLIC read (`withAuth === false`, shop.js:457) — no
  /// `pubkey`/`auth`. Caps the batch at the server's 100-pubkey limit and
  /// lowercases/validates the keys (storage.js:207-212). [fresh] forces a cache
  /// bypass on the server for those pubkeys (the PWA's `shop-update`-driven
  /// `invalidateShopCache`, shop.js:453); only pubkeys also present in [pubkeys]
  /// matter.
  ///
  /// Returns a map of pubkey → [ShopStatus] (`active` items + `updatedAt`) for
  /// every pubkey the server reported. Failures resolve to an empty map
  /// (best-effort; the PWA swallows the error and keeps the cached items).
  Future<Map<String, ShopStatus>> shopStatus(
    List<String> pubkeys, {
    List<String> fresh = const [],
  }) async {
    final pks = <String>[];
    final seen = <String>{};
    for (final raw in pubkeys) {
      final pk = raw.toLowerCase();
      if (!_isHex64(pk) || !seen.add(pk)) continue;
      pks.add(pk);
      if (pks.length >= 100) break; // server caps at 100 (storage.js:207)
    }
    if (pks.isEmpty) return const {};
    final freshPks = <String>[];
    final freshSeen = <String>{};
    for (final raw in fresh) {
      final pk = raw.toLowerCase();
      if (!_isHex64(pk) || !freshSeen.add(pk)) continue;
      if (seen.contains(pk)) freshPks.add(pk);
    }
    Map<String, dynamic> data;
    try {
      data = await _api.storageAction({
        'action': 'shop-status',
        'pubkeys': pks,
        if (freshPks.isNotEmpty) 'fresh': freshPks,
      });
    } catch (_) {
      return const {};
    }
    final statuses = data['statuses'];
    if (statuses is! Map) return const {};
    final out = <String, ShopStatus>{};
    statuses.forEach((pk, st) {
      if (pk is! String || st is! Map) return;
      out[pk.toLowerCase()] = ShopStatus.fromJson(st.cast<String, dynamic>());
    });
    return out;
  }

  // ===========================================================================
  // Helpers.
  // ===========================================================================

  /// The NIP-98 (kind-27235) auth event the worker's `verifyClientAuth`
  /// expects, bound to the storage endpoint + action (built via [Nip98Auth] in
  /// the ApiClient; the PWA signs the same event in `_signBotAuth`). Returns the
  /// signed event JSON for `body.auth`.
  ///
  /// Signs a kind-27235 auth event for [action] via the injected builder. Async
  /// because the builder signs through the active [EventSigner] — a NIP-46
  /// remote signer round-trips the `sign_event` RPC. Returns null when there's
  /// no builder or signing fails (auth then omitted; tolerated best-effort).
  Future<Map<String, dynamic>?> _auth(String action) async =>
      _authBuilder == null ? null : await _authBuilder!(action);

  /// Auth-event builder injected by the controller (which holds the signer).
  /// Returns the signed kind-27235 event JSON, or null. Async so it can sign via
  /// a NIP-46 remote signer (the PWA's `_signBotAuth` → `signEvent` dispatch).
  /// When null (e.g. pure tests of body shape via a pre-signed auth), callers
  /// pass `auth` themselves. Set via [setAuthBuilder].
  Future<Map<String, dynamic>?> Function(String action)? _authBuilder;

  /// Registers the async auth builder. The controller wires this to a signed
  /// kind-27235 event via the active signer — local OR NIP-46 remote, so durable
  /// remote-signer accounts now authenticate their settings/PM sync too.
  void setAuthBuilder(
    Future<Map<String, dynamic>?> Function(String action) builder,
  ) {
    _authBuilder = builder;
  }

  Future<String?> _encryptToSelf(String plaintext) async {
    try {
      return await _signer.nip44Encrypt(_pubkey, plaintext);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _decryptFromSelf(String ciphertext) async {
    try {
      return await _signer.nip44Decrypt(_pubkey, ciphertext);
    } catch (_) {
      return null;
    }
  }

  static String _sha256Hex(String s) =>
      sha256.convert(utf8.encode(s)).toString();

  static bool _isHex64(String s) =>
      s.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(s);

  static bool _addressedTo(Map<String, dynamic> wrap, String pubkey) {
    final tags = wrap['tags'];
    if (tags is! List) return false;
    for (final t in tags) {
      if (t is List && t.length > 1 && t[0] == 'p' && t[1] == pubkey) {
        return true;
      }
    }
    return false;
  }

  static String? _recipientOf(Map<String, dynamic> wrap) {
    final tags = wrap['tags'];
    if (tags is! List) return null;
    for (final t in tags) {
      if (t is List && t.length > 1 && t[0] == 'p') {
        final v = t[1];
        if (v is String && _isHex64(v.toLowerCase())) return v.toLowerCase();
      }
    }
    return null;
  }

  static int _createdAt(Map<String, dynamic> ev) =>
      (ev['created_at'] as num?)?.toInt() ?? 0;

  static void _trim(Set<String> ids) {
    if (ids.length <= 6000) return;
    final keep = ids.toList().sublist(ids.length - 4000);
    ids
      ..clear()
      ..addAll(keep);
  }

  /// The storage endpoint URL the NIP-98 `u`-tag must bind to.
  static String storageUrl() => 'https://${ApiConfig.apiHost}/api/storage';
}

/// A decoded settings category (real category + decrypted payload + updatedAt).
class _DecodedCategory {
  _DecodedCategory({
    required this.category,
    required this.payload,
    required this.updatedAt,
  });
  final String category;
  final Map<String, dynamic> payload;
  final int updatedAt;
}

/// The result of [StorageSync.settingsGet]: the merged synced-settings payload
/// and the newest `updatedAt` (ms) across the applied core sections. The caller
/// applies [payload] only when [newestTs] is newer than the stored
/// `nym_last_settings_sync_ts`.
class SettingsLoadResult {
  const SettingsLoadResult({required this.payload, required this.newestTs});
  final Map<String, dynamic> payload;
  final int newestTs;
}

/// An inbound settings-transfer offer (one synced settings section another
/// device published, newer than this device's last sync). The list UI shows
/// these as accept/decline rows; accepting applies [payload] via the settings
/// controller and advances the sync ts.
class SettingsTransferOffer {
  const SettingsTransferOffer({
    required this.id,
    required this.section,
    required this.payload,
    required this.updatedAt,
  });

  /// Stable id (the D1 category, e.g. `nymchat-settings-appearance`) — used as
  /// the accept/decline key.
  final String id;

  /// The settings-modal section name (`appearance`, `privacy`, …) or the raw
  /// category for the legacy monolithic blob.
  final String section;

  /// The decoded payload (PWA field names, `__cat` removed).
  final Map<String, dynamic> payload;

  /// The category's `updatedAt` in ms (D1 wall-clock of the publishing device).
  final int updatedAt;
}

/// The result of a channel-activity D1 read ([StorageSync.channelActive] /
/// [StorageSync.channelActiveNamed] / [StorageSync.channelActivity]). [activity]
/// maps a lowercased channel name → 24 hourly buckets (index 0 = current hour);
/// [last] maps a lowercased channel name → its last-activity unix-seconds
/// timestamp. Mirrors the `{activity, last}` payload (storage.js:1086).
class ChannelActivityResult {
  const ChannelActivityResult({required this.activity, required this.last});

  /// Channel name → 24 hourly message-count buckets (kind 20000/23333 only).
  final Map<String, List<int>> activity;

  /// Channel name → last-activity timestamp in unix seconds.
  final Map<String, int> last;

  bool get isEmpty => activity.isEmpty && last.isEmpty;
}

/// Another user's active shop items from a `shop-status` D1 read
/// (storage.js:226-237): the `active` cosmetics record + the record's
/// `updatedAt` (used to skip a re-render when nothing changed, shop.js:471).
class ShopStatus {
  const ShopStatus({required this.active, required this.updatedAt});

  final ShopStatusActive active;
  final int updatedAt;

  factory ShopStatus.fromJson(Map<String, dynamic> j) => ShopStatus(
        active: ShopStatusActive.fromJson(
          (j['active'] as Map?)?.cast<String, dynamic>(),
        ),
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

/// The `active` block of a `shop-status` record — the same `{style, flair,
/// cosmetics, supporter, editions}` shape the owner publishes via
/// `shop-set-active` (storage.js:308-314, read back at shop.js:459-467).
class ShopStatusActive {
  const ShopStatusActive({
    this.style,
    this.flair = const [],
    this.cosmetics = const [],
    this.supporter = false,
    this.editions = const {},
  });

  /// Active message-style item id, or null.
  final String? style;

  /// Active nickname-flair item ids (the PWA renders the last, shop.js:401).
  final List<String> flair;

  /// Active special-cosmetic ids.
  final List<String> cosmetics;

  /// True when the supporter badge is active.
  final bool supporter;

  /// Numbered-edition map (item id → edition number, e.g. Genesis #42).
  final Map<String, int> editions;

  factory ShopStatusActive.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const ShopStatusActive();
    return ShopStatusActive(
      style: j['style'] is String ? j['style'] as String : null,
      flair: (j['flair'] as List?)?.whereType<String>().toList() ?? const [],
      cosmetics:
          (j['cosmetics'] as List?)?.whereType<String>().toList() ?? const [],
      supporter: j['supporter'] == true,
      editions: (j['editions'] as Map?)?.map(
            (k, v) => MapEntry(k.toString(), (v is num) ? v.toInt() : 0),
          ) ??
          const {},
    );
  }
}
