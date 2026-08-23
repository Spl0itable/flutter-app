// The pre-translated UI pack.
//
// Picking a language used to re-translate the whole interface on the device,
// one request per string — around 1300 of them — so the UI filled in over tens
// of seconds and every user paid for the same work again. The web build now
// ships the finished translations as one flat JSON map per language, and this
// fetches it.
//
// What these pin is that the pack is an OPTIMISATION and never a dependency:
// a missing, unreachable or malformed pack has to leave the old runtime path
// exactly as it was, and an on-device translation must never be overwritten by
// an older one from the pack.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nym_bar/features/i18n/localization_service.dart';
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<KeyValueStore> _store() async {
  SharedPreferences.setMockInitialValues({});
  return KeyValueStore(await SharedPreferences.getInstance());
}

/// A JSON response encoded the way a real server sends it. `http.Response`
/// with a bare String encodes latin-1, which would let a mojibake bug through
/// the very decode path a translated pack depends on.
http.Response _json(Object body) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

/// An ApiClient whose translate calls always fail, so anything that ends up
/// translated came from the pack and nowhere else.
ApiClient _deadProxy() => ApiClient(
      client: MockClient((_) async => http.Response('{"error":"down"}', 502)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalizationService svc;

  setUp(() async {
    svc = LocalizationService.instance;
    svc.setLanguage('');
    svc.packClient = null;
    svc.resetPackStateForTest();
    svc.configure(kv: await _store(), language: '', apiClient: _deadProxy());
  });

  tearDown(() {
    svc.setLanguage('');
    svc.packClient = null;
  });

  test('a pack translates without a single proxy call', () async {
    var fetched = 0;
    svc.packClient = MockClient((req) async {
      fetched++;
      expect(req.url.path, '/i18n/es.json');
      return _json({'Settings': 'Ajustes', 'Language': 'Idioma'});
    });
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fetched, 1);
    expect(svc.translate('Settings'), 'Ajustes');
    expect(svc.translate('Language'), 'Idioma');
  });

  test('a string the pack lacks still falls through to the old path', () async {
    svc.packClient = MockClient(
        (_) async => _json({'Settings': 'Ajustes'}));
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.translate('Settings'), 'Ajustes');
    // Not in the pack, and the proxy is dead: English, exactly as before.
    expect(svc.translate('Some brand new string'), 'Some brand new string');
  });

  test('a missing pack is not an error', () async {
    svc.packClient = MockClient((_) async => http.Response('', 404));
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.translate('Settings'), 'Settings');
    expect(svc.isActive, isTrue);
  });

  test('a malformed pack is not an error', () async {
    svc.packClient =
        MockClient((_) async => http.Response('not json at all', 200));
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.translate('Settings'), 'Settings');
  });

  test('a network failure is not an error', () async {
    svc.packClient = MockClient((_) async => throw Exception('offline'));
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.translate('Settings'), 'Settings');
  });

  test('non-string values in a pack are ignored', () async {
    svc.packClient = MockClient((_) async => _json({'Settings': 'Ajustes', 'Language': 42, 'Close': ''}));
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.translate('Settings'), 'Ajustes');
    expect(svc.translate('Language'), 'Language');
    expect(svc.translate('Close'), 'Close');
  });

  test('an on-device translation is not overwritten by the pack', () async {
    // The device's copy is either from the pack already or newer than it.
    final kv = await _store();
    kv.setString('nym_ui_i18n_es', jsonEncode({'Settings': 'On-device'}));
    svc.setLanguage('');
    svc.resetPackStateForTest();
    svc.configure(kv: kv, language: '', apiClient: _deadProxy());
    svc.packClient = MockClient(
        (_) async => _json({'Settings': 'From-pack'}));
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.translate('Settings'), 'On-device');
  });

  test('the pack is fetched once per language per session', () async {
    var fetched = 0;
    svc.packClient = MockClient((_) async {
      fetched++;
      return _json({'Settings': 'Ajustes'});
    });
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    svc.setLanguage('');
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fetched, 1);
  });

  test('English fetches nothing', () async {
    var fetched = 0;
    svc.packClient = MockClient((_) async {
      fetched++;
      return http.Response('{}', 200);
    });
    svc.setLanguage('en');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fetched, 0);
  });

  test('a pack that lands after a language switch is discarded', () async {
    // Otherwise Spanish strings would appear in a French UI.
    svc.packClient = MockClient((req) async {
      // Spanish is slow, French is instant — so the Spanish body arrives after
      // the switch and must be thrown away.
      final spanish = req.url.path.endsWith('es.json');
      if (spanish) await Future<void>.delayed(const Duration(milliseconds: 60));
      return _json({'Settings': spanish ? 'Ajustes' : 'Paramètres'});
    });
    svc.setLanguage('es');
    svc.setLanguage('fr');
    await Future<void>.delayed(const Duration(milliseconds: 160));
    expect(svc.translate('Settings'), 'Paramètres');
  });
}
