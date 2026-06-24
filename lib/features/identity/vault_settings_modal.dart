import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/storage/secure_store.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/app_dialog.dart';
import 'identity_vault.dart';

/// Provides the [IdentityVault] wired to the app key/value + secure stores.
final identityVaultProvider = Provider<IdentityVault>((ref) {
  return IdentityVault(
    ref.watch(keyValueStoreProvider),
    SecureStoreAdapter(SecureStore()),
  );
});

/// Settings modal for identity encryption-at-rest (`openVaultSettings`,
/// `js/modules/key-vault.js`). Lets the user enable/disable per-device
/// encryption and pick a factor: Password, PIN, or Biometric (`local_auth`).
class VaultSettingsModal extends ConsumerStatefulWidget {
  const VaultSettingsModal({super.key});

  static Future<void> open(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => const VaultSettingsModal(),
    );
  }

  @override
  ConsumerState<VaultSettingsModal> createState() => _VaultSettingsModalState();
}

class _VaultSettingsModalState extends ConsumerState<VaultSettingsModal> {
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  String _method = 'password';
  String? _error;
  bool _busy = false;
  bool _bioAvailable = false;

  @override
  void initState() {
    super.initState();
    _checkBiometric();
  }

  Future<void> _checkBiometric() async {
    try {
      final auth = LocalAuthentication();
      final supported =
          await auth.isDeviceSupported() && await auth.canCheckBiometrics;
      if (mounted) setState(() => _bioAvailable = supported);
    } catch (_) {
      // Biometric probing unavailable (tests / desktop) — leave disabled.
    }
  }

  @override
  void dispose() {
    _pw.dispose();
    _pw2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final vault = ref.watch(identityVaultProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Material(
            color: c.bgSecondary,
            borderRadius: NymRadius.rxl,
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: vault.isEnabled
                  ? _enabledView(c, vault)
                  : _setupView(c, vault),
            ),
          ),
        ),
      ),
    );
  }

  Widget _enabledView(NymColors c, IdentityVault vault) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Identity encryption',
            style: TextStyle(
                color: c.text, fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        Text(
          'Your identity key is encrypted at rest (${vault.method}).',
          style: TextStyle(color: c.textDim, fontSize: 13),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: c.danger, fontSize: 12)),
        ],
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Close', style: TextStyle(color: c.textDim)),
            ),
            const SizedBox(width: 8),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.danger),
              onPressed: _busy ? null : () => _disable(vault),
              child: const Text('Turn off'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _setupView(NymColors c, IdentityVault vault) {
    final isBio = _method == 'biometric';
    final isPin = _method == 'pin';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Encrypt identity key',
            style: TextStyle(
                color: c.text, fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(
          "Protect your saved identity so it can't be read from this device "
          'without unlocking.',
          style: TextStyle(color: c.textDim, fontSize: 13),
        ),
        const SizedBox(height: 16),
        Text('Method', style: TextStyle(color: c.text, fontSize: 12)),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          value: _method,
          dropdownColor: c.bgTertiary,
          style: TextStyle(color: c.text, fontSize: 14),
          decoration: _decoration(c, ''),
          items: [
            const DropdownMenuItem(value: 'password', child: Text('Password')),
            const DropdownMenuItem(value: 'pin', child: Text('PIN')),
            if (_bioAvailable)
              const DropdownMenuItem(
                  value: 'biometric',
                  child: Text('Biometric (Face/Touch ID)')),
          ],
          onChanged: (v) => setState(() => _method = v ?? 'password'),
        ),
        if (!isBio) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _pw,
            obscureText: true,
            keyboardType: isPin ? TextInputType.number : TextInputType.text,
            style: TextStyle(color: c.text),
            decoration:
                _decoration(c, isPin ? 'Choose a PIN code' : 'Choose a password'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _pw2,
            obscureText: true,
            keyboardType: isPin ? TextInputType.number : TextInputType.text,
            style: TextStyle(color: c.text),
            decoration: _decoration(c, 'Confirm'),
          ),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              "You'll be asked for your biometric to unlock the app on next "
              'launch.',
              style: TextStyle(color: c.textDim, fontSize: 11),
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: c.danger, fontSize: 12)),
        ],
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel', style: TextStyle(color: c.textDim)),
            ),
            const SizedBox(width: 8),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.primary),
              onPressed: _busy ? null : () => _enable(vault),
              child: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Enable'),
            ),
          ],
        ),
      ],
    );
  }

  InputDecoration _decoration(NymColors c, String hint) => InputDecoration(
        isDense: true,
        hintText: hint.isEmpty ? null : hint,
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
      );

  Future<void> _enable(IdentityVault vault) async {
    setState(() => _error = null);
    String password;
    if (_method == 'biometric') {
      // Authenticate once; derive the vault key from a stable device secret.
      // TODO(verify): the PWA derives the key from a WebAuthn PRF output. On
      // native there is no PRF; here we gate enabling behind a biometric prompt
      // and derive from a generated device secret stored in secure storage.
      final ok = await _biometricAuth();
      if (!ok) {
        setState(() => _error = 'Biometric authentication failed.');
        return;
      }
      password = await _deviceBiometricSecret();
    } else {
      if (_pw.text.length < 4) {
        setState(() => _error = 'Use at least 4 characters.');
        return;
      }
      if (_pw.text != _pw2.text) {
        setState(() => _error = 'The two entries do not match.');
        return;
      }
      password = _pw.text;
    }
    setState(() => _busy = true);
    try {
      await vault.enable(method: _method, password: password);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Identity encryption enabled. You\'ll unlock on next launch.')),
      );
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _disable(IdentityVault vault) async {
    setState(() => _error = null);
    String password;
    if (vault.method == 'biometric') {
      // Passkey/biometric: fresh authenticator challenge (`_vaultReauth`).
      final ok = await _biometricAuth();
      if (!ok) {
        setState(() => _error = 'Biometric authentication failed.');
        return;
      }
      password = await _deviceBiometricSecret();
    } else {
      // Password/PIN: a separate "Confirm it's you" prompt before turning off,
      // matching the PWA's `_vaultReauth` (key-vault.js:479-498) instead of an
      // inline field. Verify the factor, then disable only on success.
      final entered = await showAppPrompt(
        context,
        'Enter your password or PIN to turn off identity encryption.',
        title: "Confirm it's you",
        okLabel: 'Confirm',
        placeholder: 'Password or PIN',
      );
      if (entered == null) return; // cancelled
      final ok = await vault.verifyPassword(entered);
      if (!mounted) return;
      if (!ok) {
        setState(() =>
            _error = 'Re-authentication failed. Encryption was not turned off.');
        return;
      }
      password = entered;
    }
    setState(() => _busy = true);
    try {
      await vault.disable(password);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Encryption turned off.')),
      );
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Re-authentication failed. Encryption was not turned off.';
      });
    }
  }

  Future<bool> _biometricAuth() async {
    try {
      final auth = LocalAuthentication();
      return await auth.authenticate(
        localizedReason: 'Unlock your Nymchat identity',
        options: const AuthenticationOptions(biometricOnly: true),
      );
    } catch (_) {
      return false;
    }
  }

  /// A stable per-device secret used as the PBKDF2 password for the biometric
  /// factor, stored in secure storage (behind the biometric gate).
  Future<String> _deviceBiometricSecret() async {
    final secure = SecureStore();
    const key = 'nym_vault_bio_secret';
    var s = await secure.get(key);
    if (s == null) {
      // 32 bytes from a CSPRNG — never time-derived, so the biometric factor
      // has full entropy (the WebAuthn-PRF equivalent on native).
      final rng = Random.secure();
      final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
      s = base64.encode(bytes);
      await secure.set(key, s);
    }
    return s;
  }
}

/// Cross-device "Protect your identity here too?" nudge — the native port of
/// `maybePromptEncryptAtRest` (key-vault.js:415-437). Call once AFTER settings
/// sync completes. If the user enabled identity encryption on another device
/// (`encryptAtRestPref`), this device isn't encrypted yet, a secret is
/// persisted, and the prompt wasn't dismissed, it offers to set encryption up
/// here. "Set up" opens [VaultSettingsModal]; both choices persist the
/// dismissed flag so it shows at most once.
///
/// Returns true when the prompt was shown. Safe to call when conditions aren't
/// met (returns false without UI). The trigger (calling this after sync) lives
/// in the controller — see this slice's CROSS-FILE NEEDS.
Future<bool> maybePromptEncryptAtRest(
  BuildContext context,
  WidgetRef ref,
) async {
  final kv = ref.read(keyValueStoreProvider);
  final vault = ref.read(identityVaultProvider);
  if (vault.isEnabled) return false;
  if (!kv.getBool(StorageKeys.encryptAtRestPref)) return false;
  if (kv.getBool(StorageKeys.encryptAtRestPromptDismissed)) return false;

  // Only nudge if there's actually a persisted identity secret to protect
  // (`_hasPersistedSecret`). Mirrors the PWA's guard.
  final secure = SecureStore();
  var hasSecret = false;
  for (final name in SecretKeys.all) {
    if ((await secure.get(name))?.isNotEmpty ?? false) {
      hasSecret = true;
      break;
    }
  }
  if (!hasSecret) return false;
  if (!context.mounted) return false;

  // Persist dismissed up-front (the PWA dismisses on either choice).
  await kv.setBool(StorageKeys.encryptAtRestPromptDismissed, true);
  if (!context.mounted) return true;

  final setUp = await showAppConfirm(
    context,
    'You protect your identity key with encryption on another device. Set it '
    "up on this device as well so your saved key can't be read without "
    "unlocking. You'll choose a password, PIN, or passkey for this device.",
    title: 'Protect your identity here too?',
    okLabel: 'Set up',
    cancelLabel: 'Not now',
  );
  if (setUp && context.mounted) {
    await VaultSettingsModal.open(context);
  }
  return true;
}
