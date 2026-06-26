import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/shop/cosmetics.dart';
import 'package:nym_bar/features/shop/shop_controller.dart';
import 'package:nym_bar/features/shop/shop_models.dart';
import 'package:nym_bar/features/shop/shop_widgets.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/settings.dart';
import 'package:nym_bar/models/user.dart';
import 'package:nym_bar/services/api/storage_sync.dart' show ShopStatusActive;
import 'package:nym_bar/services/nostr/identity_service.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/app_state.dart';
import 'package:nym_bar/state/nostr_controller.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/widgets/chat/message_row.dart';

/// A controller whose identity is a fixed self pubkey, so `resolveCosmetics`
/// resolves the self branch deterministically.
class _IdentityController extends NostrController {
  _IdentityController(super.ref, this._selfPubkey);

  final String _selfPubkey;

  @override
  Identity? get identity =>
      Identity(pubkey: _selfPubkey, privkey: null, nym: 'me');
}

/// A shop controller seeded with a known active record (no persistence).
class _FakeShopController extends ShopController {
  _FakeShopController(super.kv, ActiveItems active) {
    state = ShopState(active: active);
  }
}

/// An other-users shop controller seeded with known D1 shop-status records (no
/// network), so `resolveCosmetics` resolves the non-self branch deterministically.
class _SeededOtherUsersShop extends OtherUsersShopController {
  _SeededOtherUsersShop(super.kv, Map<String, ShopStatusActive> seed) {
    state = seed;
  }
}

Message _msg({
  String pubkey = 'pkOther',
  String author = 'alice#abcd',
  bool isOwn = false,
}) {
  return Message(
    id: 'm1',
    author: author,
    pubkey: pubkey,
    content: 'hello world',
    createdAt: 1000,
    isOwn: isOwn,
    eventKind: 20000,
    geohash: 'u4pruyd',
  );
}

Future<ProviderContainer> _container(List<Override> overrides) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();
  final container = ProviderContainer(
    overrides: [
      keyValueStoreProvider.overrideWithValue(kv),
      ...overrides,
    ],
  );
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const selfPubkey = 'selfpk';

  group('resolveCosmetics', () {
    test('returns self active style/flair/supporter for the self pubkey',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final kv = await KeyValueStore.open();
      final container = await _container([
        nostrControllerProvider
            .overrideWith((ref) => _IdentityController(ref, selfPubkey)),
        shopControllerProvider.overrideWith(
          (ref) => _FakeShopController(
            kv,
            const ActiveItems(
              style: 'style-satoshi',
              flair: ['flair-crown'],
              supporter: true,
            ),
          ),
        ),
      ]);
      addTearDown(container.dispose);

      final cos = resolveCosmetics(_WidgetRefShim(container), selfPubkey);
      expect(cos.styleId, 'style-satoshi');
      expect(cos.flairId, 'flair-crown');
      expect(cos.supporter, isTrue);
    });

    test('returns others cosmetics from the User fields', () async {
      final container = await _container([
        nostrControllerProvider
            .overrideWith((ref) => _IdentityController(ref, selfPubkey)),
        usersProvider.overrideWithValue({
          'pkOther': User(
            pubkey: 'pkOther',
            nym: 'bob',
            shopStyle: 'style-neon',
            shopFlair: 'flair-diamond',
            isSupporter: true,
          ),
        }),
      ]);
      addTearDown(container.dispose);

      final cos = resolveCosmetics(_WidgetRefShim(container), 'pkOther');
      expect(cos.styleId, 'style-neon');
      expect(cos.flairId, 'flair-diamond');
      expect(cos.supporter, isTrue);
    });

    test('userCosmeticsFromUser is empty for a null/blank user', () {
      expect(userCosmeticsFromUser(null).isEmpty, isTrue);
      expect(
        userCosmeticsFromUser(User(pubkey: 'x')).isEmpty,
        isTrue,
      );
    });

    test('prefers the authoritative D1 shop-status over presence User fields',
        () async {
      const otherPk = 'pkother';
      final kv = await () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        return KeyValueStore.open();
      }();
      final container = ProviderContainer(overrides: [
        keyValueStoreProvider.overrideWithValue(kv),
        nostrControllerProvider
            .overrideWith((ref) => _IdentityController(ref, selfPubkey)),
        // Presence said neon/diamond, but the D1 record (authoritative) says
        // satoshi/crown — the D1 record must win (matches the PWA).
        usersProvider.overrideWithValue({
          otherPk: User(
            pubkey: otherPk,
            nym: 'bob',
            shopStyle: 'style-neon',
            shopFlair: 'flair-diamond',
          ),
        }),
        otherUsersShopProvider.overrideWith(
          (ref) => _SeededOtherUsersShop(kv, {
            otherPk: const ShopStatusActive(
              style: 'style-satoshi',
              flair: ['flair-crown'],
              supporter: true,
              cosmetics: ['cosmetic-frost'],
              editions: {'flair-genesis': 7},
            ),
          }),
        ),
      ]);
      addTearDown(container.dispose);

      final cos = resolveCosmetics(_WidgetRefShim(container), otherPk);
      expect(cos.styleId, 'style-satoshi', reason: 'D1 record wins');
      expect(cos.flairId, 'flair-crown');
      expect(cos.supporter, isTrue);
      expect(cos.cosmetics, ['cosmetic-frost']);
    });

    test('userCosmeticsFromStatus keeps the last flair + genesis edition', () {
      final cos = userCosmeticsFromStatus(const ShopStatusActive(
        flair: ['flair-crown', 'flair-genesis'],
        editions: {'flair-genesis': 42},
      ));
      expect(cos.flairId, 'flair-genesis');
      expect(cos.genesisEdition, 42);
    });
  });

  group('messageStyleDecoration', () {
    test('maps a known style id to a non-null decoration', () {
      final deco = messageStyleDecoration('style-satoshi');
      expect(deco, isNotNull);
      expect(deco!.textColor, const Color(0xFFF7931A));
      // satoshi paints a translucent content background.
      expect(deco.contentBackground, isNotNull);
    });

    test('maps aurora to a gradient decoration', () {
      final deco = messageStyleDecoration('style-aurora');
      expect(deco, isNotNull);
      expect(deco!.gradient, isNotNull);
      expect(deco.gradient!.length, greaterThanOrEqualTo(2));
    });

    test('returns null for unknown / none id', () {
      expect(messageStyleDecoration(null), isNull);
      expect(messageStyleDecoration(''), isNull);
      expect(messageStyleDecoration('style-does-not-exist'), isNull);
    });

    test('supporterStyleDecoration carries a gold accent + glow', () {
      expect(supporterStyleDecoration.textColor, const Color(0xFFFFD700));
      expect(supporterStyleDecoration.borderAccent, isNotNull);
      expect(supporterStyleDecoration.textShadows, isNotNull);
    });

    test('light mode swaps the bright dark colour for the PWA light tone + '
        'drops the glow', () {
      // style-neon: #FF00FF + glow (dark) → #990099, no glow (light).
      final dark = messageStyleDecoration('style-neon');
      final light = messageStyleDecoration('style-neon', isLight: true);
      expect(dark!.textColor, const Color(0xFFFF00FF));
      expect(dark.textShadows, isNotNull);
      expect(light!.textColor, const Color(0xFF990099));
      expect(light.textShadows, isNull, reason: 'light resets text-shadow');
    });

    test('aurora keeps a gradient in light mode (with the light stops)', () {
      final light = messageStyleDecoration('style-aurora', isLight: true);
      expect(light!.gradient, isNotNull);
      expect(light.gradient!.first, const Color(0xFF007766));
    });

    test('glitch keeps its chromatic split in light mode', () {
      final light = messageStyleDecoration('style-glitch', isLight: true);
      expect(light!.textColor, const Color(0xFF006600));
      // The red/cyan glyph offsets are not a glow, so light keeps them.
      expect(light.textShadows, isNotNull);
      expect(light.textShadows!.length, 2);
    });

    test('supporter light variant is darker gold with no glow', () {
      expect(supporterStyleDecorationLight.textColor, const Color(0xFF8A6D00));
      expect(supporterStyleDecorationLight.textShadows, isNull);
    });
  });

  group('MessageRow cosmetics rendering', () {
    final colors = resolveNymColors(
      theme: NymThemeKey.bitchat,
      brightness: Brightness.dark,
      solidUi: true,
    );

    Future<void> pump(WidgetTester tester, ProviderContainer container) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildNymThemeData(colors),
            home: Scaffold(
              body: MessageRow(
                message: _msg(),
                settings: const Settings(chatLayout: 'irc'),
                reactions: const [],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('renders the flair badge glyph for an author with flair',
        (tester) async {
      final container = await _container([
        nostrControllerProvider
            .overrideWith((ref) => _IdentityController(ref, selfPubkey)),
        usersProvider.overrideWithValue({
          'pkOther': User(
            pubkey: 'pkOther',
            nym: 'alice',
            shopFlair: 'flair-crown',
          ),
        }),
      ]);
      addTearDown(container.dispose);

      await pump(tester, container);

      // The flair badge widget is present (its SVG renders the crown glyph).
      expect(find.byType(MessageRow), findsOneWidget);
      final flair = tester
          .widgetList<FlairBadge>(find.byType(FlairBadge))
          .where((w) => w.flairId == 'flair-crown');
      expect(flair, isNotEmpty);
      // And it is wired through the cosmetics badge row.
      expect(
        find.byWidgetPredicate((w) =>
            w is CosmeticNymBadges && w.cosmetics.flairId == 'flair-crown'),
        findsOneWidget,
      );
    });

    testWidgets('renders the supporter badge for a supporter user',
        (tester) async {
      final container = await _container([
        nostrControllerProvider
            .overrideWith((ref) => _IdentityController(ref, selfPubkey)),
        usersProvider.overrideWithValue({
          'pkOther': User(
            pubkey: 'pkOther',
            nym: 'alice',
            isSupporter: true,
          ),
        }),
      ]);
      addTearDown(container.dispose);

      await pump(tester, container);

      // SupporterBadge renders the "SUPPORTER" pill text.
      expect(find.text('SUPPORTER'), findsOneWidget);
    });
  });

  // The flair glyph is a path-only inline `<svg>`, and CSS `text-shadow` does
  // not shadow replaced inline-SVG paths — only `filter: drop-shadow` does. So
  // the `.flair-X` `text-shadow` halo is INERT in the PWA (painted for no flair,
  // in either mode); the only glow rendered is the `filter: drop-shadow` on the
  // bright star/flame/diamond/genesis flairs, which the `body.light-mode` rules
  // do NOT reset, so it is present in BOTH modes. Each glow copy is an
  // `ImageFiltered` layer behind the crisp glyph, so the layer count is the
  // drop-shadow count (0 for text-shadow-only flairs, both modes).
  group('FlairBadge glow (light vs dark, styles-features.css)', () {
    Future<void> pumpFlair(
      WidgetTester tester,
      String flairId,
      Brightness brightness,
    ) async {
      final colors = resolveNymColors(
        theme: NymThemeKey.bitchat,
        brightness: brightness,
        solidUi: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildNymThemeData(colors),
          home: Scaffold(body: Center(child: FlairBadge(flairId: flairId))),
        ),
      );
      // `flutter_svg` rasterizes asynchronously; settle so the glyph copies for
      // the current theme are the only ones mounted (a bare `pump` can briefly
      // retain the previous pump's copies).
      await tester.pumpAndSettle();
    }

    // One `ShopSvgIcon` per glyph copy: the crisp icon plus one per glow copy.
    // So #glow copies == (#ShopSvgIcon - 1).
    int glowCopies(WidgetTester tester) =>
        tester.widgetList<ShopSvgIcon>(find.byType(ShopSvgIcon)).length - 1;

    testWidgets('crown (text-shadow only): no glow in either mode',
        (tester) async {
      // text-shadow is inert on a path SVG and crown has no drop-shadow, so the
      // crisp glyph paints with no halo in dark OR light.
      await pumpFlair(tester, 'flair-crown', Brightness.dark);
      expect(glowCopies(tester), 0);
      await pumpFlair(tester, 'flair-crown', Brightness.light);
      expect(glowCopies(tester), 0);
    });

    testWidgets('star (drop-shadow): drop-shadow renders in both modes',
        (tester) async {
      // Only the `filter: drop-shadow` glows the SVG; the inert text-shadow adds
      // nothing, and the drop-shadow survives `body.light-mode`.
      await pumpFlair(tester, 'flair-star', Brightness.dark);
      expect(glowCopies(tester), 1);
      await pumpFlair(tester, 'flair-star', Brightness.light);
      expect(glowCopies(tester), 1);
    });

    testWidgets('genesis (drop-shadow): drop-shadow renders in both modes',
        (tester) async {
      // The two genesis text-shadows are inert; only its single drop-shadow
      // glows, in both dark and light.
      await pumpFlair(tester, 'flair-genesis', Brightness.dark);
      expect(glowCopies(tester), 1);
      await pumpFlair(tester, 'flair-genesis', Brightness.light);
      expect(glowCopies(tester), 1);
    });
  });
}

/// Minimal [WidgetRef] shim wrapping a [ProviderContainer] so [resolveCosmetics]
/// (which only calls `ref.read`) can run outside a widget tree.
class _WidgetRefShim implements WidgetRef {
  _WidgetRefShim(this._container);
  final ProviderContainer _container;

  @override
  T read<T>(ProviderListenable<T> provider) => _container.read(provider);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
