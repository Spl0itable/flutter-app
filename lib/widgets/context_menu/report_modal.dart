import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';

/// `#reportModal` (index.html lines 361-405; ui-context.js `openReportModal` /
/// `submitReport`). Report a user/content: a type select + optional details +
/// a "report specific message" checkbox.
///
/// UI only — submitting builds the NIP-56 kind-1984 report the PWA does, but the
/// signing/relay path is owned by another slice, so [onSubmit] is invoked with
/// the form values and the actual publish is a labelled TODO for the caller.
class ReportModal extends StatefulWidget {
  const ReportModal({
    super.key,
    required this.targetNym,
    this.hasMessage = false,
    this.onSubmit,
  });

  /// The full `base#suffix` nym being reported (shown in the body).
  final String targetNym;

  /// Whether a specific message can be reported (enables the checkbox).
  final bool hasMessage;

  /// Called with (type, details, reportMessage) on Submit.
  final void Function(String type, String details, bool reportMessage)? onSubmit;

  /// Report types, in the PWA's `#reportType` option order.
  static const types = <(String, String)>[
    ('nudity', 'Nudity - depictions of nudity, porn, etc.'),
    ('malware', 'Malware - virus, trojan, spyware, etc.'),
    ('profanity', 'Profanity - hateful speech, etc.'),
    ('illegal', 'Illegal - content that may be illegal'),
    ('spam', 'Spam'),
    ('impersonation', 'Impersonation - pretending to be someone else'),
    ('other', 'Other'),
  ];

  static Future<void> show(
    BuildContext context, {
    required String targetNym,
    bool hasMessage = false,
    void Function(String type, String details, bool reportMessage)? onSubmit,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: const Color(0xB3000000),
      builder: (_) => ReportModal(
        targetNym: targetNym,
        hasMessage: hasMessage,
        onSubmit: onSubmit,
      ),
    );
  }

  @override
  State<ReportModal> createState() => _ReportModalState();
}

class _ReportModalState extends State<ReportModal> {
  String _type = ReportModal.types.first.$1;
  final _details = TextEditingController();
  late bool _reportMessage = widget.hasMessage;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500),
        width: MediaQuery.of(context).size.width * 0.9,
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: c.bgSecondary,
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rxl,
          // `.modal-content` shadow stack: shadow-lg + shadow-glow + 1px ring.
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 32,
              offset: const Offset(0, 8),
            ),
            BoxShadow(color: c.primaryA(0.1), blurRadius: 20),
            BoxShadow(color: Colors.white.withValues(alpha: 0.05), spreadRadius: 1),
          ],
        ),
        child: Stack(
          children: [
            SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // `.modal-header` — 22px primary UPPERCASE ls1.5 w700, 1px
                  // glass bottom rule, padding-bottom 14, margin-bottom 24.
                  Container(
                    margin: const EdgeInsets.only(bottom: 24),
                    padding: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: c.glassBorder)),
                    ),
                    child: Text('REPORT USER/CONTENT',
                        style: TextStyle(
                            color: c.primary,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.5)),
                  ),
                  // `.nm-h-6` "Reporting:" — text-dim, body-size, mb15. Nym span
                  // is `.nm-primary`.
                  Text.rich(TextSpan(children: [
                    TextSpan(
                        text: 'Reporting: ',
                        style: TextStyle(color: c.textDim, fontSize: 15)),
                    TextSpan(
                        text: widget.targetNym,
                        style: TextStyle(color: c.primary, fontSize: 15)),
                  ])),
                  const SizedBox(height: 15),
                  // `.nm-h-8` label — block, text-dim, body-size, mb10.
                  Text('Report Type:',
                      style: TextStyle(color: c.textDim, fontSize: 15)),
                  const SizedBox(height: 10),
                  // `.nm-h-9` select — padding 10, bg white/0.05, color --text,
                  // radius 12.
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      // `body.light-mode select` → black@0.04 fill / black@0.1
                      // border (white@0.05 / glass in dark).
                      color: c.insetFill,
                      border: Border.all(color: c.insetBorder),
                      borderRadius: NymRadius.rsm,
                    ),
                    child: DropdownButton<String>(
                      value: _type,
                      isExpanded: true,
                      underline: const SizedBox.shrink(),
                      dropdownColor: c.bgSecondary,
                      style: TextStyle(color: c.text, fontSize: 15),
                      items: [
                        for (final t in ReportModal.types)
                          DropdownMenuItem(value: t.$1, child: Text(t.$2)),
                      ],
                      onChanged: (v) => setState(() => _type = v ?? _type),
                    ),
                  ),
                  const SizedBox(height: 20), // `.nm-h-7` block margin-bottom
                  // `.nm-h-8` label with `.nm-h-2` lowercase "(optional)" + ":".
                  Text.rich(TextSpan(
                    text: 'Additional Details',
                    style: TextStyle(color: c.textDim, fontSize: 15),
                    children: const [
                      TextSpan(
                        text: ' (optional)',
                        style: TextStyle(
                            fontWeight: FontWeight.w400, letterSpacing: 0),
                      ),
                      TextSpan(text: ':'),
                    ],
                  )),
                  const SizedBox(height: 10),
                  // `.nm-h-10` textarea — padding 10, bg white/0.05, color
                  // --text, radius 12.
                  TextField(
                    controller: _details,
                    maxLines: 4,
                    style: TextStyle(color: c.text, fontSize: 15),
                    decoration: InputDecoration(
                      hintText:
                          'Provide any additional context for this report...',
                      hintStyle: TextStyle(color: c.textDim),
                      isDense: true,
                      contentPadding: const EdgeInsets.all(10),
                      filled: true,
                      // `body.light-mode textarea` → black@0.04 fill / black@0.1
                      // border (white@0.05 / glass in dark).
                      fillColor: c.insetFill,
                      border: OutlineInputBorder(
                        borderRadius: NymRadius.rsm,
                        borderSide: BorderSide(color: c.insetBorder),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: NymRadius.rsm,
                        borderSide: BorderSide(color: c.insetBorder),
                      ),
                    ),
                  ),
                  const SizedBox(height: 15), // `.nm-h-11` block margin-bottom
                  // `.nm-h-12` — whole label clickable, text-dim, body-size,
                  // checkbox margin-right 8 (`.nm-h-13`).
                  InkWell(
                    onTap: widget.hasMessage
                        ? () => setState(() => _reportMessage = !_reportMessage)
                        : null,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 22,
                          height: 22,
                          child: Checkbox(
                            value: _reportMessage,
                            onChanged: widget.hasMessage
                                ? (v) =>
                                    setState(() => _reportMessage = v ?? false)
                                : null,
                            activeColor: c.primary,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Report specific message (if unchecked, reports the user profile)',
                            style: TextStyle(color: c.textDim, fontSize: 15),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 15),
                  // `.modal-actions` — center, gap 10.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _cancelBtn(c),
                      const SizedBox(width: 10),
                      _submitBtn(c),
                    ],
                  ),
                ],
              ),
            ),
            // `.modal-close` — 32px circular glass chip at `top:14; right:14`
            // from the modal edge. The Stack sits inside the 32px content
            // padding, so offset -18 lands the chip 14px from the edge.
            Positioned(
              top: -18,
              right: -18,
              child: _closeButton(c),
            ),
          ],
        ),
      ),
    );
  }

  void _submit() {
    // TODO(verify): publish NIP-56 kind-1984 report. The PWA's submitReport
    // signs `{kind:1984, tags:[['p',pubkey,type], ['e',messageId,type]?],
    // content:details}` and sends it to relays; signing/relay is owned by
    // another slice, so we surface the form values via onSubmit instead.
    widget.onSubmit?.call(_type, _details.text, _reportMessage);
    Navigator.of(context).maybePop();
  }

  /// `.modal-close` — 32×32 circular glass chip with a 16px ✕ (text-dim).
  Widget _closeButton(NymColors c) {
    return InkWell(
      onTap: () => Navigator.of(context).maybePop(),
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // `.icon-btn` fill: white@0.05 dark → black@0.03 light
          // (`body.light-mode .icon-btn`), else invisible on a light modal.
          color: c.subtleFill,
          border: Border.all(color: c.glassBorder),
        ),
        // `.modal-close` is a literal "✕" char in the PWA — styled text.
        child: Text('✕',
            style: TextStyle(color: c.textDim, fontSize: 16, height: 1)),
      ),
    );
  }

  /// `.icon-btn` Cancel — bg white/0.05, glass border, radius 8, color --text,
  /// UPPERCASE 12px w500 ls0.8, padding 7/14.
  Widget _cancelBtn(NymColors c) {
    return InkWell(
      onTap: () => Navigator.of(context).maybePop(),
      borderRadius: NymRadius.rxs,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          // `.icon-btn` fill: white@0.05 dark → black@0.03 light
          // (`body.light-mode .icon-btn`).
          color: c.subtleFill,
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rxs,
        ),
        child: Text(
          'CANCEL',
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

  /// `.send-btn` Submit — translucent primary outline pill (bg primary/0.1,
  /// border primary/0.3, text primary, radius 12, h42, padding 22/10,
  /// UPPERCASE 12px w600 ls1.5).
  Widget _submitBtn(NymColors c) {
    return InkWell(
      onTap: _submit,
      borderRadius: NymRadius.rsm,
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.primaryA(0.1),
          border: Border.all(color: c.primaryA(0.3)),
          borderRadius: NymRadius.rsm,
        ),
        child: Text(
          'SUBMIT REPORT',
          style: TextStyle(
            color: c.primary,
            fontSize: 12,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
