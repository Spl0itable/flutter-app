import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/constants/event_kinds.dart';
import 'package:nym_bar/features/messages/flood_tracker.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/nostr_event.dart';
import 'package:nym_bar/services/nostr/event_mapper.dart';

NostrEvent _chan(String d, String id, String content,
        {required String pubkey, required int createdAtSec}) =>
    NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: createdAtSec,
      kind: EventKind.namedChannel,
      tags: [
        ['d', d],
        ['n', 'someone'],
      ],
      content: content,
    );

void main() {
  const self = 'self_pk';
  const sender = 'sender_pk';
  int nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  group('channelMessage historical flag (PWA messageAge > 10000)', () {
    test('a fresh (live) channel event is NOT historical', () {
      final m = EventMapper.channelMessage(
        _chan('room', 'a', 'hello there', pubkey: sender, createdAtSec: nowSec()),
        selfPubkey: self,
      )!;
      expect(m.isHistorical, isFalse);
    });

    test('an aged (>10s backlog) channel event IS historical', () {
      final m = EventMapper.channelMessage(
        _chan('room', 'b', 'hello there',
            pubkey: sender, createdAtSec: nowSec() - 60),
        selfPubkey: self,
      )!;
      expect(m.isHistorical, isTrue);
    });
  });

  group('flood tracker exempts backfilled history', () {
    // Three identical 6+char messages from one sender trip the content-flood
    // gate (>= kContentFloodRepeat within the window).
    List<Message> mapped(int createdAtSec) => [
          for (var i = 0; i < kContentFloodRepeat; i++)
            EventMapper.channelMessage(
              _chan('room', 'evt$createdAtSec$i', 'flood flood',
                  pubkey: sender, createdAtSec: createdAtSec),
              selfPubkey: self,
            )!,
        ];

    test('a LIVE content-flood dims the sender', () {
      final tracker =
          FloodTracker.fromMessages(mapped(nowSec()), selfPubkey: self);
      expect(tracker.isFlooding(sender), isTrue);
    });

    test('the SAME burst arriving as BACKFILL (aged) does not dim anyone', () {
      // Opening a busy channel replays its recent history; every event is now
      // >10s old so the mapper marks it historical and the flood tracker skips
      // it — the false-positive that dimmed legit senders to opacity 0.2.
      final tracker =
          FloodTracker.fromMessages(mapped(nowSec() - 60), selfPubkey: self);
      expect(tracker.isFlooding(sender), isFalse);
    });
  });
}
