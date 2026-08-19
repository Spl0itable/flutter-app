// Shared, persistent geohash → "City, Country" cache.
//
// Reverse geocoding goes to Nominatim, which caps clients at one request per
// second and explicitly forbids bulk lookups. That was tolerable when only the
// open channel's header resolved a place, but showing the location on every
// sidebar row multiplies lookups by the channel count, so two properties are
// load-bearing:
//
//   * it PERSISTS — a per-widget Map dies with the widget, and every relaunch
//     would re-geocode the whole sidebar;
//   * lookups are SERIALISED with a ≥1.1s gap, and concurrent callers for one
//     geohash collapse into a single request (the header and its sidebar row
//     ask for the same place on channel switch).
//
// Storage key and JSON shape match the web client's `nym_geohash_places`.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/channel.dart';
import '../../services/api/api_client.dart';
import '../../services/storage/key_value_store.dart';
import '../../state/settings_provider.dart';

/// Bound on the persisted map. Entries are ~30 bytes.
const int kGeohashPlaceMax = 500;

/// Nominatim's documented rate limit, plus headroom.
const Duration kGeohashPlaceMinInterval = Duration(milliseconds: 1100);

const String kGeohashPlaceKey = 'nym_geohash_places';

class GeohashPlaceCache {
  GeohashPlaceCache({required KeyValueStore kv, required ApiClient api})
      : _kv = kv,
        _api = api {
    _load();
  }

  final KeyValueStore _kv;
  final ApiClient _api;

  final Map<String, String> _cache = {};
  final Map<String, Future<String>> _inflight = {};

  Future<void> _chain = Future<void>.value();
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _saveTimer;

  void _load() {
    try {
      final raw = _kv.getString(kGeohashPlaceKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((k, v) {
          if (v is String && v.isNotEmpty) _cache['$k'] = v;
        });
      }
    } catch (_) {
      // Corrupt or unavailable — start empty rather than fail construction.
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), () {
      try {
        var entries = _cache.entries.toList();
        if (entries.length > kGeohashPlaceMax) {
          // Keep the most recently resolved; Dart maps preserve insertion order.
          entries = entries.sublist(entries.length - kGeohashPlaceMax);
          _cache
            ..clear()
            ..addEntries(entries);
        }
        _kv.setString(kGeohashPlaceKey, jsonEncode(Map.fromEntries(entries)));
      } catch (_) {
        // Storage unavailable — the cache stays in memory for this session.
      }
    });
  }

  /// The resolved place, or null when this geohash has never been looked up.
  /// Callers render [geohashLocationLabel] (decoded locally, no network) until
  /// this returns something.
  String? cached(String geohash) => _cache[geohash.toLowerCase()];

  /// Resolves [geohash] to "City, Country", queued behind any other lookup.
  Future<String> resolve(String geohash) {
    final key = geohash.toLowerCase();
    final hit = _cache[key];
    if (hit != null) return Future.value(hit);
    if (!isValidGeohash(key)) return Future.value('');
    final pending = _inflight[key];
    if (pending != null) return pending;

    final completer = Completer<String>();
    _inflight[key] = completer.future;

    _chain = _chain.then((_) async {
      final gap = _lastAt.add(kGeohashPlaceMinInterval).difference(DateTime.now());
      if (gap > Duration.zero) await Future<void>.delayed(gap);
      _lastAt = DateTime.now();
      try {
        final coords = decodeGeohash(key);
        final data = await _api.geocode(coords.lat, coords.lng, zoom: 10);
        final addr = (data['address'] as Map?) ?? const {};
        String s(Object? v) => v is String ? v : '';
        final city = [
          s(addr['city']),
          s(addr['town']),
          s(addr['village']),
          s(addr['county']),
        ].firstWhere((x) => x.isNotEmpty, orElse: () => '');
        final country = s(addr['country']);
        var place = [city, country].where((x) => x.isNotEmpty).join(', ');
        if (place.isEmpty) place = 'Unknown location';
        _cache[key] = place;
        _scheduleSave();
        completer.complete(place);
      } catch (_) {
        // Report the miss without caching it, so it retries later — but never
        // let one failure wedge everything queued behind it.
        completer.complete('');
      } finally {
        _inflight.remove(key);
      }
    });

    return completer.future;
  }
}

final geohashPlaceCacheProvider = Provider<GeohashPlaceCache>((ref) {
  return GeohashPlaceCache(
    kv: ref.read(keyValueStoreProvider),
    api: ApiClient(),
  );
});
