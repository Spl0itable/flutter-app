import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';

/// Shared confirm / alert / prompt dialog — the native port of the PWA's
/// `dialog.js` (`showAppConfirm` / `showAppAlert` / `showAppPrompt`), styled to
/// the `.app-dialog` component (`styles-components.css:2349-2388`):
///
///  * `max-width: 440px` content
///  * message `font-size: 14px; line-height: 1.45; white-space: pre-line`
///  * optional checkbox row, optional single-line input OR `min-height: 110px`
///    textarea, optional char counter (warning at 80%, limit at 100%)
///  * `danger` OK button (`bg rgb(danger/.1)`, `border rgb(danger/.35)`,
///    text `--danger`)
///  * Esc = cancel, Enter = confirm (single-line only)
///
/// Other modal slices can reuse these helpers for a consistent danger-confirm /
/// prompt-with-char-count / checkbox-confirm surface.

/// Shows a confirmation dialog. Resolves `true` on OK, `false` on Cancel/Esc.
///
/// When [checkboxLabel] is provided the result instead resolves to an
/// [AppConfirmResult] carrying `{confirmed, checked}` (mirrors the PWA's
/// checkbox-confirm shape). Use [showAppConfirmWithCheckbox] for that case so
/// the return type is precise.
Future<bool> showAppConfirm(
  BuildContext context,
  String message, {
  String? title,
  String okLabel = 'OK',
  String cancelLabel = 'Cancel',
  bool danger = false,
}) async {
  final res = await showDialog<AppDialogResult>(
    context: context,
    barrierColor: const Color(0xB3000000), // rgba(0,0,0,0.7) overlay
    builder: (_) => _AppDialog(
      message: message,
      title: title ?? 'Confirm',
      okLabel: okLabel,
      cancelLabel: cancelLabel,
      danger: danger,
    ),
  );
  return res?.confirmed ?? false;
}

/// Confirmation dialog with a checkbox row, resolving `{confirmed, checked}`
/// (the PWA's `showAppConfirm(msg, {checkboxLabel})`).
Future<AppConfirmResult> showAppConfirmWithCheckbox(
  BuildContext context,
  String message, {
  required String checkboxLabel,
  String? title,
  String okLabel = 'OK',
  String cancelLabel = 'Cancel',
  bool danger = false,
}) async {
  final res = await showDialog<AppDialogResult>(
    context: context,
    barrierColor: const Color(0xB3000000),
    builder: (_) => _AppDialog(
      message: message,
      title: title ?? 'Confirm',
      okLabel: okLabel,
      cancelLabel: cancelLabel,
      danger: danger,
      checkboxLabel: checkboxLabel,
    ),
  );
  return AppConfirmResult(
    confirmed: res?.confirmed ?? false,
    checked: res?.checked ?? false,
  );
}

/// Shows an alert with a single OK button (the PWA's `showAppAlert`).
Future<void> showAppAlert(
  BuildContext context,
  String message, {
  String? title,
  String okLabel = 'OK',
}) {
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0xB3000000),
    builder: (_) => _AppDialog(
      message: message,
      title: title ?? 'Notice',
      okLabel: okLabel,
      alertOnly: true,
    ),
  );
}

/// Shows a prompt with a text field. Resolves the entered string on OK, or
/// `null` on Cancel/Esc (the PWA's `showAppPrompt`). [multiline] swaps the
/// single-line input for a 110px-min textarea; [maxLength] adds a live char
/// counter.
Future<String?> showAppPrompt(
  BuildContext context,
  String message, {
  String? title,
  String okLabel = 'OK',
  String cancelLabel = 'Cancel',
  String defaultValue = '',
  String placeholder = '',
  int? maxLength,
  bool multiline = false,
}) async {
  final res = await showDialog<AppDialogResult>(
    context: context,
    barrierColor: const Color(0xB3000000),
    builder: (_) => _AppDialog(
      message: message,
      title: title ?? 'Confirm',
      okLabel: okLabel,
      cancelLabel: cancelLabel,
      isPrompt: true,
      defaultValue: defaultValue,
      placeholder: placeholder,
      maxLength: maxLength,
      multiline: multiline,
    ),
  );
  if (res == null || !res.confirmed) return null;
  return res.value ?? '';
}

/// The resolved shape of [showAppConfirmWithCheckbox].
class AppConfirmResult {
  const AppConfirmResult({required this.confirmed, required this.checked});
  final bool confirmed;
  final bool checked;
}

/// Internal pop payload (so a single dialog can resolve confirm/checkbox/prompt).
class AppDialogResult {
  const AppDialogResult({required this.confirmed, this.checked = false, this.value});
  final bool confirmed;
  final bool checked;
  final String? value;
}

class _AppDialog extends StatefulWidget {
  const _AppDialog({
    required this.message,
    required this.title,
    required this.okLabel,
    this.cancelLabel = 'Cancel',
    this.danger = false,
    this.alertOnly = false,
    this.isPrompt = false,
    this.checkboxLabel,
    this.defaultValue = '',
    this.placeholder = '',
    this.maxLength,
    this.multiline = false,
  });

  final String message;
  final String title;
  final String okLabel;
  final String cancelLabel;
  final bool danger;
  final bool alertOnly;
  final bool isPrompt;
  final String? checkboxLabel;
  final String defaultValue;
  final String placeholder;
  final int? maxLength;
  final bool multiline;

  @override
  State<_AppDialog> createState() => _AppDialogState();
}

class _AppDialogState extends State<_AppDialog> {
  late final TextEditingController _input =
      TextEditingController(text: widget.defaultValue);
  bool _checked = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _ok() {
    Navigator.of(context).pop(AppDialogResult(
      confirmed: true,
      checked: _checked,
      value: widget.isPrompt ? _input.text : null,
    ));
  }

  void _cancel() {
    Navigator.of(context).pop(AppDialogResult(
      confirmed: false,
      checked: _checked,
      value: null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          // `.app-dialog-content { max-width: 440px }`.
          constraints: const BoxConstraints(maxWidth: 440),
          child: Material(
            color: Colors.transparent,
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): _cancel,
                if (!widget.multiline)
                  const SingleActivator(LogicalKeyboardKey.enter): _ok,
                if (!widget.multiline)
                  const SingleActivator(LogicalKeyboardKey.numpadEnter): _ok,
              },
              child: Focus(
                autofocus: true,
                child: Container(
                  decoration: BoxDecoration(
                    color: c.bgSecondary,
                    borderRadius: NymRadius.rxl,
                    border: Border.all(color: c.glassBorder),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 40,
                        offset: const Offset(0, 20),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // `.modal-header`.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                        child: Text(
                          widget.title,
                          style: TextStyle(
                            color: c.text,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      // `.modal-body`.
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // `.app-dialog-message` — 14px / 1.45, pre-line.
                              Text(
                                widget.message,
                                style: TextStyle(
                                  color: c.text,
                                  fontSize: 14,
                                  height: 1.45,
                                ),
                              ),
                              if (widget.checkboxLabel != null)
                                _checkboxRow(c),
                              if (widget.isPrompt) _promptField(c),
                            ],
                          ),
                        ),
                      ),
                      // `.modal-actions`.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 12, 16, 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (!widget.alertOnly) ...[
                              TextButton(
                                onPressed: _cancel,
                                child: Text(widget.cancelLabel,
                                    style: TextStyle(color: c.textDim)),
                              ),
                              const SizedBox(width: 8),
                            ],
                            _okButton(c),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _checkboxRow(NymColors c) {
    // `.app-dialog-checkbox` — 12px top margin, 13px dim text, 8px gap.
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: InkWell(
        onTap: () => setState(() => _checked = !_checked),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: _checked,
                onChanged: (v) => setState(() => _checked = v ?? false),
                activeColor: c.primary,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(widget.checkboxLabel!,
                  style: TextStyle(color: c.textDim, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _promptField(NymColors c) {
    final max = widget.maxLength;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // `.app-dialog-input` / `.app-dialog-textarea` — 12px top margin.
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: widget.multiline ? 110 : 0),
            child: TextField(
              controller: _input,
              autofocus: true,
              maxLength: max,
              maxLines: widget.multiline ? null : 1,
              minLines: widget.multiline ? 4 : 1,
              expands: false,
              onChanged: (_) {
                if (max != null) setState(() {});
              },
              onSubmitted: widget.multiline ? null : (_) => _ok(),
              buildCounter: (_,
                      {required currentLength,
                      required isFocused,
                      maxLength}) =>
                  null,
              style: TextStyle(color: c.text, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                hintText: widget.placeholder.isEmpty ? null : widget.placeholder,
                hintStyle: TextStyle(color: c.textDim),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: NymRadius.rxs,
                  borderSide: BorderSide(color: c.glassBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: NymRadius.rxs,
                  borderSide: BorderSide(color: c.glassBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: NymRadius.rxs,
                  borderSide: BorderSide(color: c.primaryA(0.3)),
                ),
              ),
            ),
          ),
        ),
        if (max != null)
          // `.input-char-count` — warning at 80%, limit at 100%.
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${_input.text.length}/$max',
                style: TextStyle(
                  fontSize: 11,
                  color: _input.text.length >= max
                      ? c.danger
                      : (_input.text.length >= max * 0.8
                          ? c.warning
                          : c.textDim),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _okButton(NymColors c) {
    if (widget.danger) {
      // `.send-btn.danger` — bg danger/.1, border danger/.35, text danger.
      return OutlinedButton(
        onPressed: _ok,
        style: OutlinedButton.styleFrom(
          backgroundColor: c.danger.withValues(alpha: 0.1),
          foregroundColor: c.danger,
          side: BorderSide(color: c.danger.withValues(alpha: 0.35)),
          shape: RoundedRectangleBorder(borderRadius: NymRadius.rsm),
        ),
        child: Text(widget.okLabel),
      );
    }
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: c.primary,
        foregroundColor: c.bg,
      ),
      onPressed: _ok,
      child: Text(widget.okLabel),
    );
  }
}
