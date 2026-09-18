import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_config.dart';

class SocketTickets {
  SocketTickets._();

  static http.Client? client;
  static Duration timeout = const Duration(seconds: 4);
  static const Duration refreshBefore = Duration(seconds: 20);

  static String? _ticket;
  static int _expiresAt = 0;
  static Future<String?>? _pending;

  static bool appliesTo(Uri url) => url.host.toLowerCase() == ApiConfig.apiHost;

  static String? get held =>
      _ticket != null && _expiresAt > DateTime.now().millisecondsSinceEpoch
          ? _ticket
          : null;

  static Future<String?> fetch() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_ticket != null && _expiresAt - now > refreshBefore.inMilliseconds) {
      return Future.value(_ticket);
    }
    final pending = _pending;
    if (pending != null) return pending;
    final run = _refresh().whenComplete(() => _pending = null);
    _pending = run;
    return run;
  }

  static Future<String?> _refresh() async {
    try {
      final c = client ?? http.Client();
      final resp = await c
          .post(
            Uri.parse('https://${ApiConfig.apiHost}/api/ticket'),
            headers: ApiConfig.defaultHeaders,
          )
          .timeout(timeout);
      if (resp.statusCode != 200) return held;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return held;
      final ticket = decoded['ticket'];
      if (ticket is! String || ticket.isEmpty) return held;
      _ticket = ticket;
      _expiresAt = (decoded['expiresAt'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch + 60000;
      return ticket;
    } catch (_) {
      return held;
    }
  }

  static Uri apply(Uri url, String? ticket) {
    if (ticket == null || ticket.isEmpty) return url;
    return url.replace(queryParameters: {...url.queryParameters, 't': ticket});
  }

  static void touch() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_ticket != null && _expiresAt - now > refreshBefore.inMilliseconds) {
      return;
    }
    if (_pending != null) return;
    fetch().ignore();
  }

  static Future<Uri> ticketed(Uri url) async {
    if (!appliesTo(url)) return url;
    return apply(url, await fetch());
  }

  static void reset() {
    _ticket = null;
    _expiresAt = 0;
    _pending = null;
  }
}
