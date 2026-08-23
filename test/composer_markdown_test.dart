// Tests the composer's live formatting: the markdown grammar in
// composer_markdown.dart and the way EmojiSentinelController paints it into the
// message field.
//
// The point of these tests is the caret coordinate system. The field renders
// `**bold**` as bold and hides the asterisks, so what is on screen no longer
// matches the draft — but every offset the rest of the composer hands the field
// (TextSelection, the toolbar's slice arithmetic, `expand` for the wire) still
// addresses the draft. That only holds because a hidden delimiter is painted at
// zero size rather than dropped: the characters stay in the span tree and keep
// their own offsets.
//
// So each case checks the same things: the parse tree covers the draft exactly,
// the painted spans are the same length as the draft, the delimiters actually
// disappear rather than being mis-sized, and a caret inside a run brings them
// back.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/widgets/chat/composer.dart';
import 'package:nym_bar/widgets/chat/composer_markdown.dart';

/// The drafts every structural invariant is checked against.
const List<(String, String)> _drafts = [
  ('plain', 'hello world'),
  ('bold', 'a **bold** b'),
  ('bold at both ends', '**b** and **c**'),
  ('italic', 'a *it* b'),
  ('strike', 'x ~~y~~ z'),
  ('inline code', 'run `flutter test` now'),
  ('nested', '**bold with *italic* inside**'),
  ('nested three deep', '**a ~~b *c* d~~ e**'),
  ('heading', '# Big title'),
  ('heading with bold', '## A **bold** title'),
  ('quote', '> quoted **text**'),
  ('multiline', '# Title\nbody **bold**\n> quote'),
  ('fence', '```\nlet x = 1;\n```'),
  ('fence with language', '```dart\nvar x = 1;\n```'),
  ('unterminated fence', '```dart\nvar x = 1;'),
  ('fence then text', '```\ncode\n```\nafter **that**'),
  ('adjacent markers', '**a**~~b~~'),
  ('empty lines', 'a\n\n**b**\n\nc'),
  ('trailing newline', '**bold**\n'),
  ('leading newline', '\n**bold**'),
  ('unmatched markers', '**a * b ~~ c'),
  ('underscore emphasis', 'an _emphasised_ word'),
  ('url in bold', '**see https://x.test/a.png**'),
  ('colon before star', 'time 3:00*x*'),
];

/// Walks [runs] and reports every way the tree fails to cover [text] exactly.
List<String> _coverageProblems(String text, List<RichRun> runs) {
  final problems = <String>[];
  void walk(List<RichRun> nodes, int from, int to) {
    var pos = from;
    for (final n in nodes) {
      if (n.start != pos) problems.add('gap/overlap at ${n.start}, expected $pos');
      if (!n.isText) {
        final innerStart = n.start + n.open.length;
        final innerEnd = n.end - n.close.length;
        if (innerEnd < innerStart) problems.add('negative body at ${n.start}');
        if (text.substring(n.start, innerStart) != n.open) {
          problems.add('open marker mismatch at ${n.start}');
        }
        if (text.substring(innerEnd, n.end) != n.close) {
          problems.add('close marker mismatch at ${n.end}');
        }
        walk(n.children, innerStart, innerEnd);
      }
      pos = n.end;
    }
    if (pos != to) problems.add('tail gap: ended at $pos, expected $to');
  }

  walk(runs, 0, text.length);
  return problems;
}

/// The types present in a tree, innermost last.
List<String> _types(List<RichRun> runs) {
  final out = <String>[];
  void walk(List<RichRun> nodes) {
    for (final n in nodes) {
      if (n.isText) continue;
      out.add(n.type);
      walk(n.children);
    }
  }

  walk(runs);
  return out;
}

/// Everything the user can see: the text of every span that is not painted at
/// the hidden delimiter's zero size.
String _visibleText(TextSpan root) {
  final buf = StringBuffer();
  void walk(InlineSpan span) {
    if (span is TextSpan) {
      final hidden = (span.style?.fontSize ?? 14) < 1;
      if (span.text != null && !hidden) buf.write(span.text);
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  walk(root);
  return buf.toString();
}

void main() {
  group('grammar', () {
    for (final (label, text) in _drafts) {
      test('$label: the tree covers the draft', () {
        expect(_coverageProblems(text, parseRichFormat(text)), isEmpty);
      });
    }

    test('each construct is recognised', () {
      expect(_types(parseRichFormat('**b**')), ['bold']);
      expect(_types(parseRichFormat('__b__')), ['bold']);
      expect(_types(parseRichFormat('*i*')), ['italic']);
      expect(_types(parseRichFormat('_i_')), ['italic']);
      expect(_types(parseRichFormat('~~s~~')), ['strike']);
      expect(_types(parseRichFormat('`c`')), ['code']);
      expect(_types(parseRichFormat('```\nc\n```')), ['codeblock']);
      expect(_types(parseRichFormat('# h')), ['h1']);
      expect(_types(parseRichFormat('## h')), ['h2']);
      expect(_types(parseRichFormat('### h')), ['h3']);
      expect(_types(parseRichFormat('> q')), ['quote']);
    });

    test('bold wins over italic at the same offset', () {
      expect(_types(parseRichFormat('**b** and *i*')), ['bold', 'italic']);
    });

    test('inline code takes no nested formatting', () {
      expect(_types(parseRichFormat('`**not bold**`')), ['code']);
    });

    test('nesting is preserved', () {
      expect(_types(parseRichFormat('**a *b* c**')), ['bold', 'italic']);
    });

    test('what the renderer leaves alone stays plain', () {
      for (final text in [
        'a * b',
        'a *  b',
        'https://x.test/a_b_c',
        'some_var_name here',
        'not # a heading',
        '#hashtag',
        '```',
        'ratio 3:4',
      ]) {
        expect(_types(parseRichFormat(text)), isEmpty, reason: text);
      }
    });

    test('a line prefix only counts at a line start', () {
      expect(_types(parseRichFormat('text\n# heading')), ['h1']);
      expect(_types(parseRichFormat('text # not a heading')), isEmpty);
    });

    test('an unterminated fence has no closing marker to hide', () {
      final fence = parseRichFormat('```\ncode').single;
      expect(fence.type, 'codeblock');
      expect(fence.open, '```');
      expect(fence.close, isEmpty);
    });

    test('an empty draft parses to nothing', () {
      expect(parseRichFormat(''), isEmpty);
      expect(hasRichFormat(parseRichFormat('plain text')), isFalse);
      expect(hasRichFormat(parseRichFormat('**bold**')), isTrue);
    });
  });

  group('reveal', () {
    test('an inline run reveals from anywhere inside it', () {
      // "a **bold** b" — the run spans [2, 10].
      final run = parseRichFormat('a **bold** b')[1];
      expect(run.type, 'bold');
      expect(run.revealedAt(0, 0), isFalse);
      expect(run.revealedAt(1, 1), isFalse);
      expect(run.revealedAt(2, 2), isTrue); // arriving at the run's edge
      expect(run.revealedAt(6, 6), isTrue);
      expect(run.revealedAt(10, 10), isTrue);
      expect(run.revealedAt(11, 11), isFalse);
    });

    test('a selection across a run reveals it', () {
      final run = parseRichFormat('a **bold** b')[1];
      expect(run.revealedAt(0, 12), isTrue);
    });

    test('a heading reveals only from its prefix', () {
      final run = parseRichFormat('# A long heading').single;
      expect(run.revealedAt(0, 0), isTrue);
      expect(run.revealedAt(2, 2), isTrue);
      // Typing in the body must not shift the line back and forth.
      expect(run.revealedAt(8, 8), isFalse);
    });

    test('a fence reveals only from its fence lines', () {
      final run = parseRichFormat('```\nlots of code here\n```').single;
      expect(run.revealedAt(1, 1), isTrue);
      expect(run.revealedAt(10, 10), isFalse);
      expect(run.revealedAt(24, 24), isTrue);
    });

    test('no caret means nothing is revealed', () {
      final run = parseRichFormat('**bold**').single;
      expect(run.revealedAt(-1, -1), isFalse);
    });
  });

  group('painting', () {
    late BuildContext ctx;
    late TextStyle style;

    Future<void> mount(WidgetTester tester) async {
      final colors = resolveNymColors(
        theme: NymThemeKey.bitchat,
        brightness: Brightness.dark,
        solidUi: true,
      );
      await tester.pumpWidget(MaterialApp(
        theme: buildNymThemeData(colors),
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ));
      style = const TextStyle(fontSize: 14);
    }

    TextSpan paint(String text, {TextSelection? selection, bool focused = true}) {
      final c = EmojiSentinelController(text: text);
      c.composerFocused = focused;
      if (selection != null) {
        c.value = c.value.copyWith(text: text, selection: selection);
      }
      return c.buildTextSpan(
          context: ctx, style: style, withComposing: false);
    }

    testWidgets('the painted spans are exactly as long as the draft',
        (tester) async {
      await mount(tester);
      for (final (label, text) in _drafts) {
        final span = paint(text, selection: const TextSelection.collapsed(offset: 0));
        expect(span.toPlainText().length, text.length, reason: label);
      }
    });

    testWidgets('...at every caret position, revealed or not', (tester) async {
      await mount(tester);
      for (final (label, text) in _drafts) {
        for (var i = 0; i <= text.length; i++) {
          final span =
              paint(text, selection: TextSelection.collapsed(offset: i));
          expect(span.toPlainText(), text, reason: '$label at $i');
        }
      }
    });

    testWidgets('the delimiters disappear, whole', (tester) async {
      await mount(tester);
      const cases = [
        ('**bold**', 'bold'),
        ('__bold__', 'bold'),
        ('*it*', 'it'),
        ('_it_', 'it'),
        ('~~gone~~', 'gone'),
        ('`x = 1`', 'x = 1'),
        ('```\nx = 1\n```', '\nx = 1\n'),
        ('```dart\nx\n```', 'dart\nx\n'),
        ('# Title', 'Title'),
        ('## Title', 'Title'),
        ('### Title', 'Title'),
        ('> quoted', 'quoted'),
        ('a **b** c *d* e', 'a b c d e'),
        ('**bold with *italic* inside**', 'bold with italic inside'),
        ('# A **bold** heading', 'A bold heading'),
        ('plain text', 'plain text'),
        ('a * b', 'a * b'),
        ('#hashtag', '#hashtag'),
      ];
      for (final (text, want) in cases) {
        // Caret parked away from every run so nothing is revealed.
        final span = paint(text, selection: const TextSelection.collapsed(offset: -1));
        expect(_visibleText(span), want, reason: text);
      }
    });

    testWidgets('a caret inside a run brings its delimiters back',
        (tester) async {
      await mount(tester);
      const text = 'a **bold** b';
      final away = paint(text, selection: const TextSelection.collapsed(offset: 0));
      expect(_visibleText(away), 'a bold b');
      final inside = paint(text, selection: const TextSelection.collapsed(offset: 6));
      expect(_visibleText(inside), text);
      // Revealing must not change what the field is holding.
      expect(inside.toPlainText(), text);
      expect(inside.toPlainText().length, away.toPlainText().length);
    });

    testWidgets('an unfocused field reveals nothing', (tester) async {
      await mount(tester);
      const text = '**bold**';
      final span = paint(text,
          selection: const TextSelection.collapsed(offset: 4), focused: false);
      expect(_visibleText(span), 'bold');
    });

    testWidgets('bold is painted bold and code is painted mono',
        (tester) async {
      await mount(tester);
      TextStyle? styleOf(TextSpan root, String text) {
        TextStyle? found;
        void walk(InlineSpan span) {
          if (span is TextSpan) {
            if (span.text == text) found ??= span.style;
            for (final child in span.children ?? const <InlineSpan>[]) {
              walk(child);
            }
          }
        }

        walk(root);
        return found;
      }

      expect(styleOf(paint('**b**'), 'b')?.fontWeight, FontWeight.w700);
      expect(styleOf(paint('*i*'), 'i')?.fontStyle, FontStyle.italic);
      expect(styleOf(paint('~~s~~'), 's')?.decoration,
          TextDecoration.lineThrough);
      expect(styleOf(paint('`c`'), 'c')?.fontFamily, kMonoFont);
      expect(styleOf(paint('# h'), 'h')?.fontWeight, FontWeight.w700);
      expect((styleOf(paint('# h'), 'h')?.fontSize ?? 0), greaterThan(14));
    });

    testWidgets('the draft still reaches the wire unchanged', (tester) async {
      await mount(tester);
      // The whole scheme is only safe if `text` is untouched by the painting.
      for (final (label, text) in _drafts) {
        final c = EmojiSentinelController(text: text);
        c.composerFocused = true;
        c.buildTextSpan(context: ctx, style: style, withComposing: false);
        expect(c.text, text, reason: label);
        expect(c.expand(c.text), text, reason: label);
      }
    });

    testWidgets('a custom emoji inside a formatted run still paints',
        (tester) async {
      await mount(tester);
      final c = EmojiSentinelController();
      c.codeToUrl = {'blob': 'https://x.test/blob.png'};
      c.value = const TextEditingValue(text: '**hi :blob:**');
      c.resolveInput();
      c.composerFocused = true;
      // The shortcode collapsed to one sentinel char, and the bold survived.
      expect(c.text, '**hi \u{E000}**');
      expect(c.expand(c.text), '**hi :blob:**');
      final span =
          c.buildTextSpan(context: ctx, style: style, withComposing: false);
      // A WidgetSpan is one character in the plain text, exactly like the
      // sentinel it replaced.
      expect(span.toPlainText().length, c.text.length);
      expect(_types(parseRichFormat(c.text)), ['bold']);
    });

    testWidgets('nothing is restyled while an IME is composing',
        (tester) async {
      await mount(tester);
      final c = EmojiSentinelController();
      c.composerFocused = true;
      c.value = const TextEditingValue(
        text: '**bold**',
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange(start: 2, end: 6),
      );
      final span =
          c.buildTextSpan(context: ctx, style: style, withComposing: true);
      // The framework's own span, delimiters and all — an IME has enough to
      // contend with without the field rewriting itself underneath it.
      expect(_visibleText(span), '**bold**');
    });
  });
}
