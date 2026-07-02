import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../widgets/nym_icons.dart';

/// Shared form/control widgets that mirror the PWA's `.form-*` and
/// `.settings-section` styling (docs/specs/02 §5.10, §5.6). All controls take
/// their colors from `context.nym`.

/// A collapsible `.settings-section`. The header bar is full-bleed: a
/// `rgba(255,255,255,.04)` tinted bar, primary 12px/700 uppercase label with
/// letter-spacing 1.2, a primary chevron that rotates -90° when collapsed, and a
/// bottom glass-border divider. The section spans the full modal-body width (the
/// PWA's `.settings-section{margin:0 -32px}` cancels the modal padding); [bleed]
/// is the horizontal inset (32) applied to the header/body content so it lines up
/// with the rest of the modal.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.open,
    required this.onToggle,
    required this.children,
    this.bleed = 32,
  });

  final String title;
  final bool open;
  final VoidCallback onToggle;
  final List<Widget> children;
  final double bleed;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return DecoratedBox(
      // `.settings-section { border-bottom: 1px glass-border }`.
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            child: Container(
              // `.settings-section-header { background: rgba(255,255,255,.04);
              //   padding: 14px 32px }`.
              color: const Color(0x0AFFFFFF),
              padding: EdgeInsets.symmetric(vertical: 14, horizontal: bleed),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title.toUpperCase(),
                      style: TextStyle(
                        color: c.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    duration: NymMotion.transition,
                    curve: NymMotion.curve,
                    // chevron points down when open, -90° (right) when collapsed.
                    turns: open ? 0 : -0.25,
                    // `.settings-section-chevron` (index.html:1363) — the down
                    // chevron; the PWA rotates it -90° when collapsed.
                    child: NymSvgIcon(
                      NymIcons.chevronDown,
                      size: 18,
                      color: c.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (open)
            Padding(
              // `.settings-section-body { padding: 18px 32px 4px }`.
              padding: EdgeInsets.fromLTRB(bleed, 18, bleed, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
        ],
      ),
    );
  }
}

/// A `.form-group`: label + control + optional hint/warning.
class FormGroup extends StatelessWidget {
  const FormGroup({
    super.key,
    this.label,
    required this.child,
    this.hint,
    this.amberHint,
    this.warning,
    this.footer,
  });

  final String? label;
  final Widget child;
  final String? hint;

  /// A plain amber `.form-hint.nm-h-59` line (`color: var(--warning-color,
  /// #f0a030); margin-top: 4px`, no-inline.css:77) — un-boxed hint text, used
  /// by e.g. the hardcore-keypair warning (index.html hardcoreKeypairWarning).
  final String? amberHint;
  final String? warning;

  /// Optional trailing widget rendered after the hint(s), inside the group —
  /// e.g. the "Reset columns to defaults" button that follows the Chat View
  /// hint in the PWA markup (index.html `.nm-h-58`).
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (label != null) ...[
            // `.form-label`: 11px uppercase, letter-spacing 1.2, weight 600.
            Text(
              label!.toUpperCase(),
              style: TextStyle(
                color: c.textDim,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 8),
          ],
          child,
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(
              hint!,
              style: TextStyle(color: c.textDim, fontSize: 11, height: 1.4),
            ),
          ],
          if (amberHint != null) ...[
            const SizedBox(height: 4),
            // `.nm-h-59`: plain form-hint text in the amber warning color
            // (`var(--warning-color, #f0a030)` — the variable is undefined in
            // the PWA CSS, so the #f0a030 fallback always applies). No box.
            Text(
              amberHint!,
              style: const TextStyle(
                  color: Color(0xFFF0A030), fontSize: 11, height: 1.4),
            ),
          ],
          if (warning != null) ...[
            const SizedBox(height: 6),
            // `.form-warning`: danger-tinted box (not the amber warning color).
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: c.danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: c.danger.withValues(alpha: 0.4)),
              ),
              child: Text(
                warning!,
                style: TextStyle(color: c.danger, fontSize: 11, height: 1.4),
              ),
            ),
          ],
          if (footer != null) ...[
            const SizedBox(height: 12),
            footer!,
          ],
        ],
      ),
    );
  }
}

/// A `.form-select`: a styled dropdown over [items] (value, label). When
/// [disabled] is true the control is locked (the PWA's `select.disabled`): dimmed
/// and non-interactive, with an optional [tooltip] (the PWA's `title=`).
class FormSelect<T> extends StatelessWidget {
  const FormSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.disabled = false,
    this.tooltip,
  });

  final T value;
  final List<({T value, String label})> items;
  final ValueChanged<T> onChanged;
  final bool disabled;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final field = Opacity(
      // Disabled native selects render at reduced opacity.
      opacity: disabled ? 0.5 : 1.0,
      child: _field(c),
    );
    if (disabled && tooltip != null) {
      return Tooltip(message: tooltip!, child: field);
    }
    return field;
  }

  Widget _field(NymColors c) {
    return Container(
      // `.form-select { background: rgba(255,255,255,.05); padding: 11px 14px }`.
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: c.isLight
            ? c.bg
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          dropdownColor: c.bgTertiary,
          iconEnabledColor: c.textDim,
          // `.form-select { color: var(--text-bright); font-size: 15px }`.
          style: TextStyle(color: c.text, fontSize: 15),
          borderRadius: NymRadius.rsm,
          padding: const EdgeInsets.symmetric(vertical: 11),
          items: [
            for (final it in items)
              DropdownMenuItem<T>(
                value: it.value,
                child: Text(it.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          // `disabled` → null handler (Material renders it greyed + inert).
          onChanged: disabled
              ? null
              : (v) {
                  if (v != null) onChanged(v);
                },
          disabledHint: () {
            for (final it in items) {
              if (it.value == value) {
                return Text(it.label, overflow: TextOverflow.ellipsis);
              }
            }
            return null;
          }(),
        ),
      ),
    );
  }
}

/// A `.form-input` single-line text field.
class FormInput extends StatelessWidget {
  const FormInput({
    super.key,
    this.controller,
    this.hint,
    this.onSubmitted,
    this.onChanged,
    this.focusNode,
    this.onTap,
    this.prefix,
  });

  final TextEditingController? controller;
  final String? hint;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final VoidCallback? onTap;

  /// Optional leading in-field icon (the PWA's `.settings-search-icon`: a 16px
  /// glyph inset at the left with the input's text starting at 36px).
  final Widget? prefix;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      onTap: onTap,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      style: TextStyle(color: c.text, fontSize: 13),
      cursorColor: c.isLight ? Colors.black : Colors.white,
      decoration: InputDecoration(
        isDense: true,
        // `.settings-search .form-input { padding-left: 36px }` with the 16px
        // icon inset at the left (styles-components.css:148-157).
        prefixIcon: prefix == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(left: 12, right: 8),
                child: prefix,
              ),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 36, minHeight: 16),
        hintText: hint,
        hintStyle: TextStyle(color: c.textDim, fontSize: 13),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        filled: true,
        fillColor: c.bg.withValues(alpha: c.isLight ? 1 : 0.4),
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
          borderSide: BorderSide(color: c.primaryA(0.4)),
        ),
      ),
    );
  }
}

/// `.color-mode-group`: a segmented control. Container bg @0.04, radius sm,
/// padding 3px; buttons flex:1, radius xs; active = primary @15%.
class SegmentGroup<T> extends StatelessWidget {
  const SegmentGroup({
    super.key,
    required this.value,
    required this.segments,
    required this.onChanged,
  });

  final T value;
  final List<({T value, String label})> segments;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.text.withValues(alpha: 0.04),
        borderRadius: NymRadius.rsm,
      ),
      child: Row(
        children: [
          for (final s in segments)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(s.value),
                child: AnimatedContainer(
                  duration: NymMotion.transition,
                  curve: NymMotion.curve,
                  // `.color-mode-btn { padding: 8px 4px; border: 1px solid
                  //   transparent }`; `.active { border-color: primary@.2 }`.
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  decoration: BoxDecoration(
                    color: s.value == value
                        ? c.primaryA(0.15)
                        : Colors.transparent,
                    borderRadius: NymRadius.rxs,
                    border: Border.all(
                      color: s.value == value
                          ? c.primaryA(0.2)
                          : Colors.transparent,
                    ),
                  ),
                  child: Text(
                    s.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: s.value == value ? c.primary : c.textDim,
                      fontSize: 12,
                      fontWeight:
                          s.value == value ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A `.icon-btn`-style button used for inline actions (Add, Send, Reset…).
class NymOutlineButton extends StatelessWidget {
  const NymOutlineButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.danger = false,
    this.uppercase = true,
  });

  final String label;
  final VoidCallback onPressed;
  final bool danger;

  /// `.icon-btn` text is uppercase with letter-spacing; `.btn-small` (Reset)
  /// is not.
  final bool uppercase;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final accent = danger ? c.danger : c.text;
    return InkWell(
      onTap: onPressed,
      borderRadius: NymRadius.rxs,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          // `.icon-btn`: bg white@5%, 1px glass border, radius xs.
          color: danger
              ? accent.withValues(alpha: 0.08)
              : c.text.withValues(alpha: 0.05),
          borderRadius: NymRadius.rxs,
          border: Border.all(
            color: danger ? accent.withValues(alpha: 0.3) : c.glassBorder,
          ),
        ),
        child: Text(
          uppercase ? label.toUpperCase() : label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: accent,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: uppercase ? 0.8 : 0,
          ),
        ),
      ),
    );
  }
}
