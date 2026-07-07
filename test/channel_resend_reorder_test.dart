import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/state/app_state.dart';

/// A relay echo of one of OUR channel sends (pubkey == self so isOwn is true).
NostrEvent _echo(String d, String id, String content,
        {required String pubkey, required int createdAtSec, int? ms}) =>
    NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: createdAtSec,
      kind: EventKind.namedChannel,
      tags: [
        ['d', d],
        ['n', 'me'],
        if (ms != null) ['ms', '$ms'],
      ],
      content: content,
    );

List<Message> _gm(AppStateNotifier n, [String content = 'gm']) =>
    (n.state.messages['#room'] ?? const <Message>[])
        .where((m) => m.content == content)
        .toList();

void main() {
  AppStateNotifier fresh() {
    final n = AppStateNotifier()..goLive('self_pk', 'me#0001');
    n.switchView(const ChatView.channel('room'));
    return n;
  }

  // Sends the same text twice a few seconds apart, both still optimistic, then
  // delivers their relay echoes in [echoOrder]. Returns the reconciled rows.
  List<Message> twoSameContent(
    AppStateNotifier n, {
    required List<String> echoOrder,
  }) {
    final e1 = n.sendLocal('gm')!;
    final t0 = e1.createdAt;
    final t0ms = e1.ms;
    final e2 = n.sendLocal('gm')!;
    e2
      ..createdAt = t0 + 5
      ..timestamp = (t0 + 5) * 1000
      ..ms = t0ms + 5000;
    final t1 = e2.createdAt;
    final t1ms = e2.ms;
    final byId = {
      'r1': (createdAt: t0, ms: t0ms, echo: e1),
      'r2': (createdAt: t1, ms: t1ms, echo: e2),
    };
    for (final id in echoOrder) {
      final v = byId[id]!;
      n.ingestEvent(_echo('room', id, 'gm',
          pubkey: 'self_pk', createdAtSec: v.createdAt, ms: v.ms));
    }
    // Publish awaits resolve afterwards (real ids r1/r2 for e1/e2 respectively).
    n.replaceOptimistic(e1.id, 'r1', realCreatedAt: t0, realMs: t0ms);
    n.replaceOptimistic(e2.id, 'r2', realCreatedAt: t1, realMs: t1ms);
    return _gm(n);
  }

  void expectOrderedDistinct(List<Message> rows, {required int t0}) {
    expect(rows.length, 2, reason: 'exactly two distinct bubbles');
    // Two distinct real ids, correctly time-ordered, first above second.
    expect(rows.map((m) => m.id).toSet(), {'r1', 'r2'});
    final r1 = rows.firstWhere((m) => m.id == 'r1');
    final r2 = rows.firstWhere((m) => m.id == 'r2');
    expect(r1.createdAt, t0, reason: 'first send keeps its original time');
    expect(r2.createdAt, t0 + 5, reason: 'second send keeps its own time');
    expect(rows.indexOf(r1) < rows.indexOf(r2), true,
        reason: 'earlier message stays above the later one');
  }

  test('same-content sends: in-order echoes → ordered, distinct, no re-stamp',
      () {
    final n = fresh();
    final rows = twoSameContent(n, echoOrder: ['r1', 'r2']);
    expectOrderedDistinct(rows, t0: rows.first.createdAt < rows.last.createdAt
        ? rows.first.createdAt
        : rows.last.createdAt);
  });

  test(
      'same-content sends: OUT-OF-ORDER echoes → ordered, distinct, no re-stamp '
      '(the phantom-resend repro)', () {
    final n = fresh();
    // The second message's echo (r2) lands before the first message's (r1).
    final rows = twoSameContent(n, echoOrder: ['r2', 'r1']);
    final t0 =
        rows.map((m) => m.createdAt).reduce((a, b) => a < b ? a : b);
    expectOrderedDistinct(rows, t0: t0);
  });

  test('three same-content sends: fully shuffled echoes → three ordered rows',
      () {
    final n = fresh();
    final e1 = n.sendLocal('yo')!;
    final base = e1.createdAt;
    final baseMs = e1.ms;
    final e2 = n.sendLocal('yo')!
      ..createdAt = base + 3
      ..timestamp = (base + 3) * 1000
      ..ms = baseMs + 3000;
    final e3 = n.sendLocal('yo')!
      ..createdAt = base + 7
      ..timestamp = (base + 7) * 1000
      ..ms = baseMs + 7000;
    // Echoes arrive scrambled: e3, e1, e2.
    n.ingestEvent(_echo('room', 'r3', 'yo',
        pubkey: 'self_pk', createdAtSec: e3.createdAt, ms: e3.ms));
    n.ingestEvent(_echo('room', 'r1', 'yo',
        pubkey: 'self_pk', createdAtSec: e1.createdAt, ms: e1.ms));
    n.ingestEvent(_echo('room', 'r2', 'yo',
        pubkey: 'self_pk', createdAtSec: e2.createdAt, ms: e2.ms));
    n.replaceOptimistic(e1.id, 'r1', realCreatedAt: base, realMs: baseMs);
    n.replaceOptimistic(e2.id, 'r2',
        realCreatedAt: base + 3, realMs: baseMs + 3000);
    n.replaceOptimistic(e3.id, 'r3',
        realCreatedAt: base + 7, realMs: baseMs + 7000);
    final rows = _gm(n, 'yo');
    expect(rows.length, 3);
    expect(rows.map((m) => m.id).toList(), ['r1', 'r2', 'r3'],
        reason: 'each echo binds to its own send; feed stays time-ordered');
    expect(rows.map((m) => m.createdAt).toList(),
        [base, base + 3, base + 7]);
  });

  test('a genuinely FAILED send + same-content resend still collapses to one',
      () {
    // Regression guard: the failed-twin sweep must survive the new matching.
    final n = fresh();
    final e1 = n.sendLocal('retry me')!;
    n.markOptimisticFailed(e1.id); // publish threw → stays _optim_* failed
    final e2 = n.sendLocal('retry me')!;
    n.ingestEvent(_echo('room', 'r2', 'retry me',
        pubkey: 'self_pk', createdAtSec: e2.createdAt, ms: e2.ms));
    n.replaceOptimistic(e2.id, 'r2', realCreatedAt: e2.createdAt);
    final rows = _gm(n, 'retry me');
    expect(rows.length, 1, reason: 'the live resend supersedes the failed twin');
    expect(rows.single.id, 'r2');
    expect(rows.single.deliveryStatus, DeliveryStatus.sent);
  });
}
