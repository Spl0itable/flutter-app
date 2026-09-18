import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/services/api/api_config.dart';
import 'package:nym_bar/services/api/http_overrides.dart';

void main() {
  test('every HTTP client the app opens identifies as the app', () {
    HttpOverrides.runZoned(() {
      expect(HttpClient().userAgent, ApiConfig.userAgent);
      expect(HttpClient().userAgent, startsWith('Dart/'));
      expect(HttpClient().userAgent, contains('(dart:io), NymchatApp/'));
    }, createHttpClient: (c) => NymHttpOverrides().createHttpClient(c));
  });

  test('the socket client still carries no default, so nothing doubles', () {
    HttpOverrides.runZoned(() {
      expect(ApiConfig.socketClient().userAgent, isNull);
    }, createHttpClient: (c) => NymHttpOverrides().createHttpClient(c));
  });
}
