// Through the relay-pool proxy the pool and the spam engine already filter
// every channel message, so the app's own automatic heuristics (web-of-trust
// gate, content heuristics, campaign auto-mute, gibberish nyms) apply only in
// direct mode. User choices still apply in both.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/settings_provider.dart';

const _self = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _stranger = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();
  final c = ProviderContainer(overrides: [keyValueStoreProvider.overrideWithValue(kv)]);
  c.read(appStateProvider.notifier).goLive(_self, 'you#1a2b');
  return c;
}

NostrEvent _msg(String id, String content) => NostrEvent(
      id: id,
      pubkey: _stranger,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: 23333,
      tags: [
        ['n', 'Stranger#dddd'],
        ['d', 'nymchat'],
      ],
      content: content,
      sig: '0' * 128,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    nymVouchSpamGateEnabled = true;
    appSpamFilterEnabled = true;
    appSpamFilterAggressive = true;
  });
  tearDown(() {
    nymVouchSpamGateEnabled = false;
  });

  test('an untrusted sender without proof of work shows through the proxy', () async {
    final c = await _container();
    final n = c.read(appStateProvider.notifier);
    n.setProxyMode(true);
    n.ingestEvent(_msg('1' * 64, 'hello from a phone that never mined'));
    expect(visibleMessagesFor(c.read(appStateProvider), '#nymchat').length, 1);
    expect(c.read(appStateProvider).clientGatesActive, isFalse);

    n.setProxyMode(false);
    expect(visibleMessagesFor(c.read(appStateProvider), '#nymchat').length, 0,
        reason: 'in direct mode the web-of-trust gate still hides an untrusted stranger');
    c.dispose();
  });

  test('the content heuristic and blocks behave the same way', () async {
    final c = await _container();
    final n = c.read(appStateProvider.notifier);
    n.setProxyMode(true);
    n.ingestEvent(_msg('2' * 64, 'look ["client","chorus"] tagged'));
    expect(visibleMessagesFor(c.read(appStateProvider), '#nymchat').length, 1,
        reason: 'the pool already applies the shared content heuristics');
    n.setProxyMode(false);
    expect(visibleMessagesFor(c.read(appStateProvider), '#nymchat').length, 0);

    n.setProxyMode(true);
    n.blockUser(_stranger);
    expect(visibleMessagesFor(c.read(appStateProvider), '#nymchat').length, 0,
        reason: 'an explicit block applies in both modes');
    c.dispose();
  });
}
