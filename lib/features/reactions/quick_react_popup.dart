import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';

/// The six default quick-react emojis (calls.js `_messageQuickReactDefaults`,
/// line 1491: `['👍', '❤️', '😂', '🔥', '👎', '😮']`). The PWA pads the user's
/// recent reactions up to six with these and drops duplicates.
const List<String> kQuickReactDefaults = ['👍', '❤️', '😂', '🔥', '👎', '😮'];

/// Builds the six-emoji quick-react row: recents first, padded with the
/// defaults, deduped, capped at six (mirrors calls.js lines 1488-1499).
List<String> quickReactEmojis(List<String> recents) {
  final out = <String>[];
  for (final e in recents) {
    if (out.length >= 6) break;
    if (!out.contains(e)) out.add(e);
  }
  for (final e in kQuickReactDefaults) {
    if (out.length >= 6) break;
    if (!out.contains(e)) out.add(e);
  }
  return out.take(6).toList();
}

/// One row in the long-press quick-context-menu (`.quick-context-item`,
/// ui-context.js:1358-1450): a leading 16px icon + label, optionally tinted
/// (lightning / danger). [onTap] runs the action after the popup closes.
class QuickContextItem {
  const QuickContextItem({
    required this.label,
    required this.icon,
    required this.onTap,
    this.color = QuickContextItemColor.normal,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final QuickContextItemColor color;
}

/// Colour variants for [QuickContextItem] (`.lightning` #f7931a, `.danger`).
enum QuickContextItemColor { normal, lightning, danger }

/// The inline quick-context-menu (`.quick-context-menu`, styles-features.css
/// :2778-2845): a vertical card (`min-width:200px`, radius 14, `rgba(20,20,35,
/// 0.92)`, 4px padding) of labeled icon rows, shown below the quick-react pill
/// on long-press. Built from a gated item list mirroring ui-context.js
/// :1358-1450 (Slap/Hug/Zap/Quote/Copy/Translate/Edit/Delete).
class QuickContextMenu extends StatelessWidget {
  const QuickContextMenu({super.key, required this.items});

  final List<QuickContextItem> items;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        constraints: const BoxConstraints(minWidth: 200),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xEB141423), // rgba(20,20,35,0.92)
          border: Border.all(color: c.glassBorder),
          borderRadius: const BorderRadius.all(Radius.circular(14)),
          boxShadow: const [
            BoxShadow(
                color: Color(0x66000000), blurRadius: 32, offset: Offset(0, 8)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final it in items) _QuickContextRow(item: it)],
        ),
      ),
    );
  }
}

class _QuickContextRow extends StatefulWidget {
  const _QuickContextRow({required this.item});
  final QuickContextItem item;

  @override
  State<_QuickContextRow> createState() => _QuickContextRowState();
}

class _QuickContextRowState extends State<_QuickContextRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final Color fg;
    final Color iconColor;
    switch (widget.item.color) {
      case QuickContextItemColor.lightning:
        fg = const Color(0xFFF7931A);
        iconColor = const Color(0xFFF7931A);
        break;
      case QuickContextItemColor.danger:
        fg = c.danger;
        iconColor = c.danger;
        break;
      case QuickContextItemColor.normal:
        fg = c.text;
        iconColor = c.textDim; // `.quick-context-item svg { color: text-dim }`
        break;
    }
    final hoverBg = widget.item.color == QuickContextItemColor.danger
        ? const Color(0x1FFF4444) // rgba(255,68,68,0.12)
        : Colors.white.withValues(alpha: 0.08);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.item.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _hover ? hoverBg : null,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: Row(
            children: [
              Icon(widget.item.icon, size: 16, color: iconColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.item.label,
                  style: TextStyle(color: fg, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The quick-react popup (`.quick-react-popup`, styles-features.css
/// :2712-2776): a pill of emoji buttons (28px) plus a "more" chevron with a
/// left divider (opens the full picker) and, for other users' messages, a
/// "menu" affordance (opens the context menu). Shown on long-press.
class QuickReactPopup extends StatelessWidget {
  const QuickReactPopup({
    super.key,
    required this.emojis,
    required this.onReact,
    required this.onMore,
    this.onMenu,
  });

  final List<String> emojis;
  final ValueChanged<String> onReact;
  final VoidCallback onMore;

  /// Opens the user/message context menu; null hides the affordance (own msg).
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xEB141423), // rgba(20,20,35,0.92)
          border: Border.all(color: c.glassBorder),
          borderRadius: const BorderRadius.all(Radius.circular(24)),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 32, offset: Offset(0, 8)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in emojis)
              _EmojiButton(emoji: e, onTap: () => onReact(e)),
            // `.quick-react-expand`: chevron with a 1px left divider.
            Container(
              margin: const EdgeInsets.only(left: 2),
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: Color(0x1AFFFFFF)), // rgba(255,255,255,0.1)
                ),
              ),
              child: _btn(
                child: Icon(Icons.keyboard_arrow_down, size: 18, color: c.textDim),
                onTap: onMore,
              ),
            ),
            if (onMenu != null)
              _btn(
                child: Icon(Icons.more_vert, size: 18, color: c.textDim),
                onTap: onMenu!,
              ),
          ],
        ),
      ),
    );
  }

  static Widget _btn({required Widget child, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: child,
      ),
    );
  }
}

/// A single 28px emoji button with hover-scale 1.3 / active-scale 0.95
/// (`.quick-react-emoji`, F13).
class _EmojiButton extends StatefulWidget {
  const _EmojiButton({required this.emoji, required this.onTap});
  final String emoji;
  final VoidCallback onTap;

  @override
  State<_EmojiButton> createState() => _EmojiButtonState();
}

class _EmojiButtonState extends State<_EmojiButton> {
  double _scale = 1;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _scale = 1.3),
      onExit: (_) => setState(() => _scale = 1),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _scale = 0.95),
        onTapCancel: () => setState(() => _scale = 1),
        onTap: () {
          setState(() => _scale = 1);
          widget.onTap();
        },
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Text(widget.emoji, style: const TextStyle(fontSize: 28, height: 1)),
          ),
        ),
      ),
    );
  }
}

/// Shows [QuickReactPopup] near [anchorRect] (global coords). The pressed
/// message is spotlit by dimming the rest of the screen (F9) and the popup
/// scales/rises in over 150ms (F13). When [contextItems] is non-empty an inline
/// [QuickContextMenu] is rendered just below the pill (F3, ui-context.js
/// :1452-1475); it is positioned below the pill, flipping above on overflow.
void showQuickReactPopup(
  BuildContext context, {
  required Rect anchorRect,
  required List<String> emojis,
  required ValueChanged<String> onReact,
  required VoidCallback onMore,
  VoidCallback? onMenu,
  List<QuickContextItem> contextItems = const [],
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late OverlayEntry entry;
  void close() {
    if (entry.mounted) entry.remove();
  }

  entry = OverlayEntry(
    builder: (ctx) => _QuickReactOverlay(
      anchorRect: anchorRect,
      emojis: emojis,
      onReact: (e) {
        close();
        onReact(e);
      },
      onMore: () {
        close();
        onMore();
      },
      onMenu: onMenu == null
          ? null
          : () {
              close();
              onMenu();
            },
      contextItems: contextItems
          .map((it) => QuickContextItem(
                label: it.label,
                icon: it.icon,
                color: it.color,
                onTap: () {
                  close();
                  it.onTap();
                },
              ))
          .toList(),
      onDismiss: close,
    ),
  );
  overlay.insert(entry);
}

/// The animated overlay body: an animated dim scrim (F9) + the pill + an
/// optional quick-context-menu, both entering with the PWA's scale/translate
/// transitions (F13). Positions the pill above/below the anchor and the menu
/// below the pill (flipping above on overflow).
class _QuickReactOverlay extends StatefulWidget {
  const _QuickReactOverlay({
    required this.anchorRect,
    required this.emojis,
    required this.onReact,
    required this.onMore,
    required this.onMenu,
    required this.contextItems,
    required this.onDismiss,
  });

  final Rect anchorRect;
  final List<String> emojis;
  final ValueChanged<String> onReact;
  final VoidCallback onMore;
  final VoidCallback? onMenu;
  final List<QuickContextItem> contextItems;
  final VoidCallback onDismiss;

  @override
  State<_QuickReactOverlay> createState() => _QuickReactOverlayState();
}

class _QuickReactOverlayState extends State<_QuickReactOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    )..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final r = widget.anchorRect;
    final spaceAbove = r.top;
    final preferAbove = spaceAbove > 80;
    final alignLeft = r.center.dx < size.width / 2;

    return Stack(
      children: [
        // Dim scrim (F9): fade all other content to ~0.35 over 150ms; tap to
        // dismiss (`.has-long-press-highlight`).
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
            child: FadeTransition(
              opacity: _c,
              child: Container(color: const Color(0x59000000)), // black 0.35
            ),
          ),
        ),
        // Pill + (optional) quick-context-menu, anchored above/below the press.
        Positioned(
          left: 10,
          right: 10,
          top: preferAbove ? null : r.bottom + 6,
          bottom: preferAbove ? (size.height - r.top + 6) : null,
          child: Align(
            alignment: alignLeft ? Alignment.centerLeft : Alignment.centerRight,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: alignLeft
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.end,
              children: [
                // Pill: scale 0.8 / +8px → 1, opacity 0→1 (F13).
                _Enter(
                  controller: _c,
                  beginScale: 0.8,
                  beginOffsetY: 8,
                  child: QuickReactPopup(
                    emojis: widget.emojis,
                    onReact: widget.onReact,
                    onMore: widget.onMore,
                    onMenu: widget.onMenu,
                  ),
                ),
                if (widget.contextItems.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  // Menu: scale 0.9 / -6px → 1, opacity 0→1 (F13).
                  _Enter(
                    controller: _c,
                    beginScale: 0.9,
                    beginOffsetY: -6,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: math.min(280, size.width - 20)),
                      child: QuickContextMenu(items: widget.contextItems),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Wraps [child] with the PWA's enter transition: a scale + vertical translate
/// driven by [controller] plus an opacity fade.
class _Enter extends StatelessWidget {
  const _Enter({
    required this.controller,
    required this.beginScale,
    required this.beginOffsetY,
    required this.child,
  });

  final AnimationController controller;
  final double beginScale;
  final double beginOffsetY;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: controller, curve: Curves.easeOut);
    return AnimatedBuilder(
      animation: curve,
      builder: (context, animatedChild) {
        final t = curve.value;
        final scale = beginScale + (1 - beginScale) * t;
        final dy = beginOffsetY * (1 - t);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, dy),
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topCenter,
              child: animatedChild,
            ),
          ),
        );
      },
      child: child,
    );
  }
}
