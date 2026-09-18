import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nym_bar/services/api/socket_ticket.dart';

void stubTickets({String ticket = 'tk-test', int status = 200}) {
  SocketTickets.reset();
  SocketTickets.client = MockClient((req) async {
    if (status != 200) return http.Response('{}', status);
    return http.Response(
        jsonEncode({
          'ticket': ticket,
          'expiresAt': DateTime.now().millisecondsSinceEpoch + 120000,
        }),
        200);
  });
}
