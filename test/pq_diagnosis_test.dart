/// The diagnosis names the term that failed.
///
/// Four terms decide whether a conversation is post-quantum, and from outside
/// all four look the same: a shield reading "Not quantum-resistant". A report
/// of "it is not working" therefore cannot be told apart from any other, which
/// is how two separate causes were fixed without a third becoming visible.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/identity/pq_registry.dart';

String why({
  bool supported = true,
  bool modeOff = false,
  bool haveEntry = true,
  bool haveKey = true,
  bool acceptsLayered = true,
  int bitchatSeenAtSec = 0,
  int announcedAtSec = 1000,
  int? lookupAgeSec,
}) =>
    pqPeerDiagnosis(
      supported: supported,
      modeOff: modeOff,
      haveEntry: haveEntry,
      haveKey: haveKey,
      acceptsLayered: acceptsLayered,
      bitchatSeenAtSec: bitchatSeenAtSec,
      announcedAtSec: announcedAtSec,
      lookupAgeSec: lookupAgeSec,
    );

void main() {
  test('a healthy peer reports post-quantum', () {
    expect(why(), 'post-quantum');
  });

  test('never looked up says so', () {
    expect(why(haveEntry: false), contains('none has been looked up'));
  });

  test('a recent miss reports how long ago', () {
    expect(why(haveEntry: false, lookupAgeSec: 42), contains('42s ago'));
  });

  test('a keyless announcement is named as such', () {
    expect(why(haveKey: false), contains('no ML-KEM key'));
  });

  test('a legacy-only announcement is named as such', () {
    expect(why(acceptsLayered: false), contains('legacy format'));
  });

  test('newer Bitchat traffic is named as the reason', () {
    expect(why(bitchatSeenAtSec: 2000, announcedAtSec: 1000),
        contains('Bitchat-format message'));
  });

  test('older Bitchat traffic is not', () {
    expect(why(bitchatSeenAtSec: 500, announcedAtSec: 1000), 'post-quantum');
  });

  test('an unsupported build says so before anything else', () {
    expect(why(supported: false, haveEntry: false), contains('ML-KEM did not load'));
  });

  test('mode off outranks every peer-side term', () {
    expect(why(modeOff: true, haveKey: false), contains('mode is off'));
  });

  // The diagnosis must never disagree with the plan: every state the plan calls
  // classical has a reason, and every state it calls post-quantum has none. A
  // diagnosis that drifts from the code is worse than no diagnosis.
  test('the diagnosis never disagrees with the plan', () {
    for (final key in [true, false]) {
      for (final layered in [true, false]) {
        for (final bAt in [0, 500, 2000]) {
          final plan = PqPmPlan.decide(
            recipientKemKey: key ? Uint8List(1184) : null,
            recipientAcceptsLayered: layered,
            knownBitchat: bAt > 0,
            knownNym: false,
            bitchatSeenAtSec: bAt,
            announcedAtSec: 1000,
          );
          final d = why(
              haveKey: key,
              acceptsLayered: layered,
              bitchatSeenAtSec: bAt,
              announcedAtSec: 1000);
          expect(d == 'post-quantum', plan.pq,
              reason: 'key=$key layered=$layered bitchatAt=$bAt -> "$d"');
        }
      }
    }
  });
}
