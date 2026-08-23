// The direct-to-Google fallback for translation.
//
// The proxy exists to keep the user's IP away from Google, so it is always
// tried first. But Google rate-limits its endpoint by caller IP and a
// Cloudflare Worker egresses from an address shared with every other Worker in
// its colo, so a busy colo returns HTTP 429 to the proxy and the proxy returns
// 502 to everyone behind it. The PWA has always fallen back to a direct
// request; this app did not, so translation simply stopped working for those
// users while the browser kept going.
//
// These pin the fallback: that a proxy failure reaches it, that a proxy
// SUCCESS never does (the fallback must not become the default path), and that
// it parses the same response shape the proxy parses server-side.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nym_bar/features/translate/translate_service.dart';
import 'package:nym_bar/services/api/api_client.dart';

/// The `translate_a/single` body Google returns for one segment.
String _googleBody(String translated, String detected) =>
    jsonEncode([
      [
        [translated, 'original', null, null, 10]
      ],
      null,
      detected
    ]);

void main() {
  group('direct fallback', () {
    test('parses a Google response', () async {
      final client = MockClient((req) async {
        expect(req.url.host, 'translate.googleapis.com');
        expect(req.url.queryParameters['tl'], 'es');
        expect(req.url.queryParameters['q'], 'hello');
        return http.Response(_googleBody('hola', 'en'), 200);
      });
      final r = await TranslateService.translateDirect('hello', 'es',
          client: client);
      expect(r.translatedText, 'hola');
      expect(r.detectedLanguage, 'en');
    });

    test('joins multi-segment responses in order', () async {
      final client = MockClient((_) async => http.Response(
            jsonEncode([
              [
                ['uno ', 'one', null, null, 10],
                ['dos', 'two', null, null, 10]
              ],
              null,
              'en'
            ]),
            200,
          ));
      final r = await TranslateService.translateDirect('one two', 'es',
          client: client);
      expect(r.translatedText, 'uno dos');
    });

    test('a non-200 is an error, not an empty translation', () async {
      // The failure that matters: silently returning '' would blank the
      // message the user asked to translate.
      final client = MockClient((_) async => http.Response('nope', 429));
      expect(
        () => TranslateService.translateDirect('hello', 'es', client: client),
        throwsA(isA<TranslateException>()),
      );
    });

    test('an unrecognised shape is an error, not a guess', () async {
      final client =
          MockClient((_) async => http.Response(jsonEncode({'x': 1}), 200));
      expect(
        () => TranslateService.translateDirect('hello', 'es', client: client),
        throwsA(isA<TranslateException>()),
      );
    });

    test('a missing detected language falls back to auto', () async {
      final client = MockClient((_) async => http.Response(
            jsonEncode([
              [
                ['hola', 'hello', null, null, 10]
              ]
            ]),
            200,
          ));
      final r = await TranslateService.translateDirect('hello', 'es',
          client: client);
      expect(r.detectedLanguage, 'auto');
    });

    test('long text is truncated the way the proxy truncates it', () async {
      String? sent;
      final client = MockClient((req) async {
        sent = req.url.queryParameters['q'];
        return http.Response(_googleBody('x', 'en'), 200);
      });
      await TranslateService.translateDirect('a' * 6000, 'es', client: client);
      expect(sent!.length, 5000);
    });
  });

  group('routing', () {
    /// An ApiClient whose proxy calls all fail the way a rate-limited colo
    /// makes them fail: HTTP 502 with the worker's JSON error body.
    ApiClient failingProxy() => ApiClient(
          client: MockClient((_) async => http.Response(
                jsonEncode({'error': 'Translation failed: HTTP 429'}),
                502,
              )),
        );

    test('a 502 from the proxy reaches the direct path', () async {
      var directCalls = 0;
      final direct = MockClient((req) async {
        directCalls++;
        return http.Response(_googleBody('hola', 'en'), 200);
      });
      final svc =
          TranslateService(api: failingProxy(), directClient: direct);
      final r = await svc.translate('hello', 'es');
      expect(r.translatedText, 'hola');
      expect(directCalls, 1);
    });

    test('a working proxy never reaches the direct path', () async {
      // The fallback must stay a fallback: routing every translation direct
      // would hand the user's IP to Google for no reason.
      var directCalls = 0;
      final api = ApiClient(
        client: MockClient((_) async => http.Response(
              jsonEncode(
                  {'translatedText': 'hola', 'detectedLanguage': 'en'}),
              200,
            )),
      );
      final direct = MockClient((_) async {
        directCalls++;
        return http.Response(_googleBody('WRONG', 'en'), 200);
      });
      final svc = TranslateService(api: api, directClient: direct);
      final r = await svc.translate('hello', 'es');
      expect(r.translatedText, 'hola');
      expect(directCalls, 0);
    });

    test('both failing surfaces an error rather than the original text',
        () async {
      final direct = MockClient((_) async => http.Response('nope', 429));
      final svc =
          TranslateService(api: failingProxy(), directClient: direct);
      expect(() => svc.translate('hello', 'es'),
          throwsA(isA<TranslateException>()));
    });

    test('mentions and emoji still survive the fallback path', () async {
      // The fallback sits under the chunking, so everything the service
      // preserves must still be preserved when it fires.
      final direct = MockClient((req) async {
        final q = req.url.queryParameters['q']!;
        return http.Response(_googleBody('[$q]', 'en'), 200);
      });
      final svc =
          TranslateService(api: failingProxy(), directClient: direct);
      final r = await svc.translate('hi @bob 🎉 see https://x.test', 'es');
      expect(r.translatedText, contains('@bob'));
      expect(r.translatedText, contains('🎉'));
      expect(r.translatedText, contains('https://x.test'));
    });
  });
}
