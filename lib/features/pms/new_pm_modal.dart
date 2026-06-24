import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/crypto/bech32_codec.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/common/nym_avatar.dart';

/// A picked recipient: pubkey (64-hex) + a display nym.
class PmRecipient {
  const PmRecipient(this.pubkey, this.nym);
  final String pubkey;
  final String nym;
}

/// Resolves a recipient token to a 64-hex pubkey: accepts a bare 64-hex pubkey,
/// an `npub1…`, or a `nym#suffix` matched against [users]. Returns null if it
/// can't be resolved. Mirrors the PWA's `onNewPMRecipientInput` /
/// `resolvePubkeyFromNym` paste handling (pms.js).
String? resolveRecipientPubkey(String input, Map<String, User> users) {
  final raw = input.trim().replaceFirst(RegExp(r'^@'), '');
  if (raw.isEmpty) return null;

  // Direct hex pubkey.
  if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(raw)) return raw.toLowerCase();

  // npub.
  if (RegExp(r'^npub1', caseSensitive: false).hasMatch(raw)) {
    try {
      return decodeNpub(raw.toLowerCase());
    } catch (_) {
      return null;
    }
  }

  // Nym match (case-insensitive, with or without #suffix).
  final query = raw.toLowerCase();
  for (final u in users.values) {
    if (u.nym.toLowerCase() == query) return u.pubkey;
    if (stripPubkeySuffix(u.nym).toLowerCase() == query) return u.pubkey;
  }
  return null;
}

/// `#newPMModal` — "New Message" / "New Group". A recipient picker (nym /
/// pubkey / npub) yields chips; one recipient → `startPM`, two or more →
/// `createGroup` (with an optional group name). Mirrors pms.js
/// `openNewPMModal` / `startNewPMFromModal`.
class NewPmModal extends ConsumerStatefulWidget {
  const NewPmModal({super.key});

  static Future<void> open(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => const NewPmModal(),
    );
  }

  @override
  ConsumerState<NewPmModal> createState() => _NewPmModalState();
}

class _NewPmModalState extends ConsumerState<NewPmModal> {
  final _recipientController = TextEditingController();
  final _recipientFocus = FocusNode();
  // A non-focusable key sentinel around the recipient input so Backspace on an
  // empty field can pop the last chip without stealing the field's own focus.
  final _recipientKeyFocus = FocusNode(skipTraversal: true, canRequestFocus: false);
  final _groupNameController = TextEditingController();
  final _groupDescController = TextEditingController();
  final _messageController = TextEditingController();
  final List<PmRecipient> _recipients = [];

  /// Group-creation extras (revealed for ≥2 recipients, index.html:319-347).
  String? _groupAvatarPath;
  String? _groupBannerPath;
  bool _allowInvites = true; // `newGroupAllowInvites` checked by default

  bool get _groupMode => _recipients.length >= 2;

  @override
  void initState() {
    super.initState();
    _recipientController.addListener(_onRecipientInput);
    _recipientFocus.addListener(
        () => setState(() => _recipientFocused = _recipientFocus.hasFocus));
  }

  @override
  void dispose() {
    _recipientController.dispose();
    _recipientFocus.dispose();
    _recipientKeyFocus.dispose();
    _groupNameController.dispose();
    _groupDescController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  void _onRecipientInput() => setState(() {}); // refresh suggestions live

  /// True while the recipient input has focus (drives the `.pm-recipient-box`
  /// `:focus-within` glow).
  bool _recipientFocused = false;

  /// Whether the current suggestion list is the empty-query "recently seen"
  /// list (which gets a header) vs. a live filter (pms.js `_showRecentlySeen`).
  bool get _isRecentlySeen => _recipientController.text.trim().isEmpty;

  /// Live recipient suggestions (`onNewPMRecipientInput` / pms.js
  /// `_showRecentlySeenSuggestions`): known users (minus self + already-picked)
  /// filtered by the typed nym, sorted by `lastSeen` desc, capped at 10. On
  /// empty input this becomes the "recently seen users" list.
  List<User> get _suggestions {
    final raw = _recipientController.text.trim().replaceFirst(RegExp(r'^@'), '');
    final query = raw.toLowerCase();
    final self = ref.read(appStateProvider).selfPubkey;
    final picked = _recipients.map((r) => r.pubkey).toSet();
    final out = <User>[];
    for (final u in ref.read(usersProvider).values) {
      if (u.pubkey == self || picked.contains(u.pubkey)) continue;
      if (query.isEmpty ||
          u.nym.toLowerCase().contains(query) ||
          stripPubkeySuffix(u.nym).toLowerCase().contains(query)) {
        out.add(u);
      }
    }
    out.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return out.take(10).toList();
  }

  void _addRecipient(String pubkey, String nym) {
    if (pubkey == ref.read(appStateProvider).selfPubkey) return;
    if (_recipients.any((r) => r.pubkey == pubkey)) {
      _recipientController.clear();
      return;
    }
    setState(() {
      _recipients.add(PmRecipient(pubkey, nym));
      _recipientController.clear();
    });
  }

  void _addFromInput() {
    final users = ref.read(usersProvider);
    final pk = resolveRecipientPubkey(_recipientController.text, users);
    if (pk == null) return;
    final nym = users[pk]?.nym ?? getNymFromPubkey('anon', pk);
    _addRecipient(pk, nym);
  }

  void _remove(String pubkey) {
    setState(() => _recipients.removeWhere((r) => r.pubkey == pubkey));
  }

  /// Backspace on an empty input removes the last chip (pms.js
  /// `onNewPMRecipientKeydown`).
  void _removeLast() {
    if (_recipientController.text.isNotEmpty || _recipients.isEmpty) return;
    setState(() => _recipients.removeLast());
  }

  Future<void> _pickGroupImage(bool avatar) async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(source: ImageSource.gallery);
      if (file == null || !mounted) return;
      setState(() {
        if (avatar) {
          _groupAvatarPath = file.path;
        } else {
          _groupBannerPath = file.path;
        }
      });
    } catch (_) {
      // Picker unavailable (tests / desktop) — ignore.
    }
  }

  Future<void> _start() async {
    if (_recipients.isEmpty) return;
    final controller = ref.read(nostrControllerProvider);
    if (_recipients.length == 1) {
      final r = _recipients.first;
      controller.startPM(r.pubkey, nym: r.nym);
    } else {
      final name = _groupNameController.text.trim().isNotEmpty
          ? _groupNameController.text.trim()
          : _recipients.map((r) => stripPubkeySuffix(r.nym)).take(3).join(', ');
      final description = _groupDescController.text.trim();
      // Thread the group-creation extras the modal collected into createGroup
      // (groups.js `createGroup(name, members, { avatar, banner, description,
      // allowMemberInvites })`). The avatar/banner here are the picked local
      // file paths; an upload-to-URL step is a separate concern (the PWA uploads
      // before passing a URL — see CROSS-FILE NEEDS), so we forward what's
      // collected and let empty stay null.
      await controller.createGroup(
        name,
        _recipients.map((r) => r.pubkey).toList(),
        avatar: _groupAvatarPath,
        banner: _groupBannerPath,
        description: description.isNotEmpty ? description : null,
        allowMemberInvites: _allowInvites,
      );
    }
    // Send the optional initial message into the just-opened conversation
    // (`pmInitialMessage` → first DM/group send, index.html:348-351). After
    // startPM/createGroup the active view IS the new conversation.
    final initial = _messageController.text.trim();
    if (initial.isNotEmpty) {
      await controller.sendCurrent(initial);
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final title = _groupMode ? 'New Group' : 'New Message';

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        // `.modal-content` — max-width 440 (`.pm-modal-content` is not set; the
        // PWA modal-content defaults apply, narrowed to 440 by the brief).
        constraints: const BoxConstraints(maxWidth: 440),
        child: Container(
          decoration: BoxDecoration(
            color: c.bgSecondary,
            border: Border.all(color: c.glassBorder),
            // radius 24 + shadow-lg/glow/ring stack.
            borderRadius: NymRadius.rxl,
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
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // `.modal-header` — 22px primary UPPERCASE ls1.5 w700, bottom
                  // rule, padding-bottom 14, margin-bottom 24. (32px padding.)
                  Container(
                    margin: const EdgeInsets.fromLTRB(32, 32, 32, 24),
                    padding: const EdgeInsets.only(bottom: 14),
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
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(32, 0, 32, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _label(c, 'To'),
                          const SizedBox(height: 8),
                          // `.pm-recipient-box` — chips + inline input in one box.
                          _recipientBox(c),
                          _suggestionsList(c),
                      if (_groupMode) ...[
                        const SizedBox(height: 16),
                        _label(c, 'Group Name', optional: true),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _groupNameController,
                          maxLength: 40,
                          onChanged: (_) => setState(() {}),
                          style: TextStyle(color: c.textBright, fontSize: 15),
                          decoration: _inputDecoration(
                            c,
                            'Enter a group name...',
                          ).copyWith(counterText: ''),
                        ),
                        // `pmGroupNameCharCount 0/40` (index.html:317).
                        _charCount(c, _groupNameController.text.length, 40),
                        const SizedBox(height: 16),
                        _groupMediaSection(c),
                        const SizedBox(height: 16),
                        _label(c, 'Description', optional: true),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _groupDescController,
                          maxLength: 150,
                          maxLines: 3,
                          onChanged: (_) => setState(() {}),
                          style: TextStyle(color: c.textBright, fontSize: 15),
                          decoration: _inputDecoration(
                            c,
                            "What's this group about?",
                          ).copyWith(counterText: ''),
                        ),
                        // `newGroupDescCharCount 0/150` (index.html:339).
                        _charCount(c, _groupDescController.text.length, 150),
                        const SizedBox(height: 12),
                        _allowInvitesRow(c),
                      ],
                      // `pmInitialMessage` — "Message (optional)" (index.html:348).
                      const SizedBox(height: 16),
                      _label(c, 'Message', optional: true),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _messageController,
                        maxLines: 3,
                        style: TextStyle(color: c.textBright, fontSize: 15),
                        decoration:
                            _inputDecoration(c, 'Start the conversation...'),
                      ),
                        ],
                      ),
                    ),
                  ),
                  // `.modal-actions` — center, gap 10.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _cancelBtn(c),
                        const SizedBox(width: 10),
                        _startBtn(c),
                      ],
                    ),
                  ),
                ],
              ),
              // `.modal-close` — 32px circular glass chip at top:14/right:14.
              Positioned(top: 14, right: 14, child: _closeButton(c)),
            ],
          ),
        ),
      ),
    );
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
          color: Colors.white.withValues(alpha: 0.05),
          border: Border.all(color: c.glassBorder),
        ),
        child: Icon(Icons.close, size: 16, color: c.textDim),
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
          color: Colors.white.withValues(alpha: 0.05),
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

  /// `.send-btn` Start/Create — translucent primary outline pill (bg
  /// primary/0.1, border primary/0.3, text primary, radius 12, h42, padding
  /// 22/10, UPPERCASE 12px w600 ls1.5; disabled opacity 0.35).
  Widget _startBtn(NymColors c) {
    final enabled = _recipients.isNotEmpty;
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: InkWell(
        onTap: enabled ? _start : null,
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
            (_groupMode ? 'Create' : 'Start').toUpperCase(),
            style: TextStyle(
              color: c.primary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.5,
            ),
          ),
        ),
      ),
    );
  }

  /// `.form-label` — 11px UPPERCASE ls1.2 w600 text-dim, with an optional
  /// trailing `.nm-h-2` "(optional)" span (lowercase, w400, ls0). Pass the
  /// label text WITHOUT "(optional)"; set [optional] to append the span.
  Widget _label(NymColors c, String text, {bool optional = false}) => Text.rich(
        TextSpan(
          text: text.toUpperCase(),
          style: TextStyle(
            color: c.textDim,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
          children: optional
              ? const [
                  TextSpan(
                    text: ' (optional)',
                    style: TextStyle(
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0,
                    ),
                  ),
                ]
              : null,
        ),
      );

  /// The unified `.pm-recipient-box`: chips wrap inline with a borderless input
  /// inside one bordered box, with the `:focus-within` glow.
  Widget _recipientBox(NymColors c) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: NymRadius.rsm,
        boxShadow: _recipientFocused
            ? [BoxShadow(color: c.primaryA(0.06), spreadRadius: 3)]
            : null,
      ),
      child: Container(
        constraints: const BoxConstraints(minHeight: 42),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: _recipientFocused ? 0.07 : 0.05),
          border: Border.all(
            color: _recipientFocused ? c.primaryA(0.3) : c.glassBorder,
          ),
          borderRadius: NymRadius.rsm,
        ),
        child: Wrap(
          spacing: 5,
          runSpacing: 5,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final r in _recipients)
              _Chip(
                base: stripPubkeySuffix(r.nym),
                suffix: getPubkeySuffix(r.pubkey),
                onRemove: () => _remove(r.pubkey),
              ),
            // Borderless inline input (`.pm-recipient-input`): 13px, --text.
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 120, maxWidth: 280),
              child: IntrinsicWidth(
                child: Focus(
                  focusNode: _recipientKeyFocus,
                  onKeyEvent: (_, e) {
                    if (e is KeyDownEvent &&
                        e.logicalKey == LogicalKeyboardKey.backspace) {
                      _removeLast();
                    }
                    // Never consume — let the TextField handle the key itself.
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    controller: _recipientController,
                    focusNode: _recipientFocus,
                    autofocus: true, // PWA focuses pmRecipientInput on open
                    onSubmitted: (_) => _addFromInput(),
                    style: TextStyle(color: c.text, fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: _recipients.isEmpty
                          ? 'Search nym or paste pubkey...'
                          : null,
                      hintStyle: TextStyle(color: c.textDim, fontSize: 13),
                      contentPadding: const EdgeInsets.symmetric(vertical: 2),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `.input-char-count` — base text-dim @0.6 opacity, warning #f59e0b at 80%,
  /// limit (--danger) at 100% (updateFieldCharCount).
  Widget _charCount(NymColors c, int len, int max) {
    final Color color;
    if (len >= max) {
      color = c.danger;
    } else if (len >= max * 0.8) {
      color = const Color(0xFFF59E0B);
    } else {
      color = c.textDim.withValues(alpha: 0.6);
    }
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('$len/$max', style: TextStyle(fontSize: 11, color: color)),
      ),
    );
  }

  /// `.pm-suggestions` — bg-secondary box, radius 12, mt4, `0 6px 20px
  /// rgba(0,0,0,0.4)` shadow, max-height 200. On empty input the list is the
  /// "recently seen users" set under an uppercase header.
  Widget _suggestionsList(NymColors c) {
    final suggestions = _suggestions;
    if (suggestions.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 4),
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        color: c.bgSecondary,
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: [
          // `.pm-suggestion-header` — only for the empty-query recently-seen
          // list (11px UPPERCASE ls0.5 text-dim + bottom hairline).
          if (_isRecentlySeen)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
                ),
              ),
              child: Text(
                'RECENTLY SEEN USERS',
                style: TextStyle(
                  color: c.textDim,
                  fontSize: 11,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          for (final u in suggestions) _suggestionItem(c, u),
        ],
      ),
    );
  }

  /// `.pm-suggestion-item` — avatar 26 + base nym (13px --text) + `#suffix`
  /// (11px text-dim), padding 8/12, gap 6.
  Widget _suggestionItem(NymColors c, User u) {
    final base = stripPubkeySuffix(u.nym);
    final suffix = getPubkeySuffix(u.pubkey);
    return InkWell(
      onTap: () => _addRecipient(u.pubkey, u.nym),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            NymAvatar(
              seed: u.nym.isNotEmpty ? u.nym : u.pubkey,
              size: 26,
              imageUrl: u.profile?.picture,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                base,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.text, fontSize: 13),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '#$suffix',
              style: TextStyle(color: c.textDim, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  /// `newGroupMediaGroup` (index.html:319-335) — `.new-group-media`: a 96px
  /// gradient banner with the 56px circular avatar overhanging its bottom-left
  /// (`left:12; bottom:-22`), so the section reserves a 30px bottom margin.
  Widget _groupMediaSection(NymColors c) {
    final hasBanner = _groupBannerPath != null;
    final hasAvatar = _groupAvatarPath != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(c, 'Group Avatar & Banner', optional: true),
        const SizedBox(height: 4), // `.new-group-media` margin-top
        Padding(
          padding: const EdgeInsets.only(bottom: 30), // clear the -22 overhang
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // `.new-group-banner` — 96px, radius 12, 135° primary→secondary
              // gradient (hidden when an image is set), glass border.
              GestureDetector(
                onTap: () => _pickGroupImage(false),
                child: Container(
                  height: 96,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: NymRadius.rsm,
                    border: Border.all(color: c.glassBorder),
                    gradient: hasBanner
                        ? null
                        : LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [c.primaryA(0.4), c.secondaryA(0.4)],
                          ),
                    image: hasBanner
                        ? DecorationImage(
                            image: FileImage(File(_groupBannerPath!)),
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: hasBanner
                      ? null
                      // `.new-group-media-hint` — dark pill (12px white).
                      : Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.4),
                            borderRadius: NymRadius.rsm,
                          ),
                          child: const Text('Add banner',
                              style:
                                  TextStyle(color: Colors.white, fontSize: 12)),
                        ),
                ),
              ),
              // `.new-group-avatar` — 56px circle, left:12, bottom:-22, bg
              // bg-secondary, 3px bg-primary border, people icon (primary).
              Positioned(
                left: 12,
                bottom: -22,
                child: GestureDetector(
                  onTap: () => _pickGroupImage(true),
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c.bgSecondary,
                      border: Border.all(color: c.bg, width: 3),
                      image: hasAvatar
                          ? DecorationImage(
                              image: FileImage(File(_groupAvatarPath!)),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: hasAvatar
                        ? null
                        : Icon(Icons.group, color: c.primary, size: 26),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// `newGroupAllowInvites` (index.html:341-347) — checked by default; off ⇒
  /// only the owner can add members.
  Widget _allowInvitesRow(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _allowInvites = !_allowInvites),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: Checkbox(
                  value: _allowInvites,
                  onChanged: (v) => setState(() => _allowInvites = v ?? true),
                  activeColor: c.primary,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 8),
              Text('Allow members to add others',
                  style: TextStyle(color: c.text, fontSize: 13)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 30, top: 2),
          child: Text(
            'When off, only you (the group owner) can add new members.',
            style: TextStyle(color: c.textDim, fontSize: 11),
          ),
        ),
      ],
    );
  }

  /// `.form-input` — radius 12, bg white/0.05, padding 11/14, font 15 hint.
  InputDecoration _inputDecoration(NymColors c, String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: c.textDim, fontSize: 15),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
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
        borderSide: BorderSide(color: c.primaryA(0.3)),
      ),
    );
  }
}

/// `.pm-recipient-chip` — base nym (--text) + `#suffix` (text-dim) pill with a
/// remove ✕. bg primary/0.15, border primary/0.3, radius 999, padding
/// 2px 8px 2px 10px, gap 4.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.base,
    required this.suffix,
    required this.onRemove,
  });
  final String base;
  final String suffix;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 8, top: 2, bottom: 2),
      decoration: BoxDecoration(
        color: c.primaryA(0.15),
        borderRadius: const BorderRadius.all(Radius.circular(999)),
        border: Border.all(color: c.primaryA(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(base, style: TextStyle(color: c.text, fontSize: 12)),
          // `.pm-chip-suffix` — text-dim 11px.
          Text('#$suffix', style: TextStyle(color: c.textDim, fontSize: 11)),
          const SizedBox(width: 4),
          // `.pm-chip-remove` — text-dim 14px ✕ (danger on hover).
          InkWell(
            onTap: onRemove,
            borderRadius: const BorderRadius.all(Radius.circular(999)),
            child: Icon(Icons.close, size: 14, color: c.textDim),
          ),
        ],
      ),
    );
  }
}
