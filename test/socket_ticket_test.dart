import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nym_bar/services/api/api_config.dart';
import 'package:nym_bar/services/api/socket_ticket.dart';

void main() {
  late List<http.Request> posts;
  late int status;
  late String ticket;

  setUp(() {
    posts = [];
    status = 200;
    ticket = 'tk-1';
    SocketTickets.reset();
    SocketTickets.client = MockClient((req) async {
      posts.add(req);
      if (status != 200) return http.Response('{}', status);
      return http.Response(
          jsonEncode({
            'ticket': ticket,
            'expiresAt': DateTime.now().millisecondsSinceEpoch + 120000,
          }),
          200);
    });
  });

  test('a socket on our host carries a ticket fetched as the app', () async {
    final u = await SocketTickets.ticketed(
        Uri.parse('wss://${ApiConfig.apiHost}/api/relay-pool'));
    expect(u.queryParameters['t'], 'tk-1');
    expect(posts.single.url.path, '/api/ticket');
    expect(posts.single.headers['User-Agent'], ApiConfig.userAgent);
  });

  test('one fetch serves every socket while the ticket is fresh', () async {
    await SocketTickets.ticketed(Uri.parse('wss://${ApiConfig.apiHost}/api'));
    await SocketTickets.ticketed(
        Uri.parse('wss://${ApiConfig.apiHost}/api/relay-pool'));
    expect(posts.length, 1);
  });

  test('an existing query keeps its parameters', () async {
    final u = await SocketTickets.ticketed(Uri.parse(
        'wss://${ApiConfig.apiHost}/api/relay?relay=wss%3A%2F%2Fx'));
    expect(u.queryParameters['relay'], 'wss://x');
    expect(u.queryParameters['t'], 'tk-1');
  });

  test('another host is left alone and nothing is fetched', () async {
    final u = await SocketTickets.ticketed(Uri.parse('wss://h/api/relay-pool'));
    expect(u.toString(), 'wss://h/api/relay-pool');
    expect(posts, isEmpty);
  });

  test('a refused fetch opens the socket without a ticket', () async {
    status = 403;
    final u = await SocketTickets.ticketed(
        Uri.parse('wss://${ApiConfig.apiHost}/api/relay-pool'));
    expect(u.queryParameters.containsKey('t'), isFalse);
  });
}
