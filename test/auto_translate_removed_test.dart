import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/constants/storage_keys.dart';
import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/translate/translate_service.dart';
import 'package:nym_bar/features/translate/translate_target.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/settings.dart';
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/services/api/storage_sync.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/nostr_controller.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/widgets/chat/message_row.dart';

TranslateService _uppercasingService(List<String> calls) {
  final mock = MockClient((req) async {
    final text = (jsonDecode(req.body)['text'] ?? '').toString();
    calls.add(text);
    return http.Response(
      jsonEncode(
          {'translatedText': text.toUpperCase(), 'detectedLanguage': 'es'}),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  return TranslateService(
    api: ApiClient(client: mock, baseUrl: 'https://h/api/proxy'),
  );
}

const _legacyFlat = <String, dynamic>{
  'autoTranslate': true,
  'autoTranslateChannels': true,
  'autoTranslatePMs': true,
  'autoTranslateGroups': true,
};

Map<String, dynamic> _flatten(Settings s, KeyValueStore kv) {
  final out = <String, dynamic>{};
  StorageSync.buildSectionPayloads(s, kv: kv, selfPubkey: 'a' * 64)
      .forEach((_, fields) => out.addAll(fields));
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('legacy auto-translate keys', () {
    test('are dropped from local storage on load and never re-saved',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        for (final k in StorageKeys.legacyAutoTranslateKeys) k: true,
        StorageKeys.translateLanguage: 'es',
      });
      final kv = await KeyValueStore.open();
      final container = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(kv)],
      );
      addTearDown(container.dispose);
      expect(container.read(settingsProvider).translateLanguage, 'es');
      await Future<void>.delayed(Duration.zero);
      for (final k in StorageKeys.legacyAutoTranslateKeys) {
        expect(kv.contains(k), isFalse, reason: k);
      }
      container.read(settingsProvider.notifier).setTranslateLanguage('fr');
      expect(container.read(settingsProvider).translateLanguage, 'fr');
      for (final k in StorageKeys.legacyAutoTranslateKeys) {
        expect(kv.contains(k), isFalse, reason: k);
      }
      final flat = _flatten(container.read(settingsProvider), kv);
      for (final k in _legacyFlat.keys) {
        expect(flat.containsKey(k), isFalse, reason: k);
      }
    });

    test('synced settings carrying them still apply and round-trip', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      final container = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(kv)],
      );
      addTearDown(container.dispose);
      final baseline = _flatten(container.read(settingsProvider), kv);
      container.read(nostrControllerProvider).applySyncedSettingsForTest({
        ...baseline,
        ..._legacyFlat,
        'translateLanguage': 'de',
        'v': 2,
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(container.read(settingsProvider).translateLanguage, 'de');
      for (final k in StorageKeys.legacyAutoTranslateKeys) {
        expect(kv.contains(k), isFalse, reason: k);
      }
      final sections = StorageSync.buildSectionPayloads(
          container.read(settingsProvider),
          kv: kv,
          selfPubkey: 'a' * 64);
      for (final fields in sections.values) {
        for (final k in _legacyFlat.keys) {
          expect(fields.containsKey(k), isFalse, reason: k);
        }
      }
      expect(sections['messaging']?['translateLanguage'], 'de');
    });
  });

  group('stale auto-translate preference', () {
    testWidgets('a saved true value no longer translates incoming messages',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'nym_auto_translate': true,
        'nym_auto_translate_channels': true,
        'nym_auto_translate_pms': true,
        'nym_auto_translate_groups': true,
        StorageKeys.translateLanguage: 'es',
      });
      final kv = await KeyValueStore.open();
      final container = ProviderContainer(
        overrides: [keyValueStoreProvider.overrideWithValue(kv)],
      );
      addTearDown(container.dispose);
      final settings = container.read(settingsProvider);
      expect(settings.translateLanguage, 'es');
      final colors = resolveNymColors(
        theme: NymThemeKey.bitchat,
        brightness: Brightness.dark,
        solidUi: true,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildNymThemeData(colors),
            home: Scaffold(
              body: MessageRow(
                message: Message(
                  id: 'm1',
                  author: 'bob#1234',
                  pubkey: 'pkOther',
                  content: 'hello from bob',
                  createdAt: 1000,
                  isPM: true,
                  conversationKey: 'pm-pkOther',
                  conversationPubkey: 'pkOther',
                ),
                settings: settings,
                reactions: const [],
                scrollKey: 'pm-pkOther',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('hello from bob'), findsWidgets);
      expect(find.text('Show original'), findsNothing);
    });
  });

  group('manualTranslateTargetFor', () {
    test('prefers translateLanguage, then UI language, then English', () {
      expect(
          manualTranslateTargetFor(
              const Settings(translateLanguage: 'fr', uiLanguage: 'de')),
          'fr');
      expect(manualTranslateTargetFor(const Settings(uiLanguage: 'de')), 'de');
      expect(manualTranslateTargetFor(const Settings()), 'en');
    });
  });

  group('manual translation still preserves tokens', () {
    test('@mentions are never sent upstream', () async {
      final calls = <String>[];
      final res = await _uppercasingService(calls)
          .translate('@alice#1a2b hello there', 'en');
      expect(res.translatedText, contains('@alice#1a2b'));
      expect(res.translatedText, contains('HELLO THERE'));
      expect(calls.any((c) => c.contains('alice')), isFalse);
    });

    test('URLs and :shortcode: emoji survive', () async {
      final calls = <String>[];
      final res = await _uppercasingService(calls)
          .translate('look https://ex.com/a.png :party: hello', 'en');
      expect(res.translatedText, contains('https://ex.com/a.png'));
      expect(res.translatedText, contains(':party:'));
      expect(res.translatedText, contains('HELLO'));
    });
  });
}
