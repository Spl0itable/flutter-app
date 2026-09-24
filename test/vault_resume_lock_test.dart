import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/identity/identity_vault.dart';
import 'package:nym_bar/features/identity/vault_boot_unlock.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemSecure implements SecureStoreLike {
  final Map<String, String> map = {};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
  @override
  Future<void> remove(String key) async => map.remove(key);
  @override
  Future<void> wipeAll() async => map.clear();
}

Future<KeyValueStore> _kv() async {
  SharedPreferences.setMockInitialValues({});
  return KeyValueStore(await SharedPreferences.getInstance());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('where no background wake exists the vault key is not escrowed',
      () async {
    final secure = _MemSecure();
    await secure.set('nym_session_nsec', 'the-secret');
    secure.map['nym_vault_bg_key'] = 'left-by-an-older-version';
    final vault = IdentityVault(await _kv(), secure, escrow: false);

    await vault.enable(method: 'password', password: 'hunter2');
    expect(secure.map.containsKey('nym_vault_bg_key'), isFalse);
    expect(await vault.unlockForBackgroundWake(), isNull);

    await vault.unlock('hunter2');
    expect(secure.map.containsKey('nym_vault_bg_key'), isFalse);
  });

  testWidgets('an app woken in the background stays behind the lock',
      (tester) async {
    await tester.pumpWidget(const VaultLockedApp(
      app: Directionality(
          textDirection: TextDirection.ltr, child: Text('private chats')),
      lock: Directionality(
          textDirection: TextDirection.ltr, child: Text('unlock')),
    ));
    expect(find.text('unlock'), findsOneWidget);
    expect(find.text('private chats'), findsNothing);
    expect(find.text('private chats', skipOffstage: false), findsOneWidget);
  });

  testWidgets('the resume lock offers no way around the password',
      (tester) async {
    final kv = await _kv();
    await tester.pumpWidget(ProviderScope(
      overrides: [keyValueStoreProvider.overrideWithValue(kv)],
      child: MaterialApp(
        theme: buildNymThemeData(resolveNymColors(
          theme: NymThemeKey.bitchat,
          brightness: Brightness.dark,
          solidUi: true,
        )),
        home: VaultBootUnlock(
          onUnlocked: (_) {},
          onForget: () {},
          canForget: false,
        ),
      ),
    ));
    expect(find.text('FORGET IDENTITY'), findsNothing);
    expect(find.text('UNLOCK'), findsOneWidget);
  });
}
