// The tier ladder is duplicated in `functions/api/_iap.js` (nym-staging), which
// re-derives the tier server-side and refuses a receipt for a cheaper product
// than the item costs. These tests pin the table and the bucketing so a drift
// shows up here rather than as failed claims in production.
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/shop/iap/iap_tiers.dart';

void main() {
  group('ladder shape', () {
    test('is ordered by maxSats ascending', () {
      for (var i = 1; i < kIapTiers.length; i++) {
        expect(kIapTiers[i].maxSats, greaterThan(kIapTiers[i - 1].maxSats));
      }
    });

    test('product ids are unique and store-legal', () {
      final ids = kIapTiers.map((t) => t.productId).toSet();
      expect(ids.length, kIapTiers.length);
      // Play requires lowercase alphanumerics, underscores and periods, and a
      // leading letter or digit; Apple accepts the same shape.
      final legal = RegExp(r'^[a-z0-9][a-z0-9_.]*$');
      for (final id in ids) {
        expect(legal.hasMatch(id), isTrue, reason: id);
      }
    });

    test('matches the server ladder byte for byte', () {
      // Mirror of TIER_LADDER in functions/api/_iap.js.
      const server = [
        ('t1', 1000, 'nymchat.flair.t1'),
        ('t2', 2000, 'nymchat.flair.t2'),
        ('t3', 3500, 'nymchat.flair.t3'),
        ('t4', 5000, 'nymchat.flair.t4'),
        ('t5', 10000, 'nymchat.flair.t5'),
        ('t6', 25000, 'nymchat.flair.t6'),
        ('t7', 50000, 'nymchat.flair.t7'),
        ('t8', 100000, 'nymchat.flair.t8'),
        ('t9', 150000, 'nymchat.flair.t9'),
      ];
      expect(kIapTiers.length, server.length + 1, reason: 'plus the catch-all');
      for (var i = 0; i < server.length; i++) {
        expect(kIapTiers[i].id, server[i].$1);
        expect(kIapTiers[i].maxSats, server[i].$2);
        expect(kIapTiers[i].productId, server[i].$3);
      }
      expect(kIapTiers.last.productId, 'nymchat.flair.t10');
    });
  });

  group('bucketing', () {
    test('an item takes the first tier it fits in', () {
      expect(tierForSats(666).id, 't1');
      expect(tierForSats(1000).id, 't1', reason: 'maxSats is inclusive');
      expect(tierForSats(1001).id, 't2');
      expect(tierForSats(2000).id, 't2');
      expect(tierForSats(2001).id, 't3');
      expect(tierForSats(5000).id, 't4');
      expect(tierForSats(10000).id, 't5');
      expect(tierForSats(21420).id, 't6');
      expect(tierForSats(42069).id, 't7');
      expect(tierForSats(149999).id, 't9');
    });

    test('anything above the ladder lands on the catch-all', () {
      expect(tierForSats(500000).id, 't10');
      expect(tierForSats(1 << 40).id, 't10');
    });

    test('a free or nonsense price still resolves', () {
      expect(tierForSats(0).id, 't1');
      expect(tierForSats(-5).id, 't1');
    });

    test('every catalog price maps to a tier that covers it', () {
      // The real spread of the flair catalog (666 .. 149,999 sats).
      const catalogPrices = [
        666, 777, 900, 911, 1000, 1100, 1200, 1300, 1313, 1337, 1400, 1500,
        1600, 1666, 1800, 1900, 1984, 1995, 2048, 2100, 2222, 2300, 2424, 2500,
        2800, 3000, 3200, 3300, 3500, 4200, 4444, 5000, 6000, 8888, 10000,
        10101, 21420, 42069, 149999,
      ];
      for (final p in catalogPrices) {
        final tier = tierForSats(p);
        expect(p <= tier.maxSats, isTrue, reason: '$p -> ${tier.id}');
      }
    });
  });

  test('product id set covers every tier', () {
    expect(kIapProductIds.length, kIapTiers.length);
    for (final tier in kIapTiers) {
      expect(kIapProductIds, contains(tier.productId));
    }
  });
}
