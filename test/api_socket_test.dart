import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:nym_bar/services/api/api_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A fake `/api` WebSocket the test drives: queued auto-replies are injected in
/// response to the frames the client sends, so we can exercise the multiplexed
/// AUTH/REQ → AUTH_OK/RES/ITEM/END protocol without a real socket.
class _FakeApiChannel implements WebSocketChannel {
  _FakeApiChannel(this._onSend);

  final StreamController<dynamic> _inbound = StreamController<dynamic>.broadcast();
  final List<String> sent = [];
  late final _FakeSink _sink = _FakeSink(sent, _inbound, _onSend);

  /// Called with (channel, decodedFrame) whenever the client sends a frame, so
  /// the test can inject the matching server reply.
  final void Function(_FakeApiChannel ch, List<dynamic> frame) _onSend;

  void inject(List<dynamic> frame) {
    if (!_inbound.isClosed) _inbound.add(jsonEncode(frame));
  }

  @override
  Stream<dynamic> get stream => _inbound.stream;
  @override
  WebSocketSink get sink => _sink;
  @override
  Future<void> get ready => Future<void>.value();
  @override
  String? get protocol => null;
  @override
  int? get closeCode => _sink.closeCode;
  @override
  String? get closeReason => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._sent, this._inbound, this._onSend);
  final List<String> _sent;
  final StreamController<dynamic> _inbound;
  final void Function(_FakeApiChannel ch, List<dynamic> frame) _onSend;
  _FakeApiChannel? channel;
  int? closeCode;

  @override
  void add(dynamic data) {
    _sent.add(data.toString());
    final frame = jsonDecode(data.toString());
    if (frame is List && channel != null) {
      // Reply asynchronously, like a real socket.
      scheduleMicrotask(() => _onSend(channel!, frame));
    }
  }

  @override
  Future<dynamic> close([int? code, String? reason]) async {
    closeCode = code;
    if (!_inbound.isClosed) await _inbound.close();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<dynamic> addStream(Stream<dynamic> stream) async {
    await for (final d in stream) {
      add(d);
    }
  }

  @override
  Future<dynamic> get done => Future<void>.value();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Builds a fake channel whose sink replies via [onSend], wiring the back-ref.
_FakeApiChannel _makeChannel(
    void Function(_FakeApiChannel ch, List<dynamic> frame) onSend) {
  final ch = _FakeApiChannel(onSend);
  ch._sink.channel = ch;
  return ch;
}

void main() {
  group('ApiClient WS-first storage transport', () {
    test('public read rides the socket (HTTP never called); parses ITEM/END',
        () async {
      var httpCalls = 0;
      final client = MockClient((req) async {
        httpCalls++;
        return http.Response('', 200);
      });
      late _FakeApiChannel channel;
      final api = ApiClient(client: client);
      api.activateApiSocket(factory: (url) {
        channel = _makeChannel((ch, frame) {
          // profile-get is a public read → no AUTH; just a REQ.
          if (frame[0] == 'REQ') {
            final id = frame[1];
            ch.inject(['ITEM', id, ['pk', {'event': {'id': 'e1'}}]]);
            ch.inject(['END', id, {'x-has-more': '0'}]);
          }
        });
        return channel;
      });

      final stream = await api.storageStream({
        'action': 'profile-get',
        'pubkeys': ['a' * 64],
      });
      expect(httpCalls, 0, reason: 'socket served the read, HTTP not used');
      expect(stream.items.length, 1);
      expect((stream.items.first as List)[0], 'pk');
      // The framed REQ carried the action + extra (no auth/pubkey on a public read).
      final reqFrame = jsonDecode(channel.sent.last) as List;
      expect(reqFrame[0], 'REQ');
      expect(reqFrame[2], 'profile-get');
      expect((reqFrame[3] as Map).containsKey('pubkeys'), isTrue);
    });

    test('authed action does AUTH handshake; strips pubkey/auth from REQ extra',
        () async {
      final client = MockClient((req) async => http.Response('', 200));
      final api = ApiClient(client: client);
      api.setApiSocketAuthBuilder(() async => {
            'kind': 27235,
            'id': 'auth-id',
            'pubkey': 'a' * 64,
            'sig': 's',
            'created_at': 1,
            'tags': const [],
            'content': 'nymbot-pm-auth',
          });
      late _FakeApiChannel channel;
      api.activateApiSocket(factory: (url) {
        channel = _makeChannel((ch, frame) {
          if (frame[0] == 'AUTH') {
            ch.inject(['AUTH_OK']);
          } else if (frame[0] == 'REQ') {
            ch.inject(['RES', frame[1], 200, {'owned': {}, 'active': {}}]);
          }
        });
        return channel;
      });

      final data = await api.storageAction({
        'action': 'shop-get',
        'pubkey': 'a' * 64,
        'auth': {'kind': 27235},
      });
      expect(data['owned'], isA<Map>());
      // First frame is AUTH, last is the REQ with pubkey/auth stripped.
      final frames = channel.sent.map((s) => jsonDecode(s) as List).toList();
      expect(frames.first[0], 'AUTH');
      final req = frames.firstWhere((f) => f[0] == 'REQ');
      final extra = req[3] as Map;
      expect(extra.containsKey('auth'), isFalse, reason: 'socket is authed once');
      expect(extra.containsKey('pubkey'), isFalse);
      expect(extra.containsKey('action'), isFalse);
    });

    test('socket connect failure falls back to HTTP', () async {
      var httpCalls = 0;
      final client = MockClient((req) async {
        httpCalls++;
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['action'], 'profile-get');
        return http.Response('${jsonEncode(['pk', null])}\n', 200,
            headers: {'Content-Type': 'application/x-ndjson'});
      });
      final api = ApiClient(client: client);
      // A factory that throws → ensureConnected fails → HTTP fallback.
      api.activateApiSocket(factory: (url) => throw StateError('no socket'));

      final stream = await api.storageStream({
        'action': 'profile-get',
        'pubkeys': ['a' * 64],
      });
      expect(httpCalls, 1, reason: 'fell back to HTTP after socket failure');
      expect(stream.items.length, 1);
    });

    test('a RES error status surfaces as an ApiException', () async {
      final client = MockClient((req) async => http.Response('', 200));
      final api = ApiClient(client: client);
      api.setApiSocketAuthBuilder(() async => {'kind': 27235, 'id': 'x'});
      api.activateApiSocket(factory: (url) {
        return _makeChannel((ch, frame) {
          if (frame[0] == 'AUTH') {
            ch.inject(['AUTH_OK']);
          } else if (frame[0] == 'REQ') {
            ch.inject(['RES', frame[1], 402, {'error': 'Payment not confirmed yet.'}]);
          }
        });
      });

      expect(
        () => api.storageAction({
          'action': 'shop-claim',
          'pubkey': 'a' * 64,
          'auth': {'kind': 27235},
        }),
        throwsA(isA<ApiException>()),
      );
    });

    test('socket disabled by default → HTTP path is used', () async {
      var httpCalls = 0;
      final client = MockClient((req) async {
        httpCalls++;
        return http.Response('${jsonEncode(['pk', null])}\n', 200,
            headers: {'Content-Type': 'application/x-ndjson'});
      });
      // No activateApiSocket → HTTP only (the unit-test / shop-controller default).
      final api = ApiClient(client: client);
      await api.storageStream({
        'action': 'profile-get',
        'pubkeys': ['a' * 64],
      });
      expect(httpCalls, 1);
    });
  });
}
