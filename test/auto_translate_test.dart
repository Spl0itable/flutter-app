import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/features/translate/auto_translate.dart';
import 'package:nym_bar/features/translate/translate_service.dart';
import 'package:nym_bar/models/message.dart';
import 'package:nym_bar/models/settings.dart';

/// A [TranslateService] that returns a canned result without touching the
/// network, so the notifier's caching / no-op logic can be exercised offline.
class _FakeTranslate extends TranslateService {
  _FakeTranslate(this.result, {this.calls}) : super();
  final TranslationResult result;
  final List<String>? calls;
  @override
  Future<TranslationResult> translate(String text, String target) async {
    calls?.add(text);
    return result;
  }
}

Message _msg({
  String id = 'm1',
  String content = 'hola',
  bool isOwn = false,
  bool isPM = false,
  bool isGroup = false,
  MessageKind kind = MessageKind.normal,
}) =>
    Message(
      id: id,
      author: 'a',
      pubkey: 'pk',
      content: content,
      createdAt: 1,
      isOwn: isOwn,
      isPM: isPM,
      isGroup: isGroup,
      kind: kind,
    );

void main() {
  group('autoTranslateAppliesTo', () {
    const off = Settings(autoTranslate: false);
    const on = Settings(autoTranslate: true);

    test('never applies when the master switch is off', () {
      expect(autoTranslateAppliesTo(_msg(), off), isFalse);
    });

    test('never applies to your own messages or system rows', () {
      expect(autoTranslateAppliesTo(_msg(isOwn: true), on), isFalse);
      expect(
        autoTranslateAppliesTo(_msg(kind: MessageKind.system), on),
        isFalse,
      );
    });

    test('public channel messages honour the channels gate', () {
      final ch = _msg(); // not PM, not group ⇒ public channel
      expect(autoTranslateAppliesTo(ch, on), isTrue);
      expect(
        autoTranslateAppliesTo(
            ch, const Settings(autoTranslate: true, autoTranslateChannels: false)),
        isFalse,
      );
    });

    test('PMs honour the PMs gate', () {
      final pm = _msg(isPM: true);
      expect(autoTranslateAppliesTo(pm, on), isTrue);
      expect(
        autoTranslateAppliesTo(
            pm, const Settings(autoTranslate: true, autoTranslatePMs: false)),
        isFalse,
      );
    });

    test('group chats honour the groups gate', () {
      final g = _msg(isGroup: true);
      expect(autoTranslateAppliesTo(g, on), isTrue);
      expect(
        autoTranslateAppliesTo(
            g, const Settings(autoTranslate: true, autoTranslateGroups: false)),
        isFalse,
      );
    });
  });

  group('AutoTranslateNotifier', () {
    test('does nothing without a target language', () {
      final n = AutoTranslateNotifier(
        service: _FakeTranslate(const TranslationResult(
            translatedText: 'hello', detectedLanguage: 'es')),
      );
      n.ensure(_msg(), '');
      expect(n.state, isEmpty);
    });

    test('translates and marks ready when the text differs', () async {
      final n = AutoTranslateNotifier(
        service: _FakeTranslate(const TranslationResult(
            translatedText: 'hello', detectedLanguage: 'es')),
      );
      n.ensure(_msg(content: 'hola'), 'en');
      // loading first
      expect(n.state['m1']!.status, AutoTranslateStatus.loading);
      await Future<void>.delayed(Duration.zero);
      final e = n.state['m1']!;
      expect(e.status, AutoTranslateStatus.ready);
      expect(e.translated, 'hello');
      expect(e.detected, 'es');
    });

    test('marks no-op when the message is already in the target language',
        () async {
      final n = AutoTranslateNotifier(
        // detected == target ⇒ nothing to translate.
        service: _FakeTranslate(const TranslationResult(
            translatedText: 'hello', detectedLanguage: 'en')),
      );
      n.ensure(_msg(content: 'hello'), 'en');
      await Future<void>.delayed(Duration.zero);
      expect(n.state['m1']!.status, AutoTranslateStatus.noop);
    });

    test('caches per (message, target): no duplicate proxy calls', () async {
      final calls = <String>[];
      final n = AutoTranslateNotifier(
        service: _FakeTranslate(
          const TranslationResult(
              translatedText: 'hello', detectedLanguage: 'es'),
          calls: calls,
        ),
      );
      final m = _msg(content: 'hola');
      n.ensure(m, 'en');
      await Future<void>.delayed(Duration.zero);
      n.ensure(m, 'en'); // same input again
      await Future<void>.delayed(Duration.zero);
      expect(calls.length, 1);
      expect(n.entryFor('m1', 'en', 'hola')?.isReady, isTrue);
      // Stale on a different target language.
      expect(n.entryFor('m1', 'fr', 'hola'), isNull);
    });
  });
}
