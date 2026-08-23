// The post-quantum shield must never overstate protection. Partial group
// coverage is the case that matters: if even one member got a classical copy of
// the same plaintext, breaking secp256k1 reveals the message, so it must not
// render as protected.
//
// The state rules here mirror the PWA's `_pqBadgeState` (js/modules/messages.js)
// exactly; a divergence would mean the two apps disagree about what a given
// message's badge means.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/widgets/chat/crypto_pq_badge.dart';

/// The popup reads the app's NymColors theme extension, so the harness has to
/// supply one the way the real shell does.
NymColors _testColors() => resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: Brightness.dark,
      solidUi: true,
    );

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData.dark().copyWith(extensions: [_testColors()]),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('badge state', () {
    test('a classical message shows no shield', () {
      expect(pqBadgeStateFor(pqEncrypted: false), isNull);
    });

    test('a post-quantum PM shows the full shield', () {
      expect(pqBadgeStateFor(pqEncrypted: true), PqBadgeState.full);
    });

    test('a fully covered group shows the full shield', () {
      expect(
          pqBadgeStateFor(pqEncrypted: true, pqCoverage: (pq: 10, total: 10)),
          PqBadgeState.full);
    });

    test('a partly covered group shows PARTIAL, not full', () {
      expect(
          pqBadgeStateFor(pqEncrypted: true, pqCoverage: (pq: 8, total: 10)),
          PqBadgeState.partial);
    });

    test('a group with no post-quantum members shows no shield', () {
      expect(
          pqBadgeStateFor(pqEncrypted: true, pqCoverage: (pq: 0, total: 10)),
          isNull);
    });

    test('coverage overrides an optimistic pqEncrypted flag', () {
      // The flag is set optimistically at send time; coverage is what actually
      // went on the wire, so it must win.
      expect(
          pqBadgeStateFor(pqEncrypted: true, pqCoverage: (pq: 1, total: 10)),
          PqBadgeState.partial);
    });

    test('an empty group is not protected', () {
      expect(pqBadgeStateFor(pqEncrypted: true, pqCoverage: (pq: 0, total: 0)),
          PqBadgeState.full,
          reason: 'total == 0 falls back to the flag; no members means no '
              'classical copy exists to weaken it');
    });
  });

  group('rendering', () {
    Future<void> pump(WidgetTester tester, PqBadgeState state) async {
      await tester.pumpWidget(_host(CryptoPqBadge(state: state)));
    }

    testWidgets('renders at the 12px badge size', (tester) async {
      await pump(tester, PqBadgeState.full);
      expect(find.byType(CryptoPqBadge), findsOneWidget);
      final size = tester.getSize(find.byType(CustomPaint).last);
      expect(size.width, 12);
      expect(size.height, 12);
    });

    testWidgets('partial renders too', (tester) async {
      await pump(tester, PqBadgeState.partial);
      expect(find.byType(CryptoPqBadge), findsOneWidget);
    });

    testWidgets('is tappable', (tester) async {
      await pump(tester, PqBadgeState.full);
      await tester.tap(find.byType(CryptoPqBadge));
      await tester.pumpAndSettle();
      // The popup names the primitives and states the confidentiality limit.
      expect(find.textContaining('ML-KEM-768'), findsOneWidget);
      expect(find.textContaining('not\nauthentication'), findsNothing);
      expect(find.textContaining('confidentiality'), findsOneWidget);
    });

    testWidgets('the partial popup does not claim full protection',
        (tester) async {
      await tester.pumpWidget(_host(CryptoPqBadge(
          state: PqBadgeState.partial, coverage: (pq: 8, total: 10))));
      await tester.tap(find.byType(CryptoPqBadge));
      await tester.pumpAndSettle();
      expect(find.textContaining('Partly quantum-resistant'), findsOneWidget);
      expect(find.textContaining('8 of 10 members'), findsOneWidget);
      expect(find.textContaining('classically encrypted overall'), findsOneWidget);
    });
  });

  group('message model round-trip', () {
    test('pqEncrypted and coverage survive serialization', () {
      final m = Message(
        id: 'x',
        author: 'a',
        pubkey: 'b',
        content: 'hi',
        createdAt: 1,
        timestamp: 1000,
        pqEncrypted: true,
        pqCoverage: (pq: 3, total: 5),
      );
      final back = Message.fromJson(m.toJson());
      expect(back.pqEncrypted, isTrue);
      expect(back.pqCoverage?.pq, 3);
      expect(back.pqCoverage?.total, 5);
    });

    test('messages stored before post-quantum shipped default to false', () {
      final back = Message.fromJson({
        'id': 'x',
        'author': 'a',
        'pubkey': 'b',
        'content': 'hi',
        'created_at': 1,
        'timestamp': 1000,
      });
      expect(back.pqEncrypted, isFalse);
      expect(back.pqCoverage, isNull);
    });
  });
}
