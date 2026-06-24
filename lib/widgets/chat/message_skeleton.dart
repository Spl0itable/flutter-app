import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';

/// Animated shimmer placeholder shown while a conversation loads its history,
/// a 1:1 port of the PWA `.msg-skeleton` (`messages.js:_buildMessageSkeleton`,
/// `styles-chat.css:1980-2043`).
///
/// The PWA builds N placeholder rows (`Math.max(8, ceil(vh / rowH) + 3)`, capped
/// at 50) using the real message/bubble classes so the layout matches the live
/// list exactly, then runs a single synchronized `@keyframes sk-shimmer`
/// (`1.4s ease-in-out infinite`) on every shape: a `linear-gradient(90deg,
/// transparent, var(--glass-border), transparent)` highlight that translates
/// from `translateX(-100%)` to `translateX(100%)`. Each shape's base fill is
/// `var(--bg-tertiary)` with `border-radius: 6px` (avatars 50%).
///
/// Here the moving highlight is implemented once as a [ShaderMask] sweeping a
/// `glassBorder`-cored gradient across the whole column (an [AnimationController]
/// driving the `-1 → 1` translate), so all placeholder shapes shimmer in lockstep
/// like the CSS. There are distinct bubble vs IRC variants matching the two chat
/// layouts ([MessageSkeleton.bubble] / [MessageSkeleton.irc]).
class MessageSkeleton extends StatefulWidget {
  const MessageSkeleton({super.key, required this.useBubbles, this.rowCount = 8});

  /// Bubble layout when true (`body.chat-bubbles`), IRC layout otherwise.
  final bool useBubbles;

  /// Number of placeholder rows to render. The PWA sizes this to the viewport;
  /// a fixed 8 (its floor) fills a typical pane and keeps the widget cheap.
  final int rowCount;

  @override
  State<MessageSkeleton> createState() => _MessageSkeletonState();
}

class _MessageSkeletonState extends State<MessageSkeleton>
    with SingleTickerProviderStateMixin {
  // `sk-shimmer 1.4s ease-in-out infinite`.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  late final Animation<double> _t = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // The moving highlight is `var(--glass-border)` flanked by transparent
    // (`linear-gradient(90deg, transparent, var(--glass-border), transparent)`).
    final highlight = c.glassBorder;

    // `.msg-skeleton { justify-content: flex-end }` — rows settle at the bottom,
    // newest-style at the foot, like the reversed live list.
    final rows = widget.useBubbles
        ? _bubbleRows(c)
        : _ircRows(c);

    final column = Column(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );

    // One ShaderMask over the whole column reproduces the synchronized
    // per-shape `::after` sweep: a narrow highlight band translating across.
    return ClipRect(
      child: AnimatedBuilder(
        animation: _t,
        builder: (context, child) {
          return ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (rect) {
              // Map t∈[0,1] to a band traveling left→right across [-1, 1] of the
              // width (matching translateX(-100%) → translateX(100%)).
              final dx = (_t.value * 2 - 1) * rect.width;
              return LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Colors.transparent,
                  highlight,
                  Colors.transparent,
                ],
                stops: const [0.35, 0.5, 0.65],
              ).createShader(
                Rect.fromLTWH(rect.left + dx, rect.top, rect.width, rect.height),
              );
            },
            child: child,
          );
        },
        child: column,
      ),
    );
  }

  // ---- IRC variant ----
  // Reuses the live IRC row metrics: leading author column (min 120 incl. the
  // 18px avatar + bracketed nym), a 50px time column, then content lines.
  // Bar widths/line patterns mirror the PWA `_ircSkeletonHtml` arrays
  // (`messages.js:2965-2981`): `ska-{1,2,3}` author widths, `skl-{1..4}` line
  // widths (as % of the content column), repeated over `rowCount`.
  List<Widget> _ircRows(NymColors c) {
    // [authorWidthClass, [lineWidthClasses…]] — verbatim from the PWA pattern.
    const pattern = <List<Object>>[
      [2, ['skl-3']],
      [1, ['skl-4', 'skl-2']],
      [3, ['skl-2']],
      [2, ['skl-3', 'skl-3', 'skl-1']],
      [1, ['skl-2']],
      [2, ['skl-4']],
      [3, ['skl-1']],
      [1, ['skl-3', 'skl-2']],
      [2, ['skl-2']],
      [2, ['skl-4', 'skl-3']],
      [1, ['skl-1']],
      [3, ['skl-3']],
      [2, ['skl-2', 'skl-1']],
      [1, ['skl-4']],
    ];
    return [
      for (var i = 0; i < widget.rowCount; i++)
        _ircRow(
          c,
          authorWidth: _skAuthorWidth(pattern[i % pattern.length][0] as int),
          lineFractions: [
            for (final cls in pattern[i % pattern.length][1] as List<String>)
              _sklFraction(cls),
          ],
        ),
    ];
  }

  Widget _ircRow(
    NymColors c, {
    required double authorWidth,
    required List<double> lineFractions,
  }) {
    // `.message` padding: 14/10 (matches MessageRow._buildIrc).
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // `.message-time` — `sk-time` is 34×10, in a 50px-min column.
          SizedBox(
            width: 50,
            child: _bar(c, width: 34, height: 10),
          ),
          const SizedBox(width: 10),
          // `.message-author` — `sk-author ska-N` (52/78/104 wide, 10 tall).
          SizedBox(
            width: 120,
            child: _bar(c, width: authorWidth, height: 10),
          ),
          const SizedBox(width: 10),
          // `.message-content` — one or more `sk-line skl-N` (height 9, 5px gap),
          // widths as a fraction of the remaining content column.
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var j = 0; j < lineFractions.length; j++)
                      Padding(
                        padding: EdgeInsets.only(top: j == 0 ? 0 : 5),
                        child: _bar(c, width: w * lineFractions[j], height: 9),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---- Bubble variant ----
  // Mirrors the PWA `_bubbleSkeletonHtml` (`messages.js:2985-3012`): grouped
  // bubbles alternating other/self, a 32px avatar for others' groups, each
  // bubble holding `skb-{1..4}` lines (110/160/210/260 wide) that step DOWN per
  // line (`base - j`), exactly like the real grouped bubble layout.
  List<Widget> _bubbleRows(NymColors c) {
    // {self, bubbles:[[baseWidthClass, lineCount], …]} — verbatim from the PWA.
    const pattern = <_BubbleGroup>[
      _BubbleGroup(false, [[3, 3], [1, 1]]),
      _BubbleGroup(true, [[2, 2]]),
      _BubbleGroup(false, [[1, 1]]),
      _BubbleGroup(true, [[1, 1], [3, 2], [1, 1]]),
      _BubbleGroup(false, [[4, 4]]),
      _BubbleGroup(true, [[2, 1]]),
      _BubbleGroup(false, [[3, 2], [1, 1]]),
      _BubbleGroup(true, [[3, 3]]),
      _BubbleGroup(false, [[2, 1]]),
    ];
    return [
      for (var i = 0; i < widget.rowCount; i++)
        _bubbleGroup(c, pattern[i % pattern.length]),
    ];
  }

  Widget _bubbleGroup(NymColors c, _BubbleGroup g) {
    final stack = <Widget>[];
    for (var idx = 0; idx < g.bubbles.length; idx++) {
      final base = g.bubbles[idx][0];
      final n = g.bubbles[idx][1];
      // Each bubble: one or more `skb-N` lines stepping down (`base - j`).
      final lines = <Widget>[
        for (var j = 0; j < n; j++)
          Padding(
            padding: EdgeInsets.only(top: j == 0 ? 0 : 5),
            child: _bar(
              c,
              width: _skbWidth((base - j).clamp(1, 4)),
              height: 9,
            ),
          ),
      ];
      stack.add(
        Padding(
          // Continuation bubbles sit ~2px below the previous (matches the live
          // `bubble-grouped` -4px margin reduced to a small positive gap).
          padding: EdgeInsets.only(top: idx == 0 ? 0 : 2),
          child: _bubbleBox(c, self: g.self, lines: lines),
        ),
      );
    }

    final stackColumn = Column(
      crossAxisAlignment:
          g.self ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: stack,
    );

    // `.message-group`: align-end row; others lead with a 32px avatar.
    final row = Row(
      mainAxisAlignment:
          g.self ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!g.self) ...[
          _avatar(c, 32),
          const SizedBox(width: 6),
        ],
        Flexible(child: stackColumn),
      ],
    );

    // Group padding mirrors MessageRow._buildBubble: self 14, others 6 left.
    return Padding(
      padding: EdgeInsets.fromLTRB(g.self ? 14 : 6, 6, 14, 0),
      child: row,
    );
  }

  Widget _bubbleBox(NymColors c, {required bool self, required List<Widget> lines}) {
    // The placeholder bubble uses the skeleton fill (`bg-tertiary`) rather than
    // the live bubble tint, rounded-16 with the tail corner like a real bubble.
    const r = Radius.circular(16);
    const tail = Radius.circular(4);
    final radius = self
        ? const BorderRadius.only(
            topLeft: r, topRight: tail, bottomLeft: r, bottomRight: r)
        : const BorderRadius.only(
            topLeft: tail, topRight: r, bottomLeft: r, bottomRight: r);
    return ConstrainedBox(
      // `.message-content { min-width: 180px }` (the skeleton CSS keeps min-width
      // via the real class; we cap a touch tighter so narrow panes don't clip).
      constraints: const BoxConstraints(minWidth: 140, maxWidth: 280),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: c.bgTertiary,
          borderRadius: radius,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: lines,
        ),
      ),
    );
  }

  // ---- shared shapes ----
  // Base placeholder fill: `var(--bg-tertiary)`, `border-radius: 6px`.
  Widget _bar(NymColors c, {required double width, required double height}) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: c.bgTertiary,
        borderRadius: const BorderRadius.all(Radius.circular(6)),
      ),
    );
  }

  // `.sk-avatar { border-radius: 50% }`.
  Widget _avatar(NymColors c, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.bgTertiary,
        shape: BoxShape.circle,
      ),
    );
  }

  // `ska-1/2/3` author bar widths (52 / 78 / 104).
  double _skAuthorWidth(int n) => const {1: 52.0, 2: 78.0, 3: 104.0}[n] ?? 78.0;

  // `skl-1/2/3/4` content-line widths as fractions (35% / 55% / 72% / 88%).
  double _sklFraction(String cls) =>
      const {'skl-1': 0.35, 'skl-2': 0.55, 'skl-3': 0.72, 'skl-4': 0.88}[cls] ??
      0.55;

  // `skb-1/2/3/4` bubble-line widths (110 / 160 / 210 / 260).
  double _skbWidth(int n) =>
      const {1: 110.0, 2: 160.0, 3: 210.0, 4: 260.0}[n] ?? 160.0;
}

/// One bubble-skeleton group: [self] side + a list of `[baseWidthClass, lines]`
/// bubbles (verbatim from the PWA `_bubbleSkeletonHtml` pattern).
class _BubbleGroup {
  const _BubbleGroup(this.self, this.bubbles);
  final bool self;
  final List<List<int>> bubbles;
}
