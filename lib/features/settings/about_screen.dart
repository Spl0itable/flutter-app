import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../identity/modal_chrome.dart';
import 'settings_widgets.dart';

/// Absolute base for the PWA's relative `static/*.html` legal pages. The PWA
/// serves them from its own origin; on native we point at the same files in the
/// public source repo so the links are real and tappable (gap report F14).
const String _kStaticBase = 'https://github.com/Spl0itable/NYM/blob/main/';

/// App version string shown in the About header (`#aboutVersion`). Matches the
/// current PWA constant `NYMCHAT_VERSION` (app.js:4229). The native build can
/// later override this from its own manifest; until then it tracks the PWA.
const String kAboutVersion = 'v3.72.517';

/// The About modal (`#aboutModal`, index.html:2118), presented as a centered
/// `.modal-content`. Layout mirrors the PWA: header (Nymchat + version), build
/// integrity + warrant-canary panels (honest static native state + verify
/// links), description, external links, divider, and the "Contact the
/// developer" form.
class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key, this.initialTopic, this.initialMessage});

  /// Pre-selected contact-form topic (must be one of the [FormSelect] options,
  /// e.g. `'Spam false positive'`). Null keeps the default 'General feedback'.
  final String? initialTopic;

  /// Pre-filled contact-form message body. Null leaves it empty.
  final String? initialMessage;

  static Future<void> open(
    BuildContext context, {
    String? initialTopic,
    String? initialMessage,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => AboutScreen(
        initialTopic: initialTopic,
        initialMessage: initialMessage,
      ),
    );
  }

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  final _messageController = TextEditingController();
  String _topic = 'General feedback';
  final List<TapGestureRecognizer> _recognizers = [];

  /// Contact-form status line (`#aboutContactStatus`). [_statusOk] picks the
  /// secondary (success) vs danger (error) color.
  String? _status;
  bool _statusOk = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // Pre-fill from `reportSpamFalsePositive(content)` (app.js:4399): topic
    // 'Spam false positive' + the flagged message in a code block.
    final topic = widget.initialTopic;
    if (topic != null && topic.isNotEmpty) _topic = topic;
    final msg = widget.initialMessage;
    if (msg != null && msg.isNotEmpty) _messageController.text = msg;
  }

  @override
  void dispose() {
    _messageController.dispose();
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Material(
            color: Colors.transparent,
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
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.9,
                ),
                child: Stack(
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _header(c),
                        Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildPanel(c),
                            const SizedBox(height: 10),
                            _canaryPanel(c),
                            _description(c),
                            _links(c),
                            const SizedBox(height: 20),
                            Container(height: 1, color: c.glassBorder),
                            const SizedBox(height: 20),
                            Text(
                              'Contact the developer',
                              style: TextStyle(
                                color: c.text,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Send feedback, a question, or a bug report. '
                              'Your message is delivered as an encrypted '
                              'private message to the Nymchat developer.',
                              style: TextStyle(
                                  color: c.textDim, fontSize: 11, height: 1.4),
                            ),
                            const SizedBox(height: 16),
                            FormGroup(
                              label: 'Topic',
                              child: FormSelect<String>(
                                value: _topic,
                                items: const [
                                  (
                                    value: 'General feedback',
                                    label: 'General feedback'
                                  ),
                                  (value: 'Bug report', label: 'Bug report'),
                                  (
                                    value: 'Feature request',
                                    label: 'Feature request'
                                  ),
                                  (value: 'Question', label: 'Question'),
                                  (
                                    value: 'Spam false positive',
                                    label: 'Spam false positive'
                                  ),
                                ],
                                onChanged: (v) => setState(() => _topic = v),
                              ),
                            ),
                            FormGroup(
                              label: 'Message',
                              child: _messageBox(c),
                            ),
                            // Contact status line (`#aboutContactStatus`, F12).
                            if (_status != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  _status!,
                                  style: TextStyle(
                                    color: _statusOk ? c.secondary : c.danger,
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                        _actions(c),
                      ],
                    ),
                    // `.modal-close`: 32×32 glass ✕ chip, absolute top-right
                    // (14,14) over the card — not inline in the title row.
                    ModalChrome.closeChip(
                        c, () => Navigator.of(context).maybePop()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(NymColors c) {
    // `.modal-header "Nymchat <ver>"`: a full-width title (name + version) with
    // a 1px glass bottom rule. The close ✕ is the separate absolute chip
    // (build); right padding (56) keeps the title clear of the floating chip.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(28, 24, 56, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 8,
        children: [
          Text(
            'NYMCHAT',
            style: TextStyle(
              color: c.primary,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(
              kAboutVersion,
              style: TextStyle(
                color: c.textDim,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// `.about-build` panel. The web bundle-attestation verification has no native
  /// analogue (the app ships as a signed store binary, not a hashed web bundle),
  /// so instead of a perpetual "—" we show an honest static state and link out
  /// to the source/provenance (F15). The title uses `--text-dim` like the PWA's
  /// `.about-build-title`.
  Widget _buildPanel(NymColors c) {
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.text.withValues(alpha: 0.04),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Build integrity',
                  style: TextStyle(color: c.textDim, fontSize: 13)),
              // Native ships as a signed store binary; verify via the repo.
              Text('Signed native build',
                  style: TextStyle(color: c.textDim, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              _link(c, 'source', 'https://github.com/Spl0itable/NYM'),
              _link(c, 'Build provenance',
                  'https://github.com/Spl0itable/NYM/actions'),
              _link(c, 'How to verify',
                  'https://github.com/Spl0itable/NYM#verify-build'),
            ],
          ),
        ],
      ),
    );
  }

  /// `.about-canary` warrant-canary panel. The live Nostr/BTC-anchor signature
  /// check is its own feature; here we show an honest static state and link to
  /// the published canary (F15). Title uses `--text-dim` like the PWA.
  Widget _canaryPanel(NymColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.text.withValues(alpha: 0.04),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Warrant canary',
                  style: TextStyle(color: c.textDim, fontSize: 13)),
              Text('Published on Nostr',
                  style: TextStyle(color: c.textDim, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 6),
          _link(c, 'canary',
              'https://github.com/Spl0itable/NYM/blob/main/canary.json'),
        ],
      ),
    );
  }

  Widget _description(NymColors c) {
    return Padding(
      padding: const EdgeInsets.only(top: 30, bottom: 16),
      child: Text.rich(
        TextSpan(
          children: [
            const TextSpan(
                text: 'A decentralized, pseudonymous chat built on the '),
            _linkSpan(c, 'Nostr', 'https://nostr.com'),
            const TextSpan(
                text: " protocol. Inspired by and bridged with Jack Dorsey's "),
            _linkSpan(c, 'Bitchat', 'https://bitchat.free'),
            const TextSpan(text: '.'),
          ],
        ),
        style: TextStyle(color: c.textDim, fontSize: 13, height: 1.6),
      ),
    );
  }

  Widget _links(NymColors c) {
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        _link(c, 'GitHub', 'https://github.com/Spl0itable/NYM'),
        _link(c, 'Terms of Service', 'static/tos.html'),
        _link(c, 'Privacy Policy', 'static/pp.html'),
        _link(c, 'DMCA', 'static/dmca.html'),
      ],
    );
  }

  Widget _messageBox(NymColors c) {
    return TextField(
      controller: _messageController,
      maxLines: 4,
      maxLength: 2000,
      style: TextStyle(color: c.text, fontSize: 13),
      cursorColor: c.isLight ? Colors.black : Colors.white,
      decoration: InputDecoration(
        hintText: 'Write your message...',
        hintStyle: TextStyle(color: c.textDim, fontSize: 13),
        contentPadding: const EdgeInsets.all(12),
        filled: true,
        fillColor: c.bg.withValues(alpha: c.isLight ? 1 : 0.4),
        counterStyle: TextStyle(color: c.textDim, fontSize: 10),
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

  Widget _actions(NymColors c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 20),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          NymOutlineButton(
            label: 'Close',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 10),
          // `.send-btn` style; disabled while sending → opacity .35 (PWA
          // `.send-btn:disabled`), height 42.
          Opacity(
            opacity: _sending ? 0.35 : 1.0,
            child: InkWell(
              onTap: _sending ? null : _sendContact,
              borderRadius: NymRadius.rsm,
              child: Container(
                height: 42,
                alignment: Alignment.center,
                padding:
                    const EdgeInsets.symmetric(horizontal: 22),
                decoration: BoxDecoration(
                  color: c.primaryA(0.10),
                  borderRadius: NymRadius.rsm,
                  border: Border.all(color: c.primaryA(0.30)),
                ),
                child: Text(
                  _sending ? 'SENDING...' : 'SEND MESSAGE',
                  style: TextStyle(
                    color: c.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _link(NymColors c, String text, String url) {
    return GestureDetector(
      onTap: () => _openLink(url),
      child: Text(
        text,
        style: TextStyle(
          color: c.secondary,
          fontSize: 12,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }

  TextSpan _linkSpan(NymColors c, String text, String url) {
    final recognizer = TapGestureRecognizer()..onTap = () => _openLink(url);
    _recognizers.add(recognizer);
    return TextSpan(
      text: text,
      style: TextStyle(color: c.secondary),
      recognizer: recognizer,
    );
  }

  /// Opens [url] externally (F14). Relative `static/*` legal pages are resolved
  /// against the source-repo base.
  Future<void> _openLink(String url) async {
    final abs = url.startsWith('http') ? url : '$_kStaticBase$url';
    final uri = Uri.tryParse(abs);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Best-effort; a missing browser/handler just no-ops.
    }
  }

  /// About → Send Message (F12; app.js:4406 `sendAboutContact`): validate a
  /// non-empty message + relay connection, then build the
  /// `[Nymchat contact — <topic>]` body and deliver it as an encrypted PM to the
  /// verified developer via the controller. Drives the button label
  /// ("Sending…") and the `#aboutContactStatus` line through sent/error states,
  /// clearing the field only on success.
  Future<void> _sendContact() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _status = 'Please enter a message.';
        _statusOk = false;
      });
      return;
    }
    // Relay connectivity (PWA `nym.connected`).
    final connected = ref.read(appStateProvider).connectedRelays > 0;
    if (!connected) {
      setState(() {
        _status = 'Not connected to relay. Try again once connected.';
        _statusOk = false;
      });
      return;
    }

    setState(() {
      _sending = true;
      _status = null;
    });

    // The body the PWA gift-wraps to the developer (`sendAboutContact`):
    //   `[Nymchat contact — <topic>]\n\n<message>`
    // sent as an encrypted PM to `NostrController.verifiedDeveloperPubkey`.
    final body = '[Nymchat contact — $_topic]\n\n$text';
    var ok = false;
    try {
      ok = await ref.read(nostrControllerProvider).sendContactMessage(body);
    } catch (_) {
      ok = false;
    }

    if (!mounted) return;
    setState(() {
      _sending = false;
      if (ok) {
        _status = 'Message sent. Thanks for reaching out!';
        _statusOk = true;
        _messageController.clear();
      } else {
        _status = 'Failed to send. Please try again.';
        _statusOk = false;
      }
    });
  }
}
