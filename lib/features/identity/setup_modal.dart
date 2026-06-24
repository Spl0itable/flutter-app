import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import 'dev_nsec_modal.dart';
import 'nostr_login_modal.dart';

/// First-run setup screen mirroring `#setupModal` (index.html 1257–1346).
///
/// The user picks an optional nickname / avatar / banner / bio and taps
/// **Enter** to create an ephemeral identity, or opens the Nostr login. On
/// success [onComplete] fires so the [BootGate] proceeds to the shell.
///
/// Avatar/banner are file pickers (`setupAvatarPreview` / `setupBannerPreview`,
/// index.html:1285-1323): a preview, "Choose photo"/"Remove" buttons, and the
/// picked local path is threaded through `saveProfile`'s upload→URL path.
class SetupModal extends ConsumerStatefulWidget {
  const SetupModal({super.key, required this.onComplete});

  /// Called after the identity is created / login starts so the gate advances.
  final VoidCallback onComplete;

  @override
  ConsumerState<SetupModal> createState() => _SetupModalState();
}

class _SetupModalState extends ConsumerState<SetupModal> {
  final _nymCtl = TextEditingController();
  final _bioCtl = TextEditingController();
  String? _avatarPath;
  String? _bannerPath;
  bool _busy = false;

  @override
  void dispose() {
    _nymCtl.dispose();
    _bioCtl.dispose();
    super.dispose();
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

  Future<void> _enter() async {
    if (_busy) return;
    final nym = _nymCtl.text.trim();

    // Reserved nicknames ("Luxas") require the developer nsec before the name
    // is allowed (index.html setup submit → isReservedNick, app.js:4766).
    if (nym.isNotEmpty && isReservedNick(nym)) {
      final verified = await DevNsecModal.open(context);
      if (!mounted) return;
      if (verified == null) return; // cancelled — don't proceed with the name
    }

    setState(() => _busy = true);

    final kv = ref.read(keyValueStoreProvider);
    final controller = ref.read(nostrControllerProvider);

    // Persist auto-ephemeral so future boots skip the modal (initializeNym).
    await kv.setBool(StorageKeys.autoEphemeral, true);
    if (nym.isNotEmpty) {
      await kv.setString(StorageKeys.autoEphemeralNick, nym);
      await kv.setString(StorageKeys.customNick, nym);
    }
    final bio = _bioCtl.text.trim();
    final avatar = _avatarPath;
    final banner = _bannerPath;
    if (bio.isNotEmpty) await kv.setString(StorageKeys.bio, bio);
    if (avatar != null) await kv.setString(StorageKeys.avatarUrl, avatar);
    if (banner != null) await kv.setString(StorageKeys.bannerUrl, banner);

    // The ephemeral keypair was already booted in main(); publish the chosen
    // profile so the nym + avatar/banner/bio land on relays (saveToNostrProfile).
    // TODO(verify): the PWA uploads the picked file to a host and persists the
    // returned URL; here we pass the local path through saveProfile's
    // upload→URL path (same as nick_edit_modal).
    await controller.saveProfile(
      name: nym.isEmpty ? null : nym,
      about: bio.isEmpty ? null : bio,
      picture: avatar,
      banner: banner,
    );

    if (!mounted) return;
    widget.onComplete();
  }

  Future<void> _login() async {
    final result = await NostrLoginModal.open(context);
    if (!mounted) return;
    // A non-null result means a login method was chosen + persisted.
    if (result != null) widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final invite = _inviteBannerText();

    return Material(
      color: c.bg,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: c.bgSecondary,
                  borderRadius: NymRadius.rxl,
                  border: Border.all(color: c.glassBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ASCII "nymchat" logo doubles as a login affordance.
                    GestureDetector(
                      onTap: _login,
                      child: Text(
                        'nymchat',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: c.primary,
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (invite != null) ...[
                      _InviteBanner(text: invite, c: c),
                      const SizedBox(height: 16),
                    ],
                    GestureDetector(
                      onTap: _login,
                      child: Text(
                        'Login with nsec private key or extension? Click here',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: c.secondary,
                          fontSize: 13,
                          decoration: TextDecoration.underline,
                          decorationColor: c.secondary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _label(c, 'Choose Your Nickname', optional: true),
                    const SizedBox(height: 6),
                    _field(
                      c,
                      controller: _nymCtl,
                      hint: 'Leave empty for random nickname',
                      maxLength: 20,
                      showCounter: true,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Your ephemeral pseudonym nickname for this session',
                      style: TextStyle(color: c.textDim, fontSize: 11),
                    ),
                    const SizedBox(height: 16),
                    _label(c, 'Choose Your Avatar', optional: true),
                    const SizedBox(height: 6),
                    _avatarPicker(c),
                    const SizedBox(height: 16),
                    _label(c, 'Choose Your Banner', optional: true),
                    const SizedBox(height: 6),
                    _bannerPicker(c),
                    const SizedBox(height: 16),
                    _label(c, 'Bio', optional: true),
                    const SizedBox(height: 6),
                    _field(
                      c,
                      controller: _bioCtl,
                      hint: 'Tell people a bit about yourself...',
                      maxLength: 150,
                      maxLines: 3,
                      showCounter: true,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'NOTE: Nymchat is bridged with Bitchat geohash channels '
                      'and the messages are public and ephemeral; sent across '
                      'the Nostr relay network. Only private messages and group '
                      'chats are end-to-end encrypted.',
                      style: TextStyle(
                          color: c.textDim, fontSize: 11, height: 1.4),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      height: 46,
                      child: FilledButton(
                        key: const Key('setupEnterBtn'),
                        onPressed: _busy ? null : _enter,
                        style: FilledButton.styleFrom(
                          backgroundColor: c.primary,
                          foregroundColor: c.bg,
                          shape: RoundedRectangleBorder(
                              borderRadius: NymRadius.rsm),
                        ),
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Enter',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 15)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'By entering, you agree to our Terms of Service and '
                      'Privacy Policy.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.textDim, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Mirrors updateSetupInviteBanner: shows an invite line when a pending
  /// group-invite token is present (`nym_pending_group_invite`).
  String? _inviteBannerText() {
    final kv = ref.read(keyValueStoreProvider);
    final token = kv.getString(StorageKeys.pendingGroupInvite);
    if (token == null || token.isEmpty) return null;
    // TODO(verify): decode the group name from the token (parseGroupInviteInput).
    // We surface the generic copy until the token decoder is ported here.
    return 'You\'ve been invited to join a group. Pick a nym or log in '
        'below to continue.';
  }

  Widget _label(NymColors c, String text, {bool optional = false}) {
    return RichText(
      text: TextSpan(
        text: text,
        style: TextStyle(
            color: c.textBright, fontSize: 13, fontWeight: FontWeight.w600),
        children: [
          if (optional)
            TextSpan(
              text: '  (optional)',
              style: TextStyle(
                  color: c.textDim,
                  fontSize: 12,
                  fontWeight: FontWeight.normal),
            ),
        ],
      ),
    );
  }

  Widget _field(
    NymColors c, {
    required TextEditingController controller,
    required String hint,
    int? maxLength,
    int maxLines = 1,
    bool showCounter = false,
  }) {
    final field = TextField(
      controller: controller,
      maxLength: maxLength,
      maxLines: maxLines,
      onChanged: showCounter ? (_) => setState(() {}) : null,
      inputFormatters:
          maxLength == null ? null : [LengthLimitingTextInputFormatter(maxLength)],
      style: TextStyle(color: c.text, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: c.textDim, fontSize: 14),
        counterText: '',
        filled: true,
        fillColor: c.bg,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderRadius: NymRadius.rsm,
          borderSide: BorderSide(color: c.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: NymRadius.rsm,
          borderSide: BorderSide(color: c.primary),
        ),
      ),
    );
    if (!showCounter || maxLength == null) return field;
    // `.input-char-count` — warn at 80%, limit at 100% (updateFieldCharCount).
    final len = controller.text.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '$len/$maxLength',
            style: TextStyle(
              fontSize: 11,
              color: len >= maxLength
                  ? c.danger
                  : (len >= maxLength * 0.8 ? c.warning : c.textDim),
            ),
          ),
        ),
      ],
    );
  }

  /// `setupAvatarPreview` (index.html:1285-1302) — 80×80 preview + Choose/Remove.
  Widget _avatarPicker(NymColors c) {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 80,
            height: 80,
            color: c.bg,
            child: _avatarPath != null
                ? Image.file(File(_avatarPath!), fit: BoxFit.cover)
                : Icon(Icons.person_outline, color: c.textDim, size: 36),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Row(
            children: [
              _smallButton(c, 'Choose photo', () => _pickImage(true)),
              if (_avatarPath != null) ...[
                const SizedBox(width: 8),
                _smallButton(c, 'Remove',
                    () => setState(() => _avatarPath = null),
                    danger: true),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// `setupBannerPreview` (index.html:1304-1323) — preview wrap + Choose/Remove
  /// with a "No banner set" placeholder.
  Widget _bannerPicker(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 80,
          decoration: BoxDecoration(
            color: c.bg,
            borderRadius: NymRadius.rsm,
            border: Border.all(color: c.glassBorder),
            image: _bannerPath != null
                ? DecorationImage(
                    image: FileImage(File(_bannerPath!)), fit: BoxFit.cover)
                : null,
          ),
          alignment: Alignment.center,
          child: _bannerPath == null
              ? Text('No banner set', style: TextStyle(color: c.textDim))
              : null,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _smallButton(c, 'Choose banner', () => _pickImage(false)),
            if (_bannerPath != null) ...[
              const SizedBox(width: 8),
              _smallButton(
                  c, 'Remove', () => setState(() => _bannerPath = null),
                  danger: true),
            ],
          ],
        ),
      ],
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
}

class _InviteBanner extends StatelessWidget {
  const _InviteBanner({required this.text, required this.c});

  final String text;
  final NymColors c;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('setupInviteBanner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.primaryA(0.10),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.primaryA(0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.group, size: 18, color: c.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(color: c.textBright, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
