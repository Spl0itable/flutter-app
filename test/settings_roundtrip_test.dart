// The cross-device round trip.
//
// A settings-set REPLACES the whole category row, so every key this client
// publishes must also be one it can APPLY. When it publishes a key it cannot
// receive, it reads the other device's value, ignores it, and writes its own
// back — and because D1 is the source of truth, that reverts the setting on
// every device. The user sees "I changed it on the web, then my phone
// connected, and it went back to the default".
//
// Each key is probed in isolation, against a fresh container, so one key's
// value cannot mask or break another's. Several candidate values are tried per
// key and it is only reported as broken when NONE survives: a list of channel
// names and a list of pubkeys accept different shapes, and a value rejected for
// being malformed is not the same as a value that was dropped.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/models/settings.dart';
import 'package:nym_bar/services/api/storage_sync.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/nostr_controller.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Booleans that are a VIEW of another key rather than state of their own: the
/// scope string is authoritative and the flag is recomputed from it. Probing
/// one without the other makes the pair contradict, and the apply is right to
/// prefer the scope.
const _derivedFrom = <String, String>{
  'readReceiptsEnabled': 'readReceiptsScope',
  'typingIndicatorsEnabled': 'typingIndicatorsScope',
};

/// Shapes to try for a collection-valued key. A channel list, a pubkey list and
/// a language list validate their entries differently.
final _candidates = <Object>[
  'f' * 64, // a well-formed pubkey / event id
  'probe', // a plain channel or geohash name
  'en', // a language tag
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final selfPubkey = 'a' * 64;

  Future<(ProviderContainer, KeyValueStore)> freshContainer() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final kv = await KeyValueStore.open();
    return (
      ProviderContainer(overrides: [keyValueStoreProvider.overrideWithValue(kv)]),
      kv
    );
  }

  Map<String, dynamic> flatten(Settings s, KeyValueStore kv) {
    final out = <String, dynamic>{};
    StorageSync.buildSectionPayloads(s, kv: kv, selfPubkey: selfPubkey)
        .forEach((_, fields) => out.addAll(fields));
    return out;
  }

  test('every published settings key survives an inbound apply', () async {
    final (probeContainer, probeKv) = await freshContainer();
    // Start from what this client itself publishes, so every value already has
    // the type and shape the apply guards expect.
    final baseline = flatten(const Settings(), probeKv);
    probeContainer.dispose();

    final broken = <String>[];
    var probed = 0;

    for (final entry in baseline.entries) {
      final key = entry.key;
      final base = entry.value;
      if (key == 'v' || _derivedFrom.containsKey(key)) continue;

      // Values to try for this key. Strings are left alone — most are enum ids,
      // and inventing one would be rejected by the apply guards and read as a
      // bug that isn't there.
      final tries = <Object>[
        if (base is bool) !base,
        if (base is int) base + 7,
        if (base is List && base.isEmpty)
          for (final c in _candidates) <dynamic>[c],
        if (base is Map && base.isEmpty)
          for (final c in _candidates) <String, dynamic>{'$c': 1700000000},
      ];
      if (tries.isEmpty) continue;
      probed++;

      Object? lastGot;
      var survived = false;
      for (final want in tries) {
        final (container, kv) = await freshContainer();
        try {
          container
              .read(nostrControllerProvider)
              .applySyncedSettingsForTest({...baseline, key: want, 'v': 2});
          // Some apply paths persist through an unawaited future.
          await Future<void>.delayed(const Duration(milliseconds: 20));
          final got = flatten(container.read(settingsProvider), kv)[key];
          lastGot = got;
          if (_holds(want, got)) {
            survived = true;
            break;
          }
        } finally {
          container.dispose();
        }
      }
      if (!survived) broken.add('  $key: sent ${tries.first}, published back $lastGot');
    }

    expect(probed, greaterThan(20), reason: 'the probe must cover real ground');
    expect(
      broken,
      isEmpty,
      reason: 'these keys are published but never applied, so this device '
          'overwrites every other device with its own value:\n${broken.join('\n')}',
    );
  });
}

/// Collections sync as a union, so growth is fine; losing the value is not.
bool _holds(Object? want, Object? got) {
  if (want is List) return got is List && want.every(got.contains);
  if (want is Map) {
    return got is Map &&
        want.entries.every((e) => got.containsKey(e.key) && got[e.key] == e.value);
  }
  return want == got;
}
