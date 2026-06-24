import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/crypto/bech32_codec.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/nostr/nym_generator.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/common/nym_avatar.dart';
import 'dev_nsec_modal.dart';
import 'modal_chrome.dart';
import 'nym_identicon.dart';

/// The profile / nickname editor (`#nickEditModal`, index.html:1149).
///
/// Fields (verbatim order from the PWA): Nickname (≤20, char count) with the
/// `#xxxx` pubkey suffix, Avatar (image/url), Banner, Bio (≤150), Lightning
/// address, then a "Reveal this nym's private key" slideout gated behind a
/// press-and-hold confirm. Save → `NostrController.saveProfile(...)`.
class NickEditModal extends ConsumerStatefulWidget {
  const NickEditModal({super.key});

  static Future<void> open(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => const NickEditModal(),
    );
  }

  @override
  ConsumerState<NickEditModal> createState() => _NickEditModalState();
}

class _NickEditModalState extends ConsumerState<NickEditModal> {
  late final TextEditingController _nick;
  late final TextEditingController _bio;
  late final TextEditingController _lightning;

  /// The original bio / lightning so `_save` writes only changed fields and
  /// never blanks an existing value (`changeNick`, app.js:2662-2691).
  String _originalBio = '';
  String _originalLightning = '';
  String _originalNick = '';

  /// The current avatar / banner URLs (kind-0 is a full replacement, so these
  /// must be re-published when the user only edits bio/lightning, or the
  /// existing avatar/banner would be dropped).
  String? _currentAvatarUrl;
  String? _currentBannerUrl;

  String? _avatarPath;
  String? _bannerPath;
  bool _revealOpen = false;
  bool _nsecVisible = false;
  bool _pubkeyOpen = false; // full-hex pubkey slideout
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final id = ref.read(nostrControllerProvider).identity;
    final nym = id?.nym ?? '';
    // The nym is `name#suffix`; the input edits only the name part.
    final hash = nym.indexOf('#');
    _originalNick = hash >= 0 ? nym.substring(0, hash) : nym;
    _nick = TextEditingController(text: _originalNick);

    // Pre-fill bio + lightning from the current profile so opening the editor
    // shows existing values and saving can't silently blank them (app.js:2595).
    final profile = id != null
        ? ref.read(appStateProvider).users[id.pubkey]?.profile
        : null;
    _originalBio = profile?.about ?? '';
    _originalLightning = profile?.lightningAddress ?? '';
    _currentAvatarUrl = profile?.picture;
    _currentBannerUrl = profile?.banner;
    _bio = TextEditingController(text: _originalBio);
    _lightning = TextEditingController(text: _originalLightning);
  }

  @override
  void dispose() {
    _nick.dispose();
    _bio.dispose();
    _lightning.dispose();
    super.dispose();
  }

  String get _pubkey => ref.read(nostrControllerProvider).identity?.pubkey ?? '';

  String get _suffix {
    final pk = _pubkey;
    return pk.length >= 4 ? '#${pk.substring(pk.length - 4)}' : '';
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
            child: Stack(
              children: [
                ModalChrome.box(
                  c,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.9,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _modalHeader(c),
                        Flexible(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _nicknameGroup(c),
                                const SizedBox(height: 18),
                                _avatarGroup(c),
                                const SizedBox(height: 18),
                                _bannerGroup(c),
                                const SizedBox(height: 18),
                                _bioGroup(c),
                                const SizedBox(height: 18),
                                _lightningGroup(c),
                                const SizedBox(height: 18),
                                _revealPrivkeyGroup(c),
                              ],
                            ),
                          ),
                        ),
                        _actions(c),
                      ],
                    ),
                  ),
                ),
                ModalChrome.closeChip(c, () => Navigator.of(context).pop()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // `.modal-header`: 22px primary UPPERCASE ls1.5 w700 + bottom rule.
  Widget _modalHeader(NymColors c) => Container(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.glassBorder)),
        ),
        child: Text(
          "Change Nym's Details".toUpperCase(),
          style: TextStyle(
            color: c.primary,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
      );

  Widget _label(NymColors c, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            color: c.text,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _hint(NymColors c, String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text, style: TextStyle(color: c.textDim, fontSize: 11)),
      );

  InputBorder _inputBorder(NymColors c, [Color? color]) => OutlineInputBorder(
        borderRadius: NymRadius.rxs,
        borderSide: BorderSide(color: color ?? c.glassBorder),
      );

  Widget _nicknameGroup(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(c, 'Nickname'),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _nick,
                maxLength: 20,
                buildCounter: (_,
                        {required currentLength,
                        required isFocused,
                        maxLength}) =>
                    null,
                onChanged: (_) => setState(() {}),
                style: TextStyle(color: c.text, fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Enter new nym',
                  hintStyle: TextStyle(color: c.textDim),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 11),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.05),
                  border: _inputBorder(c),
                  enabledBorder: _inputBorder(c),
                  focusedBorder: _inputBorder(c, c.primaryA(0.3)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // `.nym-suffix-clickable` (index.html:1159) — tap to view the full
            // hex pubkey.
            Tooltip(
              message: 'Click to view full pubkey',
              child: InkWell(
                onTap: () => setState(() => _pubkeyOpen = !_pubkeyOpen),
                borderRadius: NymRadius.rxs,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    _suffix,
                    style: TextStyle(
                      color: c.primary,
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '${_nick.text.length}/20',
            style: TextStyle(color: c.textDim, fontSize: 11),
          ),
        ),
        if (_pubkeyOpen) _pubkeySlideout(c),
        _hint(
          c,
          'Your ephemeral pseudonym nickname for this session. The # and four '
          'characters identify this Nym\'s pubkey.',
        ),
      ],
    );
  }

  /// The full-hex pubkey panel (`#pubkeySlideout`, index.html:1159-1169): a
  /// title, an explanatory paragraph, the full pubkey, and a Copy button.
  Widget _pubkeySlideout(NymColors c) {
    final pk = _pubkey;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Full Hex Pubkey',
              style: TextStyle(
                  color: c.text, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            'This is your public key — a unique identifier derived from your '
            'keypair. Share it so others can find and verify this Nym. It is '
            'safe to share (unlike your private key).',
            style: TextStyle(color: c.textDim, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  pk,
                  style: TextStyle(
                    color: c.text,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _smallButton(
                c,
                'Copy',
                () => _copyToClipboard(pk, 'Pubkey copied'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _avatarGroup(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(c, 'Avatar'),
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 64,
                height: 64,
                child: _avatarPath != null
                    ? Image.file(File(_avatarPath!), fit: BoxFit.cover)
                    : (_currentAvatarUrl != null && _currentAvatarUrl!.isNotEmpty
                        ? NymAvatar(
                            seed: _pubkey,
                            size: 64,
                            imageUrl: _currentAvatarUrl,
                          )
                        : NymIdenticon(seed: _pubkey, size: 64)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _smallButton(c, 'Change photo', () => _pickImage(true)),
                      if (_avatarPath != null) ...[
                        const SizedBox(width: 8),
                        _smallButton(
                          c,
                          'Remove',
                          () => setState(() => _avatarPath = null),
                          danger: true,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _bannerGroup(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(c, 'Banner'),
        Builder(builder: (_) {
          final remoteBanner = _bannerPath == null
              ? proxiedAvatarUrl(_currentBannerUrl)
              : null;
          return Container(
            height: 80,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: NymRadius.rsm,
              border: Border.all(color: c.glassBorder),
              image: _bannerPath != null
                  ? DecorationImage(
                      image: FileImage(File(_bannerPath!)), fit: BoxFit.cover)
                  : (remoteBanner != null
                      ? DecorationImage(
                          image: NetworkImage(remoteBanner), fit: BoxFit.cover)
                      : null),
            ),
            alignment: Alignment.center,
            child: (_bannerPath == null && remoteBanner == null)
                ? Text('No banner set', style: TextStyle(color: c.textDim))
                : null,
          );
        }),
        const SizedBox(height: 8),
        Row(
          children: [
            _smallButton(c, 'Choose banner', () => _pickImage(false)),
            if (_bannerPath != null) ...[
              const SizedBox(width: 8),
              _smallButton(c, 'Remove', () => setState(() => _bannerPath = null),
                  danger: true),
            ],
          ],
        ),
      ],
    );
  }

  Widget _bioGroup(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(c, 'Bio'),
        TextField(
          controller: _bio,
          maxLength: 150,
          maxLines: 3,
          onChanged: (_) => setState(() {}),
          buildCounter: (_,
                  {required currentLength, required isFocused, maxLength}) =>
              null,
          style: TextStyle(color: c.text, fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Tell people a bit about yourself...',
            hintStyle: TextStyle(color: c.textDim),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.05),
            border: _inputBorder(c),
            enabledBorder: _inputBorder(c),
            focusedBorder: _inputBorder(c, c.primaryA(0.3)),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Text('${_bio.text.length}/150',
              style: TextStyle(color: c.textDim, fontSize: 11)),
        ),
        _hint(c, 'Short bio shown on your profile (max 150 characters)'),
      ],
    );
  }

  Widget _lightningGroup(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(c, 'Bitcoin Lightning Address'),
        TextField(
          controller: _lightning,
          style: TextStyle(color: c.text, fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'your@lightning-address.com',
            hintStyle: TextStyle(color: c.textDim),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.05),
            border: _inputBorder(c),
            enabledBorder: _inputBorder(c),
            focusedBorder: _inputBorder(c, c.primaryA(0.3)),
          ),
        ),
        _hint(c, 'Your Bitcoin Lightning address for receiving zaps'),
      ],
    );
  }

  Widget _revealPrivkeyGroup(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _revealOpen = !_revealOpen),
          child: Row(
            children: [
              Icon(
                _revealOpen
                    ? Icons.arrow_drop_down
                    : Icons.arrow_right,
                size: 18,
                color: c.textDim,
              ),
              Text(
                "Reveal this nym's private key",
                style: TextStyle(color: c.textDim, fontSize: 13),
              ),
            ],
          ),
        ),
        if (_revealOpen) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: c.warning.withValues(alpha: 0.08),
              borderRadius: NymRadius.rsm,
              border: Border.all(color: c.warning.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 16, color: c.warning),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Your private key (nsec) is like a password for your '
                        'Nym identity. Anyone with access to it can post as you '
                        'and read your encrypted messages. Never share it.',
                        style: TextStyle(color: c.text, fontSize: 11),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // The PWA reveals the nsec on a plain click toggle — no hold
                // gate (toggleRevealPrivkey, app.js:2959). Populate immediately.
                _nsecRow(c),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _nsecRow(NymColors c) {
    final id = ref.read(nostrControllerProvider).identity;
    String nsec = '';
    if (id?.privkey != null) {
      try {
        nsec = encodeNsecBytes(id!.privkey!);
      } catch (_) {}
    }
    final display = nsec.isEmpty
        ? 'No local private key (delegated signer)'
        : (_nsecVisible
            ? nsec
            : '•' * (nsec.length.clamp(8, 24)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('nsec (Nostr Private Key)',
            style: TextStyle(color: c.text, fontSize: 12)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: NymRadius.rxs,
                  border: Border.all(color: c.glassBorder),
                ),
                child: Text(
                  display,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.text,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            IconButton(
              icon: Icon(_nsecVisible ? Icons.visibility_off : Icons.visibility,
                  size: 18, color: c.textDim),
              onPressed: () => setState(() => _nsecVisible = !_nsecVisible),
            ),
            // `copyRevealedNsec` (index.html:1243) — one-tap copy of the nsec.
            if (nsec.isNotEmpty)
              IconButton(
                tooltip: 'Copy',
                icon: Icon(Icons.copy, size: 16, color: c.textDim),
                onPressed: () => _copyToClipboard(nsec, 'Private key copied'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _actions(NymColors c) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      // `.modal-actions`: center, gap 10 (Randomize / Cancel are `.icon-btn`,
      // Change is `.send-btn`). No casino icon in the PWA.
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ModalChrome.iconButton(
              c, 'Randomize', _saving ? null : _randomize),
          const SizedBox(width: 10),
          ModalChrome.iconButton(
              c, 'Cancel', () => Navigator.of(context).pop()),
          const SizedBox(width: 10),
          ModalChrome.sendButton(
            c,
            'Change',
            _saving ? null : _save,
            child: _saving
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: c.primary),
                  )
                : null,
          ),
        ],
      ),
    );
  }

  Widget _smallButton(NymColors c, String label, VoidCallback onTap,
      {bool danger = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: NymRadius.rxs,
          border: Border.all(
            color: danger ? c.danger.withValues(alpha: 0.4) : c.glassBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: danger ? c.danger : c.text,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Future<void> _pickImage(bool avatar) async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(source: ImageSource.gallery);
      if (file == null || !mounted) return;
      setState(() {
        if (avatar) {
          _avatarPath = file.path;
        } else {
          _bannerPath = file.path;
        }
      });
    } catch (_) {
      // Picker unavailable (e.g. tests / desktop) — silently ignore.
    }
  }

  Future<void> _save() async {
    final newNick = _nick.text.trim();
    final nickChanged = newNick.isNotEmpty && newNick != _originalNick;

    // Reserved nicknames ("Luxas") require proving the developer nsec before
    // the rename is allowed (changeNick → isReservedNick gate, app.js:2693).
    if (nickChanged && isReservedNick(newNick)) {
      final verified = await DevNsecModal.open(context);
      if (!mounted) return;
      if (verified == null) {
        // Cancelled the reserved-nick check: persist bio/lightning edits but
        // keep the current nick (app.js:2705-2709).
        await _persist(includeName: false);
        return;
      }
    }

    await _persist(includeName: nickChanged);
  }

  /// Publishes the kind-0 profile. Because a kind-0 is a full replacement, ALL
  /// fields are sent from the prefilled controllers / current URLs — an
  /// untouched bio/lightning/avatar is re-published as-is (never blanked); a
  /// cleared field is intentionally blanked. [includeName] gates the rename so
  /// a non-change (or a cancelled reserved-nick check) leaves the nick alone.
  Future<void> _persist({required bool includeName}) async {
    setState(() => _saving = true);
    final bio = _bio.text.trim();
    final lightning = _lightning.text.trim();
    bool ok = false;
    try {
      ok = await ref.read(nostrControllerProvider).saveProfile(
            name: includeName ? _nick.text.trim() : null,
            about: bio,
            // Re-publish the EXISTING avatar/banner URLs so editing only the
            // bio doesn't drop them from the replaced kind-0. A locally-picked
            // file is NOT sent: a `file://` path is not a valid kind-0
            // `picture`/`banner`, and the host-upload→URL step is cross-file
            // (NostrController.uploadAvatar/uploadBanner — see CROSS_FILE_NEEDS).
            // We render the local preview honestly but never publish it.
            picture: _httpUrlOrCurrent(_avatarPath, _currentAvatarUrl),
            banner: _httpUrlOrCurrent(_bannerPath, _currentBannerUrl),
            lud16: lightning,
          );
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(ok ? 'Profile updated' : 'Could not save profile')),
    );
  }

  /// Returns [picked] only when it is already a hosted http(s) URL (it never is
  /// for a gallery pick), else the [current] URL — so a `file://` path from the
  /// picker is never published as a kind-0 image. Once a real host-upload step
  /// lands ([CROSS_FILE_NEEDS]: NostrController.uploadAvatar/uploadBanner), the
  /// uploaded URL flows through here.
  String? _httpUrlOrCurrent(String? picked, String? current) {
    if (picked != null &&
        (picked.startsWith('http://') || picked.startsWith('https://'))) {
      return picked;
    }
    return current;
  }

  /// Fills the nick field with a freshly generated random nym (Randomize,
  /// app.js:2721 `randomizeNick`).
  void _randomize() {
    final pk = _pubkey;
    final generated = NymGenerator().generate(pk);
    final hash = generated.indexOf('#');
    final base = hash >= 0 ? generated.substring(0, hash) : generated;
    setState(() => _nick.text = base);
  }

  void _copyToClipboard(String value, String confirm) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(confirm)));
  }
}
