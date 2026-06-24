import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/constants/relays.dart';
import '../../models/nostr_event.dart';
import '../api/api_config.dart';
import 'relay_connection.dart' show WebSocketChannelFactory;
import 'relay_message.dart';
import 'relay_pool.dart';
import 'relay_stats.dart';

/// One role-keyed shard: a stable id, its relay set, and (for critical) the DM
/// relays. Mirrors the objects produced by `_shardRelaysByRole` (relays.js).
class RelayShard {
  RelayShard({
    required this.id,
    required this.role,
    required this.relays,
    required this.dmRelays,
  });

  final String id;
  final String role; // 'critical' | 'geo' | 'discovered'
  final List<String> relays;
  final List<String> dmRelays;
}

/// Relays the PWA hard-blocks from any shard (relays.js:1704).
const Set<String> _blockedRelays = {
  'wss://relay.nosflare.com',
  'wss://relay.nostraddress.com',
  'wss://nostr-server-production.up.railway.app',
};

/// Canonicalize a relay url for discovered-dedup: lowercase host, drop a
/// trailing slash. Mirrors `_canonicalRelayUrl` closely enough for sharding
/// (only used to dedup the discovered bucket).
String canonicalRelayUrl(String url) {
  var u = url.trim();
  if (u.endsWith('/')) u = u.substring(0, u.length - 1);
  return u.toLowerCase();
}

/// Pure port of `_shardRelaysByRole` (relays.js:1699). Buckets relays into
/// `app-0` (the app relay), `critical-N` (defaults + dmRelays minus app relay),
/// `geo-N`, `discovered-N`, chunking each role at [chunkSize] (50). Stable
/// role-keyed ids.
List<RelayShard> shardRelaysByRole(
  Iterable<String> allRelays,
  Iterable<String> geoRelayUrls,
  List<String> dmRelays, {
  List<String> defaultRelays = RelayConfig.defaultRelays,
  String appRelay = RelayConfig.appRelay,
  Set<String> permanentBlacklist = const {},
  int chunkSize = RelayConfig.relaysPerWorker,
}) {
  bool isValid(String url) =>
      url.startsWith('wss://') &&
      !_blockedRelays.contains(url) &&
      !permanentBlacklist.contains(url);

  final geoSet = <String>{for (final u in geoRelayUrls) if (isValid(u)) u};
  final appValid = isValid(appRelay);

  // Critical = default relays (+ DM relays), excluding the app relay.
  final critical = <String>[
    for (final u in {...defaultRelays, ...dmRelays})
      if (isValid(u) && u != appRelay) u
  ];

  final reservedSet = <String>{...critical};
  if (appValid) reservedSet.add(appRelay);

  // Geo = CSV relays not already reserved.
  final geo = <String>[for (final u in geoSet) if (!reservedSet.contains(u)) u];

  // Discovered = anything in allRelays not already reserved or geo (canon-dedup).
  final geoForDiscovered = <String>{...geo};
  final claimedCanon = <String>{
    for (final u in reservedSet) canonicalRelayUrl(u),
    for (final u in geoForDiscovered) canonicalRelayUrl(u),
  };
  final seenDiscoveredCanon = <String>{};
  final discovered = <String>[];
  for (final url in {...allRelays}) {
    if (!isValid(url) ||
        reservedSet.contains(url) ||
        geoForDiscovered.contains(url)) {
      continue;
    }
    final canon = canonicalRelayUrl(url);
    if (claimedCanon.contains(canon) || seenDiscoveredCanon.contains(canon)) {
      continue;
    }
    seenDiscoveredCanon.add(canon);
    discovered.add(url);
  }

  List<List<String>> chunk(List<String> arr) {
    final out = <List<String>>[];
    for (var i = 0; i < arr.length; i += chunkSize) {
      out.add(arr.sublist(i, min(i + chunkSize, arr.length)));
    }
    return out;
  }

  final shards = <RelayShard>[];

  // Dedicated app relay shard.
  if (appValid) {
    shards.add(RelayShard(
        id: 'app-0', role: 'critical', relays: [appRelay], dmRelays: [appRelay]));
  }

  final criticalDmRelays = <String>[
    for (final u in dmRelays) if (isValid(u) && u != appRelay) u
  ];
  final criticalChunks = chunk(critical);
  for (var i = 0; i < criticalChunks.length; i++) {
    shards.add(RelayShard(
      id: 'critical-$i',
      role: 'critical',
      relays: criticalChunks[i],
      dmRelays: i == 0 ? criticalDmRelays : const [],
    ));
  }

  final geoChunks = chunk(geo);
  for (var i = 0; i < geoChunks.length; i++) {
    shards.add(RelayShard(
        id: 'geo-$i', role: 'geo', relays: geoChunks[i], dmRelays: const []));
  }

  final discoveredChunks = chunk(discovered);
  for (var i = 0; i < discoveredChunks.length; i++) {
    shards.add(RelayShard(
        id: 'discovered-$i',
        role: 'discovered',
        relays: discoveredChunks[i],
        dmRelays: const []));
  }

  if (shards.isEmpty) {
    shards.add(RelayShard(
        id: 'critical-0', role: 'critical', relays: const [], dmRelays: const []));
  }
  return shards;
}

/// Builds the WRAPPED outbound frames for the `/api/relay-pool` socket
/// (spec §4.6). Pure + testable.
class PoolFrame {
  PoolFrame._();

  /// `["RELAYS",{relays,dmRelays}]`
  static String relays(List<String> relays, List<String> dmRelays) =>
      jsonEncode(<dynamic>[
        'RELAYS',
        {'relays': relays, 'dmRelays': dmRelays}
      ]);

  /// `["EVENT",e]`
  static String event(NostrEvent e) =>
      jsonEncode(<dynamic>['EVENT', e.toJson()]);

  /// `["GEO_EVENT",e,[urls]]`
  static String geoEvent(NostrEvent e, List<String> urls) =>
      jsonEncode(<dynamic>['GEO_EVENT', e.toJson(), urls]);

  /// `["DM_EVENT",e]`
  static String dmEvent(NostrEvent e) =>
      jsonEncode(<dynamic>['DM_EVENT', e.toJson()]);

  /// `["REQ",subId,...filters]`
  static String req(String subId, List<NostrFilter> filters) => jsonEncode(
      <dynamic>['REQ', subId, ...filters.map((f) => f.toJson())]);

  /// `["CLOSE",subId]`
  static String close(String subId) => jsonEncode(<dynamic>['CLOSE', subId]);
}

/// Sealed parse result for an INBOUND wrapped pool frame. Note the wrapped
/// protocol differs from raw nostr: EVENT carries the subId at index 1
/// (`["EVENT",subId,e,(sourceRelay)]`) and OK/EOSE behave as in nostr but may
/// carry a trailing attribution `wss://` url.
sealed class PoolMessage {
  const PoolMessage();

  static PoolMessage? parse(String raw) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! List || decoded.isEmpty) return null;
    return fromList(decoded);
  }

  static PoolMessage? fromList(List<dynamic> arr) {
    if (arr.isEmpty || arr[0] is! String) return null;
    final type = arr[0] as String;
    switch (type) {
      case 'EVENT':
        // ["EVENT", subId, event, sourceRelay?]
        if (arr.length < 3) return null;
        final subId = arr[1]?.toString() ?? '';
        final ev = arr[2];
        if (ev is! Map) return null;
        final sourceRelay = arr.length > 3 ? arr[3]?.toString() : null;
        return PoolEvent(
          subId,
          NostrEvent.fromJson(Map<String, dynamic>.from(ev)),
          sourceRelay,
        );
      case 'OK':
        // ["OK", id, accepted, reason, relayUrl?]
        if (arr.length < 3) return null;
        return PoolOk(
          arr[1]?.toString() ?? '',
          arr[2] == true,
          arr.length > 3 ? (arr[3]?.toString() ?? '') : '',
        );
      case 'EOSE':
        // ["EOSE", subId]
        if (arr.length < 2) return null;
        return PoolEose(arr[1]?.toString() ?? '');
      case 'CLOSED':
        // ["CLOSED", subId, reason, relayUrl?]
        if (arr.length < 2) return null;
        return PoolClosed(arr[1]?.toString() ?? '');
      case 'POOL:PING':
        // ["POOL:PING", ts] — keepalive; ts ignored, just bumps liveness.
        return const PoolPing();
      case 'POOL:STATUS':
        // ["POOL:STATUS", {connected:[urls], latency:{url:ms}}]
        final status = arr.length > 1 && arr[1] is Map
            ? Map<String, dynamic>.from(arr[1] as Map)
            : const <String, dynamic>{};
        final connected = (status['connected'] is List)
            ? (status['connected'] as List).map((e) => e.toString()).toList()
            : const <String>[];
        // Per-relay latency reported by this worker (relays.js:2137-2141), used
        // for the Network Stats per-relay rows + Avg Latency in proxy mode.
        final latency = <String, int>{};
        final rawLat = status['latency'];
        if (rawLat is Map) {
          rawLat.forEach((k, v) {
            final ms = v is num ? v.round() : int.tryParse('$v');
            if (ms != null) latency[k.toString()] = ms;
          });
        }
        return PoolStatus(connected, latency);
      case 'POOL:RELAY_BAN':
        // ["POOL:RELAY_BAN", relayUrl, reason?] — the proxy permanently dropped
        // this relay (relays.js:2117 `_permanentlyBlacklistRelay`).
        final url = arr.length > 1 ? arr[1]?.toString() ?? '' : '';
        if (!url.startsWith('wss://')) return null;
        final reason = arr.length > 2 ? arr[2]?.toString() ?? 'banned' : 'banned';
        return PoolRelayBan(url, reason);
      default:
        // POOL:SHARDS / NOTICE / AUTH — unhandled by transport.
        return null;
    }
  }
}

class PoolEvent extends PoolMessage {
  const PoolEvent(this.subId, this.event, this.sourceRelay);
  final String subId;
  final NostrEvent event;
  final String? sourceRelay;
}

class PoolOk extends PoolMessage {
  const PoolOk(this.id, this.accepted, this.message);
  final String id;
  final bool accepted;
  final String message;
}

class PoolEose extends PoolMessage {
  const PoolEose(this.subId);
  final String subId;
}

class PoolClosed extends PoolMessage {
  const PoolClosed(this.subId);
  final String subId;
}

class PoolPing extends PoolMessage {
  const PoolPing();
}

class PoolStatus extends PoolMessage {
  const PoolStatus(this.connected, [this.latency = const {}]);
  final List<String> connected;

  /// Per-relay latency in ms reported by the worker (relays.js POOL:STATUS).
  final Map<String, int> latency;
}

class PoolRelayBan extends PoolMessage {
  const PoolRelayBan(this.url, this.reason);
  final String url;
  final String reason;
}

/// A single shard's WebSocket to `/api/relay-pool`, with per-shard reconnect
/// backoff (`_reconnectPoolShard`: min(3000*1.7^n,60000), jitter 0.7–1.0).
class _ShardSocket {
  _ShardSocket({
    required this.shard,
    required this.url,
    required this.channelFactory,
    required this.rng,
    required this.stats,
    required this.onMessage,
    required this.onConnected,
    required this.onClosed,
  });

  RelayShard shard;
  final String url;
  final WebSocketChannelFactory channelFactory;
  final Random rng;

  /// Shared, pool-owned counters. This shard adds its inbound/outbound frame
  /// byte lengths here (mirrors the PWA's per-socket writes to `relayStats`).
  final RelayStats stats;
  final void Function(_ShardSocket sock, PoolMessage msg) onMessage;
  final void Function(_ShardSocket sock) onConnected;
  final void Function(_ShardSocket sock) onClosed;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _closedByUser = false;
  bool _open = false;

  /// Relays this shard's proxy reports as connected (from POOL:STATUS).
  List<String> connectedRelays = const [];

  bool get isOpen => _open;

  void connect() {
    _closedByUser = false;
    if (_open) return;
    _open = false;
    try {
      final ch = channelFactory(Uri.parse(url));
      _channel = ch;
      _sub = ch.stream.listen(
        _onData,
        onError: (Object _) => _onDone(),
        onDone: _onDone,
        cancelOnError: false,
      );
      // web_socket_channel has no discrete open event; treat listen as open and
      // immediately push the shard's RELAYS config (mirrors ws.onopen).
      _open = true;
      _reconnectAttempt = 0;
      send(PoolFrame.relays(shard.relays, shard.dmRelays));
      onConnected(this);
    } catch (e) {
      debugPrint('[RelayPoolProxy] Failed to open shard socket ($url): $e');
      _onDone();
    }
  }

  void _onData(dynamic data) {
    // Count every inbound frame's UTF-8 byte length (relays.js pool
    // ws.onmessage: `relayStats.bytesReceived += dataLen`).
    if (data is String) {
      stats.bytesReceived += utf8.encode(data).length;
    } else if (data is List<int>) {
      stats.bytesReceived += data.length;
    }
    if (data is! String) return;
    final msg = PoolMessage.parse(data);
    if (msg == null) return;
    if (msg is PoolStatus) connectedRelays = msg.connected;
    onMessage(this, msg);
  }

  void _onDone() {
    _open = false;
    _cleanup();
    onClosed(this);
    if (_closedByUser) return;
    _scheduleReconnect();
  }

  void _cleanup() {
    _sub?.cancel();
    _sub = null;
    _channel = null;
  }

  void _scheduleReconnect() {
    if (_closedByUser) return;
    _reconnectTimer?.cancel();
    // _reconnectPoolShard: base = min(3000*1.7^n, 60000); jitter 0.7–1.0.
    final base = min(3000 * pow(1.7, _reconnectAttempt), 60000).toDouble();
    final delayMs = (base * (0.7 + rng.nextDouble() * 0.3)).floor();
    _reconnectAttempt++;
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (_closedByUser) return;
      connect();
    });
  }

  bool send(String frame) {
    final ch = _channel;
    if (ch == null || !_open) return false;
    try {
      ch.sink.add(frame);
      // Count the outbound frame's UTF-8 byte length (relays.js `_safeWsSend`:
      // `relayStats.bytesSent += msg.length`).
      stats.bytesSent += utf8.encode(frame).length;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> close() async {
    _closedByUser = true;
    _open = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }
}

/// Multiplexed relay-pool PROXY transport. Drop-in alternative to [RelayPool]:
/// the same public surface (connectAll / subscribe -> [Subscription] /
/// publish / connectedCount / disconnectAll), but over a single
/// `wss://<host>/api/relay-pool` endpoint with one socket per role-shard
/// (spec §4.6).
///
/// Implements the [PoolTransport] surface so [Subscription] can route
/// CLOSE/unsubscribe through it identically to [RelayPool].
class RelayPoolProxy implements PoolTransport {
  RelayPoolProxy({
    required List<String> relays,
    EventVerifier? verify,
    List<String>? geoRelayUrls,
    List<String>? dmRelays,
    Set<String>? permanentBlacklist,
    String? poolUrl,
    WebSocketChannelFactory? channelFactory,
    Random? random,
    this.eoseQuorum = 0.6,
    this.eoseTimeout = const Duration(seconds: 4),
  })  : _verify = verify ?? ((_) async => true),
        _allRelays = {...relays},
        _geoRelayUrls = [...?geoRelayUrls],
        _dmRelays = dmRelays ?? RelayConfig.defaultRelays,
        _permanentBlacklist = {...?permanentBlacklist},
        _poolUrl = poolUrl ?? ApiConfig.relayPoolUrl(),
        _channelFactory = channelFactory ?? WebSocketChannel.connect,
        _rng = random ?? Random();

  final EventVerifier _verify;
  final Set<String> _allRelays;
  final List<String> _geoRelayUrls;
  final List<String> _dmRelays;
  final Set<String> _permanentBlacklist;
  final String _poolUrl;
  final WebSocketChannelFactory _channelFactory;
  final Random _rng;

  final double eoseQuorum;
  final Duration eoseTimeout;

  final List<_ShardSocket> _sockets = [];

  /// Active subscriptions keyed by subId, and their filters (re-REQ'd on a
  /// reconnected shard).
  final Map<String, Subscription> _subscriptions = {};
  final Map<String, List<NostrFilter>> _activeFilters = {};

  /// Global cross-shard event dedup (relays.js: `eventDeduplication`, cap 10k).
  final EventDeduper _deduper = EventDeduper(maxIds: 10000);

  /// Pool-owned live traffic counters. Shard sockets write byte counts here;
  /// [_onShardMessage] writes event counts + REQ→EOSE latency. The 1-second
  /// [_sampler] feeds its throughput history (mirrors the PWA's single
  /// `nym.relayStats`).
  final RelayStats _stats = RelayStats();

  /// 1-second throughput sampler (`startRelayStatsSampling`): pushes the last
  /// second's event count onto the throughput history (cap 60) and resets the
  /// per-second counter.
  Timer? _sampler;

  /// subId → epoch-ms the REQ was broadcast, so an inbound EOSE can stamp
  /// REQ→EOSE latency. In proxy mode the per-relay unit is the shard, so
  /// latency is keyed by the delivering shard's id (the same attribution the
  /// proxy uses for events). Cleared once every open shard has EOSE'd.
  final Map<String, int> _reqSentAt = {};

  /// subId → shard ids that have already EOSE'd, so we stamp each shard's
  /// REQ→EOSE latency exactly once and can drop [_reqSentAt] when all are in.
  final Map<String, Set<String>> _eosedShards = {};

  // --- Public surface (matches RelayPool) -----------------------------------

  /// Total relays the proxy reports as connected across all shards (deduped).
  @override
  int get connectedCount {
    final s = <String>{};
    for (final sock in _sockets) {
      s.addAll(sock.connectedRelays);
    }
    return s.length;
  }

  /// The deduped set of relay URLs reported connected across all shards (for the
  /// Network Stats per-relay list). Same aggregation as [connectedCount].
  Set<String> get connectedRelayUrls {
    final s = <String>{};
    for (final sock in _sockets) {
      s.addAll(sock.connectedRelays);
    }
    return s;
  }

  /// Number of shard sockets currently open (transport-level).
  int get openShardCount => _sockets.where((s) => s.isOpen).length;

  /// Live aggregate traffic counters (a fresh snapshot each read). Bytes are
  /// summed by the shard sockets; events + latency by [_onShardMessage]. Mirrors
  /// the PWA's single `nym.relayStats`.
  @override
  RelayStats get stats => _stats.snapshot();

  /// Start the 1-second throughput sampler (idempotent). Mirrors
  /// `startRelayStatsSampling`.
  void _startSampler() {
    if (_sampler != null) return;
    _sampler = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _stats.sampleThroughput(),
    );
  }

  void _stopSampler() {
    _sampler?.cancel();
    _sampler = null;
  }

  /// The current shard layout (for inspection / tests).
  List<RelayShard> get shards => _sockets.map((s) => s.shard).toList();

  /// Build shards and open one socket per shard.
  @override
  void connectAll() {
    _startSampler();
    if (_sockets.isNotEmpty) {
      for (final s in _sockets) {
        s.connect();
      }
      return;
    }
    final layout = shardRelaysByRole(
      _allRelays,
      _geoRelayUrls,
      _dmRelays,
      permanentBlacklist: _permanentBlacklist,
    );
    for (final shard in layout) {
      final sock = _ShardSocket(
        shard: shard,
        url: _poolUrl,
        channelFactory: _channelFactory,
        rng: _rng,
        stats: _stats,
        onMessage: _onShardMessage,
        onConnected: _onShardConnected,
        onClosed: _onShardClosed,
      );
      _sockets.add(sock);
      sock.connect();
    }
  }

  /// Subscribe across the pool. Sends one `["REQ",subId,...filters]` to every
  /// open shard socket. Returns a [Subscription] that dedupes + verifies.
  @override
  Subscription subscribe(List<NostrFilter> filters, {String? subId}) {
    final id = subId ?? generateSubId(_rng);
    final sub = Subscription.forTransport(
      id,
      this,
      _verify,
      max(1, openShardCount),
      eoseQuorum: eoseQuorum,
      eoseTimeout: eoseTimeout,
    );
    _subscriptions[id] = sub;
    _activeFilters[id] = filters;
    // Record the REQ broadcast time so each shard's EOSE can stamp REQ→EOSE
    // latency (keyed by shard id — the proxy's per-relay unit).
    _reqSentAt[id] = DateTime.now().millisecondsSinceEpoch;
    _eosedShards[id] = <String>{};
    sub.startEose();
    final frame = PoolFrame.req(id, filters);
    for (final sock in _sockets) {
      sock.send(frame);
    }
    return sub;
  }

  @override
  void closeSubscription(Subscription sub) {
    _subscriptions.remove(sub.subId);
    _activeFilters.remove(sub.subId);
    _reqSentAt.remove(sub.subId);
    _eosedShards.remove(sub.subId);
    final frame = PoolFrame.close(sub.subId);
    for (final sock in _sockets) {
      sock.send(frame);
    }
  }

  /// Publish [event] over the pool. Broadcasts `["EVENT",e]` to every shard
  /// socket (mirrors `_poolSend(['EVENT', e])`). Returns the number of shard
  /// sockets the frame was written to (best-effort; the proxy ACKs async via
  /// inbound OK).
  @override
  Future<int> publish(NostrEvent event) async {
    return _broadcast(PoolFrame.event(event));
  }

  /// Publish a DM gift-wrap via `["DM_EVENT",e]` (relays.js:3274).
  @override
  Future<int> publishDm(NostrEvent event) async {
    return _broadcast(PoolFrame.dmEvent(event));
  }

  /// Publish a geohash channel event via `["GEO_EVENT",e,[urls]]`
  /// (relays.js:3394) so the proxy prioritizes the closest geo relays. When no
  /// closest relays are known the PWA falls back to a plain `["EVENT",e]`
  /// (relays.js:3390-3401), so we mirror that here.
  @override
  Future<int> publishGeo(NostrEvent event, List<String> closestRelayUrls) async {
    if (closestRelayUrls.isEmpty) {
      return _broadcast(PoolFrame.event(event));
    }
    return _broadcast(PoolFrame.geoEvent(event, closestRelayUrls));
  }

  int _broadcast(String frame) {
    var n = 0;
    for (final sock in _sockets) {
      if (sock.send(frame)) n++;
    }
    return n;
  }

  /// Close every shard socket and all subscriptions.
  @override
  Future<void> disconnectAll() async {
    _stopSampler();
    final subs = _subscriptions.values.toList();
    for (final s in subs) {
      await s.close();
    }
    final socks = _sockets.toList();
    _sockets.clear();
    for (final s in socks) {
      await s.close();
    }
  }

  // --- Shard socket callbacks -----------------------------------------------

  void _onShardConnected(_ShardSocket sock) {
    // Re-issue every active subscription on the (re)connected shard.
    for (final entry in _activeFilters.entries) {
      sock.send(PoolFrame.req(entry.key, entry.value));
    }
  }

  void _onShardClosed(_ShardSocket sock) {
    // Per-shard reconnect is handled inside _ShardSocket; nothing else to do
    // here at the transport level.
  }

  /// Stamp REQ→EOSE latency for [shardId] on subscription [subId]: compute
  /// `now - reqSentAt` once per shard and record it under the shard id. When
  /// every open shard has EOSE'd, drop the timing entry so a later re-REQ on
  /// the same subId re-measures.
  void _stampShardLatency(String subId, String shardId) {
    final sentAt = _reqSentAt[subId];
    if (sentAt == null) return;
    final eosed = _eosedShards[subId] ??= <String>{};
    if (!eosed.add(shardId)) return; // already stamped this shard
    final ms = DateTime.now().millisecondsSinceEpoch - sentAt;
    if (ms >= 0) _stats.latencyPerRelay[shardId] = ms;
    if (eosed.length >= openShardCount) {
      _reqSentAt.remove(subId);
      _eosedShards.remove(subId);
    }
  }

  void _onShardMessage(_ShardSocket sock, PoolMessage msg) {
    switch (msg) {
      case PoolEvent(:final subId, :final event, :final sourceRelay):
        // Cross-shard dedup: the first shard to deliver an id wins.
        if (!_deduper.add(event.id)) return;
        // Post-dedup event accounting (relays.js handleRelayMessage:3738-3746):
        // bump the unique total + per-second counter, and the per-relay tally
        // attributed to the proxy-tagged sourceRelay when present.
        _stats.totalEvents++;
        _stats.eventsThisSecond++;
        if (sourceRelay != null && sourceRelay.startsWith('wss://')) {
          _stats.eventsPerRelay[sourceRelay] =
              (_stats.eventsPerRelay[sourceRelay] ?? 0) + 1;
        }
        final sub = _subscriptions[subId];
        if (sub != null) unawaited(sub.onEvent(sock.shard.id, event));
      case PoolEose(:final subId):
        _stampShardLatency(subId, sock.shard.id);
        _subscriptions[subId]?.onEose(sock.shard.id);
      case PoolClosed(:final subId):
        _stampShardLatency(subId, sock.shard.id);
        _subscriptions[subId]?.onEose(sock.shard.id);
      case PoolOk():
        // Publish ACK; publish() does not await per-relay OK in proxy mode.
        break;
      case PoolStatus(:final latency):
        // connectedRelays already updated on the socket. Fold this worker's
        // per-relay latency into the aggregate (relays.js:2137-2141) so the
        // Network Stats rows + Avg Latency show real per-URL numbers in proxy
        // mode (complements the per-shard REQ→EOSE timing).
        latency.forEach((url, ms) {
          _stats.latencyPerRelay[url] = ms;
        });
        break;
      case PoolRelayBan(:final url):
        // The proxy permanently dropped this relay (relays.js:2117). Mirror the
        // PWA's `_permanentlyBlacklistRelay` effect on the shard layout so any
        // future rebuild excludes it.
        _permanentBlacklist.add(url);
        break;
      case PoolPing():
        // Keepalive — no PONG; liveness is implicit (relays.js:2112).
        break;
    }
  }

  /// Relays the proxy has banned this session (`POOL:RELAY_BAN`) plus any seed
  /// blacklist. Exposed for inspection / tests.
  Set<String> get permanentBlacklist => Set.unmodifiable(_permanentBlacklist);
}
