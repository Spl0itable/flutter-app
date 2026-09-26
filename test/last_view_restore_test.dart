import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/models/channel.dart';
import 'package:nym_bar/models/group.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/last_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _self =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _alice =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _bob =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class _Boot {
  _Boot(this.notifier, this.restored);
  final AppStateNotifier notifier;
  final ChatView? restored;
  ChatView get view => notifier.currentView;
}

_Boot _freshBoot(
  KeyValueStore kv, {
  void Function(AppStateNotifier n)? hydrate,
  void Function(AppStateNotifier n)? beforeLive,
  void Function(AppStateNotifier n)? duringHydration,
}) {
  final n = AppStateNotifier();
  final restore = BootViewRestore(n, kv);
  beforeLive?.call(n);
  restore.beforeGoLive();
  n.goLive(_self, 'me#cccc');
  restore.afterGoLive();
  duringHydration?.call(n);
  hydrate?.call(n);
  return _Boot(n, restore.apply());
}

void _withAlicePm(AppStateNotifier n) => n.ensurePMConversation(_alice);

void _withGroup(AppStateNotifier n) =>
    n.upsertGroup(Group(id: 'g1', name: 'crew', members: [_self, _alice]));

void main() {
  late KeyValueStore kv;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    kv = KeyValueStore(await SharedPreferences.getInstance());
  });

  group('parseLastView', () {
    test('round-trips every conversation kind through its storage key', () {
      for (final v in const [
        ChatView.channel('9q8y'),
        ChatView.channel('bitcoin'),
        ChatView.pm(_alice),
        ChatView.group('g1'),
      ]) {
        expect(parseLastView(v.storageKey), v);
      }
    });

    test('rejects empty and unknown values', () {
      expect(parseLastView(null), isNull);
      expect(parseLastView(''), isNull);
      expect(parseLastView('#'), isNull);
      expect(parseLastView('pm-'), isNull);
      expect(parseLastView('group-'), isNull);
      expect(parseLastView('nymchat'), isNull);
    });
  });

  test('switchView counts every navigation', () {
    final n = AppStateNotifier()..goLive(_self, 'me#cccc');
    final before = n.viewSwitchCount;
    n.switchView(const ChatView.channel('bitcoin'));
    n.switchView(const ChatView.pm(_alice));
    expect(n.viewSwitchCount, before + 2);
  });

  group('fresh boot restore', () {
    test('with nothing remembered the boot lands on #nymchat', () {
      final boot = _freshBoot(kv);
      expect(boot.restored, isNull);
      expect(boot.view, const ChatView.channel(kDefaultChannel));
    });

    test('reopens the last PM', () {
      rememberLastView(kv, const ChatView.pm(_alice));
      final boot = _freshBoot(kv, hydrate: _withAlicePm);
      expect(boot.restored, const ChatView.pm(_alice));
      expect(boot.view, const ChatView.pm(_alice));
    });

    test('reopens the last group chat', () {
      rememberLastView(kv, const ChatView.group('g1'));
      final boot = _freshBoot(kv, hydrate: _withGroup);
      expect(boot.view, const ChatView.group('g1'));
    });

    test('reopens the last geohash channel and registers it', () {
      rememberLastView(kv, const ChatView.channel('9q8y'));
      final boot = _freshBoot(kv);
      expect(boot.view, const ChatView.channel('9q8y'));
      expect(boot.notifier.currentState.channels.any((c) => c.key == '9q8y'),
          isTrue);
      expect(boot.notifier.currentState.channels
          .firstWhere((c) => c.key == '9q8y')
          .isGeohash, isTrue);
    });

    test('reopens the last named channel', () {
      rememberLastView(kv, const ChatView.channel('bitcoin'));
      final boot = _freshBoot(kv);
      expect(boot.view, const ChatView.channel('bitcoin'));
    });

    test('reopens the Nymbot chat without a stored conversation', () {
      rememberLastView(kv, const ChatView.pm(kNymbotPubkey));
      final boot = _freshBoot(kv);
      expect(boot.view, const ChatView.pm(kNymbotPubkey));
    });

    test('a remembered #nymchat is a no-op', () {
      rememberLastView(kv, const ChatView.channel(kDefaultChannel));
      final boot = _freshBoot(kv);
      expect(boot.restored, isNull);
      expect(boot.view, const ChatView.channel(kDefaultChannel));
    });
  });

  group('missing conversation falls back to #nymchat', () {
    void expectFallback(_Boot boot) {
      expect(boot.restored, isNull);
      expect(boot.view, const ChatView.channel(kDefaultChannel));
      expect(kv.getString(StorageKeys.lastView), isNull);
    }

    test('deleted PM', () {
      rememberLastView(kv, const ChatView.pm(_bob));
      expectFallback(_freshBoot(kv, hydrate: _withAlicePm));
    });

    test('PM with a blocked user', () {
      rememberLastView(kv, const ChatView.pm(_alice));
      expectFallback(_freshBoot(kv, hydrate: (n) {
        _withAlicePm(n);
        n.hydrateSocialState(blockedUsers: {_alice});
      }));
    });

    test('group that no longer exists', () {
      rememberLastView(kv, const ChatView.group('gone'));
      expectFallback(_freshBoot(kv, hydrate: _withGroup));
    });

    test('group the user left', () {
      rememberLastView(kv, const ChatView.group('g1'));
      expectFallback(_freshBoot(kv, hydrate: (n) {
        _withGroup(n);
        n.mergeLeftGroups({'g1'}, {'g1': 1});
      }));
    });

    test('blocked channel', () {
      rememberLastView(kv, const ChatView.channel('bitcoin'));
      expectFallback(_freshBoot(kv,
          hydrate: (n) => n.hydrateSocialState(blockedChannels: {'bitcoin'})));
    });

    test('garbage value', () {
      kv.setString(StorageKeys.lastView, 'whatever');
      final boot = _freshBoot(kv);
      expect(boot.restored, isNull);
      expect(boot.view, const ChatView.channel(kDefaultChannel));
    });
  });

  group('notification and deep link precedence', () {
    test('a notification opened while the store hydrates wins', () {
      rememberLastView(kv, const ChatView.group('g1'));
      final boot = _freshBoot(
        kv,
        hydrate: _withGroup,
        duringHydration: (n) {
          n.ensurePMConversation(_bob);
          n.switchView(const ChatView.pm(_bob));
        },
      );
      expect(boot.restored, isNull);
      expect(boot.view, const ChatView.pm(_bob));
    });

    test('a notification opened before the identity boots survives goLive',
        () {
      rememberLastView(kv, const ChatView.group('g1'));
      final boot = _freshBoot(
        kv,
        hydrate: _withGroup,
        beforeLive: (n) {
          n.ensurePMConversation(_bob);
          n.switchView(const ChatView.pm(_bob));
        },
      );
      expect(boot.restored, const ChatView.pm(_bob));
      expect(boot.view, const ChatView.pm(_bob));
      expect(
          boot.notifier.currentState.pmConversations
              .any((c) => c.pubkey == _bob),
          isTrue);
    });

    test('a deep link to a channel before the identity boots wins', () {
      rememberLastView(kv, const ChatView.pm(_alice));
      final boot = _freshBoot(
        kv,
        hydrate: _withAlicePm,
        beforeLive: (n) => n.switchChannel('u4pr', geohash: 'u4pr'),
      );
      expect(boot.view, const ChatView.channel('u4pr'));
    });

    test('a group notification before the identity boots wins', () {
      rememberLastView(kv, const ChatView.pm(_alice));
      final boot = _freshBoot(
        kv,
        hydrate: (n) {
          _withAlicePm(n);
          _withGroup(n);
        },
        beforeLive: (n) => n.switchView(const ChatView.group('g1')),
      );
      expect(boot.view, const ChatView.group('g1'));
    });
  });

  test('remembering writes the storage key and skips unchanged writes', () {
    rememberLastView(kv, const ChatView.group('g1'));
    expect(kv.getString(StorageKeys.lastView), 'group-g1');
    rememberLastView(kv, const ChatView.pm(_alice));
    expect(kv.getString(StorageKeys.lastView), 'pm-$_alice');
  });
}
