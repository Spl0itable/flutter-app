import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';

/// Shared `.modal` chrome primitives — the exact CSS the PWA applies to every
/// standard modal (audit2/11 §"SHARED MODAL CHROME", lines 21-37). Used by the
/// identity modals so their buttons/headers/inputs/close-chip match the web 1:1.
///
/// References (default bitchat dark theme):
///  * `.modal-content`  — bg `--bg-secondary`, 1px glass, radius 24, padding 32,
///    shadow-lg + glow + `0 0 0 1px white/0.05`.
///  * `.modal-header`   — 22px `--primary`, UPPERCASE, ls1.5, w700, bottom rule.
///  * `.modal-close`    — 32×32 circular glass ✕ (top-right 14,14), danger hover.
///  * `.send-btn`       — translucent primary/0.1 fill, primary/0.3 border,
///    primary text, radius 12, h42, padding 10/22, 12px UPPERCASE ls1.5 w600.
///  * `.icon-btn`       — white/0.05 fill, glass border, radius 8, `--text`,
///    padding 7/14, 12px UPPERCASE ls0.8 w500.
///  * `.form-input`     — white/0.05 fill, glass border, radius 12, padding
///    11/14, font 15, `--text-bright`, focus glow `0 0 0 3px primary/0.06`.
///  * `.form-label`     — 11px textDim UPPERCASE ls1.2 w600, mb8.
class ModalChrome {
  ModalChrome._();

  /// The `.modal-content` outer card (no inner padding — callers add header /
  /// body / actions). [maxWidth] defaults to the shared 500.
  static Widget box(NymColors c, {required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: c.bgSecondary,
        borderRadius: NymRadius.rxl,
        border: Border.all(color: c.glassBorder),
        boxShadow: [
          // shadow-lg
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
          // shadow-glow (primary/0.1)
          BoxShadow(
            color: c.primary.withValues(alpha: 0.1),
            blurRadius: 20,
          ),
          // 0 0 0 1px white/0.05 ring
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.05),
            spreadRadius: 1,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  /// The `.modal-header`: 22px primary UPPERCASE ls1.5 w700 with a 1px glass
  /// bottom rule (padding-bottom 14, margin-bottom 24).
  static Widget header(NymColors c, String title) {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 14),
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: c.primary,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  /// The `.modal-close` — a 32×32 circular glass ✕ chip positioned at top-right
  /// (14,14), with a danger hover (web/desktop).
  static Widget closeChip(NymColors c, VoidCallback onTap) {
    return Positioned(
      top: 14,
      right: 14,
      child: _CloseChip(c: c, onTap: onTap),
    );
  }

  /// The `.send-btn` translucent primary pill. [danger] swaps to the
  /// `.send-btn.danger` palette (danger/0.1 fill, danger/0.35 border, danger
  /// text). [enabled] false → opacity 0.35.
  static Widget sendButton(
    NymColors c,
    String label,
    VoidCallback? onTap, {
    bool danger = false,
    bool fullWidth = false,
    Widget? child,
  }) {
    final fill = danger ? c.danger.withValues(alpha: 0.1) : c.primaryA(0.1);
    final border = danger ? c.danger.withValues(alpha: 0.35) : c.primaryA(0.3);
    final fg = danger ? c.danger : c.primary;
    final enabled = onTap != null;
    final btn = Opacity(
      opacity: enabled ? 1 : 0.35,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: NymRadius.rsm,
            border: Border.all(color: border),
          ),
          child: child ??
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.5,
                ),
              ),
        ),
      ),
    );
    return fullWidth ? SizedBox(width: double.infinity, child: btn) : btn;
  }

  /// The `.icon-btn`: bordered translucent uppercase pill.
  static Widget iconButton(NymColors c, String label, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: NymRadius.rxs,
          border: Border.all(color: c.glassBorder),
        ),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: c.text,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }

  /// The `.form-label`: 11px textDim UPPERCASE ls1.2 w600.
  static Widget formLabel(NymColors c, String text) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: c.textDim,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
      ),
    );
  }

  /// The `.form-input` decoration: white/0.05 fill, glass border, radius 12,
  /// padding 11/14, with the focus glow approximated by a thicker primary/0.3
  /// border on focus (Flutter has no multi-layer input shadow).
  static InputDecoration inputDecoration(NymColors c, String hint) {
    return InputDecoration(
      isDense: true,
      hintText: hint.isEmpty ? null : hint,
      hintStyle: TextStyle(color: c.textDim, fontSize: 15),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.05),
      border: OutlineInputBorder(
        borderRadius: NymRadius.rsm,
        borderSide: BorderSide(color: c.glassBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: NymRadius.rsm,
        borderSide: BorderSide(color: c.glassBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: NymRadius.rsm,
        borderSide: BorderSide(color: c.primaryA(0.3), width: 2),
      ),
    );
  }

  /// A plain centered "or" divider (`.nm-h-25`): 12px text-dim, margin 16 0, NO
  /// flanking rules.
  static Widget orDivider(NymColors c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text('or', style: TextStyle(color: c.textDim, fontSize: 12)),
      ),
    );
  }

  /// A tap recognizer that opens [path] (resolved against the live host) in the
  /// external browser, matching the ToS/Privacy `<a target="_blank">` links.
  static TapGestureRecognizer linkTap(String path) {
    return TapGestureRecognizer()
      ..onTap = () {
        final uri = Uri.parse('https://web.nymchat.app/$path');
        launchUrl(uri, mode: LaunchMode.externalApplication);
      };
  }
}

class _CloseChip extends StatefulWidget {
  const _CloseChip({required this.c, required this.onTap});
  final NymColors c;
  final VoidCallback onTap;

  @override
  State<_CloseChip> createState() => _CloseChipState();
}

class _CloseChipState extends State<_CloseChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _hover
                ? c.danger.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.05),
            border: Border.all(
              color: _hover
                  ? c.danger.withValues(alpha: 0.3)
                  : c.glassBorder,
            ),
          ),
          child: Text(
            '✕',
            style: TextStyle(
              color: _hover ? c.danger : c.textDim,
              fontSize: 16,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
