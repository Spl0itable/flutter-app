import 'dart:io';

import 'package:flutter/material.dart';
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
  }

  @override
  void dispose() {
    _recipientController.dispose();
    _groupNameController.dispose();
    _groupDescController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  void _onRecipientInput() => setState(() {}); // refresh suggestions live

  /// Live recipient suggestions (`onNewPMRecipientInput` / `pmSuggestions`,
  /// index.html:312): known users whose nym matches the current input, minus
  /// self and already-picked recipients. Empty input → no suggestions.
  List<User> get _suggestions {
    final raw = _recipientController.text.trim().replaceFirst(RegExp(r'^@'), '');
    if (raw.isEmpty) return const [];
    final query = raw.toLowerCase();
    final self = ref.read(appStateProvider).selfPubkey;
    final picked = _recipients.map((r) => r.pubkey).toSet();
    final out = <User>[];
    for (final u in ref.read(usersProvider).values) {
      if (u.pubkey == self || picked.contains(u.pubkey)) continue;
      final nym = u.nym.toLowerCase();
      if (nym.contains(query) ||
          stripPubkeySuffix(u.nym).toLowerCase().contains(query)) {
        out.add(u);
      }
      if (out.length >= 8) break;
    }
    return out;
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
        constraints: const BoxConstraints(maxWidth: 480),
        child: Container(
          decoration: BoxDecoration(
            color: c.bgSecondary,
            border: Border.all(color: c.glassBorder),
            borderRadius: NymRadius.rmd,
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          color: c.textBright,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: Icon(Icons.close, size: 18, color: c.textDim),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _label(c, 'To'),
                      const SizedBox(height: 8),
                      // Recipient chips.
                      if (_recipients.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final r in _recipients)
                                _Chip(
                                  nym: r.nym,
                                  onRemove: () => _remove(r.pubkey),
                                ),
                            ],
                          ),
                        ),
                      TextField(
                        controller: _recipientController,
                        onSubmitted: (_) => _addFromInput(),
                        style: TextStyle(color: c.text, fontSize: 14),
                        decoration: _inputDecoration(
                          c,
                          'Search nym or paste pubkey...',
                          suffix: IconButton(
                            tooltip: 'Add',
                            icon: Icon(Icons.add, size: 18, color: c.primary),
                            onPressed: _addFromInput,
                          ),
                        ),
                      ),
                      _suggestionsList(c),
                      if (_groupMode) ...[
                        const SizedBox(height: 16),
                        _label(c, 'Group Name (optional)'),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _groupNameController,
                          maxLength: 40,
                          onChanged: (_) => setState(() {}),
                          style: TextStyle(color: c.text, fontSize: 14),
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
                        _label(c, 'Description (optional)'),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _groupDescController,
                          maxLength: 150,
                          maxLines: 3,
                          onChanged: (_) => setState(() {}),
                          style: TextStyle(color: c.text, fontSize: 14),
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
                      _label(c, 'Message (optional)'),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _messageController,
                        maxLines: 3,
                        style: TextStyle(color: c.text, fontSize: 14),
                        decoration:
                            _inputDecoration(c, 'Start the conversation...'),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      style: TextButton.styleFrom(foregroundColor: c.textDim),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _recipients.isNotEmpty ? _start : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: c.primary,
                        foregroundColor: c.bg,
                        disabledBackgroundColor: c.primaryA(0.3),
                      ),
                      child: Text(_groupMode ? 'Create' : 'Start'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(NymColors c, String text) => Text(
        text,
        style: TextStyle(
          color: c.textDim,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.5,
        ),
      );

  /// `.input-char-count` — warn at 80%, limit at 100% (updateFieldCharCount).
  Widget _charCount(NymColors c, int len, int max) => Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '$len/$max',
            style: TextStyle(
              fontSize: 11,
              color: len >= max
                  ? c.danger
                  : (len >= max * 0.8 ? c.warning : c.textDim),
            ),
          ),
        ),
      );

  /// `.pm-suggestions` (index.html:312) — live matches from known users; tap to
  /// add a recipient chip.
  Widget _suggestionsList(NymColors c) {
    final suggestions = _suggestions;
    if (suggestions.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 6),
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: NymRadius.rxs,
        border: Border.all(color: c.glassBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: [
          for (final u in suggestions)
            InkWell(
              onTap: () => _addRecipient(u.pubkey, u.nym),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    NymAvatar(
                      seed: u.nym.isNotEmpty ? u.nym : u.pubkey,
                      size: 24,
                      imageUrl: u.profile?.picture,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        u.nym,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.text, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// `newGroupMediaGroup` (index.html:319-335) — group avatar + banner pickers.
  Widget _groupMediaSection(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(c, 'Group Avatar & Banner (optional)'),
        const SizedBox(height: 8),
        Row(
          children: [
            // Avatar tile.
            GestureDetector(
              onTap: () => _pickGroupImage(true),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 56,
                  height: 56,
                  color: c.glassBg,
                  child: _groupAvatarPath != null
                      ? Image.file(File(_groupAvatarPath!), fit: BoxFit.cover)
                      : Icon(Icons.group, color: c.textDim, size: 26),
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Banner tile.
            Expanded(
              child: GestureDetector(
                onTap: () => _pickGroupImage(false),
                child: Container(
                  height: 56,
                  decoration: BoxDecoration(
                    color: c.glassBg,
                    borderRadius: NymRadius.rxs,
                    border: Border.all(color: c.glassBorder),
                    image: _groupBannerPath != null
                        ? DecorationImage(
                            image: FileImage(File(_groupBannerPath!)),
                            fit: BoxFit.cover)
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: _groupBannerPath == null
                      ? Text('Add banner',
                          style: TextStyle(color: c.textDim, fontSize: 12))
                      : null,
                ),
              ),
            ),
          ],
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

  InputDecoration _inputDecoration(NymColors c, String hint, {Widget? suffix}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: c.textDim, fontSize: 14),
      suffixIcon: suffix,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      filled: true,
      fillColor: c.glassBg,
      enabledBorder: OutlineInputBorder(
        borderRadius: NymRadius.rxs,
        borderSide: BorderSide(color: c.glassBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: NymRadius.rxs,
        borderSide: BorderSide(color: c.primaryA(0.5)),
      ),
    );
  }
}

/// `.pm-recipient-chip` — nym pill with a remove button.
class _Chip extends StatelessWidget {
  const _Chip({required this.nym, required this.onRemove});
  final String nym;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: c.primaryA(0.10),
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        border: Border.all(color: c.primaryA(0.20)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            nym,
            style: TextStyle(color: c.primary, fontSize: 12),
          ),
          const SizedBox(width: 2),
          InkWell(
            onTap: onRemove,
            borderRadius: const BorderRadius.all(Radius.circular(20)),
            child: Icon(Icons.close, size: 14, color: c.primary),
          ),
        ],
      ),
    );
  }
}
