// The Pro model catalog is served live by the model-catalog worker, which
// mirrors Cloudflare's model docs into D1 hourly. These cover the parsing and
// resolution the client does on that payload — in particular that a model key
// a user pinned before a version bump still resolves, and that every failure
// path lands on the list compiled into the binary rather than an empty picker.
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/nymbot/nymbot_models.dart';

/// A worker `models` payload shaped like the real one.
Map<String, dynamic> _payload() => {
      'source': 'catalog',
      'models': [
        {
          'key': 'claude-fable-5-1',
          'label': 'Claude Fable 5.1',
          'model': 'anthropic/claude-fable-5.1',
          'credits': 2,
          'max': 16,
          'description': 'Anthropic\'s next model in the Fable family.',
          'author': 'Anthropic',
          'authorSlug': 'anthropic',
          'vision': true,
          'reasoning': true,
          'tools': true,
          'context': 1000000,
          'priced': true,
        },
        {
          'key': 'claude-opus-5',
          'label': 'Claude Opus 5',
          'model': 'anthropic/claude-opus-5',
          'credits': 1,
          'max': 8,
          'author': 'Anthropic',
          'authorSlug': 'anthropic',
          'priced': true,
        },
        {
          'key': 'gemini-3-6-flash',
          'label': 'Gemini 3.6 Flash',
          'model': 'google/gemini-3.6-flash',
          'credits': 1,
          'max': 3,
          'author': 'Google',
          'authorSlug': 'google',
          'priced': false,
        },
        {
          'key': 'deepseek-v4-pro-0813',
          'label': 'deepseek-v4-pro-0813',
          'model': '@cf/deepseek-ai/deepseek-v4-pro-0813',
          'credits': 1,
          'max': 3,
          'author': 'DeepSeek',
          'authorSlug': 'deepseek',
          'reasoning': true,
          'tools': true,
          'hosting': 'cloudflare-hosted',
          'priced': true,
        },
      ],
      'groups': [
        {
          'author': 'Anthropic',
          'authorSlug': 'anthropic',
          'keys': ['claude-fable-5-1', 'claude-opus-5'],
        },
        {
          'author': 'Google',
          'authorSlug': 'google',
          'keys': ['gemini-3-6-flash'],
        },
        {
          'author': 'DeepSeek',
          'authorSlug': 'deepseek',
          'keys': ['deepseek-v4-pro-0813'],
        },
      ],
      'aliases': {
        'claude-fable': 'claude-fable-5-1',
        'claude-opus': 'claude-opus-5',
        'gemini-flash': 'gemini-3-6-flash',
        // The third-party DeepSeek row is retired in the overrides table; its
        // replacedBy rides down to the client as an ordinary alias.
        'deepseek-v4-pro': 'deepseek-v4-pro-0813',
      },
    };

void main() {
  group('ProModelCatalog.fromJson', () {
    test('parses models, groups and aliases', () {
      final cat = ProModelCatalog.fromJson(_payload());
      expect(cat.models, hasLength(4));
      expect(cat.source, 'catalog');
      expect(cat.isEmpty, isFalse);

      final fable = cat.models.first;
      expect(fable.key, 'claude-fable-5-1');
      expect(fable.label, 'Claude Fable 5.1');
      expect(fable.modelId, 'anthropic/claude-fable-5.1');
      expect(fable.baseCredits, 2);
      expect(fable.max, 16);
      expect(fable.vision, isTrue);
      expect(fable.reasoning, isTrue);
      expect(fable.tools, isTrue);
      expect(fable.context, 1000000);
      expect(fable.description, isNotEmpty);
    });

    // Cloudflare-hosted models run on the worker's AI binding rather than
    // going out through the gateway, so the client has to be able to tell them
    // apart — the picker badges them, and DeepSeek is only reachable that way.
    test('a Cloudflare-hosted model is parsed and flagged as one', () {
      final cat = ProModelCatalog.fromJson(_payload());
      final ds = cat.byKey('deepseek-v4-pro-0813')!;
      expect(ds.hosting, 'cloudflare-hosted');
      expect(ds.cloudflareHosted, isTrue);
      expect(ds.modelId, startsWith('@cf/'));
      expect(cat.byKey('claude-opus-5')!.cloudflareHosted, isFalse);
    });

    test('a @cf/ id alone marks a model Cloudflare-hosted', () {
      // An older worker sends no hosting field; the id still settles it.
      final cat = ProModelCatalog.fromJson({
        'models': [
          {'key': 'x', 'label': 'X', 'model': '@cf/meta/llama', 'credits': 1},
        ],
      });
      expect(cat.byKey('x')!.hosting, isEmpty);
      expect(cat.byKey('x')!.cloudflareHosted, isTrue);
    });

    test('a pin on a retired third-party model follows its replacement', () {
      final cat = ProModelCatalog.fromJson(_payload());
      expect(cat.byKey('deepseek-v4-pro')!.modelId,
          '@cf/deepseek-ai/deepseek-v4-pro-0813');
    });

    test('a model Cloudflare prices only in its dashboard is flagged', () {
      final cat = ProModelCatalog.fromJson(_payload());
      expect(cat.byKey('gemini-3-6-flash')!.priced, isFalse);
      // Absent means "assume priced", so an older worker never greys the list.
      final older = ProModelCatalog.fromJson({
        'models': [
          {'key': 'x', 'label': 'X', 'credits': 1},
        ],
      });
      expect(older.byKey('x')!.priced, isTrue);
    });

    test('drops entries with no key and reports an empty payload', () {
      final cat = ProModelCatalog.fromJson({
        'models': [
          {'label': 'nameless'},
          {'key': 'ok', 'label': 'Ok', 'credits': 1},
        ],
      });
      expect(cat.models, hasLength(1));
      expect(ProModelCatalog.fromJson({'models': []}).isEmpty, isTrue);
      expect(ProModelCatalog.fromJson({}).isEmpty, isTrue);
    });

    test('survives a garbage payload instead of throwing', () {
      expect(ProModelCatalog.fromJson({'models': 'nope'}).isEmpty, isTrue);
      expect(
          ProModelCatalog.fromJson({
            'models': ['not a map', 42],
          }).isEmpty,
          isTrue);
    });

    test('round-trips through JSON, which is how it is cached', () {
      final cat = ProModelCatalog.fromJson(_payload());
      final again = ProModelCatalog.fromJson(cat.toJson());
      expect(again.models.map((m) => m.key), cat.models.map((m) => m.key));
      expect(again.aliases, cat.aliases);
      expect(again.grouped().map((g) => g.key),
          ['Anthropic', 'Google', 'DeepSeek']);
      expect(again.byKey('claude-opus')!.key, 'claude-opus-5');
    });
  });

  group('ProModelCatalog.byKey', () {
    final cat = ProModelCatalog.fromJson(_payload());

    test('resolves an exact key', () {
      expect(cat.byKey('claude-opus-5')!.label, 'Claude Opus 5');
    });

    test('resolves a key pinned before a version bump, via the alias map', () {
      expect(cat.byKey('claude-opus')!.key, 'claude-opus-5');
      expect(cat.byKey('claude-fable')!.key, 'claude-fable-5-1');
      expect(cat.byKey('gemini-flash')!.key, 'gemini-3-6-flash');
    });

    test('resolves a retired built-in alias through the live list', () {
      // kProModelAliases maps claude-opus-4.8 -> claude-opus, and the live
      // alias map carries claude-opus -> claude-opus-5.
      expect(cat.byKey('claude-opus-4.8')!.key, 'claude-opus-5');
    });

    test('resolves a full model id', () {
      expect(cat.byKey('anthropic/claude-fable-5.1')!.key, 'claude-fable-5-1');
    });

    test('is case- and whitespace-insensitive', () {
      expect(cat.byKey('  Claude-Opus  ')!.key, 'claude-opus-5');
    });

    test('returns null for an unknown key rather than guessing', () {
      expect(cat.byKey('no-such-model'), isNull);
      expect(cat.byKey(''), isNull);
    });
  });

  group('grouping', () {
    test('groups in the order the worker returned them', () {
      final grouped = ProModelCatalog.fromJson(_payload()).grouped();
      expect(grouped.map((g) => g.key), ['Anthropic', 'Google', 'DeepSeek']);
      expect(grouped.first.value.map((m) => m.key),
          ['claude-fable-5-1', 'claude-opus-5']);
    });

    test('a group naming a model that is gone drops just that row', () {
      final p = _payload();
      (p['groups'] as List)[1] = {
        'author': 'Google',
        'authorSlug': 'google',
        'keys': ['gemini-3-6-flash', 'vanished-model'],
      };
      final grouped = ProModelCatalog.fromJson(p).grouped();
      expect(grouped[1].value.map((m) => m.key), ['gemini-3-6-flash']);
    });

    test('a group left with nothing is omitted entirely', () {
      final p = _payload();
      (p['groups'] as List)[1] = {
        'author': 'Google',
        'authorSlug': 'google',
        'keys': ['vanished-model'],
      };
      expect(ProModelCatalog.fromJson(p).grouped().map((g) => g.key),
          ['Anthropic', 'DeepSeek']);
    });

    test('no groups means one unnamed group holding everything', () {
      final grouped = kProModelCatalogFallback.grouped();
      expect(grouped, hasLength(1));
      expect(grouped.single.key, '');
      expect(grouped.single.value, hasLength(kProModels.length));
    });
  });

  group('the built-in fallback', () {
    test('is the compiled-in list and resolves its own keys', () {
      expect(kProModelCatalogFallback.isEmpty, isFalse);
      expect(kProModelCatalogFallback.models, same(kProModels));
      expect(kProModelCatalogFallback.byKey('claude-opus')!.label,
          'Claude Opus 5');
      // Retired keys still resolve off the built-in alias table.
      expect(kProModelCatalogFallback.byKey('codex')!.key, 'gpt-5');
    });

    test('price labels are unchanged by the catalog work', () {
      final fable = kProModelCatalogFallback.byKey('claude-fable')!;
      expect(fable.baseCredits, 2);
      expect(fable.priceLabel,
          'from 2 Pro credits, up to 16 for max-length replies');
      final haiku = kProModelCatalogFallback.byKey('claude-haiku')!;
      expect(haiku.priceLabel, '1 Pro credit/reply');
    });
  });
}
