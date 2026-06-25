import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/crypto/keys.dart' as keys;
import '../core/crypto/pow.dart' as pow;
import '../core/constants/event_kinds.dart';
import '../core/constants/relays.dart';
import '../core/constants/storage_keys.dart';
import '../core/utils/nym_utils.dart';
import '../features/commands/action_rate_limit.dart';
import '../features/commands/command_handler.dart';
import '../features/commands/command_registry.dart';
import '../features/emoji/custom_emoji.dart';
import '../features/groups/group_logic.dart';
import '../features/groups/group_manager.dart';
import '../features/messages/trust_graph.dart';
import '../features/notifications/notifications_service.dart';
import '../features/shop/shop_controller.dart';
import '../features/nymbot/bot_commands.dart';
import '../features/nymbot/nymbot_providers.dart';
import '../features/nymbot/nymbot_service.dart';
import '../features/p2p/p2p_models.dart';
import '../features/p2p/p2p_service.dart';
import '../features/pms/pm_logic.dart';
import '../features/polls/poll_logic.dart';
import '../features/zaps/zap_logic.dart';
import '../services/api/api_client.dart';
import '../services/api/storage_sync.dart';
import '../services/relay/relay_message.dart';
import '../services/relay/relay_pool.dart';
import '../services/relay/relay_pool_proxy.dart';
import '../services/relay/relay_stats.dart';
import '../models/channel.dart';
import '../models/group.dart';
import '../models/message.dart';
import '../models/nostr_event.dart';
import '../models/poll.dart';
import '../models/user.dart';
import '../features/identity/nip46_service.dart';
import '../services/nostr/event_mapper.dart';
import '../services/nostr/event_signer.dart';
import '../services/nostr/identity_service.dart';
import '../services/nostr/nostr_service.dart';
import '../services/nostr/nym_generator.dart';
import '../services/storage/cache_store.dart';
import '../services/storage/key_value_store.dart';
import '../services/storage/secure_store.dart';
import 'app_state.dart';
import 'settings_provider.dart';

/// The well-known "common" geohash channels seeded into the sidebar on connect
/// (PWA `this.commonGeohashes`, app.js:681). `nymchat` is the default named
/// channel; the rest are geohash channels.
const List<String> kCommonGeohashes = [
  'nymchat', '9q', 'w2', 'dr5r', '9q8y', 'u4pr', 'gcpv', 'f2m6', 'xn77', 'tjm5',
];

/// Ties identity + relay + crypto to the [AppState] store: boots an ephemeral
/// identity, connects to relays, and routes inbound events into the store. Send
/// requests from the composer flow through here.
class NostrController {
  NostrController(this._ref);

  final Ref _ref;
  Identity? _identity;
  NostrService? _service;
  GroupManager? _groups;
  EventSigner? _signer;
  bool _started = false;

  /// Cross-device storage sync (`/api/storage`): encrypted settings, D1-first
  /// profile mirror, PM gift-wrap archive. Built in [init] once the identity +
  /// signer are known. Null before boot / when the signer is unavailable. All
  /// calls through it are lazy + failure-tolerant (the live host may be
  /// unreachable; the PWA treats every storage path as best-effort).
  StorageSync? _storageSync;

  /// Shared [ApiClient] for the storage-sync paths (one instance, reused).
  ApiClient? _api;

  /// Debounce for the encrypted settings publish (settings.js
  /// `_debouncedNostrSettingsSave`, 5s).
  Timer? _settingsSyncTimer;

  /// Throttle: pubkey/groupId-scoped last typing-start send time (ms).
  final Map<String, int> _typingThrottle = {};

  /// Reaction toggle rate-limit tracker: `messageId:emoji` → timestamps within
  /// the 30s window + a cooldown-until ms (reactions.js
  /// `_checkReactionRateLimit`: 3 toggles / 30s, then 60s cooldown).
  final Map<String, _ReactionRateTracker> _reactionToggleTracker = {};

  /// Persisted message/profile/reaction cache (hydrated on boot, flushed on a
  /// debounce + on dispose). Null until [init].
  CacheStore? _cache;
  Timer? _flushTimer;
  final Set<String> _dirtyChannelKeys = {};
  final Set<String> _dirtyPmKeys = {};
  bool _flushScheduled = false;

  /// Runtime cache caps — app.js uses 1000/1000 (the persistence module's own
  /// fallbacks are 100/500; we honor the runtime values).
  static const int _channelMessageLimit = 1000;
  static const int _pmStorageLimit = 1000;

  Identity? get identity => _identity;
  bool get isLive => _identity != null;

  /// The active [EventSigner]: a [LocalSigner] for nsec/ephemeral keys, a
  /// [Nip46SignerAdapter] for a restored NIP-46 remote signer, or null before
  /// boot. Every publish / gift-wrap path flows through this.
  EventSigner? get signer => _signer;

  /// Per-relay connection status (url → connected) for the Network Stats modal
  /// (`relay_stats_modal.dart`). Direct mode reads [RelayPool.connectionStatus];
  /// proxy mode exposes its live connected set as `url → true`. Empty before boot.
  Map<String, bool> get relayConnectionStatus {
    final svc = _service;
    if (svc == null) return const {};
    final pool = svc.pool;
    if (pool is RelayPool) return pool.connectionStatus;
    if (pool is RelayPoolProxy) {
      return {for (final u in pool.connectedRelayUrls) u: true};
    }
    return const {};
  }

  /// Live relay throughput / byte / latency stats for the Network Stats modal
  /// (`relay_stats_modal.dart`), aggregated across the pool (PWA
  /// `nym.relayStats`). Null before boot → the modal renders the empty state.
  RelayStats? get relayStats => _service?.relayStats;

  // --- Slash commands -------------------------------------------------------

  /// System-message sink (`displaySystemMessage`). The composer/chat UI
  /// registers a callback to surface command feedback in the active
  /// conversation. Defaults to a debug print so commands work headless/in tests.
  void Function(String text)? _systemMessageSink;

  late final CommandDispatcher _dispatcher = CommandDispatcher(
    engine: _CommandEngineAdapter(this),
    hooks: const CommandHooks(),
    rateLimiter: ActionCommandRateLimiter(),
  );

  /// Registers the system-message sink + the optional command modal hooks.
  /// Called once by the composer when it mounts.
  void setCommandHooks({
    void Function(String text)? onSystemMessage,
    CommandHooks? hooks,
  }) {
    if (onSystemMessage != null) _systemMessageSink = onSystemMessage;
    if (hooks != null) _dispatcher.hooksOverride = hooks;
  }

  void _emitSystemMessage(String text) {
    final sink = _systemMessageSink;
    if (sink != null) {
      sink(text);
    } else {
      debugPrint('[system] $text');
    }
  }

  /// Boots the identity and starts the relay connection. Safe to call once.
  ///
  /// [unlockedSecrets] carries the in-memory decrypted vault secrets when the
  /// identity vault is enabled (passed by the boot-unlock gate) so identity
  /// restore never reads the encrypted blob at rest (native analogue of
  /// `_vaultMem`).
  Future<void> init({Map<String, String>? unlockedSecrets}) async {
    if (_started) return;
    _started = true;
    try {
      final kv = _ref.read(keyValueStoreProvider);
      final identityService =
          IdentityService(kv: kv, secure: SecureStore());

      // NIP-46 remote-signer login: restore the persisted session and build a
      // remote signer (no local key). Mirrors the PWA's `signEvent` dispatch by
      // `nostrLoginMethod === 'nip46'` (Identity has pubkey=remotePubkey,
      // privkey=null). nsec/ephemeral fall through to IdentityService.boot().
      Identity identity;
      EventSigner? signer;
      if (kv.getString(StorageKeys.nostrLoginMethod) == 'nip46') {
        final restored = await _restoreNip46Signer(kv);
        if (restored != null) {
          identity = restored.$1;
          signer = restored.$2;
        } else {
          identity =
              await identityService.boot(unlockedSecrets: unlockedSecrets);
          signer = identity.privkey != null
              ? LocalSigner(identity.privkey!)
              : null;
        }
      } else {
        // Restore a saved nsec account, else boot/reuse the ephemeral identity.
        identity = await identityService.boot(unlockedSecrets: unlockedSecrets);
        signer =
            identity.privkey != null ? LocalSigner(identity.privkey!) : null;
      }
      _identity = identity;
      _signer = signer;

      final appState = _ref.read(appStateProvider.notifier);
      appState.goLive(identity.pubkey, identity.nym);

      // Restore friends / blocked users / blocked keywords from KV.
      _hydrateSocialState(appState);

      // Touch the live custom-emoji store so it hydrates the persisted NIP-30
      // cache (`nym_custom_emojis` / `nym_custom_emoji_packs`) at boot, mirroring
      // the PWA's `_loadCustomEmojiCache`; live 30030/10030 events then top it up.
      _ref.read(liveCustomEmojiProvider);

      // Hydrate channel/profile/reaction caches before connecting (raced
      // ≤1500ms so a slow disk never blocks boot — mirrors app.js
      // `Promise.race([hydrateFromCache(), 1500ms])`).
      await _hydrateFromCache(appState).timeout(
        const Duration(milliseconds: 1500),
        onTimeout: () {},
      );

      final service = NostrService(identity: identity, signer: signer);
      _service = service;
      _groups = GroupManager(service);
      await service.start(NostrHandlers(
        onEvent: _onEvent,
        onConnectionChanged: _onConnectionChanged,
        onGiftWrap: _onGiftWrap,
      ));

      // Broadcast presence on connect, then re-assert on a timer
      // (nostr-core.js: presence on connect + on a 60s cadence).
      recordOwnActivity();
      _startPresenceTimer();

      // Seed the sidebar with the well-known common geohash channels so the
      // channel list isn't empty before the user joins anything (PWA
      // `discoverChannels`, called on connect from relays.js).
      discoverChannels();

      // Subscribe to peers' `nym-vouches` lists (web of trust). On boot the only
      // trusted authors are the seeded dev/bot roots; the graph then expands one
      // hop at a time as their vouches arrive (relays.js:2536-2542).
      _subscribeVouches();

      // Cross-device storage sync (`/api/storage`). Durable = logged-in
      // (loginMethod != null, the PWA's `isNostrLoggedIn()`); ephemeral
      // identities skip the durable PM archive. All calls are best-effort.
      _initStorageSync(identity, signer);
      unawaited(_bootStorageSync());

      // Immediately backfill the active channel's D1 archive on boot — the PWA
      // loads the current channel's (e.g. #nymchat) history right away on load,
      // not only on a later view switch (`_onViewOpened`). This MUST run after
      // `_initStorageSync` wires `_storageSync`; otherwise `_backfillChannelArchive`
      // hits its `sync == null` early-return and the default channel never loads.
      final bootView = _ref.read(appStateProvider).view;
      if (bootView.kind == ViewKind.channel) {
        unawaited(_backfillChannelArchive(bootView.id));
      }

      // Discover recently-active GEOHASH + NAMED channels from the D1 archive and
      // seed the sidebar / globe / unread floors — the PWA's
      // `fetchGeohashActivityFromD1` + `fetchNamedChannelActivityFromD1`, fired on
      // connect inside `backfillFromD1OnReconnect` (relays.js:2799-2805), NOT only
      // on a view switch. Runs after `_initStorageSync` wires `_storageSync` (it
      // no-ops otherwise). Throttled ~30s inside; also re-fired on reconnect (see
      // [_onConnectionChanged]). Best-effort; never blocks boot.
      unawaited(_discoverChannelActivity());
    } catch (e, st) {
      // Stay on seed/offline data if boot fails (e.g. no secure storage).
      debugPrint('NostrController.init failed: $e\n$st');
    }
  }

  /// Seeds the sidebar with the well-known "common" geohash channels (PWA
  /// `discoverChannels`, channels.js:598, over the `commonGeohashes` list,
  /// app.js:681). Skipped in group/PM-only mode; `addChannel` is idempotent so
  /// re-running on each connect can't duplicate rows, and `#nymchat` (always
  /// present as the default named channel) is left to the registry.
  void discoverChannels() {
    if (_ref.read(settingsProvider).groupChatPMOnlyMode) return;
    final app = _ref.read(appStateProvider.notifier);
    for (final g in kCommonGeohashes) {
      if (g == 'nymchat') continue;
      app.addChannel(g, geohash: g);
    }
  }

  /// Relay connection-count sink. Forwards the live count to [AppState] (the old
  /// direct `setConnectedRelays` binding) AND re-fires the D1 activity discovery
  /// on a 0→connected edge, mirroring the PWA, which calls
  /// `backfillFromD1OnReconnect` (→ `fetchGeohashActivityFromD1` +
  /// `fetchNamedChannelActivityFromD1`) from the connect→subscribe chain
  /// (relays.js:2761) and on every reconnect. The discovery is throttled ~30s
  /// internally so a flapping connection can't hammer the worker.
  void _onConnectionChanged(int count) {
    final wasOffline = _ref.read(appStateProvider).connectedRelays == 0;
    _ref.read(appStateProvider.notifier).setConnectedRelays(count);
    if (count > 0 && wasOffline) {
      // Reconnect edge → re-run the D1 activity discovery (PWA
      // `backfillFromD1OnReconnect`, relays.js:2761) AND re-restore the open
      // channel's archive. The latter is the retry that recovers a boot backfill
      // which ran before the storage transport was reachable: `_backfillChannelArchive`
      // forces past the freshness window, and re-ingest dedups by event id, so it
      // is safe + idempotent.
      unawaited(_discoverChannelActivity());
      final view = _ref.read(appStateProvider).view;
      if (view.kind == ViewKind.channel) {
        unawaited(_backfillChannelArchive(view.id));
      }
    }
  }

  /// Last `_discoverChannelActivity` run (ms) — the ~30s throttle the PWA applies
  /// to `fetchGeohashActivityFromD1` / `fetchNamedChannelActivityFromD1`
  /// (`_geohashActivityFetchedAt` / `_namedActivityFetchedAt`, channels.js:131).
  /// Reset to 0 on a transport failure so the next attempt retries immediately.
  int _lastActivityDiscoveryAt = 0;

  /// Discovers recently-active GEOHASH + NAMED channels from the D1 archive and
  /// seeds the in-memory store (sidebar registry + last-activity sort + unread
  /// floors), the native port of the PWA's `fetchGeohashActivityFromD1` +
  /// `fetchNamedChannelActivityFromD1` (channels.js:128/289), which run on
  /// connect (relays.js:2799-2805) so the channel list/globe surface real
  /// recency before the user opens anything.
  ///
  /// Issues all three PUBLIC reads in parallel:
  ///   * `channel-active`        — discover active GEOHASH channels,
  ///   * `channel-active-named`  — discover active NAMED channels,
  ///   * `channel-activity`      — activity buckets for the geohashes we already
  ///     know (common + sidebar + channels with stored messages),
  /// then folds each result into [AppStateNotifier.applyChannelActivity]. The
  /// discovery results carry the globe/sidebar recency; the known-activity result
  /// seeds unread floors for joined channels. Throttled ~30s, best-effort
  /// (failures are swallowed; never blocks boot). Skipped in group/PM-only mode
  /// (the sidebar channel list is hidden there, like [discoverChannels]).
  Future<void> _discoverChannelActivity() async {
    final sync = _storageSync;
    if (sync == null) return;
    if (_ref.read(settingsProvider).groupChatPMOnlyMode) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastActivityDiscoveryAt != 0 && now - _lastActivityDiscoveryAt < 30000) {
      return;
    }
    _lastActivityDiscoveryAt = now;
    try {
      final app = _ref.read(appStateProvider.notifier);

      // Known geohashes to probe (PWA gathers commonGeohashes + sidebar channels
      // + channels with stored messages, channels.js:137-144). De-duped inside
      // [StorageSync.channelActivity]; nymchat included (it's a valid geohash key
      // in the PWA's `commonGeohashes`).
      final known = <String>{...kCommonGeohashes};
      for (final c in _ref.read(appStateProvider).channels) {
        known.add(c.key);
      }
      for (final storageKey in _ref.read(appStateProvider).messages.keys) {
        if (storageKey.startsWith('#')) known.add(storageKey.substring(1));
      }

      // All three reads in parallel (PWA `Promise.all`, each best-effort). The
      // StorageSync methods already resolve failures to empty results.
      final results = await Future.wait([
        sync.channelActive(),
        sync.channelActiveNamed(),
        sync.channelActivity(known.toList()),
      ]);
      final geo = results[0];
      final named = results[1];
      final knownActivity = results[2];

      // Discovered GEOHASH channels → sidebar (as geohash entries) + last-activity.
      app.applyChannelActivity(geo.activity, geo.last, geohash: true);
      // Discovered NAMED channels → sidebar (as named entries) + last-activity.
      app.applyChannelActivity(named.activity, named.last);
      // Known channels' activity → unread floors (+ last-activity top-up). These
      // keys are already joined, so no new sidebar rows are created here.
      app.applyChannelActivity(knownActivity.activity, knownActivity.last);
    } catch (_) {
      // Best-effort: allow the next trigger (reconnect / foreground) to retry.
      _lastActivityDiscoveryAt = 0;
    }
  }

  /// Restores a persisted NIP-46 remote-signer session and builds the matching
  /// [Identity] (pubkey=remote user pubkey, privkey=null, loginMethod='nip46')
  /// + a [Nip46SignerAdapter]. Returns null if there's no session to restore or
  /// the reconnect fails (caller then falls back to ephemeral). Mirrors the
  /// PWA's `restoreSession` → remote `signEvent` dispatch.
  Future<(Identity, EventSigner)?> _restoreNip46Signer(KeyValueStore kv) async {
    try {
      final svc = _ref.read(nip46ServiceProvider);
      final ok = await svc.restoreSession();
      if (!ok || svc.pubkey.length != 64) return null;
      final pubkey = svc.pubkey;
      final nym = kv.getString(StorageKeys.customNick) ??
          kv.getString(StorageKeys.autoEphemeralNick) ??
          NymGenerator()
              .generate(pubkey, style: kv.getString(StorageKeys.nickStyle) ?? 'fancy');
      final identity = Identity(
        pubkey: pubkey,
        privkey: null,
        nym: nym,
        loginMethod: 'nip46',
      );
      return (identity, Nip46SignerAdapter(svc));
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Sign out / disconnect (app.js `signOut`, 6740). Clears the active identity +
  // in-memory secrets, drops the persisted login + auto-ephemeral state so the
  // boot gate falls back to first-run setup, disconnects relays, and resets the
  // in-memory store. The UI call site (chat_pane / sidebar) is responsible for
  // confirming and then returning to the boot/setup gate (e.g. remounting it),
  // mirroring the PWA's post-`cmdQuit` reload to a pristine first-run state.
  // ---------------------------------------------------------------------------

  /// Signs out: forgets the identity, disconnects, and resets local state.
  ///
  /// Removes the same persisted keys the PWA's `signOut()` clears
  /// (`nym_nostr_login_*`, the session/dev/login nsec secrets, the auto-ephemeral
  /// prefs, and the per-identity profile/cosmetic caches) so the next launch (or
  /// the boot gate re-check) shows the setup modal instead of restoring the old
  /// identity. Stops the relay service + presence/flush/sync timers, tears down
  /// the storage sync, and resets [AppState] plus the notification history /
  /// pending settings transfers / live custom-emoji state that were scoped to the
  /// signed-out identity. Idempotent and safe to call before [init].
  ///
  /// After this returns the controller is back in its pre-boot state ([_started]
  /// is reset), so a fresh identity created through the setup flow can [init]
  /// again on the same provider instance.
  Future<void> signOut() async {
    // 1) Tear down the live session: cancel timers, close subs, flush + close the
    //    cache, and stop the relay service. (Mirrors `cmdQuit` + the page reload
    //    dropping all in-memory NYM state.)
    _flushTimer?.cancel();
    _presenceTimer?.cancel();
    _settingsSyncTimer?.cancel();
    _vouchPublishTimer?.cancel();
    _vouchPublishTimer = null;
    _vouchExpansionTimer?.cancel();
    _vouchExpansionTimer = null;
    _trustPersistTimer?.cancel();
    _trustPersistTimer = null;
    _lastVouchPublishAt = 0;
    _profileBackfillTimer?.cancel();
    _profileBackfillTimer = null;
    _profileBackfillQueue.clear();
    _profileBackfillQueued.clear();
    _flushScheduled = false;
    _dirtyChannelKeys.clear();
    _dirtyPmKeys.clear();
    if (_p2pSub != null) {
      _service?.pool.closeSubscription(_p2pSub!);
      _p2pSub = null;
    }
    try {
      await _flush();
    } catch (_) {}
    try {
      await _cache?.close();
    } catch (_) {}
    _cache = null;
    try {
      await _service?.stop();
    } catch (_) {}
    _api?.dispose();
    _api = null;
    // Drop any cached signed kind-27235 auth so the next identity never reuses
    // the previous one's auth event (the cache is keyed by pubkey, but clear it
    // explicitly on identity teardown to be safe).
    Nip98Auth.clearAuthCache();

    // 2) Drop in-memory identity + signer + group/service/storage-sync handles
    //    (panic.js: `this.privkey = null; this.pubkey = null; … _vaultMem = null`).
    _identity = null;
    _signer = null;
    _service = null;
    _groups = null;
    _storageSync = null;
    _lastPresenceBroadcast = 0;
    _presenceTimestamps.clear();
    _typingThrottle.clear();
    _sentChannelReadReceipts.clear();
    _reactionToggleTracker.clear();

    // 3) Stop syncing settings on change (the binding captured the old signer).
    _ref.read(settingsProvider.notifier).onSyncedChange = null;
    // Stop backfilling on view-open (the binding captured the old storage sync).
    _ref.read(appStateProvider.notifier).onViewOpened = null;

    // 4) Remove the persisted login + auto-ephemeral + per-identity caches the
    //    PWA's `signOut()` clears (app.js:6743-6761).
    final kv = _ref.read(keyValueStoreProvider);
    for (final k in const [
      StorageKeys.autoEphemeral,
      StorageKeys.autoEphemeralNick,
      StorageKeys.autoEphemeralChannel,
      StorageKeys.randomKeypairPerSession,
      StorageKeys.colorMode,
      StorageKeys.purchasesCache,
      StorageKeys.activeStyle,
      StorageKeys.activeFlair,
      StorageKeys.nostrLoginMethod,
      StorageKeys.nostrLoginPubkey,
      StorageKeys.nostrLoginNpub,
      StorageKeys.nostrLoginProfile,
      StorageKeys.nip46RemotePubkey,
      StorageKeys.bio,
      StorageKeys.lightningAddressGlobal,
      StorageKeys.avatarUrl,
      StorageKeys.bannerUrl,
      StorageKeys.customNick,
    ]) {
      await kv.remove(k);
    }
    // Identity secrets live in the platform keystore (the PWA's `nymSecretRemove`
    // → vault). Clear the session/dev/login keys; leave the NIP-46 client secret
    // removal to the keystore wipe so a half-removed key can't linger.
    final secure = SecureStore();
    for (final s in SecretKeys.all) {
      try {
        await secure.remove(s);
      } catch (_) {}
    }

    // 5) Reset the in-memory store + identity-scoped UI state.
    _ref.read(appStateProvider.notifier).reset();
    try {
      _ref.read(notificationHistoryProvider.notifier).clear();
    } catch (_) {}
    try {
      _ref.read(pendingSettingsTransfersProvider.notifier).clear();
    } catch (_) {}
    try {
      _ref.read(liveCustomEmojiProvider.notifier).clearAll();
    } catch (_) {}

    // 6) Allow a fresh identity to boot again on this provider instance.
    _started = false;

    // 7) Drive the UI back to a pristine first-run gate. The PWA reloads the
    //    page here; we bump the boot generation so `app.dart` remounts a fresh
    //    BootGate (which re-checks setup-needed — now true — and tears down the
    //    signed-out HomeShell + any modals stacked above it).
    _ref.read(bootEpochProvider.notifier).state++;
  }

  MessagingSettings get _msgSettings {
    final s = _ref.read(settingsProvider);
    return MessagingSettings(
      dmForwardSecrecyEnabled: s.dmForwardSecrecyEnabled,
      dmTtlSeconds: s.dmTtlSeconds,
    );
  }

  bool _readReceiptsAllowed() =>
      _ref.read(settingsProvider).readReceiptsScope != 'disabled';

  // ---------------------------------------------------------------------------
  // Inbound routing
  // ---------------------------------------------------------------------------

  void _onEvent(NostrEvent event) {
    final appState = _ref.read(appStateProvider.notifier);
    if (event.kind == EventKind.appData) {
      // Kind 30078 is multiplexed by the `['t', ...]` topic (nostr-core.js:
      // 570-577 dispatches on `tTag[1]`): presence / poll / poll-vote / vouches.
      final topic = event.tagValue('t');
      if (topic == AppDataTopic.vouches) {
        _ingestVouch(event);
      } else {
        _ingestPresence(event);
      }
      return;
    }
    // NIP-30 custom emoji packs / the user's emoji-pack list (nostr-core.js:595).
    if (event.kind == EventKind.emojiPack) {
      _ingestEmojiPack(event);
      return;
    }
    if (event.kind == EventKind.userEmojiList) {
      _ingestUserEmojiList(event);
      return;
    }
    // Public channel read receipt (kind 24421) — someone saw one of our channel
    // messages. Ephemeral; routed here from the active channel's typing/receipt
    // sub. Channel typing (24420) inbound is handled elsewhere.
    if (event.kind == EventKind.channelReceipt) {
      _onChannelReadReceipt(event);
      return;
    }
    // A live kind-0 from relays refreshes the D1 profile cache so we don't
    // re-issue a `profile-get` for a profile we just received (mirrors the PWA's
    // `profileFetchedAt` freshness gate).
    if (event.kind == EventKind.profile) {
      _storageSync?.markProfileCached(event.pubkey);
    }
    appState.ingestEvent(event);
    // Public reaction (kind 7) to our message → notify + record (reactions.js
    // `handleReaction` notify block). Skip removals.
    if (event.kind == EventKind.reaction) {
      final removed =
          event.tagsNamed('action').any((t) => t.length > 1 && t[1] == 'remove');
      // Resolve the REACTOR's D1 profile so the reactors sheet (and any future
      // surface) shows their custom avatar, not the identicon — the PWA resolves
      // list/reaction author avatars too (`ensureListProfiles`, reactions.js:631).
      // Guarded + debounced inside; a no-op once we know their picture.
      if (!removed) _maybeBackfillProfiles(event.pubkey);
      if (!removed) {
        final target = event.tagValue('e');
        final author = event.tagValue('p');
        if (target != null && author != null) {
          _maybeNotifyReaction(
            messageId: target,
            reactorPubkey: event.pubkey,
            targetAuthorPubkey: author,
            emoji: event.content,
            tsSec: event.createdAt,
            eventId: event.id,
            route: event.pubkey,
          );
        }
      }
    }
    // Channel-message notification: a public channel message that @-mentions us
    // (nostr-core.js channel `shouldNotify`). Runs after ingest so the store is
    // current; gating happens in `_maybeNotifyChannel`.
    if (event.kind == EventKind.geoChannel ||
        event.kind == EventKind.namedChannel) {
      // Register any NIP-30 custom emoji declared on the message so its
      // `:shortcode:` tokens render as images (emoji.js `ingestEmojiTags`).
      if (event.tags.isNotEmpty) {
        _ref.read(liveCustomEmojiProvider.notifier).ingestEmojiTags(event.tags);
      }
      // Register an inbound P2P file offer with the service so the rendered
      // file-offer card's download button can request it (nostr-core.js:434 —
      // `parseFileOfferTag` populates `p2pFileOffers`, the store `requestP2PFile`
      // reads). The mapper sets the message's isFileOffer/fileOffer (so the card
      // renders); this side makes the card actionable. Skip our own echo — the
      // offer is registered at share time by `shareP2PFile`.
      if (event.pubkey != (_identity?.pubkey ?? '')) {
        final offer = parseFileOfferTag(event.tags, event.pubkey);
        if (offer != null) {
          _ref.read(p2pServiceProvider).registerOffer(offer);
        }
      }
      _maybeNotifyChannel(event);

      // Web-of-trust observation for a non-own channel message (nostr-core.js:
      // 383-392). Two effects:
      //  (1) ≥2 distinct messages from a sender earns them session trust
      //      (`_trackPubkeyMessage`), exempting them from the spam gate.
      //  (2) NIP-13 PoW meeting the Nymchat floor (16 bits) is a self-attestation
      //      that the sender runs Nymchat → add to the trust graph + our vouch
      //      list (`_markNymchatPubkey` + `_observeNymchatPubkey`).
      final selfPk = _identity?.pubkey ?? '';
      if (event.pubkey != selfPk) {
        final earnedTrust = _ref
            .read(appStateProvider.notifier)
            .trackPubkeyMessage(event.pubkey, event.id);
        if (earnedTrust) _scheduleTrustPersist();
        if (pow.validatePow(event, _nymchatPowFloor)) {
          _observeNymchatPubkey(event.pubkey);
        }
      }

      // Hydrate the author's kind-0 from D1 if we don't have it (the PWA queues
      // a profile fetch for every message author it lacks a profile for —
      // `queueProfileFetch`, nostr-core.js:1767). Debounced/batched.
      _maybeBackfillProfiles(event.pubkey);

      // Send a public read receipt (kind 24421) for a fresh, visible, non-own
      // channel message in the channel we currently have open — the native
      // analogue of the PWA's `addMessageToUI` send (gated on `canBeSeen &&
      // !isOwn && !isHistorical && geohash && id matches`). The open channel is
      // our visibility proxy (no scroll-position tracking on native).
      final self = _identity?.pubkey ?? '';
      final geohash = event.tagValue('g');
      final key = EventMapper.channelKeyOf(event);
      if (event.pubkey != self &&
          geohash != null &&
          geohash.isNotEmpty &&
          _isChannelMessageId(event.id) &&
          !_isHistorical(event.createdAt) &&
          key != null &&
          _isActiveView(key)) {
        unawaited(sendChannelReadReceipt(event.id, event.pubkey, geohash));
      }
    }
  }

  /// Ingests a kind-30030 emoji-pack event into the live custom-emoji store
  /// (emoji.js `handleEmojiPackEvent`): parse the `d`/`title`/`emoji` tags into a
  /// pack (≤120 emoji, deduped) and store it (newest-wins per pubkey:identifier).
  void _ingestEmojiPack(NostrEvent e) {
    final emojis = <({String shortcode, String url})>[];
    final seen = <String>{};
    for (final t in e.tags) {
      if (t.length >= 3 && t[0] == 'emoji') {
        final sc = t[1];
        final url = t[2];
        if (sc.isEmpty || url.isEmpty || seen.contains(sc)) continue;
        seen.add(sc);
        emojis.add((shortcode: sc, url: url));
        if (emojis.length >= 120) break;
      }
    }
    if (emojis.isEmpty) return;
    final identifier = e.tagValue('d') ?? '';
    final title = e.tagValue('title') ??
        (identifier.isNotEmpty ? identifier : 'Emoji pack');
    _ref.read(liveCustomEmojiProvider.notifier).storePack(
          CustomEmojiPack(
            pubkey: e.pubkey,
            identifier: identifier,
            title: title,
            createdAt: e.createdAt,
            emojis: emojis,
          ),
        );
  }

  /// Ingests the user's kind-10030 emoji-pack list (emoji.js
  /// `handleUserEmojiListEvent`): our author only; record the `a`-tag pack refs
  /// (`30030:<pubkey>:<id>`) + any inline `emoji` tags (newest event wins).
  void _ingestUserEmojiList(NostrEvent e) {
    final self = _service?.selfPubkey ?? _identity?.pubkey;
    if (self != null && e.pubkey != self) return;
    final refs = <String>[];
    final inlineEmoji = <List<String>>[];
    for (final t in e.tags) {
      if (t.isEmpty) continue;
      if (t[0] == 'a' && t.length > 1 && t[1].startsWith('30030:')) {
        refs.add(t[1]);
      } else if (t[0] == 'emoji' && t.length >= 3) {
        inlineEmoji.add(t);
      }
    }
    _ref.read(liveCustomEmojiProvider.notifier).setUserPackRefs(
          refs,
          e.createdAt,
          inlineEmojiTags: inlineEmoji,
        );
  }

  // ---------------------------------------------------------------------------
  // Inbound notifications (notifications.js `showNotification` gate, wired into
  // the inbound pipeline per the PWA's `handleEvent` notification checks).
  // ---------------------------------------------------------------------------

  /// True when [content] @-mentions the self nym (messages.js `isMentioned`):
  /// matches `@<nym>` optionally followed by our `#suffix`, ignoring blockquoted
  /// (`>`-prefixed) lines so a quoted mention doesn't notify.
  bool _mentionsSelf(String content) {
    final identity = _identity;
    if (identity == null || content.isEmpty) return false;
    final cleanNym = stripPubkeySuffix(identity.nym);
    if (cleanNym.isEmpty) return false;
    final suffix = getPubkeySuffix(identity.pubkey);
    // Strip blockquoted lines (mentions inside quotes don't count).
    final scrubbed = content
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('>'))
        .join('\n');
    final esc = RegExp.escape(cleanNym);
    final sfx = RegExp.escape(suffix);
    // `@nym` followed by `#suffix` OR a boundary that isn't a *different*
    // #abcd suffix (mirrors `_getMentionPattern`'s tail).
    final tail = sfx.isNotEmpty
        ? '(?:#$sfx\\b|(?!#[0-9a-f]{4})(?:\\b|\$))'
        : '(?!#[0-9a-f]{4})(?:\\b|\$)';
    final pattern = RegExp('@$esc$tail', caseSensitive: false);
    return pattern.hasMatch(scrubbed);
  }

  /// Whether a message at [createdAtSec] is historical (replayed backlog):
  /// older than 10s (nostr-core.js `messageAge > 10000`).
  bool _isHistorical(int createdAtSec) =>
      DateTime.now().millisecondsSinceEpoch - createdAtSec * 1000 > 10000;

  bool get _notificationsEnabled =>
      _ref.read(settingsProvider).notificationsEnabled;
  bool get _notifyFriendsOnly =>
      _ref.read(keyValueStoreProvider).getString(StorageKeys.notifyFriendsOnly) ==
      'true';
  bool get _groupNotifyMentionsOnly =>
      _ref
          .read(keyValueStoreProvider)
          .getString(StorageKeys.groupNotifyMentionsOnly) ==
      'true';

  bool _isActiveView(String storageKey) =>
      _ref.read(appStateProvider).view.storageKey == storageKey;

  void _maybeNotifyChannel(NostrEvent e) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    final isOwn = e.pubkey == self;
    final appState = _ref.read(appStateProvider);
    final isBlocked = appState.blockedUsers.contains(e.pubkey);
    final key = EventMapper.channelKeyOf(e);
    final mention = _mentionsSelf(e.content);
    final isActive = key != null && _isActiveView(key);
    // Record gate (history) vs alert gate (sound/popup). A historical channel
    // mention is still added to history silently (nostr-core.js:546-555:
    // `_addNotificationToHistory` in the `isHistorical` branch) — only the loud
    // `showNotification` is suppressed.
    final record = shouldRecordNotification(
      kind: NotifyKind.channel,
      isOwn: isOwn,
      notificationsEnabled: _notificationsEnabled,
      isMention: mention,
      isFriend: appState.isFriend(e.pubkey),
      isBlocked: isBlocked,
      isActiveView: isActive,
      friendsOnly: _notifyFriendsOnly,
    );
    if (!record) return;
    final alert = !_isHistorical(e.createdAt);
    // PWA footer context label for a channel source is `in #<geohash>`
    // (notifications.js, derived from `channelInfo`). `channelKeyOf` already
    // returns the `#`-prefixed key (geohash `g` tag / named `d` tag), so reuse
    // it directly; null for an unkeyed event leaves the label off.
    _dispatchNotification(
      title: _nymDisplayFor(e.pubkey),
      body: e.content,
      senderPubkey: e.pubkey,
      isFriend: appState.isFriend(e.pubkey),
      isMention: mention,
      // A channel notification only fires on an @-mention; record it as such so
      // the panel labels it "Mention" and routes to the sender's PM/profile.
      historyType: 'mention',
      route: e.pubkey,
      eventId: e.id,
      tsMs: e.createdAt * 1000,
      contextLabel: key != null ? 'in $key' : null,
      silent: !alert,
    );
  }

  /// PM/group notification for an ingested [Message] (mirrors the PWA's PM/group
  /// handlers, pms.js:1369-1385 / groups.js:1329-1351). The PWA always records a
  /// qualifying message into the bell history — loudly (`showNotification`) when
  /// it's fresh, silently (`_addNotificationToHistory`) when it's old — so a PM
  /// or group message must reach history regardless of age. Historical here is
  /// the PWA's `msg.isHistorical || ageMs > 30000`: only the loud sound/popup is
  /// gated on it, not the history record. PMs always qualify; group messages
  /// qualify unless mentions-only is on and the message isn't a mention.
  void _maybeNotifyMessage(Message m, {required bool isGroup}) {
    final appState = _ref.read(appStateProvider);
    final mention = _mentionsSelf(m.content);
    final key = m.conversationKey ??
        (isGroup
            ? GroupLogic.groupStorageKey(m.groupId ?? '')
            : (m.conversationPubkey != null
                ? PmLogic.pmStorageKey(m.conversationPubkey!)
                : ''));
    // Record gate (history) — NOT gated on age, so backlog/gift-wrapped PMs and
    // group messages (which always arrive with an old `created_at`) still land
    // in the bell. This is the fix for PMs/group messages never appearing.
    final record = shouldRecordNotification(
      kind: isGroup ? NotifyKind.group : NotifyKind.pm,
      isOwn: m.isOwn,
      notificationsEnabled: _notificationsEnabled,
      isMention: mention,
      isFriend: appState.isFriend(m.pubkey),
      isBlocked: appState.blockedUsers.contains(m.pubkey),
      isActiveView: _isActiveView(key),
      friendsOnly: _notifyFriendsOnly,
      groupMentionsOnly: _groupNotifyMentionsOnly,
    );
    if (!record) return;
    // PWA `treatAsHistorical = msg.isHistorical || ageMs > 30000` — drives the
    // loud alert only. A fresh message alerts; an older one records silently.
    final ageMs = DateTime.now().millisecondsSinceEpoch - m.timestamp;
    final treatAsHistorical = m.isHistorical || ageMs > 30000;
    _dispatchNotification(
      // The panel renders the avatar + decorated `<author#suffix>` from the
      // sender pubkey (like the PWA modal, which keys both off `senderPubkey`),
      // so the title is the bare author for BOTH PM and group; the group name
      // is carried as the `in <GroupName>` context label below (mirrors the PWA
      // modal pulling `groupName` from the context, not rendering the raw title).
      title: m.author,
      body: m.content,
      senderPubkey: m.pubkey,
      isFriend: appState.isFriend(m.pubkey),
      isMention: mention,
      isGroup: isGroup,
      // PM → routes to the peer pubkey; group → routes to the group id. The
      // sender pubkey (for the avatar/author) is carried separately.
      historyType: isGroup ? 'group' : 'pm',
      route: isGroup ? (m.groupId ?? '') : m.pubkey,
      eventId: m.nymMessageId ?? m.id,
      tsMs: m.timestamp,
      // Group footer label `in <GroupName>` (PWA `channelInfo`); PMs leave it
      // null so the panel labels them 'PM' from the type.
      contextLabel: isGroup ? 'in ${_groupNameFor(m.groupId)}' : null,
      silent: treatAsHistorical,
    );
  }

  /// Group display name for a notification title/context (falls back to "Group").
  String _groupNameFor(String? groupId) {
    if (groupId == null) return 'Group';
    final g = _ref.read(appStateProvider.notifier).groupById(groupId);
    return (g != null && g.name.isNotEmpty) ? g.name : 'Group';
  }

  /// Records a notification into the in-app notification history
  /// (`notificationHistoryProvider`) and, unless [silent], also fires the loud
  /// alert (sound + local popup). Mirrors the PWA's two entry points: a fresh
  /// message goes through `showNotification` (alert + history), an old/replayed
  /// one through `_addNotificationToHistory` ([silent] — history only). So the
  /// bell always reflects the message; only the sound/popup is suppressed when
  /// historical. [historyType] is the panel category ('pm' | 'group' | 'mention'
  /// | 'reaction'); [route] is the tap target (peer pubkey or group id);
  /// [eventId] dedupes live + replayed copies.
  void _dispatchNotification({
    required String title,
    required String body,
    required String senderPubkey,
    required bool isFriend,
    required bool isMention,
    bool isGroup = false,
    String historyType = 'pm',
    String? route,
    String? eventId,
    int? tsMs,
    String? contextLabel,
    bool silent = false,
  }) {
    if (!silent) {
      unawaited(_ref.read(notificationsServiceProvider).notify(
            title: title,
            body: body,
            notifyFriendsOnly: _notifyFriendsOnly,
            groupNotifyMentionsOnly: _groupNotifyMentionsOnly,
            context: NotifyContext(
              senderPubkey: senderPubkey,
              isFriend: isFriend,
              isMention: isMention,
              isGroup: isGroup,
            ),
          ));
    }
    // The verified Nymbot never records to history (notifications.js:14).
    if (isVerifiedBot(senderPubkey)) return;
    try {
      _ref.read(notificationHistoryProvider.notifier).record(
            type: historyType,
            title: title,
            body: body,
            route: route ?? senderPubkey,
            ts: tsMs,
            eventId: eventId,
            senderPubkey: senderPubkey,
            contextLabel: contextLabel,
          );
    } catch (_) {
      // History store may be unavailable in teardown; alerting still happened.
    }
  }

  /// Notifies + records history when someone reacts to OUR message (reactions.js
  /// `handleReaction` notify block, lines 336-427). [messageId] is the reacted
  /// message (`e` tag), [reactorPubkey] the reactor, [targetAuthorPubkey] the
  /// reacted message's author (the `p` tag). Fires only when the target is us and
  /// the reactor isn't us (and isn't blocked / notifications are enabled). The
  /// body mirrors the PWA: `reacted <emoji> to: "<preview>"` (or `…to your
  /// message`). [route] is the conversation to open on tap.
  void _maybeNotifyReaction({
    required String messageId,
    required String reactorPubkey,
    required String targetAuthorPubkey,
    required String emoji,
    required int tsSec,
    String? eventId,
    String? route,
  }) {
    if (emoji.isEmpty || messageId.isEmpty) return;
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (self.isEmpty) return;
    // Only notify for reactions to our message, and not our own reaction.
    if (targetAuthorPubkey != self || reactorPubkey == self) return;
    if (!_notificationsEnabled) return;
    final appState = _ref.read(appStateProvider);
    if (appState.blockedUsers.contains(reactorPubkey)) return;
    if (_notifyFriendsOnly && !appState.isFriend(reactorPubkey)) return;

    // Preview of the reacted message (first non-quoted line, ≤80 chars).
    String? preview;
    for (final list in appState.messages.values) {
      for (final m in list) {
        if (m.id == messageId || m.nymMessageId == messageId) {
          preview = m.content
              .split('\n')
              .where((l) => !l.startsWith('>'))
              .join(' ')
              .trim();
          break;
        }
      }
      if (preview != null) break;
    }
    if (preview != null && preview.length > 80) {
      preview = '${preview.substring(0, 80)}…';
    }
    final body = (preview != null && preview.isNotEmpty)
        ? 'reacted $emoji to: "$preview"'
        : 'reacted $emoji to your message';

    // A replayed/backlogged reaction is still recorded to history, silently
    // (reactions.js:2032/2057: `isHistorical ? _addNotificationToHistory :
    // showNotification`). Only a fresh reaction plays the sound/popup.
    _dispatchNotification(
      title: _nymDisplayFor(reactorPubkey),
      body: body,
      senderPubkey: reactorPubkey,
      isFriend: appState.isFriend(reactorPubkey),
      isMention: false,
      historyType: 'reaction',
      route: route ?? reactorPubkey,
      eventId: eventId,
      tsMs: tsSec * 1000,
      silent: _isHistorical(tsSec),
    );
  }

  void _ingestPresence(NostrEvent e) {
    // nym-presence ingestion (users.js `handlePresenceEvent`). Skip our own
    // presence and stale (older than last-seen) events.
    final isPresence = e.tagsNamed('t').any((t) => t.length > 1 && t[1] == AppDataTopic.presence);
    if (!isPresence) return;
    if (e.tagValue('status') == null) return; // PWA: `if (!statusTag) return`.
    final self = _service?.selfPubkey ?? _identity?.pubkey;
    if (self != null && e.pubkey == self) return;

    final lastTs = _presenceTimestamps[e.pubkey] ?? 0;
    if (e.createdAt < lastTs) return;
    _presenceTimestamps[e.pubkey] = e.createdAt;

    final statusStr = e.tagValue('status');
    final nym = e.tagValue('n');
    final away = e.tagValue('away');
    final avatar = e.tagValue('avatar-update');
    // Shop cosmetics: the PWA's `shop-update` tag is a cache-bust flag and the
    // real items come from the backend; the native build reads the inlined
    // shop-style/flair/supporter tags (see PresenceCosmetics). When a
    // `shop-update` arrives without inlined tags, the cosmetics are cleared.
    final hasShopUpdate =
        e.tagsNamed('shop-update').any((t) => t.length > 1 && t[1] == '1');
    _ref.read(appStateProvider.notifier).setUserPresence(
          pubkey: e.pubkey,
          status: userStatusFromString(statusStr),
          nym: nym,
          awayMessage: away,
          lastSeenMs: e.createdAt * 1000,
          avatarUrl: avatar,
          hasAvatarTag: avatar != null,
          shopUpdate: hasShopUpdate,
          shopStyle: e.tagValue('shop-style'),
          shopFlair: e.tagValue('shop-flair'),
          isSupporter: e.tagsNamed('shop-supporter')
              .any((t) => t.length > 1 && t[1] == '1'),
          // Inlined special cosmetics + Genesis edition (one `shop-cosmetic` tag
          // per active cosmetic; a `shop-edition` tag carries the Genesis number).
          // The PWA's canonical source is the backend `shop-status` fetch
          // (active.cosmetics/active.editions); these inlined tags let presence
          // carry them without a round-trip. See CROSS-FILE NEED for the fetch.
          shopCosmetics: e
              .tagsNamed('shop-cosmetic')
              .where((t) => t.length > 1 && t[1].isNotEmpty)
              .map((t) => t[1])
              .toList(),
          shopEdition: int.tryParse(e.tagValue('shop-edition') ?? ''),
        );

    // Resolve this user's D1 profile so their custom avatar replaces the
    // identicon even when they never send a message — the PWA resolves avatars
    // for presence/list users too (`queueProfileFetch`/`ensureListProfiles`).
    // No-op when presence already carried an `avatar-update` (picture set); the
    // backfill guard keys on the picture, so it only fetches when one is missing.
    _maybeBackfillProfiles(e.pubkey);
  }

  /// Per-pubkey newest presence timestamp (users.js `presenceTimestamps`) so a
  /// redelivered/older replaceable presence event can't clobber a newer one.
  final Map<String, int> _presenceTimestamps = {};

  // ---------------------------------------------------------------------------
  // Web of trust ("nym-vouch") — kind 30078, `['t','nym-vouches']`. Ported from
  // nostr-core.js (`handleVouchEvent`, `_observeNymchatPubkey`,
  // `publishNymchatVouches`, `_scheduleVouchExpansion`). The trust graph gates
  // channel/PM spam (app_state `isSpamGated`); observing PoW-valid Nymchat
  // activity grows OUR vouch list (published so peers expand through us), and
  // ingesting a trusted peer's vouch list grows the graph (and triggers a
  // one-hop resubscribe so the web of trust expands and then goes quiet).
  // ---------------------------------------------------------------------------

  /// Ingests a peer's kind-30078 `nym-vouches` event (nostr-core.js
  /// `handleVouchEvent`, line 2663). The content is a JSON array of pubkeys the
  /// author vouches for. Only honored when the author is already trusted
  /// (rooted at dev/bot); each valid pubkey is added to the graph. When new
  /// pubkeys appear, schedule a one-hop expansion (resubscribe to the now-larger
  /// author set).
  void _ingestVouch(NostrEvent e) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (e.pubkey.isEmpty || e.pubkey == self) return;
    dynamic decoded;
    try {
      decoded = jsonDecode(e.content.isEmpty ? '[]' : e.content);
    } catch (_) {
      return;
    }
    final list = TrustGraph.parseVouchList(decoded, selfPubkey: self);
    final added = _ref.read(appStateProvider.notifier).ingestVouchList(
          authorPubkey: e.pubkey,
          vouchedPubkeys: list,
        );
    // Newly trusted pubkeys are new vouch authors to fetch — expand one hop via
    // a heavily debounced resubscribe (converges, then goes quiet).
    if (added) {
      _scheduleVouchExpansion();
      _scheduleTrustPersist();
    }
  }

  /// Records an observation that [pubkey] is running Nymchat (valid PoW channel
  /// message or read receipt) — nostr-core.js `_observeNymchatPubkey` (line
  /// 2623). Marks them in the graph AND in our own vouch list, then schedules a
  /// debounced publish of the updated list.
  void _observeNymchatPubkey(String pubkey) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (pubkey.isEmpty || pubkey == self) return;
    final notifier = _ref.read(appStateProvider.notifier);
    notifier.markNymchatPubkey(pubkey);
    final added = notifier.observeNymchatPubkey(pubkey);
    if (added) _scheduleVouchPublish();
    _scheduleTrustPersist();
  }

  /// NIP-13 PoW floor (leading zero bits) a channel message must meet to be
  /// treated as a Nymchat-client self-attestation (`this.nymchatPowFloor = 16`,
  /// app.js:556).
  static const int _nymchatPowFloor = 16;

  /// Debounce for the vouch-list publish (nostr-core.js `_scheduleVouchPublish`,
  /// line 2635): at most one publish per 60s, else a 5s coalescing delay.
  Timer? _vouchPublishTimer;
  int _lastVouchPublishAt = 0;

  void _scheduleVouchPublish() {
    if (_vouchPublishTimer != null) return;
    final sinceLast = DateTime.now().millisecondsSinceEpoch - _lastVouchPublishAt;
    final delayMs = sinceLast < 60000 ? 60000 - sinceLast : 5000;
    _vouchPublishTimer = Timer(Duration(milliseconds: delayMs), () {
      _vouchPublishTimer = null;
      unawaited(_publishVouches());
    });
  }

  /// Signs + publishes our `nym-vouches` list (nostr-core.js
  /// `publishNymchatVouches`, line 2645). Best-effort.
  Future<void> _publishVouches() async {
    final service = _service;
    if (service == null) return;
    if (service.pool.connectedCount == 0) return;
    final list = _ref.read(appStateProvider).nymchatVouches.toList();
    if (list.isEmpty) return;
    try {
      await service.publishVouches(list);
      _lastVouchPublishAt = DateTime.now().millisecondsSinceEpoch;
    } catch (_) {
      // best-effort
    }
  }

  /// Debounced (5s coalescing) persist of the three web-of-trust sets to the
  /// on-disk cache, so the graph survives a restart instead of rebuilding cold
  /// every launch (the PWA persists nymchatPubkeys/Vouches/trusted to its meta
  /// store). Scheduled whenever an observation/vouch/earned-trust mutates a set.
  Timer? _trustPersistTimer;
  void _scheduleTrustPersist() {
    if (_trustPersistTimer != null) return;
    _trustPersistTimer = Timer(const Duration(seconds: 5), () {
      _trustPersistTimer = null;
      unawaited(_persistTrust());
    });
  }

  Future<void> _persistTrust() async {
    final cache = _cache;
    if (cache == null) return;
    final s = _ref.read(appStateProvider);
    try {
      await cache.saveMetaSet(CacheStore.metaNymchatPubkeys, s.nymchatPubkeys);
      await cache.saveMetaSet(CacheStore.metaNymchatVouches, s.nymchatVouches);
      await cache.saveMetaSet(CacheStore.metaTrustedPubkeys, s.trustedPubkeys);
    } catch (_) {
      // best-effort
    }
  }

  /// Debounce for the one-hop graph expansion (nostr-core.js
  /// `_scheduleVouchExpansion`, line 2685): 15s after new trusted pubkeys
  /// appear, resubscribe to vouches authored by the now-larger trust set.
  Timer? _vouchExpansionTimer;

  void _scheduleVouchExpansion() {
    if (_vouchExpansionTimer != null) return;
    _vouchExpansionTimer = Timer(const Duration(seconds: 15), () {
      _vouchExpansionTimer = null;
      _subscribeVouches();
    });
  }

  /// (Re)subscribes to peers' `nym-vouches` lists authored by our current trust
  /// graph (relays.js:2538-2542). Called on connect and on each expansion hop.
  void _subscribeVouches() {
    final service = _service;
    if (service == null) return;
    final authors = _ref.read(appStateProvider).nymchatPubkeys;
    service.subscribeVouches(authors);
  }

  void _onGiftWrap(GiftWrapUnwrapped u) {
    final appState = _ref.read(appStateProvider.notifier);
    final rumor = u.rumor;
    final kind = u.rumorKind;
    final self = _service?.selfPubkey ?? '';

    switch (kind) {
      case EventKind.dmRumor: // 14 — PM or group message
        // Archive the durable DM wrap to D1 (PMs + group messages; the PWA
        // archives `event` in `handleGiftWrapDM` before the group/PM split,
        // pms.js:1021). Receipts/typing (kind 69420) are NOT archived.
        _archiveGiftWrap(u);
        _onRumorMessage(u, appState, self);
      case EventKind.nymReceiptRumor: // 69420 — receipt or typing
        _onReceiptOrTyping(rumor, appState);
      case EventKind.reaction: // 7 — gift-wrapped reaction
        _onPrivateReaction(rumor, appState);
      case EventKind.zapReceipt: // 9735 — gift-wrapped private zap announcement
        _onPrivateZap(rumor, appState);
      case EventKind.callSignaling: // 25053 — call signaling transport
        if (u.senderVerified) _callSignalHandler?.call(rumor);
      case EventKind.friendPresence: // 25054 — friends-only private presence
        if (u.senderVerified) _onFriendPresence(rumor, appState);
      default:
        break;
    }
  }

  /// Ingests an inbound friends-only presence rumor (kind 25054,
  /// nostr-core.js `handleFriendPresenceRumor`): a friend running in "Friends
  /// only" mode shared their real status privately. Verified senders only; we
  /// only honor presence from someone we already know or have friended so a
  /// stranger can't inject themselves as "online".
  void _onFriendPresence(Map<String, dynamic> rumor, AppStateNotifier appState) {
    final pubkey = rumor['pubkey'] as String? ?? '';
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (pubkey.isEmpty || pubkey == self) return;

    final state = _ref.read(appStateProvider);
    if (!state.isFriend(pubkey) && !state.users.containsKey(pubkey)) return;

    final tags = _tags(rumor);
    final status = _tagValue(tags, 'status');
    if (status == null || status == 'hidden') return;

    final nym = _tagValue(tags, 'n');
    final away = _tagValue(tags, 'away');
    appState.setUserPresence(
      pubkey: pubkey,
      status: userStatusFromString(status),
      nym: nym,
      awayMessage: status == 'away' ? away : null,
      lastSeenMs: DateTime.now().millisecondsSinceEpoch,
    );
    // Resolve the friend's D1 profile so their custom avatar loads even without
    // a message this session (guard no-ops once a picture is known).
    _maybeBackfillProfiles(pubkey);
  }

  void _onRumorMessage(
      GiftWrapUnwrapped u, AppStateNotifier appState, String self) {
    final rumor = u.rumor;
    final tags = _tags(rumor);
    final groupId = _tagValue(tags, 'g');
    final type = _tagValue(tags, 'type');
    final senderPubkey = rumor['pubkey'] as String? ?? '';

    // Register any NIP-30 custom emoji declared on the PM/group rumor so its
    // `:shortcode:` tokens render (emoji.js `ingestEmojiTags` runs on every event).
    if (tags.isNotEmpty) {
      _ref.read(liveCustomEmojiProvider.notifier).ingestEmojiTags(tags);
    }

    // Track an advertised group ephemeral key.
    if (groupId != null) {
      final ephPk = _tagValue(tags, 'ephemeral_pk');
      final ts = (rumor['created_at'] as num?)?.toInt() ?? 0;
      if (ephPk != null && senderPubkey != self) {
        _groups?.recordMemberKey(groupId, senderPubkey, ephPk, ts);
      }
    }

    // Group control / invite events.
    if (groupId != null && type != null && type != GroupControlType.message) {
      if (!u.senderVerified) return;
      _onGroupControl(groupId, type, tags, senderPubkey, rumor, u, appState);
      return;
    }

    // Group message.
    if (groupId != null) {
      if (!u.senderVerified) return;
      final m = _mapGroupMessage(rumor, u, self, groupId);
      if (m == null) return;
      appState.ingestGroupMessage(m);
      _maybeNotifyMessage(m, isGroup: true);
      // Backfill the sender's kind-0 from D1 if unknown (PWA `queueProfileFetch`).
      _maybeBackfillProfiles(m.pubkey);
      // Auto-send a delivery receipt to the sender (best-effort).
      if (!m.isOwn && m.nymMessageId != null) {
        final ek = _groups?.keysFor(groupId);
        _service?.publishReceipt(
          messageId: m.nymMessageId!,
          receiptType: 'delivered',
          recipientPubkey: senderPubkey,
          encryptToPubkey: ek?.encryptionPubkeyFor(senderPubkey, self),
        );
      }
      return;
    }

    // 1:1 PM message.
    final m = PmLogic.mapPmRumor(
      rumor: rumor,
      wrapId: u.wrapId,
      selfPubkey: self,
      senderVerified: u.senderVerified,
    );
    if (m == null) return;
    appState.ingestPMMessage(m);
    _maybeNotifyMessage(m, isGroup: false);
    // Backfill the sender's kind-0 from D1 if unknown (PWA `queueProfileFetch`).
    _maybeBackfillProfiles(m.pubkey);
    // Delivery receipt back to the sender (not for our own self-copy).
    if (!m.isOwn && m.nymMessageId != null) {
      _service?.publishReceipt(
        messageId: m.nymMessageId!,
        receiptType: 'delivered',
        recipientPubkey: m.pubkey,
      );
    }
  }

  Message? _mapGroupMessage(
    Map<String, dynamic> rumor,
    GiftWrapUnwrapped u,
    String self,
    String groupId,
  ) {
    final content = rumor['content'];
    final senderPubkey = rumor['pubkey'] as String?;
    if (content is! String || senderPubkey == null) return null;
    final tags = _tags(rumor);
    final nymMessageId = _tagValue(tags, 'x');
    final ms = int.tryParse(_tagValue(tags, 'ms') ?? '') ?? 0;
    final createdAtRaw = (rumor['created_at'] as num?)?.toInt() ?? 0;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final createdAt = createdAtRaw > nowSec + 60 ? nowSec : createdAtRaw;
    final isOwn = senderPubkey == self;
    return Message(
      id: u.wrapId.isNotEmpty ? u.wrapId : (nymMessageId ?? ''),
      author: _nymFor(senderPubkey),
      pubkey: senderPubkey,
      content: content,
      createdAt: createdAt,
      originalCreatedAt: createdAtRaw,
      ms: ms,
      isOwn: isOwn,
      isGroup: true,
      groupId: groupId,
      conversationKey: GroupLogic.groupStorageKey(groupId),
      eventKind: EventKind.giftWrap,
      nymMessageId: nymMessageId,
      senderVerified: u.senderVerified,
      deliveryStatus:
          isOwn ? DeliveryStatus.sent : DeliveryStatus.delivered,
    );
  }

  void _onGroupControl(
    String groupId,
    String type,
    List<List<String>> tags,
    String senderPubkey,
    Map<String, dynamic> rumor,
    GiftWrapUnwrapped u,
    AppStateNotifier appState,
  ) {
    // Bootstrap invite: create the local group if we don't have it yet.
    if (type == GroupControlType.invite) {
      if (appState.groupById(groupId) != null) return;
      final members = tags
          .where((t) => t.length > 1 && t[0] == 'p')
          .map((t) => t[1])
          .toList();
      final owner = _tagValue(tags, 'owner') ?? senderPubkey;
      final name = _tagValue(tags, 'subject') ?? '';
      appState.upsertGroup(Group(
        id: groupId,
        name: name,
        members: members,
        createdBy: owner,
        allowMemberInvites: _tagValue(tags, 'allow_invites') != '0',
        inviteEnabled: _tagValue(tags, 'invite_enabled') == '1',
        inviteEpoch: int.tryParse(_tagValue(tags, 'invite_epoch') ?? '') ?? 0,
        lastMessageTime: DateTime.now().millisecondsSinceEpoch,
      ));
      // Group invite notification (groups.js:868 `Group invite: <name>`).
      if (_notificationsEnabled &&
          !_ref.read(appStateProvider).blockedUsers.contains(senderPubkey)) {
        final inviter = _nymDisplayFor(senderPubkey);
        _dispatchNotification(
          title: 'Group invite: ${name.isNotEmpty ? name : 'group'}',
          body: '$inviter added you to ${name.isNotEmpty ? name : 'a group'}',
          senderPubkey: senderPubkey,
          isFriend: _ref.read(appStateProvider).isFriend(senderPubkey),
          isMention: false,
          isGroup: true,
          historyType: 'group',
          route: groupId,
          eventId: u.wrapId,
          tsMs: (rumor['created_at'] as num?)?.toInt() != null
              ? (rumor['created_at'] as num).toInt() * 1000
              : null,
          // Group source → footer label `in <GroupName>` (PWA `channelInfo`).
          contextLabel: 'in ${name.isNotEmpty ? name : 'a group'}',
        );
      }
      return;
    }

    final ts = (rumor['created_at'] as num?)?.toInt() ?? 0;
    appState.applyGroupControl(
      groupId: groupId,
      type: type,
      tags: tags,
      senderPubkey: senderPubkey,
      ts: ts,
      eventId: u.wrapId,
    );
  }

  void _onReceiptOrTyping(
      Map<String, dynamic> rumor, AppStateNotifier appState) {
    if (PmLogic.isTyping(rumor)) {
      final info = PmLogic.parseTyping(rumor);
      if (info == null || info.pubkey == null) return;
      // Stale typing indicators are dropped.
      final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 -
          ((rumor['created_at'] as num?)?.toInt() ?? 0);
      if (age > 8) return;
      final storageKey = info.groupId != null
          ? GroupLogic.groupStorageKey(info.groupId!)
          : PmLogic.pmStorageKey(info.pubkey!);
      appState.setTyping(
        storageKey: storageKey,
        pubkey: info.pubkey!,
        typing: info.isStart,
      );
      return;
    }
    if (PmLogic.isReceipt(rumor)) {
      final info = PmLogic.parseReceipt(rumor);
      if (info != null) appState.applyReceipt(info);
    }
  }

  void _onPrivateReaction(
      Map<String, dynamic> rumor, AppStateNotifier appState) {
    // Reactions land in app_state's reaction store via a synthetic event.
    final tags = _tags(rumor);
    final target = _tagValue(tags, 'e');
    if (target == null) return;
    final pubkey = rumor['pubkey'] as String? ?? '';
    final content = rumor['content'] as String? ?? '';
    final ts = (rumor['created_at'] as num?)?.toInt() ?? 0;
    final action = tags.any((t) => t.length > 1 && t[0] == 'action' && t[1] == 'remove');
    // The reacted message's author (`p` tag); reaction targets us when this is
    // our pubkey. Group reactions also carry the group id (`g`) for routing.
    final targetAuthor = _tagValue(tags, 'p') ?? '';
    final groupId = _tagValue(tags, 'g');
    final synthetic = NostrEvent(
      pubkey: pubkey,
      createdAt: ts,
      kind: EventKind.reaction,
      tags: [
        ['e', target],
        ['p', targetAuthor.isNotEmpty ? targetAuthor : pubkey],
        if (action) ['action', 'remove'],
      ],
      content: content,
    );
    appState.ingestEvent(synthetic);

    // Notify + record when someone reacts to OUR PM/group message (pms.js:2032 /
    // groups reaction notify). Skip removals.
    if (!action) {
      _maybeNotifyReaction(
        messageId: target,
        reactorPubkey: pubkey,
        targetAuthorPubkey: targetAuthor,
        emoji: content,
        tsSec: ts,
        route: groupId ?? pubkey,
      );
    }
  }

  /// Routes a gift-wrapped private zap announcement (kind 9735 rumor, sent to
  /// PM/group members). Accrues sats to the zapped message's aggregate. The
  /// rumor carries an `['e', msgId]`, `['p', recipient]`, `['bolt11', …]`.
  void _onPrivateZap(Map<String, dynamic> rumor, AppStateNotifier appState) {
    final tags = _tags(rumor);
    final messageId = _tagValue(tags, 'e');
    final bolt11 = _tagValue(tags, 'bolt11');
    if (messageId == null || bolt11 == null) return;
    final amount = ZapLogic.parseAmountFromBolt11(bolt11);
    if (amount == null) return;
    final zapper = rumor['pubkey'] as String? ?? '';
    appState.recordMessageZap(
      messageId: messageId,
      zapperPubkey: zapper,
      amountSats: amount,
      dedupKey: ZapLogic.dedupKey(bolt11: bolt11, eventId: ''),
    );
    // Resolve the zapper's avatar (the zappers sheet / badge), like the PWA
    // resolves zap-list authors (`ensureListProfiles`, zaps.js:223).
    if (zapper.isNotEmpty) _maybeBackfillProfiles(zapper);
  }

  // ---------------------------------------------------------------------------
  // Call signaling (kind 25053) — transport only; WebRTC is the calls agent's.
  // ---------------------------------------------------------------------------

  void Function(Map<String, dynamic> rumor)? _callSignalHandler;

  /// Registers the inbound call-signaling handler. Gift-wrapped kind-25053
  /// rumors addressed to us are decoded and handed to [fn] verbatim.
  void setCallSignalHandler(void Function(Map<String, dynamic> rumor)? fn) {
    _callSignalHandler = fn;
  }

  /// Gift-wraps and sends a kind-25053 call-signaling rumor to [to]. [payload]
  /// is the SDP/ICE body the calls layer wants delivered (carried as the rumor
  /// content, JSON-encoded). A self-copy is NOT sent (signaling is 1:1).
  Future<bool> sendCallSignal({
    required String to,
    required Map<String, dynamic> payload,
  }) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Mirror calls.js `_sendCallSignal` (line 146): the rumor content is
    // `{ ...payload, nym }` — the sender's display name is injected into EVERY
    // signal so the recipient's incoming-call UI can label the caller even
    // before a kind-0 profile arrives. Without it an invite shows a truncated
    // pubkey instead of the nym.
    final content = <String, dynamic>{...payload, 'nym': identity.nym};
    final rumor = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: nowSec,
      kind: EventKind.callSignaling,
      tags: [
        ['p', to],
      ],
      content: jsonEncode(content),
    );
    return service.publishGiftWrappedRumor(rumor: rumor, recipients: [to]);
  }

  // ---------------------------------------------------------------------------
  // Outbound: composer SEND + entry points
  // ---------------------------------------------------------------------------

  /// Sends [text] to the current view: optimistic local echo, then relay
  /// publish (channel / PM / group).
  Future<void> sendCurrent(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    // Slash-command interception (commands.js `content.startsWith('/')`): route
    // `/cmd args` to the command handler instead of publishing as a message.
    if (isCommandLine(trimmed)) {
      _dispatcher.handle(trimmed);
      return;
    }

    // Nymbot interception (messages.js:2381): a `?` command or `@Nymbot` mention
    // in a CHANNEL view routes to the bot (publishes the message + surfaces the
    // reply) instead of a plain send.
    if (shouldRouteToBot(trimmed)) {
      await routeToBot(trimmed);
      return;
    }

    await _sendMessageContent(trimmed);
  }

  // Anon-nym word lists for pseudonymous sends (nostr-core.js:2511-2525).
  static const List<String> _anonAdjectives = [
    'quantum', 'neon', 'cyber', 'shadow', 'plasma', //
    'echo', 'nexus', 'void', 'flux', 'ghost',
    'phantom', 'stealth', 'cryptic', 'dark', 'neural',
    'binary', 'matrix', 'digital', 'virtual', 'zero',
    'null', 'nym', 'masked', 'hidden', 'cipher',
    'enigma', 'spectral', 'rogue', 'omega', 'alpha',
  ];
  static const List<String> _anonNouns = [
    'ghost', 'nomad', 'drift', 'pulse', 'wave', //
    'spark', 'node', 'byte', 'mesh', 'link',
    'runner', 'hacker', 'coder', 'agent', 'proxy',
    'daemon', 'virus', 'worm', 'bot', 'droid',
    'reaper', 'shadow', 'wraith', 'specter', 'shade',
  ];
  final Random _anonRng = Random();

  /// Pseudonymous channel send (composer ANON 2s-hold → "ANON";
  /// `sendMessagePseudonymous` → `publishMessagePseudonymous`,
  /// nostr-core.js:2493). Publishes [text] to the active CHANNEL signed with a
  /// FRESH per-message ephemeral keypair under a random anon nym, so it is
  /// unlinkable to the durable identity. Mirrors [sendCurrent]'s `/`-command and
  /// `?`/@Nymbot interception; PM/group views fall through to the normal
  /// logged-in-key send (the PWA always uses the real key for PMs/groups).
  Future<void> sendCurrentPseudonymous(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (isCommandLine(trimmed)) {
      _dispatcher.handle(trimmed);
      return;
    }
    if (shouldRouteToBot(trimmed)) {
      await routeToBot(trimmed);
      return;
    }
    final view = _ref.read(appStateProvider).view;
    if (view.kind != ViewKind.channel) {
      await _sendMessageContent(trimmed);
      return;
    }
    await _sendChannelPseudonymous(trimmed);
  }

  /// Publishes one pseudonymous channel message: a fresh ephemeral keypair +
  /// random anon nym, an optimistic echo under that anon identity, and the
  /// in-place optimistic→real id reconciliation [_sendMessageContent] uses.
  /// Deliberately does NOT `recordOwnActivity` — presence is broadcast under the
  /// durable key, and emitting it would link the anon message to the user.
  Future<void> _sendChannelPseudonymous(String content) async {
    final appState = _ref.read(appStateProvider.notifier);
    final state = _ref.read(appStateProvider);
    final service = _service;
    final view = state.view;
    _markDirty(view.storageKey);

    final ephemeralSigner = LocalSigner(keys.generatePrivateKey());
    final anonNym = _generateAnonNym();

    final echo = appState.sendLocal(
      content,
      pubkeyOverride: ephemeralSigner.pubkey,
      authorOverride: anonNym,
    );
    if (service == null) return;
    final isGeo = state.channels
        .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
    try {
      final signed = await service.publishChannelMessage(
        channelKey: view.id,
        content: content,
        nym: anonNym,
        geohash: isGeo ? view.id : null,
        emojiTags: _ref
            .read(liveCustomEmojiProvider.notifier)
            .emojiTagsForContent(content),
        signerOverride: ephemeralSigner,
      );
      if (signed != null && echo != null) {
        appState.replaceOptimistic(
          echo.id,
          signed.id,
          realCreatedAt: signed.createdAt,
          realMs: int.tryParse(signed.tagValue('ms') ?? ''),
        );
      }
    } catch (_) {
      if (echo != null) appState.markOptimisticFailed(echo.id);
    }
  }

  /// A random anon nym for a pseudonymous message (nostr-core.js:2506-2529):
  /// `nym<1000-9999>` for the 'simple' nick style, else `<adjective>_<noun>`.
  String _generateAnonNym() {
    final style = _ref.read(settingsProvider).nickStyle;
    if (style == 'simple') {
      return 'nym${1000 + _anonRng.nextInt(9000)}';
    }
    final adj = _anonAdjectives[_anonRng.nextInt(_anonAdjectives.length)];
    final noun = _anonNouns[_anonRng.nextInt(_anonNouns.length)];
    return '${adj}_$noun';
  }

  /// Publishes [content] to the active conversation surface
  /// (`_sendToCurrentTarget`), WITHOUT command interception. Used both by the
  /// composer (after the `/` check) and by formatting/action commands whose
  /// output (e.g. `/me …`) must be sent verbatim even though it starts with a
  /// slash.
  Future<void> _sendMessageContent(String content) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return;
    // Every outgoing send marks us active + throttle-broadcasts presence
    // (nostr-core.js calls recordOwnActivity on each channel/PM/group send).
    recordOwnActivity();
    final appState = _ref.read(appStateProvider.notifier);
    final state = _ref.read(appStateProvider);
    final service = _service;
    final identity = _identity;
    final view = state.view;
    _markDirty(view.storageKey);

    if (view.kind == ViewKind.channel) {
      // Optimistic local echo with a temp `_optim_*` id (messages.js sendMessage).
      final echo = appState.sendLocal(trimmed);
      if (service == null || identity == null) return;
      final isGeo = state.channels
          .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
      try {
        final signed = await service.publishChannelMessage(
          channelKey: view.id,
          content: trimmed,
          nym: identity.nym,
          geohash: isGeo ? view.id : null,
          emojiTags: _ref
              .read(liveCustomEmojiProvider.notifier)
              .emojiTagsForContent(trimmed),
        );
        // Swap the temp id for the real signed-event id IN PLACE and register
        // it so the relay echo is deduped — never shown twice (the PWA's
        // `_replaceOptimisticMessage`). Without a signer `signed` is null and the
        // echo simply stays (no relay round-trip will echo it back).
        if (signed != null && echo != null) {
          appState.replaceOptimistic(
            echo.id,
            signed.id,
            realCreatedAt: signed.createdAt,
            realMs: int.tryParse(signed.tagValue('ms') ?? ''),
          );
        }
      } catch (_) {
        // Publish failed: flip the placeholder to failed (`_markOptimisticFailed`).
        if (echo != null) appState.markOptimisticFailed(echo.id);
      }
      return;
    }

    if (view.kind == ViewKind.pm) {
      final nymMessageId = PmLogic.generateSharedEventId();
      appState.sendLocal(trimmed, nymMessageId: nymMessageId);
      if (service == null || identity == null) return;
      final rumor = PmLogic.buildPmRumor(
        selfPubkey: identity.pubkey,
        recipientPubkey: view.id,
        content: trimmed,
        nymMessageId: nymMessageId,
      );
      await service.publishPM(
        rumor: rumor,
        recipientPubkey: view.id,
        settings: _msgSettings,
      );
      return;
    }

    if (view.kind == ViewKind.group) {
      final group = appState.groupById(view.id);
      // Local echo carries its own nymMessageId for receipt matching.
      if (service == null || identity == null || group == null) {
        appState.sendLocal(trimmed);
        return;
      }
      // Build + send first so we know the shared id, then echo with it.
      final ek = _groups!.keysFor(group.id);
      final next = ek.rotateSelf();
      _service!.setEphemeralKeys(_groups!.allEphemeralSecretKeys());
      final nymMessageId = GroupLogic.generateGroupId();
      appState.sendLocal(trimmed, nymMessageId: nymMessageId);
      final rumor = GroupLogic.buildGroupMessageRumor(
        group: group,
        selfPubkey: identity.pubkey,
        content: trimmed,
        nymMessageId: nymMessageId,
        ephemeralPk: next.pk,
      );
      await service.publishGroupMessage(
        rumor: rumor,
        recipients: group.members,
        encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
        settings: _msgSettings,
      );
    }
  }

  // --- Command effects (engine half of the cmd* handlers) -------------------

  /// `/join` — sanitize, block-check, add + switch (cmdJoin). The name is
  /// lowercased and `#`-stripped; geohash channels register their geohash.
  void cmdJoin(String rawChannel) {
    var channel = rawChannel.trim().toLowerCase();
    if (channel.startsWith('#')) channel = channel.substring(1);
    // Sanitize: only letters (incl. international) and digits (sanitizeChannelName).
    channel = channel.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    if (channel.isEmpty) {
      _emitSystemMessage(
          'Invalid channel name. Only letters and numbers are allowed.');
      return;
    }
    final blocked = _ref.read(appStateProvider).blockedChannels;
    if (blocked.contains(channel)) {
      _emitSystemMessage(
          'Channel #$channel is blocked. Use /unblock #$channel to unblock it first.');
      return;
    }
    final geohash = isChannelGeohash(channel) ? channel : '';
    addChannel(channel, geohash: geohash);
    switchChannel(channel, geohash: geohash);
  }

  /// `/leave` — channel→removeChannel (cmdLeave). PM/group leave is wired by the
  /// pms/groups UI via [setCommandHooks] (not owned here).
  void cmdLeave() {
    final state = _ref.read(appStateProvider);
    if (state.view.kind != ViewKind.channel) return; // PM/group handled by hook
    final key = state.view.id.toLowerCase();
    if (key == 'nymchat') {
      _emitSystemMessage('Cannot leave the default #nymchat channel');
      return;
    }
    removeChannel(key);
  }

  /// `/who` — lists current-channel users active within 300s (cmdWho).
  void cmdWho() {
    final state = _ref.read(appStateProvider);
    final key = state.view.id.toLowerCase();
    final now = DateTime.now().millisecondsSinceEpoch;
    final names = state.users.values
        .where((u) => u.channels.contains(key))
        .where((u) => now - u.lastSeen < kActiveThresholdMs)
        .map((u) =>
            '${stripPubkeySuffix(u.nym)}#${getPubkeySuffix(u.pubkey)}')
        .toList()
      ..sort();
    _emitSystemMessage(
        'Online nyms in this channel: ${names.isEmpty ? 'none' : names.join(', ')}');
  }

  /// `/nick` — change nickname (cmdNick): publish a kind-0 with the new name.
  Future<void> cmdNick(String newNym) async {
    final next = newNym.trim();
    if (next.length > 20) {
      await saveProfile(name: next.substring(0, 20));
    } else {
      await saveProfile(name: next);
    }
    _emitSystemMessage("Your nym's new nick is now ${_identity?.nym ?? next}");
  }

  /// `/brb` — set away message + broadcast away presence (cmdBRB).
  Future<void> cmdSetAway(String message) async {
    await publishPresence('away', awayMessage: message);
    _emitSystemMessage('Away message set: "$message"');
    _emitSystemMessage(
        'You will auto-reply to mentions in ALL channels while away');
  }

  /// `/back` — clear away + broadcast online (cmdBack).
  Future<void> cmdBack() async {
    await publishPresence('online');
    _emitSystemMessage('Away message cleared - you are back!');
  }

  /// `/clear` — clear the conversation view (cmdClear). The message store is
  /// owned by app_state; we surface the PWA's confirmation. TODO(verify): a
  /// real clear needs an app_state clear API (not owned by this agent).
  void cmdClear() => _emitSystemMessage('Chat cleared');

  /// `/share` — share the current channel URL (cmdShare/shareChannel).
  void cmdShare() {
    final state = _ref.read(appStateProvider);
    if (state.view.kind != ViewKind.channel) return;
    _emitSystemMessage('https://app.nym.bar/#${state.view.id}');
  }

  /// `/quit` — disconnect (cmdQuit). Stops the service; full reload is the
  /// shell's job.
  void cmdQuit() {
    _emitSystemMessage('Disconnecting from Nymchat...');
    unawaited(_service?.stop());
  }

  /// `/block` — block #channel (cmdBlock channel path) or report a user block.
  void cmdBlock(String arg) {
    final state = _ref.read(appStateProvider);
    final target = arg.trim();
    if (target.isEmpty) {
      if (state.view.kind != ViewKind.channel) {
        _emitSystemMessage(
            'Usage: /block nym, /block nym#xxxx, /block [pubkey], or /block #channel');
        return;
      }
      final key = state.view.id.toLowerCase();
      if (key == 'nymchat') {
        _emitSystemMessage('Cannot block the default #nymchat channel');
        return;
      }
      if (blockChannel(key)) {
        _emitSystemMessage(isChannelGeohash(key)
            ? 'Blocked geohash channel #$key'
            : 'Blocked channel #$key');
        switchChannel('nymchat');
      }
      return;
    }
    if (target.startsWith('#')) {
      final name = target.substring(1).toLowerCase();
      if (name == 'nymchat') {
        _emitSystemMessage('Cannot block the default #nymchat channel');
        return;
      }
      if (blockChannel(name)) {
        _emitSystemMessage(isChannelGeohash(name)
            ? 'Blocked geohash channel #$name'
            : 'Blocked channel #$name');
      }
      return;
    }
    // User block — app_state owns blockedUsers; surface the PWA confirmation.
    final t = resolveTarget(target, state.users);
    if (t == null) {
      _emitSystemMessage('User $target not found');
      return;
    }
    blockUser(t.pubkey);
  }

  /// `/unblock` — unblock #channel (cmdUnblock channel path) or a user.
  void cmdUnblock(String arg) {
    final state = _ref.read(appStateProvider);
    final target = arg.trim();
    if (target.startsWith('#')) {
      final name = target.substring(1).toLowerCase();
      if (state.blockedChannels.contains(name)) {
        unblockChannelEffect(name);
        _emitSystemMessage(isChannelGeohash(name)
            ? 'Unblocked geohash channel #$name'
            : 'Unblocked channel #$name');
      } else {
        _emitSystemMessage('Channel #$name is not blocked');
      }
      return;
    }
    final t = resolveTarget(target, state.users);
    if (t == null || !state.blockedUsers.contains(t.pubkey)) {
      _emitSystemMessage('User $target not found or is not blocked');
      return;
    }
    unblockUser(t.pubkey);
  }

  /// Unblocks [key] and persists (mirrors blockChannel's inverse).
  void unblockChannelEffect(String key) {
    _ref.read(appStateProvider.notifier).unblockChannel(key);
    _persistSet(StorageKeys.blockedChannels,
        _ref.read(appStateProvider).blockedChannels);
  }

  /// Whether [key] is a geohash channel (isValidGeohash, non-default).
  bool isChannelGeohash(String key) =>
      isValidGeohash(key) && key != 'nymchat';

  /// Opens (or creates) a PM thread with [peerPubkey] and switches to it.
  void startPM(String peerPubkey, {String? nym}) {
    final appState = _ref.read(appStateProvider.notifier);
    appState.ensurePMConversation(peerPubkey, nym: nym);
    appState.switchView(ChatView.pm(peerPubkey));
  }

  /// Creates a group with [memberPubkeys], registers it locally, and switches.
  ///
  /// The optional [avatar] / [banner] / [description] / [allowMemberInvites]
  /// are the group-creation extras the New-Group modal collects; they thread
  /// through to [GroupManager.createGroup] and onto the bootstrap invite's
  /// metadata tags (groups.js `createGroup(name, members, opts)`). The positional
  /// `(name, memberPubkeys)` shape is preserved so existing callers/tests keep
  /// compiling; [allowMemberInvites] defaults to true (PWA
  /// `opts.allowMemberInvites !== false`).
  Future<Group?> createGroup(
    String name,
    List<String> memberPubkeys, {
    String? avatar,
    String? banner,
    String? description,
    bool allowMemberInvites = true,
  }) async {
    final service = _service;
    final identity = _identity;
    final groups = _groups;
    if (service == null || identity == null || groups == null) return null;
    final group = await groups.createGroup(
      selfPubkey: identity.pubkey,
      name: name,
      memberPubkeys: memberPubkeys,
      avatar: avatar,
      banner: banner,
      description: description,
      allowMemberInvites: allowMemberInvites,
      settings: _msgSettings,
    );
    if (group == null) return null;
    final appState = _ref.read(appStateProvider.notifier);
    appState.upsertGroup(group);
    appState.switchView(ChatView.group(group.id));
    return group;
  }

  /// Joiner side of the group invite-link flow (groups.js
  /// `requestJoinGroupViaInvite`, 449-492): gift-wrap a single
  /// `group-join-request` (kind-14) to the link's sharer (`approver`), who
  /// auto-admits us when invite links are enabled and our `invite_epoch`
  /// matches. Short-circuits when we already have the group (just opens it) or
  /// the link is our own, and degrades to a system message when no signer is
  /// available yet (the PWA prompts setup and resumes after onboarding).
  Future<void> joinGroupViaInvite(GroupInviteToken token) async {
    final appState = _ref.read(appStateProvider.notifier);
    // Already a member → just open it (groups.js:453).
    if (appState.groupById(token.groupId) != null) {
      appState.switchView(ChatView.group(token.groupId));
      return;
    }
    final identity = _identity;
    final service = _service;
    // Your own invite link (groups.js:458).
    if (identity != null && token.approver == identity.pubkey) {
      _emitSystemMessage('That is your own invite link.');
      return;
    }
    final sanitized = _sanitizeGroupName(token.name);
    final name = sanitized.isEmpty ? 'this group' : sanitized;
    // No identity / signer yet (groups.js:466 `_canSendGiftWraps`).
    if (identity == null || service == null || !service.canSign) {
      _emitSystemMessage(
          'Pick a nym or log in to join "$name", then you\'ll be added.');
      return;
    }
    // Build + gift-wrap the join request to the sharer (groups.js:480-491).
    recordOwnActivity();
    final subject = token.name.isEmpty
        ? 'Group'
        : (token.name.length > 80 ? token.name.substring(0, 80) : token.name);
    final rumor = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: EventKind.dmRumor, // 14
      tags: [
        ['p', token.approver],
        ['g', token.groupId],
        ['subject', subject],
        ['type', GroupControlType.joinRequest],
        ['invite_epoch', '${token.epoch}'],
        ['x', PmLogic.generateSharedEventId()],
      ],
      content: 'requested to join via invite link',
    );
    try {
      await service.publishGiftWrappedRumor(
        rumor: rumor,
        recipients: [token.approver],
      );
      _emitSystemMessage(
          'Join request sent for "$name". You\'ll be added once a member is '
          'online.');
    } catch (_) {
      _emitSystemMessage('Failed to send join request. Please try again.');
    }
  }

  /// Sends [body] as a gift-wrapped kind-14 PM to the verified developer
  /// ([verifiedDeveloperPubkey]) — the About → "Send Message" / contact form
  /// (app.js:4438 `nym.sendPM(body, nym.verifiedDeveloper.pubkey)`). Returns true
  /// when the wrap was published.
  ///
  /// Mirrors `sendPM` → `sendNIP17PM`: a kind-14 rumor wrapped to the recipient
  /// plus a self-copy (so the message also lands in our own PM thread with the
  /// developer). The recipient is a normal pubkey (not the Nymbot), so the
  /// bot-command short-circuit in `sendPM` doesn't apply. Empty bodies and the
  /// no-signer / not-connected states return false, matching the PWA's guards
  /// (`if (!content.trim()) return false` / `if (!connected) throw`).
  Future<bool> sendContactMessage(String body) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return false;
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null || !service.canSign) return false;

    // Mark us active (recordOwnActivity) like every other PM send.
    recordOwnActivity();

    final nymMessageId = PmLogic.generateSharedEventId();
    final rumor = PmLogic.buildPmRumor(
      selfPubkey: identity.pubkey,
      recipientPubkey: verifiedDeveloperPubkey,
      content: trimmed,
      nymMessageId: nymMessageId,
    );
    try {
      return await service.publishPM(
        rumor: rumor,
        recipientPubkey: verifiedDeveloperPubkey,
        settings: _msgSettings,
      );
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Outbound settings transfer (F9; shop.js:1767 `executeSettingsTransfer`).
  // ---------------------------------------------------------------------------

  /// Transfers this user's nickname, avatar, and transferable preferences to
  /// [recipientPubkey] by publishing a gift-wrapped kind-30078 event, mirroring
  /// the PWA's `executeSettingsTransfer` (shop.js:1804). The recipient surfaces
  /// it as a pending settings-transfer offer (`handleSettingsTransferEvent`).
  ///
  /// The event uses the replaceable `d` tag
  /// `nym-settings-transfer-<selfPubkey>-<recipientPubkey>` plus
  /// `['settings-transfer-to', recipientPubkey]`; the content is the JSON payload
  /// `{fromPubkey, fromNym, toPubkey, transferredAt, nickname, avatarUrl,
  /// settings}` where `settings` is the flat synced payload (PWA
  /// `_buildSettingsPayload`) minus the device-local keys the PWA strips
  /// (`closedPMs`, `leftGroups`, `notificationLastReadTime`, `userJoinedChannels`,
  /// `pinnedChannels`, `keypairMode`).
  ///
  /// It is gift-wrapped (NIP-59, encrypted-to-recipient) like the other 30078
  /// transfer path, reusing [NostrService.publishGiftWrappedRumor]. Caller is
  /// expected to have validated the recipient (64-hex, non-self); this also
  /// guards on a signer being available. Returns true when a wrap was published.
  Future<bool> sendSettingsTransfer(String recipientPubkey) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null || !service.canSign) return false;

    // Mark us active like every other outbound gift-wrap path.
    recordOwnActivity();

    // Flat synced payload (PWA `_buildSettingsPayload`): flatten the section
    // payloads and drop the per-section `v` markers so the shape matches the
    // PWA's flat settings object.
    final settings = _ref.read(settingsProvider);
    final transferSettings = <String, dynamic>{};
    StorageSync.buildSectionPayloads(settings).forEach((_, fields) {
      fields.forEach((k, v) {
        if (k == 'v') return;
        transferSettings[k] = v;
      });
    });
    // Strip the device-local keys the PWA deletes before sending (most aren't in
    // the native subset; this stays byte-faithful if any are added later).
    for (final k in const [
      'closedPMs',
      'leftGroups',
      'notificationLastReadTime',
      'userJoinedChannels',
      'pinnedChannels',
      'keypairMode',
    ]) {
      transferSettings.remove(k);
    }

    final avatar =
        _ref.read(appStateProvider).users[identity.pubkey]?.profile?.picture ??
            '';
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final payload = <String, dynamic>{
      'fromPubkey': identity.pubkey,
      'fromNym': identity.nym,
      'toPubkey': recipientPubkey,
      'transferredAt': nowSec,
      'nickname': identity.nym,
      'avatarUrl': avatar,
      'settings': transferSettings,
    };

    final rumor = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: nowSec,
      kind: EventKind.appData, // 30078
      tags: [
        ['d', 'nym-settings-transfer-${identity.pubkey}-$recipientPubkey'],
        ['title', 'Nymchat Settings Transfer'],
        ['p', recipientPubkey],
        ['settings-transfer-to', recipientPubkey],
      ],
      content: jsonEncode(payload),
    );
    try {
      return await service.publishGiftWrappedRumor(
        rumor: rumor,
        recipients: [recipientPubkey],
      );
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Cache size / clear (settings.js data controls: "Cache: N MB" + "Clear
  // cache"). The on-disk [CacheStore] owns the real byte accounting + wipe; this
  // exposes them to the settings UI. Both no-op safely before [init].
  // ---------------------------------------------------------------------------

  /// Real on-disk size of the message/profile/reaction cache, in bytes
  /// (settings.js `estimateCacheSize`). 0 when the cache hasn't been opened yet.
  Future<int> cacheSizeBytes() async {
    final cache = _cache;
    if (cache == null || !cache.isOpen) return 0;
    return cache.totalBytes();
  }

  /// Clears all cached channels / PMs / profiles / reactions (settings.js
  /// "Clear cache"). Flushes any pending dirty writes first so an in-flight
  /// debounce can't immediately re-persist what we just wiped, drops the dirty
  /// sets, then wipes the store. Also clears the in-memory hydrated profile /
  /// reaction caches via the cache wipe; the live app_state is untouched (the
  /// PWA clears the persisted cache, not the open session).
  Future<void> clearCache() async {
    final cache = _cache;
    if (cache == null || !cache.isOpen) return;
    // Cancel the pending flush + forget dirty keys so we don't re-write the
    // conversations we're about to drop.
    _flushTimer?.cancel();
    _flushScheduled = false;
    _dirtyChannelKeys.clear();
    _dirtyPmKeys.clear();
    await cache.wipe();
  }

  // --- moderation entry points (role-checked) -------------------------------

  Future<bool> kickFromGroup(String groupId, String targetPubkey,
      {bool ban = false}) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    if (!GroupLogic.canModerate(group, identity.pubkey)) return false;
    final ok = await groups.sendControl(
      group: group,
      selfPubkey: identity.pubkey,
      type: GroupControlType.removeMember,
      extraTags: [
        ['kick', targetPubkey],
        if (ban) ['ban', '1'],
      ],
    );
    if (ok) {
      // Apply locally too.
      appState.applyGroupControl(
        groupId: groupId,
        type: GroupControlType.removeMember,
        tags: [
          ['kick', targetPubkey],
          if (ban) ['ban', '1'],
        ],
        senderPubkey: identity.pubkey,
        ts: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        eventId: GroupLogic.generateGroupId(),
      );
    }
    return ok;
  }

  Future<bool> banFromGroup(String groupId, String targetPubkey) =>
      kickFromGroup(groupId, targetPubkey, ban: true);

  /// Promotes [targetPubkey] to moderator (owner-only). Mirrors users.js
  /// `promoteModerator` → `group-promote-mod`.
  Future<bool> promoteModerator(String groupId, String targetPubkey) =>
      _sendModRoleControl(
          groupId, targetPubkey, GroupControlType.promoteMod, ['promote', targetPubkey]);

  /// Revokes [targetPubkey]'s moderator role (owner-only). users.js
  /// `revokeModerator` → `group-revoke-mod`.
  Future<bool> revokeModerator(String groupId, String targetPubkey) =>
      _sendModRoleControl(
          groupId, targetPubkey, GroupControlType.revokeMod, ['revoke', targetPubkey]);

  /// Transfers ownership to [targetPubkey] (owner-only). users.js
  /// `transferOwner` → `group-transfer-owner`.
  Future<bool> transferOwner(String groupId, String targetPubkey) =>
      _sendModRoleControl(groupId, targetPubkey, GroupControlType.transferOwner,
          ['new_owner', targetPubkey]);

  Future<bool> _sendModRoleControl(
    String groupId,
    String targetPubkey,
    String type,
    List<String> tag,
  ) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    // Promote/revoke/transfer are owner-only (group_logic §4.1).
    if (!GroupLogic.isOwner(group, identity.pubkey)) return false;
    final extraTags = [tag];
    final ok = await groups.sendControl(
      group: group,
      selfPubkey: identity.pubkey,
      type: type,
      extraTags: extraTags,
    );
    if (ok) {
      appState.applyGroupControl(
        groupId: groupId,
        type: type,
        tags: extraTags,
        senderPubkey: identity.pubkey,
        ts: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        eventId: GroupLogic.generateGroupId(),
      );
    }
    return ok;
  }

  /// Mod/owner deletion of another member's group message (users.js
  /// `modDeleteGroupMessage`). Publishes a `group-delete-message` control and
  /// removes the message locally. Role is checked.
  Future<bool> modDeleteGroupMessage(
      String groupId, String messageId, String authorPubkey) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    final ownerSelf = GroupLogic.isOwner(group, identity.pubkey);
    final modSelf = GroupLogic.isMod(group, identity.pubkey);
    final targetIsOwner = GroupLogic.isOwner(group, authorPubkey);
    if (!(ownerSelf || (modSelf && !targetIsOwner))) return false;
    final extraTags = [
      ['delete', messageId],
      ['p', authorPubkey],
    ];
    final ok = await groups.sendControl(
      group: group,
      selfPubkey: identity.pubkey,
      type: GroupControlType.deleteMessage,
      extraTags: extraTags,
    );
    appState.removeMessage(messageId);
    if (ok) _emitSystemMessage('Message deleted');
    return ok;
  }

  // ---------------------------------------------------------------------------
  // Group owner / membership controls (groups.js:3046-3083 owner rows). The
  // metadata/leave/add primitives live in [GroupManager]; these drive the local
  // mutation + the gift-wrapped control publish + the PWA's system feedback.
  // ---------------------------------------------------------------------------

  /// Leaves [groupId]: notifies the remaining members with a `group-leave`
  /// control rumor (groups.js `leaveGroup`, 1792), then drops the group locally
  /// so it doesn't reappear from stale relay data (the self-removal path in
  /// app_state's `applyGroupControl`). Switches away if the left group was open.
  /// Returns true if the group existed and was left.
  Future<bool> leaveGroup(String groupId) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;

    // Notify the other members (best-effort; needs a signer).
    final suffix = getPubkeySuffix(identity.pubkey);
    final leaveContent =
        '${stripPubkeySuffix(identity.nym)}#$suffix left the group.';
    await groups.sendLeave(
      group: group,
      selfPubkey: identity.pubkey,
      content: leaveContent,
      settings: _msgSettings,
    );

    // Drop locally via the self-removal path (adds to leftGroups, removes the
    // group + its messages). The self-kick is always authorized (group_logic).
    appState.applyGroupControl(
      groupId: groupId,
      type: GroupControlType.removeMember,
      tags: [
        ['kick', identity.pubkey],
      ],
      senderPubkey: identity.pubkey,
      ts: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      eventId: GroupLogic.generateGroupId(),
    );

    // If we were viewing the group, fall back to the default channel.
    if (_ref.read(appStateProvider).view.kind == ViewKind.group &&
        _ref.read(appStateProvider).view.id == groupId) {
      appState.switchView(ChatView.channel('nymchat'));
    }
    return true;
  }

  /// Owner-only: updates [groupId]'s metadata in place (any of [name],
  /// [description], [avatar], [banner]) and broadcasts a `group-metadata` control
  /// to the other members (groups.js `setGroupName`/`setGroupDescription`/
  /// `_applyGroupImage`, all funnel through `_broadcastGroupMetadata`).
  ///
  /// Passing `null` for a field leaves it unchanged; passing an empty string for
  /// [avatar]/[banner] clears it (matching the Remove Avatar/Banner rows). [name]
  /// is single-line sanitized (cap 40); [description] is multiline sanitized
  /// (cap 150, empty ⇒ cleared). Returns true if a change was applied.
  Future<bool> updateGroupMetadata(
    String groupId, {
    String? name,
    String? description,
    String? avatar,
    String? banner,
  }) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    if (!GroupLogic.isOwner(group, identity.pubkey)) return false;

    var changed = false;
    if (name != null) {
      final trimmed = _sanitizeGroupName(name);
      if (trimmed.isNotEmpty && trimmed != group.name) {
        group.name = trimmed;
        changed = true;
      }
    }
    if (description != null) {
      final trimmed = _sanitizeGroupDescription(description);
      final next = trimmed.isEmpty ? null : trimmed;
      if (next != group.description) {
        group.description = next;
        changed = true;
      }
    }
    if (avatar != null) {
      final next = avatar.isEmpty ? null : avatar;
      if (next != group.avatar) {
        group.avatar = next;
        changed = true;
      }
    }
    if (banner != null) {
      final next = banner.isEmpty ? null : banner;
      if (next != group.banner) {
        group.banner = next;
        changed = true;
      }
    }
    if (!changed) return false;

    group.metaUpdatedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    appState.upsertGroup(group);
    await groups.sendMetadata(
      group: group,
      selfPubkey: identity.pubkey,
      settings: _msgSettings,
    );
    return true;
  }

  /// Owner-only: toggles whether regular members may add others
  /// (groups.js `setGroupAllowMemberInvites`, 2267). Mutates the group locally
  /// and broadcasts a `group-metadata` control. Returns true if the value
  /// changed.
  Future<bool> setGroupAllowInvites(String groupId, bool allow) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    if (!GroupLogic.isOwner(group, identity.pubkey)) return false;
    if (allow == group.allowMemberInvites) return false;

    group.allowMemberInvites = allow;
    group.metaUpdatedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    appState.upsertGroup(group);
    await groups.sendMetadata(
      group: group,
      selfPubkey: identity.pubkey,
      settings: _msgSettings,
    );
    _emitSystemMessage(allow
        ? 'Group members can now add new users.'
        : 'Only the group owner can add new users now.');
    return true;
  }

  /// Owner-only: turns joining [groupId] via an invite link on or off
  /// (groups.js `setGroupInviteEnabled`, 2288). Mutates the group locally and
  /// broadcasts a `group-metadata` control so members pick up the new
  /// `invite_enabled` flag. Returns true if the value changed.
  Future<bool> setGroupInviteEnabled(String groupId, bool enabled) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    if (!GroupLogic.isOwner(group, identity.pubkey)) {
      _emitSystemMessage('Only the group owner can change this setting.');
      return false;
    }
    if (enabled == group.inviteEnabled) return false;

    group.inviteEnabled = enabled;
    group.metaUpdatedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    appState.upsertGroup(group);
    await groups.sendMetadata(
      group: group,
      selfPubkey: identity.pubkey,
      settings: _msgSettings,
    );
    _emitSystemMessage(enabled
        ? 'Joining via invite link is now enabled.'
        : 'Joining via invite link is now disabled.');
    return true;
  }

  /// Owner-only: rotates [groupId]'s invite epoch, revoking every outstanding
  /// invite link (groups.js `rotateGroupInviteEpoch`, 2309). Mutates the group
  /// locally and broadcasts a `group-metadata` control. Returns true on success.
  Future<bool> rotateGroupInviteEpoch(String groupId) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    if (!GroupLogic.isOwner(group, identity.pubkey)) {
      _emitSystemMessage('Only the group owner can reset the invite link.');
      return false;
    }

    group.inviteEpoch = group.inviteEpoch + 1;
    group.metaUpdatedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    appState.upsertGroup(group);
    await groups.sendMetadata(
      group: group,
      selfPubkey: identity.pubkey,
      settings: _msgSettings,
    );
    _emitSystemMessage(
        'Previous invite links revoked. A new link is now active.');
    return true;
  }

  /// Adds [pubkeys] to [groupId] (owner, or a member when member-invites are
  /// allowed; groups.js `addMemberToGroup`, 1418). Each new member is appended
  /// locally, then a single `group-add-member` control is broadcast carrying the
  /// updated roster + metadata + the self ephemeral key. Already-present members
  /// are skipped; banned users are skipped unless the caller can moderate.
  /// Returns true if at least one member was added.
  Future<bool> addGroupMembers(String groupId, List<String> pubkeys) async {
    final identity = _identity;
    final groups = _groups;
    final appState = _ref.read(appStateProvider.notifier);
    final group = appState.groupById(groupId);
    if (identity == null || groups == null || group == null) return false;
    if (!GroupLogic.canAddMembers(group, identity.pubkey)) return false;

    final canMod = GroupLogic.canModerate(group, identity.pubkey);
    final added = <String>[];
    for (final pk in pubkeys) {
      if (pk.isEmpty || pk == identity.pubkey) continue;
      if (group.members.contains(pk)) continue;
      // Re-admitting a banned user requires owner/mod.
      if (group.banned.contains(pk)) {
        if (!canMod) continue;
        group.banned.remove(pk);
      }
      group.members.add(pk);
      added.add(pk);
    }
    if (added.isEmpty) return false;
    appState.upsertGroup(group);

    final inviter = '${stripPubkeySuffix(identity.nym)}#'
        '${getPubkeySuffix(identity.pubkey)}';
    final names = added.map((pk) => _nymDisplayFor(pk)).join(', ');
    final content = added.length == 1
        ? '$names was added by $inviter.'
        : '$names were added by $inviter.';
    await groups.addMembers(
      group: group,
      selfPubkey: identity.pubkey,
      content: content,
      settings: _msgSettings,
    );
    _emitSystemMessage(content);
    return true;
  }

  /// Single-line group-name sanitizer (groups.js `sanitizeGroupName`): strips
  /// control chars, collapses whitespace, caps at 40.
  static String _sanitizeGroupName(String name) {
    final collapsed = name
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return collapsed.length > 40 ? collapsed.substring(0, 40) : collapsed;
  }

  /// Multiline group-description sanitizer (groups.js `sanitizeGroupDescription`):
  /// keeps newlines, strips other control chars, collapses 3+ newlines, caps 150.
  static String _sanitizeGroupDescription(String description) {
    final cleaned = description
        .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return cleaned.length > 150 ? cleaned.substring(0, 150) : cleaned;
  }

  // ---------------------------------------------------------------------------
  // Social / moderation (docs/specs/03 §11) — friends, user blocking, keyword
  // filtering. State lives in app_state; this layer drives the change +
  // persistence + the PWA's system-message feedback.
  // ---------------------------------------------------------------------------

  /// Toggles [pubkey] as a friend, persists `nym_friends`, and surfaces the
  /// PWA's add/remove system message. Mirrors users.js `toggleFriend`.
  bool toggleFriend(String pubkey) {
    if (pubkey.isEmpty) return false;
    final appState = _ref.read(appStateProvider.notifier);
    final nowFriend = appState.toggleFriend(pubkey);
    _persistSet(StorageKeys.friends, _ref.read(appStateProvider).friends);
    final nymHtml = _nymDisplayFor(pubkey);
    _emitSystemMessage(nowFriend
        ? 'Added $nymHtml as a friend'
        : 'Removed $nymHtml from friends');
    return nowFriend;
  }

  /// Blocks [pubkey] (hides their messages), persists `nym_blocked`, and
  /// surfaces the PWA's "Blocked …" message. users.js
  /// `toggleBlockUserByPubkey` (add branch).
  bool blockUser(String pubkey) {
    if (pubkey.isEmpty) return false;
    final appState = _ref.read(appStateProvider.notifier);
    final added = appState.blockUser(pubkey);
    if (added) {
      _persistSet(StorageKeys.blocked, _ref.read(appStateProvider).blockedUsers);
      _emitSystemMessage('Blocked ${_nymDisplayFor(pubkey)}');
    }
    return added;
  }

  /// Unblocks [pubkey], persists `nym_blocked`, restores their messages, and
  /// surfaces "Unblocked …". users.js `unblockByPubkey`.
  bool unblockUser(String pubkey) {
    final appState = _ref.read(appStateProvider.notifier);
    final removed = appState.unblockUser(pubkey);
    if (removed) {
      _persistSet(StorageKeys.blocked, _ref.read(appStateProvider).blockedUsers);
      _emitSystemMessage('Unblocked ${_nymDisplayFor(pubkey)}');
    }
    return removed;
  }

  /// Toggles [pubkey]'s block state (context-menu Block/Unblock toggle).
  bool toggleBlockUser(String pubkey) {
    final blocked = _ref.read(appStateProvider).blockedUsers.contains(pubkey);
    return blocked ? !unblockUser(pubkey) : blockUser(pubkey);
  }

  /// Adds a blocked keyword (lowercased), persists `nym_blocked_keywords`, and
  /// surfaces the PWA message. users.js `addBlockedKeyword`.
  bool addBlockedKeyword(String keyword) {
    final appState = _ref.read(appStateProvider.notifier);
    final kw = appState.addBlockedKeyword(keyword);
    if (kw == null) return false;
    _persistSet(
        StorageKeys.blockedKeywords, _ref.read(appStateProvider).blockedKeywords);
    _emitSystemMessage('Blocked keyword: "$kw"');
    return true;
  }

  /// Removes a blocked keyword, persists, surfaces the PWA message. users.js
  /// `removeBlockedKeyword`.
  bool removeBlockedKeyword(String keyword) {
    final appState = _ref.read(appStateProvider.notifier);
    final removed = appState.removeBlockedKeyword(keyword);
    if (removed) {
      _persistSet(StorageKeys.blockedKeywords,
          _ref.read(appStateProvider).blockedKeywords);
      _emitSystemMessage('Unblocked keyword: "${keyword.toLowerCase()}"');
    }
    return removed;
  }

  // ---------------------------------------------------------------------------
  // Message edit / delete (messages.js startEditMessage / publishEdited… /
  // publishDeletionEvent). Tag construction is in pure helpers so it's testable
  // without a live signer; publishing uses existing service primitives.
  // ---------------------------------------------------------------------------

  /// Edits [messageId] to [newContent]. For a channel message this re-publishes
  /// the channel event with an extra `['edit', originalId]` tag (mirrors
  /// `publishEditedChannelMessage`); for PM/group it re-sends the rumor with the
  /// same `['edit', originalId]` tag. The local copy is rewritten + flagged
  /// edited. Returns true if a publish was attempted.
  Future<bool> editMessage(String messageId, String newContent) async {
    final trimmed = newContent.trim();
    if (messageId.isEmpty || trimmed.isEmpty) return false;
    final appState = _ref.read(appStateProvider.notifier);
    final state = _ref.read(appStateProvider);
    final service = _service;
    final identity = _identity;
    final view = state.view;

    // Local rewrite first (optimistic, matches the PWA's in-place update).
    appState.applyLocalEdit(messageId, trimmed);
    _markDirty(view.storageKey);

    if (service == null || identity == null || !service.canSign) return false;

    if (view.kind == ViewKind.channel) {
      final isGeo = state.channels
          .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
      final tags = buildChannelEditTags(
        nym: identity.nym,
        channelKey: view.id,
        isGeohash: isGeo,
        originalId: messageId,
      );
      final unsigned = UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: isGeo ? EventKind.geoChannel : EventKind.namedChannel,
        tags: tags,
        content: trimmed,
      );
      final signed = await _signer!.sign(unsigned);
      await service.pool.publish(signed);
      return true;
    }

    // PM / group edit: gift-wrap the rumor (kind 14) carrying ['edit', id].
    if (view.kind == ViewKind.pm) {
      final base = PmLogic.buildPmRumor(
        selfPubkey: identity.pubkey,
        recipientPubkey: view.id,
        content: trimmed,
        nymMessageId: PmLogic.generateSharedEventId(),
      );
      await service.publishPM(
        rumor: _withEditTag(base, messageId),
        recipientPubkey: view.id,
        settings: _msgSettings,
      );
      return true;
    }

    if (view.kind == ViewKind.group) {
      final group = appState.groupById(view.id);
      if (group == null) return false;
      final ek = _groups!.keysFor(group.id);
      final next = ek.rotateSelf();
      _service!.setEphemeralKeys(_groups!.allEphemeralSecretKeys());
      final base = GroupLogic.buildGroupMessageRumor(
        group: group,
        selfPubkey: identity.pubkey,
        content: trimmed,
        nymMessageId: GroupLogic.generateGroupId(),
        ephemeralPk: next.pk,
      );
      await service.publishGroupMessage(
        rumor: _withEditTag(base, messageId),
        recipients: group.members,
        encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
        settings: _msgSettings,
      );
      return true;
    }
    return false;
  }

  /// Returns a copy of [rumor] with an appended `['edit', originalId]` tag
  /// (pms.js / groups.js append `['edit', originalNymMessageId || originalId]`).
  UnsignedEvent _withEditTag(UnsignedEvent rumor, String originalId) {
    return UnsignedEvent(
      pubkey: rumor.pubkey,
      createdAt: rumor.createdAt,
      kind: rumor.kind,
      tags: [
        ...rumor.tags,
        ['edit', originalId],
      ],
      content: rumor.content,
    );
  }

  /// Publishes a kind-5 deletion for [messageId] (`['e', id], ['k', origKind]`)
  /// and removes the message locally. [originalKind] defaults to the active
  /// view's kind: 1059 for PM/group (gift wraps), else the channel wire kind
  /// (20000 geohash / 23333 named). Mirrors `publishDeletionEvent` +
  /// `deleteMessageFromContext`.
  Future<bool> deleteMessage(String messageId, {String? originalKind}) async {
    if (messageId.isEmpty) return false;
    final appState = _ref.read(appStateProvider.notifier);
    final state = _ref.read(appStateProvider);
    final service = _service;
    final identity = _identity;
    final view = state.view;

    final kind = originalKind ?? _viewDeletionKind(state);

    appState.removeMessage(messageId);
    _markDirty(view.storageKey);

    if (service == null || identity == null || !service.canSign) return false;
    final unsigned = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: EventKind.deletion,
      tags: buildDeletionTags(messageId, kind),
      content: '',
    );
    final signed = await _signer!.sign(unsigned);
    await service.pool.publish(signed);
    _emitSystemMessage('Deletion request sent to relays');
    return true;
  }

  /// The kind tag a deletion should carry for the active view: 1059 for PM/group
  /// (the gift wraps), else the channel wire kind.
  String _viewDeletionKind(AppState state) {
    final view = state.view;
    if (view.kind != ViewKind.channel) return '${EventKind.giftWrap}';
    final isGeo = state.channels
        .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
    return '${isGeo ? EventKind.geoChannel : EventKind.namedChannel}';
  }

  String _nymDisplayFor(String pubkey) {
    final u = _ref.read(appStateProvider).users[pubkey];
    final base = stripPubkeySuffix(u?.nym ?? 'anon');
    return '$base#${getPubkeySuffix(pubkey)}';
  }

  // --- presence / typing / receipts -----------------------------------------

  /// Last public presence broadcast (ms). Throttles `recordOwnActivity` relay
  /// broadcasts to ≤1/60s (nostr-core.js `_lastPresenceBroadcast`).
  int _lastPresenceBroadcast = 0;

  /// Periodic presence re-assertion timer (nostr-core.js broadcasts presence on
  /// a timer + on activity). Cancelled on dispose.
  Timer? _presenceTimer;

  static const int _presenceBroadcastThrottleMs = 60000;

  /// The status-visibility mode from `nym_show_status`
  /// ('true'|'friends'|'false') → PresenceStatusMode (PWA `_statusMode`).
  PresenceStatusMode get _statusMode =>
      presenceStatusModeFrom(_ref.read(settingsProvider).showStatus);

  /// The self user's active shop cosmetics, read from the shop controller so a
  /// presence `shop-update` carries renderable flair (see PresenceCosmetics).
  PresenceCosmetics _selfCosmetics() {
    final active = _ref.read(shopControllerProvider).active;
    return PresenceCosmetics(
      style: active.style,
      flair: active.flair.isNotEmpty ? active.flair.last : null,
      supporter: active.supporter,
    );
  }

  /// Publishes our presence (kind-30078 nym-presence). [status] is our real
  /// status; the service computes the public status from [_statusMode]. Always
  /// carries the avatar + shop-update tags so others can render our latest
  /// avatar/flair from the single replaceable event.
  Future<void> publishPresence(String status, {String awayMessage = ''}) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return;
    final avatar =
        _ref.read(appStateProvider).users[identity.pubkey]?.profile?.picture;
    await service.publishPresence(
      status: status,
      nym: identity.nym,
      awayMessage: awayMessage,
      mode: _statusMode,
      avatarUrl: (avatar != null && avatar.isNotEmpty) ? avatar : null,
      shopUpdate: true,
      cosmetics: _selfCosmetics(),
    );
    _lastPresenceBroadcast = DateTime.now().millisecondsSinceEpoch;

    // Friends-only: also deliver our real status privately to each friend via a
    // gift-wrapped kind-25054 rumor (nostr-core.js `_sendFriendPresence`). The
    // public event above already went out as `hidden`.
    if (_statusMode == PresenceStatusMode.friends) {
      unawaited(_sendFriendPresence(status, awayMessage: awayMessage));
    }
  }

  /// Gift-wraps our real presence (kind-25054) to each friend so only they can
  /// read it (nostr-core.js `_sendFriendPresence`). Best-effort; routed through
  /// the active [EventSigner] so it works under nsec/ephemeral and NIP-46.
  Future<void> _sendFriendPresence(String status,
      {String awayMessage = ''}) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null || !service.canSign) return;
    final friends = _ref.read(appStateProvider).friends;
    if (friends.isEmpty) return;
    final recipients =
        friends.where((pk) => pk.isNotEmpty && pk != identity.pubkey).toList();
    if (recipients.isEmpty) return;
    await service.sendFriendPresence(
      status: status,
      nym: identity.nym,
      recipients: recipients,
      awayMessage: awayMessage,
    );
  }

  /// Records local activity so our own status stays "online" and other clients
  /// see us as recently active. Called on connect, on every send, and on the
  /// presence timer. Throttles relay broadcasts to ≤1/60s; skipped while away or
  /// when status is disabled (nostr-core.js `recordOwnActivity`).
  void recordOwnActivity() {
    final identity = _identity;
    if (identity == null) return;
    final appState = _ref.read(appStateProvider.notifier);
    final now = DateTime.now().millisecondsSinceEpoch;

    final existing = _ref.read(appStateProvider).users[identity.pubkey];
    final away = existing?.awayMessage != null &&
        existing!.awayMessage!.isNotEmpty;
    // Mark ourselves recently-seen (online unless locally away).
    appState.setUserPresence(
      pubkey: identity.pubkey,
      status: away ? UserStatus.away : UserStatus.online,
      nym: identity.nym,
      awayMessage: away ? existing.awayMessage : null,
      lastSeenMs: now,
    );

    // Disabled: never re-assert presence (a routine send would undo 'hidden').
    if (_statusMode == PresenceStatusMode.disabled) return;
    // Throttle to ≤1/60s; skip while away (cmdSetAway/cmdBack handle those).
    if (now - _lastPresenceBroadcast < _presenceBroadcastThrottleMs) return;
    if (away) return;
    unawaited(publishPresence('online'));
  }

  /// Starts the periodic presence re-assertion timer (idempotent).
  void _startPresenceTimer() {
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(
      const Duration(milliseconds: _presenceBroadcastThrottleMs),
      (_) => recordOwnActivity(),
    );
  }

  /// Signals typing in the current PM/group view (throttled ~1/s).
  Future<void> sendTypingStart() async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return;
    final state = _ref.read(appStateProvider);
    final view = state.view;
    // Context-aware scope gate (PWA `isIndicatorAllowedFor`): a typing scope of
    // 'pms' / 'groups' / 'pms-groups' restricts indicators to those surfaces and
    // 'disabled' suppresses them; channels require the default 'everywhere'.
    final scope = _ref.read(settingsProvider).typingIndicatorsScope;
    final ctx = view.kind == ViewKind.pm
        ? 'pm'
        : view.kind == ViewKind.group
            ? 'group'
            : 'channel';
    if (!_indicatorScopeAllows(scope, ctx)) return;

    final key = view.storageKey;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - (_typingThrottle[key] ?? 0) < 1000) return;
    _typingThrottle[key] = now;

    if (view.kind == ViewKind.channel) {
      // Public channel typing (kind 24420) — only for geohash channels, exactly
      // like the PWA `handleChannelTypingSignal` (gated on `currentGeohash`).
      final entry = state.channels.where((c) => c.key == view.id.toLowerCase());
      if (entry.isEmpty || !entry.first.isGeohash) return;
      await service.publishChannelTyping(
        status: 'start',
        geohash: entry.first.geohash,
        nym: identity.nym,
      );
      return;
    }

    if (view.kind == ViewKind.pm) {
      await service.publishTyping(status: 'start', recipients: [view.id]);
    } else {
      final group = _ref.read(appStateProvider.notifier).groupById(view.id);
      if (group == null) return;
      final ek = _groups!.keysFor(group.id);
      final others =
          group.members.where((p) => p != identity.pubkey).toList();
      await service.publishTyping(
        status: 'start',
        recipients: others,
        groupId: group.id,
        encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
      );
    }
  }

  /// Mirrors the PWA `isIndicatorAllowedFor`: a typing / read-receipt scope of
  /// 'pms', 'groups', or 'pms-groups' limits indicators to those contexts,
  /// 'disabled' suppresses them, and anything else ('everywhere') allows all
  /// surfaces — including public channels.
  bool _indicatorScopeAllows(String scope, String context) {
    switch (scope) {
      case 'disabled':
        return false;
      case 'pms':
        return context == 'pm';
      case 'groups':
        return context == 'group';
      case 'pms-groups':
        return context == 'pm' || context == 'group';
      default:
        return true;
    }
  }

  /// Sends a read receipt for [messageId] to [peerPubkey] (PM scope-gated).
  Future<void> sendReadReceipt(String messageId, String peerPubkey) async {
    if (!_readReceiptsAllowed()) return;
    final service = _service;
    if (service == null) return;
    await service.publishReceipt(
      messageId: messageId,
      receiptType: 'read',
      recipientPubkey: peerPubkey,
    );
  }

  // --- Public channel read receipts (kind 24421) -----------------------------
  // Mirrors the PWA's channel read-receipt path (nostr-core.js
  // `sendChannelReadReceipt` / `markVisibleChannelMessagesRead` /
  // `handleChannelReadReceipt`). Geohash channels only, like channel typing.

  /// Message ids we've already published a 24421 read receipt for, so we never
  /// re-announce the same channel message (PWA `_sentChannelReadReceipts`,
  /// capped 2000 → trimmed to the most recent 1500).
  final Set<String> _sentChannelReadReceipts = <String>{};

  bool _channelReceiptAllowed() =>
      _indicatorScopeAllows(
          _ref.read(settingsProvider).readReceiptsScope, 'channel');

  /// Publishes a public channel read receipt (kind 24421) for [messageId] by
  /// [authorPubkey] in [geohash], once per message. Scope-gated to the channel
  /// context and geohash channels only (PWA `sendChannelReadReceipt`): never
  /// receipts our own message, and dedupes via [_sentChannelReadReceipts].
  Future<void> sendChannelReadReceipt(
      String messageId, String authorPubkey, String geohash) async {
    if (!_channelReceiptAllowed()) return;
    if (messageId.isEmpty || authorPubkey.isEmpty || geohash.isEmpty) return;
    final identity = _identity;
    final service = _service;
    if (identity == null || service == null) return;
    if (authorPubkey == identity.pubkey) return;
    if (_sentChannelReadReceipts.contains(messageId)) return;
    _sentChannelReadReceipts.add(messageId);
    if (_sentChannelReadReceipts.length > 2000) {
      final keep = _sentChannelReadReceipts.toList().sublist(
          _sentChannelReadReceipts.length - 1500);
      _sentChannelReadReceipts
        ..clear()
        ..addAll(keep);
    }
    await service.publishChannelReceipt(
      messageId: messageId,
      authorPubkey: authorPubkey,
      geohash: geohash,
      nym: identity.nym,
    );
  }

  /// Catch-up: receipts every visible, fresh, non-own message in the currently
  /// open geohash channel (PWA `markVisibleChannelMessagesRead`). Called when
  /// the user opens / returns to a channel and on inbound messages, so receipts
  /// fire for messages that piled up while away. Per-message dedup lives in
  /// [sendChannelReadReceipt].
  void markVisibleChannelMessagesRead() {
    if (!_channelReceiptAllowed()) return;
    final identity = _identity;
    if (identity == null) return;
    final state = _ref.read(appStateProvider);
    final view = state.view;
    if (view.kind != ViewKind.channel) return;
    final entry = state.channels.where((c) => c.key == view.id.toLowerCase());
    if (entry.isEmpty || !entry.first.isGeohash) return;
    final geohash = entry.first.geohash;
    final messages = state.messages[view.storageKey];
    if (messages == null || messages.isEmpty) return;
    // Mirror the PWA's tail window (`messages.slice(-channelPageSize)`); 100 is
    // the runtime channel page size used elsewhere.
    final tail = messages.length > 100
        ? messages.sublist(messages.length - 100)
        : messages;
    for (final m in tail) {
      if (m.isOwn || m.isHistorical) continue;
      if (!_isChannelMessageId(m.id)) continue;
      final gh = (m.geohash ?? '').isNotEmpty ? m.geohash! : geohash;
      unawaited(sendChannelReadReceipt(m.id, m.pubkey, gh));
    }
  }

  /// True for a 64-hex channel-message id (PWA `/^[0-9a-f]{64}$/i` gate before
  /// a channel read receipt is sent).
  static final RegExp _channelMessageIdRe = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);
  bool _isChannelMessageId(String id) => _channelMessageIdRe.hasMatch(id);

  /// Routes an inbound public channel read receipt (kind 24421): someone saw a
  /// channel message. Mirrors the PWA's `handleChannelReadReceipt`: skips our
  /// own + stale (>5 min) receipts, parses the `['e', id]` / `['g'|'d', geo]` /
  /// `['n', nym]` tags, resolves the reader's display nym, and records it so the
  /// matching own message's reader avatars render.
  void _onChannelReadReceipt(NostrEvent event) {
    final self = _service?.selfPubkey ?? _identity?.pubkey ?? '';
    if (event.pubkey == self) return;
    final ageMs = DateTime.now().millisecondsSinceEpoch - event.createdAt * 1000;
    if (ageMs > 5 * 60 * 1000) return;

    final messageId = event.tagValue('e');
    final geohash = event.tagValue('g') ?? event.tagValue('d');
    if (messageId == null || messageId.isEmpty || geohash == null) return;

    final appState = _ref.read(appStateProvider);
    if (appState.blockedUsers.contains(event.pubkey)) return;

    // A read receipt is a self-attestation that the reader runs Nymchat — add
    // them to the trust graph + our vouch list (nostr-core.js:1647-1650).
    _observeNymchatPubkey(event.pubkey);

    // Reader display name: the receipt's `['n', nym]` (base), else the known
    // user nym, decorated with the pubkey suffix (PWA `stripPubkeySuffix(rawNym
    // || getNymFromPubkey(pubkey))`).
    final rawNym = event.tagValue('n');
    final base = stripPubkeySuffix(
        rawNym ?? appState.users[event.pubkey]?.nym ?? 'anon');
    final readerNym = '$base#${getPubkeySuffix(event.pubkey)}';

    _ref.read(appStateProvider.notifier).applyChannelReader(
          messageId: messageId,
          readerPubkey: event.pubkey,
          readerNym: readerNym,
        );
  }

  // ---------------------------------------------------------------------------
  // Reactions (kind 7 public / gift-wrapped private)
  // ---------------------------------------------------------------------------

  /// Toggles the local user's [emoji] reaction on [messageId]. [target] is the
  /// reacted message's author pubkey; [kind] is the reacted message's kind
  /// ('20000' geohash / '23333' named / '1059' PM / '14' group rumor). Applies
  /// an optimistic local update, enforces the 3/30s rate limit + 60s cooldown,
  /// and re-sends with `['action','remove']` to un-react. Private (PM/group)
  /// reactions are gift-wrapped per docs/specs/03 §5.2.
  ///
  /// Returns true if the toggle was sent (false when rate-limited or no signer).
  Future<bool> toggleReaction(
    String messageId,
    String emoji, {
    required String target,
    required String kind,
  }) async {
    if (messageId.isEmpty || emoji.isEmpty) return false;
    if (!_checkReactionRateLimit(messageId, emoji)) return false;

    final appState = _ref.read(appStateProvider.notifier);
    final state = _ref.read(appStateProvider);
    final self = state.selfPubkey;

    // Determine current reaction state to decide add vs remove.
    final existing = state.reactions[messageId] ?? const [];
    final reacted = existing.any((r) => r.emoji == emoji && r.userReacted);
    final remove = reacted;

    // Optimistic local update.
    appState.applyReaction(
      messageId: messageId,
      emoji: emoji,
      reactor: self,
      removed: remove,
      reactorNym: state.selfNym,
    );

    final service = _service;
    if (service == null || !service.canSign) return false;

    // Private reactions (PM/group) are gift-wrapped to the conversation.
    if (kind == '1059' || kind == '14') {
      return _sendPrivateReaction(messageId, emoji, target, remove);
    }

    // Public channel reaction. Resolve the channel context from the active view.
    String? geohash;
    String? channel;
    if (state.view.kind == ViewKind.channel) {
      final entry = state.channels
          .where((c) => c.key == state.view.id.toLowerCase());
      if (entry.isNotEmpty && entry.first.isGeohash) {
        geohash = entry.first.geohash;
      } else {
        channel = state.view.id;
      }
    }
    await service.publishReaction(
      messageId: messageId,
      targetPubkey: target,
      emoji: emoji,
      originalKind: kind,
      geohash: geohash,
      channel: channel,
      remove: remove,
    );
    return true;
  }

  Future<bool> _sendPrivateReaction(
      String messageId, String emoji, String target, bool remove) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return false;
    final appState = _ref.read(appStateProvider.notifier);
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Group message reaction: gift-wrap to all members with ['g',groupId].
    final view = _ref.read(appStateProvider).view;
    if (view.kind == ViewKind.group) {
      final group = appState.groupById(view.id);
      if (group == null) return false;
      final ek = _groups!.keysFor(group.id);
      final rumor = UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: nowSec,
        kind: EventKind.reaction,
        tags: [
          ['g', group.id],
          ['e', messageId],
          ['k', '14'],
          if (remove) ['action', 'remove'],
        ],
        content: emoji,
      );
      return service.publishGiftWrappedRumor(
        rumor: rumor,
        recipients: group.members,
        encryptTo: (pk) => ek.encryptionPubkeyFor(pk, identity.pubkey),
      );
    }

    // 1:1 PM reaction: gift-wrap to [self, peer] with ['p',target],['k','1059'].
    final peer = view.kind == ViewKind.pm ? view.id : target;
    final rumor = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: nowSec,
      kind: EventKind.reaction,
      tags: [
        ['e', messageId],
        ['p', target],
        ['k', '1059'],
        if (remove) ['action', 'remove'],
      ],
      content: emoji,
    );
    return service.publishGiftWrappedRumor(
      rumor: rumor,
      recipients: [identity.pubkey, peer],
    );
  }

  bool _checkReactionRateLimit(String messageId, String emoji) {
    final key = '$messageId:$emoji';
    final now = DateTime.now().millisecondsSinceEpoch;
    const windowMs = 30000;
    const maxToggles = 3;
    final tracker =
        _reactionToggleTracker.putIfAbsent(key, _ReactionRateTracker.new);
    if (now < tracker.cooldownUntil) return false;
    tracker.timestamps.removeWhere((ts) => now - ts >= windowMs);
    if (tracker.timestamps.length >= maxToggles) {
      tracker.cooldownUntil = now + 60000; // 60s cooldown on breach
      return false;
    }
    tracker.timestamps.add(now);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Polls (kind 30078 nym-poll / nym-poll-vote) — channel-only.
  // ---------------------------------------------------------------------------

  /// Creates a poll in the current geohash channel (`publishPoll`). Returns the
  /// created [Poll], or null when not in a channel view or unable to sign.
  Future<Poll?> publishPoll(String question, List<String> options) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return null;
    final state = _ref.read(appStateProvider);
    if (state.view.kind != ViewKind.channel) return null;
    final geohash = state.view.id;

    final id8 = PollLogic.generatePollId8();
    final rumor = PollLogic.buildPollEvent(
      pubkey: identity.pubkey,
      nym: identity.nym,
      geohash: geohash,
      question: question,
      options: options,
      pollId8: id8,
    );
    final signed = await service.publishPollEvent(rumor);
    if (signed == null) return null;

    final poll = Poll(
      id: signed.id,
      question: question,
      options: [
        for (var i = 0; i < options.length; i++)
          PollOption(index: i, text: options[i]),
      ],
      pubkey: identity.pubkey,
      nym: identity.nym,
      geohash: geohash,
      createdAt: signed.createdAt,
    );
    _ref.read(appStateProvider.notifier).upsertPoll(poll);
    return poll;
  }

  /// Casts the local user's vote on [pollId] for [optionIndex] (`votePoll`).
  /// One vote per pubkey — no-op if already voted. Returns true if sent.
  Future<bool> votePoll(String pollId, int optionIndex) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return false;
    final appState = _ref.read(appStateProvider.notifier);
    final poll = _ref.read(appStateProvider).polls[pollId];
    if (poll == null) return false;
    if (poll.votes.containsKey(identity.pubkey)) return false;

    final rumor = PollLogic.buildVoteEvent(
      pubkey: identity.pubkey,
      nym: identity.nym,
      geohash: poll.geohash,
      pollId: pollId,
      optionIndex: optionIndex,
    );
    final signed = await service.publishPollEvent(rumor);
    if (signed == null) return false;
    appState.applyLocalVote(pollId, optionIndex);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Profile save (kind 0)
  // ---------------------------------------------------------------------------

  /// Builds, signs, and publishes a kind-0 profile, updating the local
  /// [UserProfile] + identity nym (`saveToNostrProfile`). Empty/null fields are
  /// omitted. Returns true on publish.
  Future<bool> saveProfile({
    String? name,
    String? about,
    String? picture,
    String? banner,
    String? lud16,
  }) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return false;

    final profile = <String, dynamic>{};
    if (name != null && name.isNotEmpty) {
      profile['name'] = name;
      profile['display_name'] = name;
    }
    if (about != null) profile['about'] = about;
    if (picture != null && picture.isNotEmpty) profile['picture'] = picture;
    if (banner != null && banner.isNotEmpty) profile['banner'] = banner;
    if (lud16 != null && lud16.isNotEmpty) profile['lud16'] = lud16;

    final signed = await service.publishProfile(jsonEncode(profile));
    if (signed == null) return false;

    // Update local identity nym + user profile.
    if (name != null && name.isNotEmpty) {
      identity.nym = getNymFromPubkey(name, identity.pubkey);
    }
    final appState = _ref.read(appStateProvider.notifier);
    appState.setIdentity(identity.pubkey, identity.nym);
    appState.ingestEvent(signed); // routes kind-0 → _ingestProfile

    // Mirror the signed kind-0 to D1 (`profile-set`) in addition to the relay
    // publish, so other clients get a fast public read (`_saveProfileToD1`,
    // nostr-core.js:194). Only durable identities mirror (the PWA gates on
    // `_hasCustomProfileData`; durable = logged-in is the native analogue).
    final sync = _storageSync;
    if (sync != null && sync.durableIdentity) {
      unawaited(sync.profileSet(signed.toJson()));
    }
    return true;
  }

  /// Resolves unknown [pubkeys] D1-first: batch-reads kind-0 events from D1 via
  /// `profile-get` (faster), routes each through the kind-0 ingest path (the
  /// `kind0Ts` dedup keeps live relay updates authoritative), then falls back to
  /// a relay kind-0 sub for the ones D1 didn't have. Mirrors the PWA's
  /// `_flushProfileBatch` (nostr-core.js:1784). Best-effort.
  Future<void> resolveProfiles(List<String> pubkeys) async {
    if (pubkeys.isEmpty) return;
    final service = _service;
    final appState = _ref.read(appStateProvider.notifier);
    final sync = _storageSync;
    var missing = pubkeys;
    if (sync != null) {
      try {
        final found = await sync.profileGet(pubkeys);
        if (found.isNotEmpty) {
          for (final entry in found.entries) {
            final ev = entry.value;
            if (ev.isEmpty) continue; // cache hit, no event payload
            try {
              appState.ingestEvent(NostrEvent.fromJson(ev));
            } catch (_) {}
          }
          missing = pubkeys
              .where((pk) => !found.containsKey(pk.toLowerCase()))
              .toList();
        }
      } catch (_) {
        // Fall through to relays.
      }
    }
    if (missing.isEmpty) return;
    service?.fetchProfiles(missing);
  }

  // ---------------------------------------------------------------------------
  // Channel management (docs/specs/03 §1.3–§1.6) — persists to KV list sets.
  // ---------------------------------------------------------------------------

  /// Switches to [channel] (adds it if unknown), persists the joined-channel
  /// list, and subscribes the active channel's typing sub (`switchChannel`).
  void switchChannel(String channel, {String geohash = ''}) {
    final appState = _ref.read(appStateProvider.notifier);
    appState.switchChannel(channel, geohash: geohash);
    _persistJoinedChannels();
    _subscribeActiveChannelTyping();
    // Connect the closest geo relays for a geohash channel so its messages are
    // delivered to nearby relays (PWA `connectToGeoRelays` on channel entry).
    final gh = geohash.isNotEmpty ? geohash : channel;
    if (isChannelGeohash(gh)) {
      unawaited(_service?.connectGeoRelaysForGeohash(gh) ?? Future.value());
    }
  }

  /// Adds [channel] to the registry + persists (`addChannel`).
  ChannelEntry addChannel(String channel, {String geohash = ''}) {
    final entry =
        _ref.read(appStateProvider.notifier).addChannel(channel, geohash: geohash);
    _persistJoinedChannels();
    return entry;
  }

  /// Removes [key] (not `#nymchat`) and persists (`removeChannel`).
  bool removeChannel(String key) {
    final ok = _ref.read(appStateProvider.notifier).removeChannel(key);
    if (ok) _persistJoinedChannels();
    return ok;
  }

  /// Toggles pinned (favorite) and persists `nym_pinned_channels` (`togglePin`).
  bool togglePin(String key) {
    final pinned = _ref.read(appStateProvider.notifier).togglePin(key);
    _persistSet(StorageKeys.pinnedChannels,
        _ref.read(appStateProvider).pinnedChannels);
    return pinned;
  }

  /// Hides [key] from the sidebar and persists `nym_hidden_channels`.
  bool hideChannel(String key) {
    final ok = _ref.read(appStateProvider.notifier).hideChannel(key);
    _persistSet(StorageKeys.hiddenChannels,
        _ref.read(appStateProvider).hiddenChannels);
    return ok;
  }

  /// Blocks [key] (not `#nymchat`) and persists `nym_blocked_channels`.
  bool blockChannel(String key) {
    final ok = _ref.read(appStateProvider.notifier).blockChannel(key);
    if (ok) {
      _persistSet(StorageKeys.blockedChannels,
          _ref.read(appStateProvider).blockedChannels);
      _persistJoinedChannels();
    }
    return ok;
  }

  void _persistJoinedChannels() {
    final kv = _ref.read(keyValueStoreProvider);
    final channels = _ref.read(appStateProvider).channels;
    final keys = channels.map((c) => c.key).toList();
    kv.setString(StorageKeys.userJoinedChannels, jsonEncode(keys));
    final snapshot = channels.map((c) => c.toJson()).toList();
    kv.setString(StorageKeys.userChannels, jsonEncode(snapshot));
  }

  void _persistSet(String key, Set<String> values) {
    _ref.read(keyValueStoreProvider).setString(key, jsonEncode(values.toList()));
  }

  /// Reads a persisted JSON string-array set (`['a','b']`) from KV; empty if
  /// missing/malformed.
  Set<String> _readSet(String key) {
    final raw = _ref.read(keyValueStoreProvider).getString(key);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toSet();
      }
    } catch (_) {}
    return <String>{};
  }

  /// Hydrates friends / blocked users / blocked keywords from KV (boot). Mirrors
  /// the PWA constructor parsing `nym_friends` / `nym_blocked` /
  /// `nym_blocked_keywords` JSON arrays into Sets.
  void _hydrateSocialState(AppStateNotifier appState) {
    appState.hydrateSocialState(
      friends: _readSet(StorageKeys.friends),
      blockedUsers: _readSet(StorageKeys.blocked),
      blockedKeywords: _readSet(StorageKeys.blockedKeywords),
    );
  }

  void _subscribeActiveChannelTyping() {
    final state = _ref.read(appStateProvider);
    if (state.view.kind != ViewKind.channel) return;
    final entry =
        state.channels.where((c) => c.key == state.view.id.toLowerCase());
    if (entry.isEmpty || !entry.first.isGeohash) return;
    _service?.subscribeChannelTyping(entry.first.geohash);
    // Receipt the messages that piled up here while we were away (PWA
    // `openChannel` → `markVisibleChannelMessagesRead`).
    markVisibleChannelMessagesRead();
  }

  // ---------------------------------------------------------------------------
  // Zaps (nostr side only) — the LNURL HTTP/invoice/pay flow is the UI's job.
  // ---------------------------------------------------------------------------

  /// Builds and signs a NIP-57 kind-9734 zap request, publishing it and
  /// returning the signed event so the UI can pass it to the LNURL callback's
  /// `nostr` param. [originalKind] is the zapped message's kind for message zaps
  /// ('20000'/'23333'/'1059'); null for a profile zap.
  Future<NostrEvent?> buildZapRequest({
    required String recipientPubkey,
    required int amountSats,
    String? messageId,
    String? originalKind,
    String comment = '',
  }) async {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return null;
    final rumor = ZapLogic.buildZapRequest(
      pubkey: identity.pubkey,
      recipientPubkey: recipientPubkey,
      amountSats: amountSats,
      relays: RelayConfig.defaultRelays,
      messageId: messageId,
      originalKind: originalKind,
      comment: comment,
    );
    return service.publishZapRequest(rumor);
  }

  // ---------------------------------------------------------------------------
  // Persistence hydration / flush
  // ---------------------------------------------------------------------------

  Future<void> _hydrateFromCache(AppStateNotifier appState) async {
    try {
      final cache = CacheStore();
      await cache.open();
      _cache = cache;
      // Load stores in parallel (mirrors hydrateFromCache's Promise.all).
      final results = await Future.wait([
        cache.loadAllProfiles(),
        cache.loadAllReactions(),
      ]);
      final profiles = results[0] as Map<String, UserProfile>;
      final reactions = results[1] as Map<String, List<dynamic>>;
      if (profiles.isNotEmpty) appState.hydrateProfiles(profiles);
      if (reactions.isNotEmpty) appState.hydrateReactions(reactions);
      // Web-of-trust graph: restore the persisted nymchatPubkeys / vouches /
      // trusted sets so the spam gate isn't cold on launch (it still grows live
      // from PoW-valid messages + receipts + vouches).
      final trust = await Future.wait([
        cache.loadMetaSet(CacheStore.metaNymchatPubkeys),
        cache.loadMetaSet(CacheStore.metaNymchatVouches),
        cache.loadMetaSet(CacheStore.metaTrustedPubkeys),
      ]);
      appState.hydrateTrustSets(trust[0], trust[1], trust[2]);
      // Channel/PM message rehydration happens lazily as channels are opened
      // (loadChannelMessages); the cache is wired so saves persist 1000 caps.
    } catch (e) {
      debugPrint('hydrateFromCache failed: $e');
    }
  }

  /// Marks [storageKey] dirty and schedules a debounced flush to the cache.
  void _markDirty(String storageKey) {
    if (_cache == null) return;
    if (storageKey.startsWith('pm-') || storageKey.startsWith('group-')) {
      _dirtyPmKeys.add(storageKey);
    } else {
      _dirtyChannelKeys.add(storageKey);
    }
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 6), () {
      _flushScheduled = false;
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    final cache = _cache;
    if (cache == null) return;
    final state = _ref.read(appStateProvider);
    final cachePms = _ref.read(settingsProvider).cachePMs;
    try {
      final channelKeys = _dirtyChannelKeys.toList();
      final pmKeys = _dirtyPmKeys.toList();
      final reactionEntries =
          _ref.read(appStateProvider.notifier).reactionEntriesSnapshot();
      // Commit the whole flush as ONE transaction so a busy channel's hundreds
      // of channel/PM/profile/reaction rows don't queue up as hundreds of
      // separately-locked inserts (which tripped sqflite's 10s lock warning and
      // stalled D1 ingest). Dirty sets are cleared only after the tx succeeds.
      await cache.runInTransaction((txn) async {
        for (final key in channelKeys) {
          final msgs = state.messages[key];
          if (msgs != null) {
            await cache.saveChannelMessages(key, _capChannel(msgs), txn);
          }
        }
        for (final key in pmKeys) {
          final msgs = state.messages[key];
          if (msgs != null) {
            await cache.savePmMessages(key, _capPm(msgs),
                enabled: cachePms, executor: txn);
          }
        }
        for (final entry in state.users.entries) {
          final p = entry.value.profile;
          if (p != null) await cache.saveProfile(entry.key, p, txn);
        }
        for (final e in reactionEntries.entries) {
          await cache.saveReactions(e.key, e.value, txn);
        }
      });
      _dirtyChannelKeys.clear();
      _dirtyPmKeys.clear();
      await cache.enforceLruLimits();
    } catch (e) {
      debugPrint('cache flush failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Cross-device storage sync (`/api/storage`): encrypted settings, D1-first
  // profile mirror, PM gift-wrap archive. Mirrors settings.js / nostr-core.js /
  // pms.js. Every call is lazy + failure-tolerant.
  // ---------------------------------------------------------------------------

  /// Builds the [StorageSync] for the booted identity and wires the NIP-98
  /// (kind-27235) auth builder. Durable identities (loginMethod != null, the
  /// PWA's `isNostrLoggedIn()`) participate in the PM archive; ephemeral skip it.
  void _initStorageSync(Identity identity, EventSigner? signer) {
    if (signer == null) return;
    final api = _api ??= ApiClient();
    final durable = identity.loginMethod != null;
    final sync = StorageSync(
      api: api,
      signer: signer,
      pubkey: identity.pubkey,
      durableIdentity: durable,
    );
    // Auth builder: sign a kind-27235 event bound to the storage URL + action
    // through the active signer (`Nip98Auth.buildSigned` mirrors the PWA's
    // `_signBotAuth` → `signEvent` dispatch). This signs for BOTH a local key and
    // a NIP-46 remote signer, so durable remote-signer accounts now authenticate
    // their settings/PM sync too. Non-sensitive auth is cached 90s so a remote
    // signer isn't round-tripped per request (the PWA's `_botAuthCache`).
    sync.setAuthBuilder((action) => Nip98Auth.buildSigned(
          action: action,
          url: StorageSync.storageUrl(),
          signer: signer,
        ));

    // Activate the WS-first storage transport (the PWA's persistent `/api`
    // socket). Reads in [StorageSync] now try `wss://<host>/api` FIRST and fall
    // back to HTTP on ANY socket failure (no socket, auth failure, timeout,
    // error frame, disconnect — all routed to null inside [ApiClient._trySocket]).
    // The HTTP path is untouched, so data loading is never lost to the socket.
    //
    // The socket's one-time AUTH handshake signs a kind-27235 `api-ws` event
    // bound to `https://<host>/api/WS` — the PWA's `_signBotAuth('api-ws','WS')`
    // (endpoint 'WS' → `/api/WS`), distinct from the storage `/api/storage`
    // `u`-tag. Signed through the same signer, so a NIP-46 remote signer also
    // authenticates the socket (one remote sign at connect, cached). If signing
    // fails (remote unreachable/declined), the socket opens UNAUTHENTICATED for
    // public reads, exactly like a logged-out PWA.
    api.setApiSocketAuthBuilder(() => Nip98Auth.buildSigned(
          action: 'api-ws',
          url: _apiWsAuthUrl(),
          signer: signer,
        ));
    api.activateApiSocket();
    _storageSync = sync;

    // The other-users shop-status fetcher (cosmetics for OTHER pubkeys) must
    // never query our own pubkey — our own record loads via shop-get below.
    _ref.read(otherUsersShopProvider.notifier).selfPubkey =
        identity.pubkey.toLowerCase();

    // Fire a debounced encrypted-settings publish whenever a synced setting
    // changes (the PWA's `nostrSettingsSave()` peppered through every setter).
    _ref.read(settingsProvider.notifier).onSyncedChange = syncSettings;

    // Backfill conversation history from the D1 archive on open (the PWA's
    // per-open `channelRestoreFromD1` in `switchChannel`, plus the ephemeral
    // group inbox). Best-effort; gated/idempotent inside the handler.
    _ref.read(appStateProvider.notifier).onViewOpened = _onViewOpened;
  }

  /// The NIP-98 `u`-tag URL the `/api` socket's `api-ws` AUTH event binds to:
  /// `https://<host>/api/WS`. Mirrors the PWA's `_signBotAuth('api-ws', 'WS')`
  /// (endpoint 'WS' → `https://${apiHost}/api/WS`, pms.js:1652). Derived from the
  /// storage URL so it tracks the same fixed host without an extra import.
  static String _apiWsAuthUrl() {
    final u = Uri.parse(StorageSync.storageUrl()); // …/api/storage
    final segs = List<String>.from(u.pathSegments);
    if (segs.isNotEmpty) {
      segs[segs.length - 1] = 'WS';
    } else {
      segs.add('WS');
    }
    return Uri(
      scheme: u.scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      pathSegments: segs,
    ).toString();
  }

  /// Reacts to a conversation being opened ([AppStateNotifier.switchView]) by
  /// fetching its D1 message archive and ingesting it through the same pipeline
  /// live events use. Channels hit `channel-get`; groups pull the ephemeral
  /// inbox. PMs need no per-open fetch — their archive is restored globally at
  /// boot via [_restorePmArchive] (`pmRestoreFromD1`), matching the PWA, which
  /// also restores all 1:1 PMs up front rather than per-conversation. All work
  /// is best-effort and never blocks the (already-committed) view switch.
  void _onViewOpened(ChatView view) {
    switch (view.kind) {
      case ViewKind.channel:
        unawaited(_backfillChannelArchive(view.id));
        // Catch up read receipts for messages already loaded in this channel
        // (PWA `openChannel` → `markVisibleChannelMessagesRead`). Newly
        // backfilled messages are receipted as they ingest in `_onEvent`.
        markVisibleChannelMessagesRead();
      case ViewKind.group:
        unawaited(_backfillGroupArchive());
      case ViewKind.pm:
        break;
    }
  }

  /// App returned to the foreground. Re-hydrate the open conversation from D1 so
  /// the active channel/group immediately catches up on anything missed while
  /// backgrounded — the native equivalent of the PWA's `visibilitychange →
  /// backfillFromD1OnReconnect`. Live relay feeds resume via the service's own
  /// socket reconnect, so this only needs the per-view archive top-up.
  void onAppResumed() => _onViewOpened(_ref.read(appStateProvider).view);

  /// Per-channel "backfilled" gate (channels.js `_channelD1FetchedAt`). The
  /// 60s freshness window lives in [StorageSync.channelGet]; this set just
  /// avoids redundant in-flight calls within the same tight switch loop.
  final Set<String> _channelBackfillInFlight = <String>{};

  // --- D1 profile backfill (PWA `queueProfileFetch` / `_flushProfileBatch`) ---

  /// Pubkeys queued for a batched D1 `profile-get` because we ingested a
  /// message from them but hold no kind-0 profile yet (PWA `_profileBatchQueue`,
  /// nostr-core.js:1774). Deduped against [_profileBackfillQueued] so a busy
  /// channel can't enqueue the same author repeatedly within a flush window.
  final List<String> _profileBackfillQueue = <String>[];
  final Set<String> _profileBackfillQueued = <String>{};
  Timer? _profileBackfillTimer;

  /// Resolves D1 profiles for a LIST of pubkeys (a reactors / zappers sheet, a
  /// group-member or poll-voter list, a mention set) so each row shows its custom
  /// avatar instead of the identicon — the PWA's `ensureListProfiles`. Each entry
  /// goes through the same debounced, picture-guarded [_maybeBackfillProfiles], so
  /// known avatars are skipped and the rest batch into one `profile-get`.
  void ensureProfiles(Iterable<String> pubkeys) {
    for (final pk in pubkeys) {
      _maybeBackfillProfiles(pk);
    }
  }

  /// Enqueues [pubkey] for a debounced D1 profile fetch when we have no kind-0
  /// profile for it yet. Mirrors the PWA's `queueProfileFetch`
  /// (nostr-core.js:1767): a busy channel/PM/group stream only triggers ONE
  /// batched `profile-get` per ~400ms window rather than a request per message.
  /// No-op without storage sync, for an invalid/self pubkey, or when the user is
  /// already known with a profile. The flush routes each returned kind-0 event
  /// through [resolveProfiles] (same ingest path live relay kind-0 events take).
  void _maybeBackfillProfiles(String? pubkey) {
    if (pubkey == null || pubkey.length != 64) return;
    if (_storageSync == null) return;
    final self = _service?.selfPubkey ?? _identity?.pubkey;
    if (pubkey == self) return;
    // Already have this user's AVATAR → nothing to fetch. Keying on the picture
    // (not profile-existence) mirrors the PWA, which guards on `userAvatars`
    // (nostr-core.js:440/1771): a nym-only kind-0, or a presence that cleared the
    // avatar, leaves a picture-less profile stub that must NOT permanently block
    // the avatar backfill (the old `profile != null` guard did exactly that).
    final pic = _ref.read(appStateProvider).users[pubkey]?.profile?.picture;
    if (pic != null && pic.isNotEmpty) return;
    // Staleness gate (PWA `profileFetchedAt`, 5 min): an AVATAR-LESS user (anon,
    // or a kind-0 with no picture) would otherwise re-queue a fetch on EVERY
    // presence/message/reaction — a steady background churn. Only re-attempt
    // once the previous attempt is ≥5 min old.
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _profileBackfillAttemptedAt[pubkey];
    if (last != null && now - last < 5 * 60 * 1000) return;
    _profileBackfillAttemptedAt[pubkey] = now;
    if (_profileBackfillAttemptedAt.length > 5000) {
      _profileBackfillAttemptedAt.remove(_profileBackfillAttemptedAt.keys.first);
    }
    if (!_profileBackfillQueued.add(pubkey)) return;
    _profileBackfillQueue.add(pubkey);
    _profileBackfillTimer ??= Timer(
      const Duration(milliseconds: 400),
      _flushProfileBackfill,
    );
  }

  /// Per-pubkey last profile-backfill ATTEMPT (ms) — the PWA's `profileFetchedAt`
  /// staleness gate so an avatar-less user isn't re-fetched on every event.
  final Map<String, int> _profileBackfillAttemptedAt = {};

  /// Drains the queued pubkeys and resolves their profiles D1-first
  /// (`resolveProfiles` → `profileGet`, falling back to a relay kind-0 sub for
  /// any D1 didn't have). Mirrors the PWA's `_flushProfileBatch`
  /// (nostr-core.js:1784). Best-effort; failures are swallowed inside
  /// [resolveProfiles].
  void _flushProfileBackfill() {
    _profileBackfillTimer = null;
    if (_profileBackfillQueue.isEmpty) return;
    final batch = List<String>.from(_profileBackfillQueue);
    _profileBackfillQueue.clear();
    _profileBackfillQueued.clear();
    unawaited(resolveProfiles(batch));
  }

  /// Fetches a single channel's D1 archive (`channel-get`) and replays each
  /// archived event through [AppStateNotifier.ingestEvent] — the SAME path the
  /// live relay subscription uses (`_onEvent`), so dedup by id (`_seenIds`),
  /// `created_at`/`ms` ordering, and cosmetics all apply. [channelKey] is the
  /// geohash or named-channel key (the PWA's `geohash || channel`). No-op
  /// without storage sync; failures are swallowed.
  Future<void> _backfillChannelArchive(String channelKey) async {
    final sync = _storageSync;
    if (sync == null || channelKey.isEmpty) return;
    final name = channelKey.toLowerCase();
    if (!_channelBackfillInFlight.add(name)) return;
    try {
      // FORCE the fetch, bypassing channelGet's 60s freshness window — this is an
      // explicit channel OPEN/boot, which the PWA always forces
      // (`channelRestoreFromD1(geohash || channel, { force: true })` in
      // `switchChannel`, channels.js:1264, and the boot landing-channel switch,
      // relays.js:1066). Without `force` a prior probe (or a FAILED earlier
      // attempt — `channelGet` marks `_channelFetchedAt` BEFORE the request and
      // doesn't unmark on error) would suppress the boot/open restore for 60s,
      // leaving #nymchat empty with no retry. `_channelBackfillInFlight` still
      // de-dups concurrent calls for the same channel.
      final events = await sync.channelGet([name], force: true);
      final appState = _ref.read(appStateProvider.notifier);
      for (final raw in events) {
        try {
          appState.ingestEvent(NostrEvent.fromJson(raw));
        } catch (_) {
          // Skip a malformed archived event (mirrors the PWA's per-event catch).
        }
      }
    } catch (_) {
      // Best-effort: live subscription continues regardless.
    } finally {
      _channelBackfillInFlight.remove(name);
    }
  }

  /// Restores group history from the ephemeral-key D1 inbox on group open
  /// (`_recoverEphemeralHistory`, relays.js:2631). Group messages OTHER members
  /// sent are gift-wrapped to our per-group ephemeral keys, so they live in the
  /// `pm-get?pubkeys=` inbox rather than our own (those addressed-to-us wraps,
  /// incl. our own sent copies, are restored at boot by [_restorePmArchive]).
  /// Each restored wrap is unwrapped + routed through the normal gift-wrap
  /// handler (re-archiving is a no-op via the session dedup). Gated to one
  /// in-flight pass; idempotent via the wrap-id dedup in [StorageSync].
  Future<void> _backfillGroupArchive() async {
    final sync = _storageSync;
    final groups = _groups;
    final service = _service;
    if (sync == null || groups == null || service == null) return;
    if (_groupBackfillInFlight) return;
    _groupBackfillInFlight = true;
    try {
      final ephPks = groups.allEphemeralPubkeys();
      if (ephPks.isEmpty) return;
      final wraps = await sync.pmGetByPubkeys(ephPks);
      for (final w in wraps) {
        _replayArchivedWrap(w);
      }
    } catch (_) {
      // Best-effort.
    } finally {
      _groupBackfillInFlight = false;
    }
  }

  bool _groupBackfillInFlight = false;

  /// Boot-time sync: merge cross-device encrypted settings (honoring
  /// `nym_last_settings_sync_ts`), then restore the PM backlog from D1 for
  /// durable identities (gated by `cachePMs`). Both best-effort.
  Future<void> _bootStorageSync() async {
    final sync = _storageSync;
    if (sync == null) return;
    await _mergeRemoteSettings(sync);
    await _restorePmArchive(sync);
    // Load the user's own shop record (owned + active cosmetics) from D1 so their
    // purchased flair/style applies on a fresh device (PWA `loadShopFromServer`,
    // shop.js:358). Local-key only (remote signers can't auth the read).
    final id = _identity;
    if (id != null && id.privkey != null) {
      unawaited(_ref.read(shopControllerProvider.notifier).loadFromServer(
          ShopIdentity(pubkey: id.pubkey, privkey: id.privkey)));
    }
  }

  /// `settings-get` → merge into the local [Settings] when the remote blob is
  /// newer than the stored sync ts (settings.js `settingsLoadFromD1`).
  Future<void> _mergeRemoteSettings(StorageSync sync) async {
    try {
      final result = await sync.settingsGet();
      if (result == null) return;
      final kv = _ref.read(keyValueStoreProvider);
      final lastTs = int.tryParse(
              kv.getString(StorageKeys.lastSettingsSyncTs) ?? '0') ??
          0;
      // The stored ts is in seconds (PWA); newestTs is ms. Compare in seconds.
      final newestSec = result.newestTs ~/ 1000;
      if (newestSec <= lastTs) return;
      _applySyncedSettings(result.payload);
      // Cross-device "encryption at rest preferred" hint (app.js:6101): persist
      // it so the encrypt-at-rest prompt only offers to protect this device when
      // the user already uses encryption elsewhere (key-vault.js:419 gate).
      if (result.payload['encryptAtRestPreferred'] == true) {
        await kv.setBool(StorageKeys.encryptAtRestPref, true);
      }
      kv.setString(StorageKeys.lastSettingsSyncTs, '$newestSec');
    } catch (_) {
      // Best-effort.
    }
  }

  /// Applies a decoded synced-settings payload (PWA field names) into the
  /// [SettingsController] via its typed setters. Unknown / device-local keys are
  /// ignored. Wrapped so a single bad field can't abort the merge.
  void _applySyncedSettings(Map<String, dynamic> p) {
    final c = _ref.read(settingsProvider.notifier);
    void str(String key, void Function(String) set) {
      final v = p[key];
      if (v is String && v.isNotEmpty) {
        try {
          set(v);
        } catch (_) {}
      }
    }

    void boolean(String key, void Function(bool) set) {
      final v = p[key];
      if (v is bool) {
        try {
          set(v);
        } catch (_) {}
      }
    }

    void integer(String key, void Function(int) set) {
      final v = p[key];
      if (v is num) {
        try {
          set(v.toInt());
        } catch (_) {}
      }
    }

    str('sound', c.setSound);
    boolean('autoscroll', c.setAutoscroll);
    boolean('showTimestamps', c.setShowTimestamps);
    str('timeFormat', c.setTimeFormat);
    str('dateFormat', c.setDateFormat);
    str('chatLayout', c.setChatLayout);
    str('chatViewMode', c.setChatViewMode);
    boolean('columnsWallpaper', c.setColumnsWallpaper);
    str('nickStyle', c.setNickStyle);
    str('wallpaperType', c.setWallpaperType);
    integer('textSize', c.setTextSize);
    boolean('transparencyEnabled', c.setTransparencyEnabled);
    boolean('dmForwardSecrecyEnabled', c.setDmForwardSecrecy);
    integer('dmTTLSeconds', c.setDmTtlSeconds);
    str('readReceiptsScope', c.setReadReceiptsScope);
    str('typingIndicatorsScope', c.setTypingIndicatorsScope);
    str('acceptPMs', c.setAcceptPMs);
    str('acceptCalls', c.setAcceptCalls);
    boolean('groupChatPMOnlyMode', c.setGroupChatPMOnlyMode);
    str('translateLanguage', c.setTranslateLanguage);
    boolean('gesturesEnabled', c.setGesturesEnabled);
    str('swipeLeftAction', c.setSwipeLeftAction);
    str('swipeRightAction', c.setSwipeRightAction);
    integer('swipeThreshold', c.setSwipeThreshold);
    str('swipeReactEmoji', c.setSwipeReactEmoji);
    boolean('sortByProximity', c.setSortByProximity);
    boolean('lowDataMode', c.setLowDataMode);
    boolean('cachePMs', c.setCachePMs);
    // showStatus arrives as bool|'friends' (settings.js normalization).
    final ss = p['showStatus'];
    if (ss is bool) {
      c.setShowStatus(ss ? 'true' : 'false');
    } else if (ss == 'friends') {
      c.setShowStatus('friends');
    }
  }

  // ---------------------------------------------------------------------------
  // Pending settings transfers (inbound cross-device settings offers). The PWA
  // auto-applies remote settings; the native UI instead surfaces each newer
  // section as an accept/decline offer so the user opts in. Data lives in
  // [pendingSettingsTransfersProvider]; these methods populate + resolve it.
  // ---------------------------------------------------------------------------

  /// Re-fetches the inbound settings-transfer offers (sections in D1 newer than
  /// our last applied sync ts) and publishes them to
  /// [pendingSettingsTransfersProvider]. Best-effort; no-op without storage sync.
  Future<void> refreshPendingSettingsTransfers() async {
    final sync = _storageSync;
    if (sync == null) return;
    try {
      final sinceMs = _lastSettingsSyncMs();
      final offers = await sync.settingsTransfersSince(sinceMs);
      _ref
          .read(pendingSettingsTransfersProvider.notifier)
          .setOffers(offers);
    } catch (_) {
      // Best-effort.
    }
  }

  /// Accepts an inbound settings-transfer [id]: applies the section's payload to
  /// the local [Settings] (PWA field names → typed setters), advances the stored
  /// sync ts to its `updatedAt` so it won't re-offer, and removes it from the
  /// pending list. Returns true if an offer with that id was applied.
  bool acceptSettingsTransfer(String id) {
    final notifier = _ref.read(pendingSettingsTransfersProvider.notifier);
    final offer = notifier.removeById(id);
    if (offer == null) return false;
    _applySyncedSettings(offer.payload);
    // Advance the sync ts (stored in seconds, matching the PWA) so the accepted
    // section isn't re-surfaced on the next refresh.
    final kv = _ref.read(keyValueStoreProvider);
    final lastSec = int.tryParse(
            kv.getString(StorageKeys.lastSettingsSyncTs) ?? '0') ??
        0;
    final offerSec = offer.updatedAt ~/ 1000;
    if (offerSec > lastSec) {
      kv.setString(StorageKeys.lastSettingsSyncTs, '$offerSec');
    }
    return true;
  }

  /// Declines an inbound settings-transfer [id]: drops it from the pending list
  /// without applying it. Returns true if it was present. (It may re-appear on a
  /// later refresh if that section is published again with a newer ts — matching
  /// the PWA, which has no permanent per-section suppression.)
  bool declineSettingsTransfer(String id) {
    return _ref.read(pendingSettingsTransfersProvider.notifier).removeById(id) !=
        null;
  }

  int _lastSettingsSyncMs() {
    final kv = _ref.read(keyValueStoreProvider);
    final sec =
        int.tryParse(kv.getString(StorageKeys.lastSettingsSyncTs) ?? '0') ?? 0;
    return sec * 1000;
  }

  /// Debounced encrypted-settings publish (`_debouncedNostrSettingsSave`, 5s).
  /// Call after any synced-setting change. No-op when storage sync is
  /// unavailable. The PWA also skips ephemeral random/hardcore keypair modes;
  /// here a missing signer (no local/remote auth) simply no-ops the upload.
  void syncSettings() {
    final sync = _storageSync;
    if (sync == null) return;
    _settingsSyncTimer?.cancel();
    _settingsSyncTimer = Timer(const Duration(seconds: 5), () {
      unawaited(_flushSettingsSync(sync));
    });
  }

  Future<void> _flushSettingsSync(StorageSync sync) async {
    try {
      await sync.settingsSet(_ref.read(settingsProvider));
    } catch (_) {
      // Best-effort.
    }
  }

  /// Restores the PM gift-wrap backlog from D1 for a durable identity, gated by
  /// `cachePMs` (pms.js `pmRestoreFromD1`). Each restored wrap is unwrapped +
  /// routed through the normal gift-wrap handler with the session dedup so it
  /// isn't re-applied.
  Future<void> _restorePmArchive(StorageSync sync) async {
    if (!sync.durableIdentity) return;
    if (!_ref.read(settingsProvider).cachePMs) return;
    try {
      final wraps = await sync.pmRestoreFromD1();
      for (final w in wraps) {
        _replayArchivedWrap(w);
      }
    } catch (_) {
      // Best-effort.
    }
  }

  /// Loads the next older page of archived PMs when a conversation is scrolled
  /// back (pms.js `pmLoadOlderFromD1`). Gated by `cachePMs` + durable identity.
  /// Returns the number of wraps replayed.
  Future<int> loadOlderPmArchive() async {
    final sync = _storageSync;
    if (sync == null || !sync.durableIdentity) return 0;
    if (!_ref.read(settingsProvider).cachePMs) return 0;
    try {
      final wraps = await sync.pmLoadOlderFromD1();
      for (final w in wraps) {
        _replayArchivedWrap(w);
      }
      return wraps.length;
    } catch (_) {
      return 0;
    }
  }

  /// Unwraps a D1-archived kind-1059 wrap through the service and routes it into
  /// the store (the same path as a live inbound wrap, minus re-archiving).
  void _replayArchivedWrap(Map<String, dynamic> wrap) {
    final service = _service;
    if (service == null) return;
    try {
      service.unwrapArchivedWrap(NostrEvent.fromJson(wrap));
    } catch (_) {
      // Skip a malformed/undecryptable archived wrap.
    }
  }

  /// Archives an inbound gift wrap to D1 for a durable identity: wraps addressed
  /// to us go to our own inbox (`pm-put`); recipient-addressed wraps we sent get
  /// deposited into the recipient's inbox (`pm-deposit`). No-op for ephemeral
  /// identities or when the raw wrap isn't available. Mirrors `_archivePMEvent`
  /// / `_depositPMEvent`.
  void _archiveGiftWrap(GiftWrapUnwrapped u) {
    final sync = _storageSync;
    if (sync == null || !sync.durableIdentity) return;
    if (!_ref.read(settingsProvider).cachePMs) return;
    final raw = u.rawWrap;
    if (raw == null) return;
    final self = _identity?.pubkey;
    if (self == null) return;
    // A wrap addressed to us → archive to our inbox. A wrap we sent to someone
    // else (recipient p-tag != us) → deposit into theirs. The same wrap is never
    // both (its single p-tag is either us or them).
    unawaited(sync.pmPut([raw]));
    unawaited(sync.pmDeposit([raw]));
  }

  /// Caps a channel message list to the runtime limit (1000) before saving.
  List<Message> _capChannel(List<Message> msgs) => msgs.length > _channelMessageLimit
      ? msgs.sublist(msgs.length - _channelMessageLimit)
      : msgs;

  List<Message> _capPm(List<Message> msgs) => msgs.length > _pmStorageLimit
      ? msgs.sublist(msgs.length - _pmStorageLimit)
      : msgs;

  String _nymFor(String pubkey) {
    final u = _ref.read(appStateProvider).users[pubkey];
    return u?.nym ?? getNymFor(pubkey);
  }

  static String getNymFor(String pubkey) {
    // Lightweight fallback display name when no profile is known.
    final suffix = pubkey.length >= 4 ? pubkey.substring(pubkey.length - 4) : '????';
    return 'anon#$suffix';
  }

  List<List<String>> _tags(Map<String, dynamic> rumor) {
    final raw = rumor['tags'];
    if (raw is! List) return const [];
    return raw
        .whereType<List>()
        .map((t) => t.map((e) => e.toString()).toList())
        .toList();
  }

  String? _tagValue(List<List<String>> tags, String name) {
    for (final t in tags) {
      if (t.isNotEmpty && t[0] == name && t.length > 1) return t[1];
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Composer attachments — image upload (Blossom) + P2P file share
  // ---------------------------------------------------------------------------

  /// Uploads [bytes] to a Blossom server (with the 3-server fallback list,
  /// users.js `_uploadWithFallback`) and returns the public media URL, or null
  /// on failure. The kind-24242 BUD auth event is signed locally and sent as the
  /// `Authorization: Nostr <base64>` header (`_signBlossomEvent`/`_putToBlossom`,
  /// users.js:516/533). [onProgress] reports 0..1 for the `#uploadProgress` bar.
  Future<String?> uploadImage(
    Uint8List bytes, {
    required String contentType,
    void Function(double progress)? onProgress,
  }) async {
    final identity = _identity;
    final sig = _signer;
    if (identity == null || sig == null) return null;

    onProgress?.call(0.15);
    // SHA-256 the bytes for the BUD-02 `x` tag (users.js:1013).
    final hashHex = sha256Hex(bytes);
    onProgress?.call(0.55);

    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final authEvent = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: nowSec,
      kind: EventKind.blossomAuth, // 24242 BUD-01 auth (NOT NIP-98 27235)
      tags: [
        ['t', 'upload'],
        ['x', hashHex],
        ['expiration', '${nowSec + 600}'],
      ],
      content: 'Uploading blob with SHA-256 hash',
    );
    final signed = await sig.sign(authEvent);
    final authHeader = 'Nostr ${base64.encode(utf8.encode(jsonEncode(signed.toJson())))}';

    final api = ApiClient();
    try {
      for (final server in kBlossomServers) {
        try {
          final data = await api.uploadBlob(bytes, server, authHeader,
              contentType: contentType);
          final url = data['url'];
          if (url is String && url.isNotEmpty) {
            onProgress?.call(1.0);
            return url;
          }
        } catch (e) {
          debugPrint('Blossom upload to $server failed: $e');
        }
      }
    } finally {
      api.dispose();
    }
    return null;
  }

  /// Shares [bytes] as a P2P file: builds the offer via [P2PService.shareFile],
  /// then announces it into the active conversation as a message carrying the
  /// `['offer', JSON]` tag (`shareP2PFile` → `publishFileOffer`, p2p.js:86/127).
  /// The local echo is shown as a file-offer message.
  Future<void> shareP2PFile({
    required Uint8List bytes,
    required String name,
    required String type,
  }) async {
    final identity = _identity;
    final service = _service;
    final p2p = _ref.read(p2pServiceProvider);
    p2p.start();
    final offer = p2p.shareFile(bytes: bytes, name: name, type: type);

    final state = _ref.read(appStateProvider);
    final view = state.view;
    final content =
        'Sharing file through Nymchat: ${offer.name} (${formatFileSize(offer.size)})';

    // Local echo as a file-offer message (displayMessage isFileOffer path,
    // p2p.js:158-173: own send sets isFileOffer:true + fileOffer so the sender
    // sees the same card peers do).
    final echo = _ref
        .read(appStateProvider.notifier)
        .sendLocal(content, fileOffer: offer.toJson());

    if (identity == null || service == null) return;
    if (view.kind != ViewKind.channel) {
      // PM/group offers gift-wrap the message with the offer tag; not yet wired
      // for the native PM path. TODO(verify): carry ['offer', …] on the PM rumor.
      return;
    }
    final isGeo = state.channels
        .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
    // Re-publish the channel message with the extra offer tag so peers can pick
    // up the offer (publishChannelMessage builds the base ['n', nym]+wire tags;
    // we append the offer tag via a hand-built signed event).
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final unsigned = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: nowSec,
      kind: isGeo ? EventKind.geoChannel : EventKind.namedChannel,
      tags: [
        ['n', identity.nym],
        fileOfferTag(offer),
        ['ms', '$nowMs'],
        [isGeo ? 'g' : 'd', view.id],
      ],
      content: content,
    );
    final sig = _signer;
    if (sig == null) return;
    final signed = await sig.sign(unsigned);
    await service.pool.publish(signed);
    // Reconcile the optimistic echo with the real id so the relay echo is
    // deduped (same one-message guarantee as a normal channel send).
    if (echo != null) {
      _ref.read(appStateProvider.notifier).replaceOptimistic(
            echo.id,
            signed.id,
            realCreatedAt: signed.createdAt,
            realMs: nowMs,
          );
    }
  }

  // ---------------------------------------------------------------------------
  // P2P signaling transport — plain kind 25051/25052 over the service pool
  // ---------------------------------------------------------------------------

  Subscription? _p2pSub;

  /// Subscribes to inbound plain kind-25051/25052 events p-tagged to us (NOT
  /// gift-wrapped — nostr-core.js:736 routes these by kind). [onEvent] gets
  /// `(senderPubkey, kind, content)`. Returns an unsubscribe callback.
  void Function() subscribeP2P(
    void Function(String senderPubkey, int kind, String content) onEvent,
  ) {
    final service = _service;
    final identity = _identity;
    if (service == null || identity == null) return () {};
    final sub = service.pool.subscribe([
      NostrFilter(
        kinds: [EventKind.p2pSignaling, EventKind.p2pFileStatus],
        tags: {
          'p': [identity.pubkey],
        },
      ),
    ]);
    _p2pSub = sub;
    final streamSub = sub.events.listen((e) {
      onEvent(e.pubkey, e.kind, e.content);
    });
    return () {
      unawaited(streamSub.cancel());
      service.pool.closeSubscription(sub);
      if (identical(_p2pSub, sub)) _p2pSub = null;
    };
  }

  /// Signs and publishes a plain kind-[kind] P2P event ([tags]+[content]) to the
  /// relay pool (`sendP2PSignal` / `stopSeeding`). NOT gift-wrapped.
  Future<void> publishP2P({
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) async {
    final service = _service;
    final identity = _identity;
    final sig = _signer;
    if (service == null || identity == null || sig == null) return;
    final unsigned = UnsignedEvent(
      pubkey: identity.pubkey,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: kind,
      tags: tags,
      content: content,
    );
    final signed = await sig.sign(unsigned);
    await service.pool.publish(signed);
  }

  /// Builds, signs and publishes a NIP-56 kind-1984 report event for [pubkey]
  /// (optionally about a specific [messageId]), mirroring `submitReport`
  /// (`ui-context.js:312-352`). [type] is the NIP-56 report-type string used as
  /// the third element of the `p`/`e` tags (e.g. `nudity`, `spam`, `illegal`,
  /// `profanity`, `impersonation`, `other`); [details] is the free-text content.
  /// Surfaces a system message on success/failure (matching the PWA).
  Future<bool> submitReport({
    required String pubkey,
    String? messageId,
    required String type,
    String? details,
  }) async {
    final service = _service;
    final identity = _identity;
    final sig = _signer;
    if (service == null || identity == null || sig == null) return false;
    try {
      final tags = <List<String>>[
        ['p', pubkey, type],
        if (messageId != null && messageId.isNotEmpty) ['e', messageId, type],
      ];
      final unsigned = UnsignedEvent(
        pubkey: identity.pubkey,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: 1984,
        tags: tags,
        content: details ?? '',
      );
      final signed = await sig.sign(unsigned);
      await service.pool.publish(signed);
      _emitSystemMessage('Report submitted successfully');
      return true;
    } catch (_) {
      _emitSystemMessage('Failed to submit report');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Nymbot interception (`?`/@Nymbot) — commands.js `_handleBotCommand`
  // ---------------------------------------------------------------------------

  /// The verified Nymbot pubkey (`verifiedBot.pubkey`, app.js:1096).
  static const String nymbotPubkey =
      'fb242a282d605f5f8141da8087a3ff0c16b255935306b324b578b43c6cf54bb2';

  /// The verified Nymchat developer pubkey (`verifiedDeveloper.pubkey`,
  /// app.js:1090-1094). Used for the "Nymchat Developer" verified badge.
  static const String verifiedDeveloperPubkey =
      'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df';

  /// True when [pubkey] is the verified developer (`isVerifiedDeveloper`,
  /// users.js:62). Shared API for the profile card / mention dropdown / composer.
  bool isVerifiedDeveloper(String pubkey) => pubkey == verifiedDeveloperPubkey;

  /// True when [pubkey] is the verified Nymbot (`isVerifiedBot`, users.js:71).
  bool isVerifiedBot(String pubkey) => pubkey == nymbotPubkey;

  /// True when [text] in a CHANNEL view should be routed to Nymbot instead of
  /// published as a normal message: a `?` command or an `@Nymbot` mention
  /// (messages.js:2381). PM/group views never intercept (the channel bot
  /// commands aren't wired for the paid PM surface — commands.js:438).
  bool shouldRouteToBot(String text) {
    final state = _ref.read(appStateProvider);
    if (state.view.kind != ViewKind.channel) return false;
    return isBotCommand(text) || isNymbotMention(text);
  }

  /// Routes a channel message to Nymbot: resolves `@Nymbot …` to `?ask …`
  /// (commands.js:14), gathers the channel geohash + recent messages + active
  /// users for the AI-aware commands, POSTs via [NymbotService.sendPublicCommand],
  /// and surfaces the reply as a bot message in the channel.
  ///
  /// In the PWA the worker returns a *signed* event the client publishes to
  /// relays, so the reply arrives back through the channel subscription. Here we
  /// surface the reply text directly. TODO(verify): the native worker contract
  /// returns `{event}`; if a future flow needs the relay round-trip, publish the
  /// returned event instead of injecting locally.
  Future<void> routeToBot(String rawText) async {
    final state = _ref.read(appStateProvider);
    final view = state.view;
    if (view.kind != ViewKind.channel) {
      await _sendMessageContent(rawText);
      return;
    }

    // @Nymbot mention → ?ask <question> (commands.js:14).
    var content = rawText.trim();
    if (!isBotCommand(content) && isNymbotMention(content)) {
      final question = stripNymbotMention(content);
      if (question.isEmpty) {
        await _sendMessageContent(rawText); // nothing to ask
        return;
      }
      content = '?ask $question';
    }

    final parsed = parseBotCommand(content);
    if (parsed == null) {
      await _sendMessageContent(rawText);
      return;
    }

    final isGeo = state.channels
        .any((c) => c.key == view.id.toLowerCase() && c.isGeohash);
    final geohash = isGeo ? view.id : null;
    final storageKey = view.storageKey;
    final cmd = parsed.name;

    // Channel context for the AI-aware commands (commands.js:46-191).
    List<Map<String, dynamic>>? channelMessages;
    List<Map<String, dynamic>>? activeUsers;
    const aiCommands = {'ask', 'summarize'};
    const memoryCommands = {'top', 'last', 'seen', 'who'};
    if (aiCommands.contains(cmd) || memoryCommands.contains(cmd)) {
      channelMessages = _botChannelMessages(state, storageKey,
          allChannels: memoryCommands.contains(cmd));
      activeUsers = _botActiveUsers(state, view.id,
          allUsers: memoryCommands.contains(cmd));
    }

    // The published user message (what the bot replies to).
    await _sendMessageContent(rawText);

    final identity = _identity;
    final senderNym = identity != null
        ? '${stripPubkeySuffix(identity.nym)}#${getPubkeySuffix(identity.pubkey)}'
        : null;

    try {
      final service = _ref.read(nymbotServiceProvider);
      final reply = await service.sendPublicCommand(
        cmd,
        parsed.args,
        geohash: geohash,
        senderNym: senderNym,
        publishedContent: rawText,
        channelMessages: channelMessages,
        activeUsers: activeUsers,
      );
      _injectBotReply(reply, geohash: geohash, channelKey: view.id);
    } catch (e) {
      debugPrint('Nymbot command failed: $e');
      _emitSystemMessage('Nymbot is unavailable right now.');
    }
  }

  /// Injects Nymbot's reply as a verified-bot channel message via the public
  /// `ingestEvent` path (a synthetic signed-looking event from [nymbotPubkey]).
  void _injectBotReply(String reply,
      {String? geohash, required String channelKey}) {
    if (reply.trim().isEmpty) return;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final isGeo = geohash != null && geohash.isNotEmpty;
    final event = NostrEvent(
      pubkey: nymbotPubkey,
      createdAt: nowSec,
      kind: isGeo ? EventKind.geoChannel : EventKind.namedChannel,
      tags: [
        ['n', 'Nymbot'],
        [isGeo ? 'g' : 'd', isGeo ? geohash : channelKey],
      ],
      content: reply,
    );
    event.id = event.computeId();
    _ref.read(appStateProvider.notifier).ingestEvent(event);
  }

  /// Recent channel messages mapped to the worker's context shape
  /// (`{nym,pubkey,content,timestamp,isBot,channel}`, commands.js:121).
  List<Map<String, dynamic>> _botChannelMessages(
      AppState state, String storageKey,
      {required bool allChannels}) {
    final out = <Map<String, dynamic>>[];
    void mapList(String key, List<Message> msgs) {
      for (final m in msgs.where((m) => !m.spamGated).take(100)) {
        out.add({
          'nym': m.author,
          'pubkey': m.pubkey,
          'content':
              m.content.length > 300 ? m.content.substring(0, 300) : m.content,
          'timestamp': m.createdAt,
          'isBot': m.isBot,
          'channel': key,
        });
      }
    }

    if (allChannels) {
      state.messages.forEach(mapList);
    } else {
      final msgs = state.messages[storageKey];
      if (msgs != null) mapList(storageKey, msgs);
    }
    out.sort((a, b) =>
        (a['timestamp'] as int).compareTo(b['timestamp'] as int));
    return out;
  }

  /// Active users in the channel mapped to `{nym,pubkey}` (commands.js:155/185).
  List<Map<String, dynamic>> _botActiveUsers(AppState state, String channelId,
      {required bool allUsers}) {
    final rawName =
        channelId.startsWith('#') ? channelId.substring(1) : channelId;
    final out = <Map<String, dynamic>>[];
    state.users.forEach((pubkey, user) {
      final inChannel = allUsers ||
          user.channels.any((c) =>
              c == rawName || c.startsWith(rawName) || rawName.startsWith(c));
      if (inChannel && user.nym.isNotEmpty) {
        out.add({
          'nym':
              '${stripPubkeySuffix(user.nym)}#${getPubkeySuffix(pubkey)}',
          'pubkey': pubkey,
        });
      }
    });
    return out;
  }

  /// Binds the private Nymbot chat to the live identity (so the paid PM surface
  /// can authenticate) and returns whether a bind happened. The composer calls
  /// this before opening `BotChatScreen`.
  bool bindBotChat() {
    final identity = _identity;
    if (identity == null) return false;
    // Pass the privkey so the bot controller can build per-action NIP-98 auth
    // for paid requests (PWA `_signBotAuth`). Null for delegated signers
    // (ext/nip46) — those fall back to the pre-supplied auth blob.
    _ref.read(botChatControllerProvider.notifier).bind(
          pubkey: identity.pubkey,
          privkey: identity.privkey,
        );
    return true;
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _presenceTimer?.cancel();
    _settingsSyncTimer?.cancel();
    _profileBackfillTimer?.cancel();
    if (_p2pSub != null) {
      _service?.pool.closeSubscription(_p2pSub!);
      _p2pSub = null;
    }
    await _flush(); // final flush so unsaved messages/reactions persist
    await _cache?.close();
    await _service?.stop();
    _api?.dispose();
  }
}

/// Blossom upload servers + fallback order (users.js:3 `BLOSSOM_SERVERS`).
const List<String> kBlossomServers = [
  'https://blossom.band',
  'https://blossom.primal.net',
  'https://nostr.download',
];

/// The live [P2PService], wired to the controller's signaling transport.
final p2pServiceProvider = Provider<P2PService>((ref) {
  final controller = ref.read(nostrControllerProvider);
  final service = P2PService(_ControllerP2PTransport(controller));
  // Route transfer status into the conversation (mirrors callServiceProvider)
  // and start the 25051/25052 signaling subscription so a pure receiver is
  // listening before it ever sends an offer.
  service.onSystemMessage = (m) {
    try {
      ref.read(appStateProvider.notifier).addSystemMessage(m);
    } catch (_) {}
  };
  service.start();
  ref.onDispose(service.dispose);
  return service;
});

/// Adapts [NostrController]'s `publishP2P`/`subscribeP2P` to [P2PTransport].
class _ControllerP2PTransport implements P2PTransport {
  _ControllerP2PTransport(this._c);
  final NostrController _c;

  @override
  String get selfPubkey => _c.identity?.pubkey ?? '';

  @override
  Future<void> publishP2P({
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) =>
      _c.publishP2P(kind: kind, tags: tags, content: content);

  @override
  void Function() subscribeP2P(
    void Function(String senderPubkey, int kind, String content) onEvent,
  ) =>
      _c.subscribeP2P(onEvent);
}

/// Bridges the pure [CommandDispatcher] to the [NostrController]'s engine
/// methods. Keeps the dispatcher free of controller/app_state internals.
class _CommandEngineAdapter implements CommandEngine {
  _CommandEngineAdapter(this._c);
  final NostrController _c;

  AppState get _state => _c._ref.read(appStateProvider);

  @override
  bool get inPM => _state.view.kind == ViewKind.pm;
  @override
  bool get inGroup => _state.view.kind == ViewKind.group;
  @override
  String get selfPubkey => _state.selfPubkey;
  @override
  Map<String, User> get users => _state.users;

  @override
  void sendToCurrentTarget(String content) =>
      unawaited(_c._sendMessageContent(content));
  @override
  void systemMessage(String text) => _c._emitSystemMessage(text);

  @override
  void join(String channel) => _c.cmdJoin(channel);
  @override
  void clear() => _c.cmdClear();
  @override
  void leave() => _c.cmdLeave();
  @override
  void quit() => _c.cmdQuit();
  @override
  void setNick(String newNym) => unawaited(_c.cmdNick(newNym));
  @override
  void who() => _c.cmdWho();
  @override
  void setAway(String message) => unawaited(_c.cmdSetAway(message));
  @override
  void clearAway() => unawaited(_c.cmdBack());
  @override
  void share() => _c.cmdShare();
  @override
  void block(String arg) => _c.cmdBlock(arg);
  @override
  void unblock(String arg) => _c.cmdUnblock(arg);
}

/// Per-(messageId,emoji) reaction rate-limit tracker (reactions.js
/// `reactionToggleTracker`): timestamps within the window + cooldown-until ms.
class _ReactionRateTracker {
  final List<int> timestamps = [];
  int cooldownUntil = 0;
}

/// Builds the tags for a channel message edit re-publish (messages.js
/// `publishEditedChannelMessage`): `['n', nym], [wire.tag, key], ['edit', id]`.
/// [wire.tag] is `'g'` for a geohash channel else `'d'`.
List<List<String>> buildChannelEditTags({
  required String nym,
  required String channelKey,
  required bool isGeohash,
  required String originalId,
}) {
  return [
    ['n', nym],
    [isGeohash ? 'g' : 'd', channelKey],
    ['edit', originalId],
  ];
}

/// Builds the kind-5 deletion tags (`['e', id], ['k', origKind]`) — nostr-core.js
/// `publishDeletionEvent`.
List<List<String>> buildDeletionTags(String messageId, String originalKind) {
  return [
    ['e', messageId],
    if (originalKind.isNotEmpty) ['k', originalKind],
  ];
}

final nostrControllerProvider = Provider<NostrController>((ref) {
  final c = NostrController(ref);
  ref.onDispose(c.dispose);
  return c;
});

/// Monotonically increasing "boot generation". The PWA's `signOut()` ends with
/// a full page reload to a pristine first-run state; Flutter has no reload, so
/// [NostrController.signOut] bumps this counter and the root (`app.dart`)
/// remounts a fresh [BootGate] keyed on it — tearing down the whole `HomeShell`
/// subtree and re-running the setup-needed check (which now passes because the
/// login keys were cleared). Starts at 0 (first boot needs no remount).
final bootEpochProvider = StateProvider<int>((ref) => 0);

/// Holds the inbound settings-transfer offers (cross-device settings sections
/// newer than this device's last applied sync) for the settings UI's
/// accept/decline list. Populated by
/// [NostrController.refreshPendingSettingsTransfers]; resolved via
/// [NostrController.acceptSettingsTransfer] / `declineSettingsTransfer`.
final pendingSettingsTransfersProvider = StateNotifierProvider<
    PendingSettingsTransfersNotifier, List<SettingsTransferOffer>>((ref) {
  return PendingSettingsTransfersNotifier();
});

/// StateNotifier backing [pendingSettingsTransfersProvider]. Holds the offers
/// newest-first; the controller mutates it through [setOffers] / [removeById].
class PendingSettingsTransfersNotifier
    extends StateNotifier<List<SettingsTransferOffer>> {
  PendingSettingsTransfersNotifier() : super(const []);

  /// Replaces the pending list (newest-first as supplied by the fetch).
  void setOffers(List<SettingsTransferOffer> offers) {
    state = List.unmodifiable(offers);
  }

  /// Removes and returns the offer with [id], or null if absent.
  SettingsTransferOffer? removeById(String id) {
    SettingsTransferOffer? found;
    final next = <SettingsTransferOffer>[];
    for (final o in state) {
      if (found == null && o.id == id) {
        found = o;
      } else {
        next.add(o);
      }
    }
    if (found != null) state = List.unmodifiable(next);
    return found;
  }

  /// Clears all pending offers (e.g. on logout).
  void clear() => state = const [];
}

/// The NIP-46 remote-signer transport. The controller reads this at boot to
/// restore a persisted `'nip46'` session and build a [Nip46SignerAdapter]. A
/// single instance is reused so the live WebSocket / pending-request state is
/// shared (disposed with the provider scope). `SecureStore` / `KeyValueStore`
/// structurally satisfy the service's `Nip46SecureStore` / `Nip46KeyValueStore`
/// interfaces.
final nip46ServiceProvider = Provider<Nip46Service>((ref) {
  final svc = Nip46Service(
    kv: _Nip46KvAdapter(ref.read(keyValueStoreProvider)),
    secure: _Nip46SecureAdapter(SecureStore()),
  );
  ref.onDispose(svc.dispose);
  return svc;
});

/// Adapts [KeyValueStore] to the NIP-46 service's [Nip46KeyValueStore]
/// interface (Dart's abstract classes aren't structurally satisfied).
class _Nip46KvAdapter implements Nip46KeyValueStore {
  _Nip46KvAdapter(this._kv);
  final KeyValueStore _kv;
  @override
  String? getString(String key) => _kv.getString(key);
  @override
  Future<void> setString(String key, String value) => _kv.setString(key, value);
}

/// Adapts [SecureStore] to the NIP-46 service's [Nip46SecureStore] interface.
class _Nip46SecureAdapter implements Nip46SecureStore {
  _Nip46SecureAdapter(this._secure);
  final SecureStore _secure;
  @override
  Future<String?> get(String key) => _secure.get(key);
  @override
  Future<void> set(String key, String value) => _secure.set(key, value);
  @override
  Future<void> remove(String key) => _secure.remove(key);
}
