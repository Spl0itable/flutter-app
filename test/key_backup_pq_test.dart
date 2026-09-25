import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/core/crypto/keys.dart';
import 'package:nym_bar/core/crypto/nip44.dart' as nip44;
import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/i18n/app_strings_catalog.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_crypto.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_pq_restore.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_service.dart';
import 'package:nym_bar/features/identity/key_backup/key_backup_store.dart';
import 'package:nym_bar/features/identity/key_backup/passkey_backup_crypto.dart';
import 'package:nym_bar/features/identity/key_backup/passkey_backup_service.dart';
import 'package:nym_bar/features/identity/nick_edit_modal.dart';
import 'package:nym_bar/features/identity/pq_root.dart';
import 'package:nym_bar/features/identity/setup_modal.dart';
import 'package:nym_bar/services/nostr/identity_service.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/nostr_controller.dart';
import 'package:nym_bar/state/settings_provider.dart';

import 'key_backup_flow_test.dart' show FakeStore, fastDerive;
import 'passkey_fakes.dart';

class FakeController extends NostrController {
  FakeController(super.ref);

  Identity? fakeIdentity;
  String? code;
  bool linkNeeded = false;
  bool linkAccepts = true;
  final List<String> logins = [];
  final List<String> links = [];
  final List<String> notices = [];

  @override
  Identity? get identity => fakeIdentity;

  @override
  String? get pqRootCode => code;

  @override
  bool get pqRootHeld => code != null;

  @override
  bool get pqRootLinkNeeded => linkNeeded;

  @override
  Future<bool> linkPqRootFromCode(String code) async {
    links.add(code);
    if (!linkAccepts) return false;
    this.code = code;
    linkNeeded = false;
    return true;
  }

  @override
  Future<void> loginWithNsec(String nsec) async {
    logins.add(nsec);
    linkNeeded = true;
  }

  @override
  void showSystemNotice(String text) => notices.add(text);
}

String realCode() => pqRootToCode(randomBytes(32));

String newSecret() => bytesToHex(generatePrivateKey());

Future<Uint8List> keyFor(FakeStore store, String pin) =>
    fastDerive(pin, backupSalt(store.cloud, store.accountId));

Future<void> seedPlain(FakeStore store, String pin, String plaintext) async {
  await store.write(nip44.encrypt(plaintext, await keyFor(store, pin)));
}

Future<BackupSecret?> openBackup(FakeStore store, String pin) async {
  final key = await keyFor(store, pin);
  for (final p in store.files.values) {
    final s = decryptBackupSecret(p, key);
    if (s != null) return s;
  }
  return null;
}

void main() {
  late KeyValueStore kv;
  late FakeController ctrl;

  setUp(() async {
    PinThrottle.resetAll();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.${StorageKeys.uiLanguageChosen}': 'true',
    });
    kv = await KeyValueStore.open();
  });

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Widget app(Widget home, List<KeyBackupStore> stores,
      {PasskeyBackupService? passkey}) {
    final colors = resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: Brightness.dark,
      solidUi: true,
    );
    return ProviderScope(
      overrides: [
        keyValueStoreProvider.overrideWithValue(kv),
        keyBackupStoresProvider.overrideWithValue(stores),
        keyBackupDeriverProvider.overrideWithValue(fastDerive),
        nostrControllerProvider.overrideWith((ref) {
          ctrl = FakeController(ref);
          return ctrl;
        }),
        if (passkey != null) ...[
          passkeyBackupServiceProvider.overrideWithValue(passkey),
          passkeyBackupAvailableProvider.overrideWith((ref) async => true),
        ] else
          passkeyBackupAvailableProvider.overrideWith((ref) async => false),
      ],
      child: MaterialApp(
        theme: buildNymThemeData(colors),
        home: Scaffold(
          body: Consumer(
              builder: (context, ref, child) {
                ref.read(nostrControllerProvider);
                return child!;
              },
              child: home),
        ),
      ),
    );
  }

  Widget touch() => Consumer(builder: (context, ref, _) {
        ref.read(nostrControllerProvider);
        return const SizedBox();
      });

  Widget details(void Function() setup) {
    var ready = false;
    return Consumer(builder: (context, ref, _) {
      ref.read(nostrControllerProvider);
      if (!ready) {
        ready = true;
        setup();
      }
      return const NickEditModal();
    });
  }

  group('restoring through the setup modal', () {
    Future<void> continueWithGoogle(WidgetTester tester, String pin) async {
      await tester.tap(find.byKey(const Key('keyBackupContinue_google')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('keyBackupPin')), pin);
      await tester.tap(find.text('UNLOCK'));
      await settle(tester);
    }

    testWidgets('restores the key, then links the backed-up recovery code',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.google);
      final secret = newSecret();
      final code = realCode();
      await store.write(encryptBackupSecret(secret, await keyFor(store, '2468'),
          pqCode: code));
      await tester.pumpWidget(app(SetupModal(onComplete: () {}), [store]));
      await tester.pump();

      await continueWithGoogle(tester, '2468');

      expect(ctrl.logins, [secret]);
      expect(ctrl.links, [code]);
      expect(ctrl.code, code);
      expect(ctrl.notices, isEmpty);
    });

    testWidgets('a legacy bare-hex backup restores without a code',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.google);
      final secret = newSecret();
      await seedPlain(store, '2468', secret);
      await tester.pumpWidget(app(SetupModal(onComplete: () {}), [store]));
      await tester.pump();

      await continueWithGoogle(tester, '2468');

      expect(ctrl.logins, [secret]);
      expect(ctrl.links, isEmpty);
      expect(find.text('RECOVERY CODE SKIPPED'), findsNothing);
    });

    testWidgets('a bad code is skipped with a note and never blocks sign-in',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.google);
      final secret = newSecret();
      await seedPlain(
          store, '2468', '{"v":1,"sk":"$secret","pq":"nympq1notarealcode"}');
      await tester.pumpWidget(app(SetupModal(onComplete: () {}), [store]));
      await tester.pump();

      await continueWithGoogle(tester, '2468');

      expect(find.text('RECOVERY CODE SKIPPED'), findsOneWidget);
      expect(ctrl.logins, isEmpty);
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(ctrl.logins, [secret]);
      expect(ctrl.links, isEmpty);
    });

    testWidgets('a passkey backup restores the code too', (tester) async {
      tall(tester);
      final prf = Uint8List.fromList(List.filled(32, 0xa1));
      final platform = FakePasskeyPlatform(prf: prf);
      final relays = FakeRelays();
      final service = fakePasskeyService(platform, relays);
      final secret = newSecret();
      final code = realCode();
      await service.backUp(
          secretHex: secret,
          pubkeyHex: getPublicKeyHex(hexToBytes(secret)),
          pqCode: code);
      await tester.pumpWidget(
          app(SetupModal(onComplete: () {}), const [], passkey: service));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const Key('keyBackupContinue_passkey')));
      await settle(tester);

      expect(ctrl.logins, [secret]);
      expect(ctrl.links, [code]);
    });
  });

  group('restoreBackupPqCode', () {
    testWidgets('waits for the account state, then links', (tester) async {
      await tester.pumpWidget(app(touch(), const []));
      final code = realCode();
      var done = false;
      restoreBackupPqCode(
              ctrl, BackupSecret(secretHex: newSecret(), pqCode: code))
          .then((_) => done = true);
      await tester.pump(const Duration(seconds: 1));
      expect(ctrl.links, isEmpty);
      expect(done, isFalse);
      ctrl.linkNeeded = true;
      await tester.pump(const Duration(seconds: 1));
      expect(ctrl.links, [code]);
      expect(done, isTrue);
    });

    testWidgets('does nothing when this device already holds that code',
        (tester) async {
      await tester.pumpWidget(app(touch(), const []));
      final code = realCode();
      ctrl.code = code;
      final result = await restoreBackupPqCode(
          ctrl, BackupSecret(secretHex: newSecret(), pqCode: code));
      expect(result, BackupPqRestore.alreadyHeld);
      expect(ctrl.links, isEmpty);
    });

    testWidgets('a code the account rejects leaves a note', (tester) async {
      await tester.pumpWidget(app(touch(), const []));
      ctrl
        ..linkNeeded = true
        ..linkAccepts = false;
      final result = await restoreBackupPqCode(
          ctrl, BackupSecret(secretHex: newSecret(), pqCode: realCode()));
      expect(result, BackupPqRestore.rejected);
      expect(ctrl.notices, hasLength(1));
      expect(ctrl.notices.single, contains('does not match this account'));
    });

    testWidgets('no code means nothing to do', (tester) async {
      await tester.pumpWidget(app(touch(), const []));
      final result =
          await restoreBackupPqCode(ctrl, BackupSecret(secretHex: newSecret()));
      expect(result, BackupPqRestore.none);
      expect(ctrl.links, isEmpty);
    });
  });

  group("View or Edit Nym's Details", () {
    Future<void> openReveal(WidgetTester tester) async {
      await tester
          .tap(find.text("Reveal this nym's private key and recovery code"));
      await settle(tester);
    }

    void signedIn(String secret, {String? loginMethod = 'nsec', String? code}) {
      final sk = hexToBytes(secret);
      ctrl
        ..fakeIdentity = Identity(
          pubkey: getPublicKeyHex(sk),
          privkey: loginMethod == 'nip46' ? null : sk,
          nym: 'tester#abcd',
          loginMethod: loginMethod,
        )
        ..code = code;
    }

    testWidgets('holds the backup buttons beside the nsec and recovery code',
        (tester) async {
      tall(tester);
      final prf = Uint8List.fromList(List.filled(32, 0xa1));
      final service =
          fakePasskeyService(FakePasskeyPlatform(prf: prf), FakeRelays());
      final secret = newSecret();
      final code = realCode();
      await tester.pumpWidget(app(
        details(() => signedIn(secret, code: code)),
        [FakeStore(BackupCloud.google), FakeStore(BackupCloud.apple)],
        passkey: service,
      ));
      await tester.pump();
      expect(find.byKey(const Key('keyBackupActions')), findsNothing);
      await openReveal(tester);

      expect(find.byKey(const Key('keyBackupActions')), findsOneWidget);
      expect(find.text('Cloud Key Backup'), findsOneWidget);
      expect(find.byKey(const Key('keyBackupBackUp_google')), findsOneWidget);
      expect(find.byKey(const Key('keyBackupBackUp_apple')), findsOneWidget);
      expect(find.byKey(const Key('keyBackupBackUp_passkey')), findsOneWidget);
      expect(find.byKey(const Key('keyBackupRemove_google')), findsOneWidget);
      expect(find.byKey(const Key('keyBackupRemove_apple')), findsOneWidget);
      expect(find.text('Post-quantum recovery code'), findsOneWidget);
    });

    testWidgets('backing up to Google includes the recovery code',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.google);
      final secret = newSecret();
      final code = realCode();
      await tester.pumpWidget(app(
        details(() => signedIn(secret, code: code)),
        [store],
      ));
      await tester.pump();
      await openReveal(tester);
      await tester.tap(find.byKey(const Key('keyBackupBackUp_google')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('keyBackupPin')), '4444');
      await tester.enterText(
          find.byKey(const Key('keyBackupPinConfirm')), '4444');
      await tester.tap(find.text('BACK UP'));
      await settle(tester);

      expect(find.text('BACKUP COMPLETE'), findsOneWidget);
      final back = await openBackup(store, '4444');
      expect(back!.secretHex, secret);
      expect(back.pqCode, code);
    });

    testWidgets('backing up with a passkey includes the recovery code',
        (tester) async {
      tall(tester);
      final prf = Uint8List.fromList(List.filled(32, 0xa1));
      final relays = FakeRelays();
      final service = fakePasskeyService(FakePasskeyPlatform(prf: prf), relays);
      final secret = newSecret();
      final code = realCode();
      await tester.pumpWidget(app(
        details(() => signedIn(secret, code: code)),
        const [],
        passkey: service,
      ));
      await tester.pump();
      await openReveal(tester);
      await tester.tap(find.byKey(const Key('keyBackupBackUp_passkey')));
      await settle(tester);

      expect(find.text('BACKED UP'), findsOneWidget);
      final back = PasskeyBackupKeys.fromPrf(prf)
          .decrypt(relays.published.single.content)!;
      expect(back.secretHex, secret);
      expect(back.pqCode, code);
    });

    testWidgets('an account without a code backs up the key alone',
        (tester) async {
      tall(tester);
      final store = FakeStore(BackupCloud.apple);
      final secret = newSecret();
      await tester.pumpWidget(app(
        details(() => signedIn(secret)),
        [store],
      ));
      await tester.pump();
      await openReveal(tester);
      await tester.tap(find.byKey(const Key('keyBackupBackUp_apple')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('keyBackupPin')), '4444');
      await tester.enterText(
          find.byKey(const Key('keyBackupPinConfirm')), '4444');
      await tester.tap(find.text('BACK UP'));
      await settle(tester);
      final key = await keyFor(store, '4444');
      expect(nip44.decrypt(store.files.values.single, key),
          '{"v":1,"sk":"$secret"}');
    });

    testWidgets('remote signers get no backup buttons', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(
        details(() =>
            signedIn(newSecret(), loginMethod: 'nip46', code: realCode())),
        [FakeStore(BackupCloud.google)],
      ));
      await tester.pump();
      await openReveal(tester);
      expect(find.byKey(const Key('keyBackupActions')), findsNothing);
      expect(find.byKey(const Key('keyBackupBackUp_google')), findsNothing);
    });
  });

  test('the new copy is in the sweep catalog', () {
    for (final s in const [
      'Recovery code skipped',
      'The backup also holds your post-quantum recovery code when this '
          'device has it.',
      'The backup options are in View or Edit Nym’s Details, beside '
          'your private key and recovery code.',
    ]) {
      expect(kAppStringsCatalog, contains(s), reason: s);
    }
  });
}
