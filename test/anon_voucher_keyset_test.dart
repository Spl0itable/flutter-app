import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:nym_bar/core/crypto/voucher.dart';
import 'package:nym_bar/features/nymbot/anon_bot.dart';
import 'package:nym_bar/features/nymbot/nymbot_service.dart';

const _serverKeysetId = '47a02727155496f1';

const Map<String, Map<String, String>> _serverKeys = {
  'standard': {
    '1': '033d8817e3f828029d78e902282519f999613390f48efb76e50accb4bebc7ec13e',
    '2': '039ed4b209dcf617f9935cbc77e6c2df061fa708ae431a28c7dfe39a50f5487ec0',
    '4': '032a9e21319919eb68b6f4ef4cddbd3f73292ec0bd2adf3fa1d7f6c3204b8e1ff7',
    '8': '02e8d59d9930e8305ebcc52766b215332b3dfb2d99698bc9f786a942a6a6c2fcd2',
    '16': '02405d6a7cc0bf357306646f6272e8b621b52d15607ab732f6847844a8b7e7b6bd',
    '32': '0335ab7d35098b6e7ab6143e44254a6e74f6801cc7a96dae255bc15e86e786de19',
    '64': '03fdb66de9b8bb455fe780944a18cfda229de7180cbe4925f9acdf3d6c54a9c920',
    '128': '038a678d885255b8d083ac76058f25bed26b787d1f75a38ac68f2ecf71f31ee139',
    '256': '0263e620676e58127ded16842035e42e109dbf216d671f782c19c1cb42e9482a5e',
    '512': '037f65173bd8fbf5ab2e467b8667a7a63c9e1e0e770d5ad35fba9a356c7fe0f675',
    '1024':
        '0244111d9033f83d4a88ddfe1a2f684fd3f164a44a8be91d4a66770a0d75753b9b',
    '2048':
        '029cf19385608f099c017842aeb4bc99a40096c35a51ba262b4880815d989a990c',
    '4096':
        '02a4a7c28a2a9fdd0c6f03cf6335170597e9198ed318b72c0e012d1e8865ff9662',
  },
  'pro': {
    '1': '03a7f17b248d3b38198d27b15aceeb94637bbbeb08b4954604d7fead9dcdbc9409',
    '2': '033111c7700c1da2adfade83b46521238e9f8b0b9560b2d6c1f48d3f978b75bb17',
    '4': '02724a9d2fe54e5711c9937dc2604a63256c74ba5cac26a38522abb122fdda5a29',
    '8': '03eb9f9565883f80e03cce266079b29180e04de4ac852562bdd67b25846f9705f8',
    '16': '0349ebff44135a9cd03f2fcdd564a5c8b5052f18aac03f5f0793f7c8d0b4f90029',
    '32': '03d1751fba0b11c0b760bde74929e5fc2b72f555171a49e0839c40bfd26a977920',
    '64': '03b54934844f4eb3eb839083026a1fa8854b9983f8b00c217ed7da7d5605a2f1e4',
    '128': '021d6f830b06bec6e446d8a09e0ab3b5250c311a0835b31c77cae060450e5d35bc',
    '256': '0376f038059b66e7021dc7aa056028ef669307a7b1393ead7d29d42dcb782683a3',
    '512': '02c6653bd5d8f63813d2499aff156adf18fcf8a886b3da84d225bc38957ca64fe6',
    '1024':
        '0251f49d9d98c93f1b5e55173ad3d340f53b9aa026f88a4ffefd5b34ab0afd1f70',
    '2048':
        '0279671237821378765eb9482df966d7c2713c380e1d05c761973b84bf11df289e',
    '4096':
        '033d62d0bdf76bd3272aee940a0f97e0bf6f09a30c1c9bcb481fcaef7bb1e87a29',
  },
};

Map<String, dynamic> _response({
  String id = _serverKeysetId,
  Map<String, Map<String, String>> keys = _serverKeys,
  Object? denoms = voucherDenoms,
}) =>
    <String, dynamic>{
      'keysetId': id,
      if (denoms != null) 'denoms': denoms,
      'maxOutputs': voucherMaxOutputs,
      'keys': keys,
    };

Map<String, Map<String, String>> _swapped() {
  final out = {
    for (final e in _serverKeys.entries)
      e.key: Map<String, String>.from(e.value),
  };
  out['pro']!['4096'] = _serverKeys['standard']!['4096']!;
  return out;
}

AnonBotManager _manager(Map<String, dynamic> body) => AnonBotManager(
      NymbotService(
        baseUrl: 'https://h/api/bot',
        client: MockClient((_) async => http.Response(
              jsonEncode(body),
              200,
              headers: {'content-type': 'application/json'},
            )),
      ),
    );

void main() {
  group('voucherKeysetId', () {
    test('matches the id the server derives for the same keys', () {
      expect(voucherKeysetId(_serverKeys, voucherDenoms), _serverKeysetId);
    });

    test('changes when any key changes', () {
      expect(
          voucherKeysetId(_swapped(), voucherDenoms), isNot(_serverKeysetId));
    });

    test('is null when a tier or denomination key is missing', () {
      final missing = {
        'standard': Map<String, String>.from(_serverKeys['standard']!),
      };
      expect(voucherKeysetId(missing, voucherDenoms), isNull);
      final partial = _swapped()..['pro']!.remove('1');
      expect(voucherKeysetId(partial, voucherDenoms), isNull);
    });
  });

  group('AnonBotManager voucher keyset pinning', () {
    test('pins the recomputed id for honest keys', () async {
      final m = _manager(_response());
      final ks = await m.keyset();
      expect(ks['keysetId'], _serverKeysetId);
      expect(m.keysetId(), _serverKeysetId);
      expect((ks['keys'] as Map)['pro']['4096'], _serverKeys['pro']!['4096']);
    });

    test('refuses keys that do not hash to the advertised id', () async {
      final m = _manager(_response(keys: _swapped()));
      await expectLater(m.keyset(), throwsA(isA<AnonBotException>()));
      expect(m.keysetId(), isNull);
    });

    test('refuses a forged id for honest keys', () async {
      final m = _manager(_response(id: '0000000000000000'));
      await expectLater(m.keyset(), throwsA(isA<AnonBotException>()));
      expect(m.keysetId(), isNull);
    });

    test('drops keys outside the hashed denominations', () {
      final extra = {
        for (final e in _serverKeys.entries)
          e.key: Map<String, String>.from(e.value),
      };
      extra['standard']!['8192'] = _serverKeys['pro']!['1']!;
      final pinned =
          AnonBotManager.verifiedVoucherKeyset(_response(keys: extra));
      expect(pinned, isNotNull);
      expect((pinned!['keys'] as Map)['standard'].containsKey('8192'), isFalse);
    });

    test('refuses malformed denominations', () {
      expect(
          AnonBotManager.verifiedVoucherKeyset(_response(denoms: ['1', '2'])),
          isNull);
    });
  });
}
