/// relay_stats.dart — the live relay-traffic counters that back the Network
/// Stats modal (`relay_stats_modal.dart`).
///
/// 1:1 port of the PWA's `nym.relayStats` object (app.js:497-505, written by
/// relays.js socket handlers and sampled by `startRelayStatsSampling`,
/// app.js:7324). The PWA tracks, per session:
///   - `bytesReceived`     — sum of every inbound websocket frame's length.
///   - `bytesSent`         — sum of every outbound frame's length.
///   - `totalEvents`       — unique inbound EVENT messages.
///   - `eventsThisSecond`  — events seen since the last 1s sample (reset each
///                           tick by the sampler).
///   - `throughputHistory` — the last 60 per-second event counts (the graph;
///                           `push(eventsThisSecond)` then `shift()` past 60).
///   - `eventsPerRelay`    — url → unique-event count (per-relay rows).
///   - `latencyPerRelay`   — url → latency in ms (per-relay rows + Avg Latency).
///
/// This object holds the mutable, live counters (mirroring the PWA's mutable
/// plain object). The relay layer mutates it on every frame; the modal reads a
/// stable [snapshot] each render so it never observes a half-updated map.
class RelayStats {
  RelayStats({
    this.bytesReceived = 0,
    this.bytesSent = 0,
    this.totalEvents = 0,
    this.eventsThisSecond = 0,
    List<int>? throughputHistory,
    Map<String, int>? eventsPerRelay,
    Map<String, int>? latencyPerRelay,
  })  : throughputHistory = throughputHistory ?? <int>[],
        eventsPerRelay = eventsPerRelay ?? <String, int>{},
        latencyPerRelay = latencyPerRelay ?? <String, int>{};

  /// `throughputHistory` cap — the PWA keeps the last 60 samples (one per
  /// second → a 60s window). app.js:7331.
  static const int throughputCap = 60;

  /// Total UTF-8 bytes received across every relay/shard socket this session.
  int bytesReceived;

  /// Total UTF-8 bytes sent across every relay/shard socket this session.
  int bytesSent;

  /// Unique inbound EVENT messages seen this session (post-dedup).
  int totalEvents;

  /// Events seen since the last 1-second sample. Pushed into
  /// [throughputHistory] and reset to 0 by the sampler each tick.
  int eventsThisSecond;

  /// Last [throughputCap] per-second event counts (oldest first). Drives the
  /// throughput graph; the empty list renders the flat-baseline placeholder.
  final List<int> throughputHistory;

  /// Relay url → unique-event count (per-relay rows' `<n> evt`).
  final Map<String, int> eventsPerRelay;

  /// Relay url → last measured latency in ms (per-relay rows' `<ms>ms` and the
  /// Avg-Latency card). Stamped REQ→EOSE per relay.
  final Map<String, int> latencyPerRelay;

  /// Average latency in ms across [latencyPerRelay] (rounded), or null when no
  /// latency has been measured yet (the card then renders `--`). Mirrors
  /// `renderRelayStats`'s `avgLat` computation (app.js:7376-7381).
  int? get averageLatencyMs {
    if (latencyPerRelay.isEmpty) return null;
    var sum = 0;
    for (final ms in latencyPerRelay.values) {
      sum += ms;
    }
    return (sum / latencyPerRelay.length).round();
  }

  /// Record a 1-second throughput sample: push [eventsThisSecond] onto
  /// [throughputHistory] (capped at [throughputCap]) and reset the per-second
  /// counter. Mirrors `startRelayStatsSampling`'s tick (app.js:7329-7332).
  void sampleThroughput() {
    throughputHistory.add(eventsThisSecond);
    while (throughputHistory.length > throughputCap) {
      throughputHistory.removeAt(0);
    }
    eventsThisSecond = 0;
  }

  /// An immutable copy of the current counters. The modal reads this each
  /// render so live mutation of the source maps can never tear a frame.
  RelayStats snapshot() => RelayStats(
        bytesReceived: bytesReceived,
        bytesSent: bytesSent,
        totalEvents: totalEvents,
        eventsThisSecond: eventsThisSecond,
        throughputHistory: List<int>.from(throughputHistory),
        eventsPerRelay: Map<String, int>.from(eventsPerRelay),
        latencyPerRelay: Map<String, int>.from(latencyPerRelay),
      );
}
