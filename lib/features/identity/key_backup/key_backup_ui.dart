import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/crypto/keys.dart';
import '../../../core/theme/nym_colors.dart';
import '../../../core/theme/nym_metrics.dart';
import '../../../widgets/common/app_dialog.dart';
import '../../../widgets/common/keyboard_inset_dialog.dart';
import '../../i18n/i18n.dart';
import '../modal_chrome.dart';
import 'key_backup_crypto.dart';
import 'key_backup_service.dart';
import 'key_backup_store.dart';

typedef PinSubmit = Future<String?> Function(String pin);

String keyBackupContinueLabel(BackupCloud cloud) => switch (cloud) {
      BackupCloud.google => tr('Continue with Google'),
      BackupCloud.apple => tr('Continue with Apple'),
    };

String keyBackupBackUpLabel(BackupCloud cloud) => switch (cloud) {
      BackupCloud.google => tr('Back up to Google'),
      BackupCloud.apple => tr('Back up to Apple'),
    };

String keyBackupRemoveLabel(BackupCloud cloud) => switch (cloud) {
      BackupCloud.google => tr('Remove Google backups'),
      BackupCloud.apple => tr('Remove Apple backups'),
    };

String _pinWarning(BackupCloud cloud) => tr(
    'Your key stays yours. {provider} only stores an encrypted copy that it '
    "can't read without this PIN. The PIN can't be recovered: if you forget "
    'it, the backup is lost. Anyone who has both your {provider} account and '
    'this PIN can get your key.',
    {'provider': cloud.label});

class KeyBackupPinDialog extends StatefulWidget {
  const KeyBackupPinDialog({
    super.key,
    required this.title,
    required this.message,
    required this.submitLabel,
    required this.busyLabel,
    required this.onSubmit,
    this.create = false,
    this.warning,
    this.throttle,
  });

  final String title;
  final String message;
  final String submitLabel;
  final String busyLabel;
  final PinSubmit onSubmit;
  final bool create;
  final String? warning;
  final PinThrottle? throttle;

  static Future<bool> show(BuildContext context, KeyBackupPinDialog dialog) async {
    final res = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => dialog,
    );
    return res ?? false;
  }

  @override
  State<KeyBackupPinDialog> createState() => _KeyBackupPinDialogState();
}

class _KeyBackupPinDialogState extends State<KeyBackupPinDialog> {
  final _pin = TextEditingController();
  final _pin2 = TextEditingController();
  String? _error;
  bool _busy = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _startTickerIfThrottled();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pin.clear();
    _pin2.clear();
    _pin.dispose();
    _pin2.dispose();
    super.dispose();
  }

  Duration get _wait => widget.throttle?.remaining ?? Duration.zero;

  void _startTickerIfThrottled() {
    _ticker?.cancel();
    if (_wait == Duration.zero) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_wait == Duration.zero) t.cancel();
      setState(() {});
    });
  }

  Future<void> _submit() async {
    if (_busy || _wait > Duration.zero) return;
    final pin = _pin.text;
    if (!isValidBackupPin(pin)) {
      setState(() => _error = tr('The PIN must be 4 to 8 digits.'));
      return;
    }
    if (widget.create && pin != _pin2.text) {
      setState(() => _error = tr('The two PINs do not match.'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.onSubmit(pin);
    } catch (_) {
      error = tr('Something went wrong. Please try again.');
    }
    if (!mounted) return;
    if (error == null) {
      _pin.clear();
      _pin2.clear();
      Navigator.of(context).pop(true);
      return;
    }
    _pin.clear();
    _pin2.clear();
    setState(() {
      _busy = false;
      _error = error;
    });
    _startTickerIfThrottled();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final wait = _wait;
    final waitSeconds = (wait.inMilliseconds / 1000).ceil();
    return KeyboardInsetDialog(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Material(
            color: Colors.transparent,
            child: ModalChrome.box(
              c,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(c, widget.title),
                    Text(
                      widget.message,
                      style: TextStyle(
                          color: c.textDim, fontSize: 13, height: 1.5),
                    ),
                    if (widget.warning != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        widget.warning!,
                        key: const Key('keyBackupPinWarning'),
                        style: TextStyle(
                            color: c.warning, fontSize: 12, height: 1.45),
                      ),
                    ],
                    const SizedBox(height: 16),
                    _field(c, _pin, const Key('keyBackupPin'),
                        widget.create ? tr('Choose a PIN (4–8 digits)') : tr('PIN')),
                    if (widget.create) ...[
                      const SizedBox(height: 10),
                      _field(c, _pin2, const Key('keyBackupPinConfirm'),
                          tr('Enter the PIN again')),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!,
                          key: const Key('keyBackupPinError'),
                          style: TextStyle(color: c.danger, fontSize: 12)),
                    ],
                    if (wait > Duration.zero) ...[
                      const SizedBox(height: 8),
                      Text(
                        tr('Too many wrong PINs. Try again in {seconds} s.',
                            {'seconds': waitSeconds}),
                        key: const Key('keyBackupPinWait'),
                        style: TextStyle(color: c.textDim, fontSize: 12),
                      ),
                    ],
                    if (_busy) ...[
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: c.primary),
                          ),
                          const SizedBox(width: 10),
                          Text(widget.busyLabel,
                              style: TextStyle(color: c.textDim, fontSize: 13)),
                        ],
                      ),
                    ],
                    const SizedBox(height: 24),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        ModalChrome.iconButton(
                          c,
                          tr('Cancel'),
                          _busy ? null : () => Navigator.of(context).pop(false),
                        ),
                        ModalChrome.sendButton(
                          c,
                          widget.submitLabel,
                          _busy || wait > Duration.zero ? null : _submit,
                        ),
                      ],
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

  Widget _header(NymColors c, String title) => Container(
        padding: const EdgeInsets.only(bottom: 14),
        margin: const EdgeInsets.only(bottom: 20),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.glassBorder)),
        ),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            color: c.primary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
      );

  Widget _field(
      NymColors c, TextEditingController ctl, Key key, String hint) {
    return ModalChrome.focusRing(
      c,
      child: TextField(
        key: key,
        controller: ctl,
        enabled: !_busy,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.number,
        maxLength: 8,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(8),
        ],
        onSubmitted: (_) => _submit(),
        style: TextStyle(color: c.inputText, fontSize: 15),
        decoration:
            ModalChrome.inputDecoration(c, hint).copyWith(counterText: ''),
      ),
    );
  }
}

Future<BackupCandidate?> showBackupCandidatePicker(
    BuildContext context, List<BackupCandidate> candidates) {
  return showDialog<BackupCandidate>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.7),
    builder: (ctx) {
      final c = ctx.nym;
      return KeyboardInsetDialog(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Material(
              color: Colors.transparent,
              child: ModalChrome.box(
                c,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        tr('Choose an account').toUpperCase(),
                        style: TextStyle(
                          color: c.primary,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        tr('This PIN unlocks more than one backed-up key. Pick '
                            'the one to sign in with.'),
                        style: TextStyle(
                            color: c.textDim, fontSize: 13, height: 1.5),
                      ),
                      const SizedBox(height: 16),
                      for (var i = 0; i < candidates.length; i++) ...[
                        if (i > 0) const SizedBox(height: 8),
                        InkWell(
                          key: Key('keyBackupCandidate$i'),
                          borderRadius: NymRadius.rsm,
                          onTap: () => Navigator.of(ctx).pop(candidates[i]),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.05),
                              borderRadius: NymRadius.rsm,
                              border: Border.all(color: c.glassBorder),
                            ),
                            child: Text(
                              shortNpub(candidates[i].npub),
                              style: TextStyle(
                                color: c.textBright,
                                fontSize: 14,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Center(
                        child: ModalChrome.iconButton(
                            c, tr('Cancel'), () => Navigator.of(ctx).pop()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

String _errorMessage(Object e, BackupCloud cloud) {
  if (e is KeyBackupAuthExpired) {
    return tr('{provider} did not grant access. Please sign in again.',
        {'provider': cloud.label});
  }
  return tr("Couldn't reach {provider}. Check your connection and try again.",
      {'provider': cloud.label});
}

Future<(KeyBackupSession, List<BackupEntry>)?> _openSession(
    BuildContext context, WidgetRef ref, KeyBackupStore store) async {
  final deriver = ref.read(keyBackupDeriverProvider);
  try {
    final session = await KeyBackupSession.open(store, deriver: deriver);
    final entries = await session.list();
    return (session, entries);
  } on KeyBackupCanceled {
    return null;
  } catch (e) {
    if (context.mounted) {
      await showAppAlert(
        context,
        e is KeyBackupAuthExpired
            ? _errorMessage(e, store.cloud)
            : tr("Couldn't sign in with {provider}. Please try again.",
                {'provider': store.cloud.label}),
      );
    }
    return null;
  }
}

Future<bool> runKeyBackupSignIn(
  BuildContext context,
  WidgetRef ref,
  KeyBackupStore store,
  Future<void> Function(String secretHex) signIn,
) async {
  final cloud = store.cloud;
  final opened = await _openSession(context, ref, store);
  if (opened == null || !context.mounted) return false;
  final (session, entries) = opened;

  if (entries.isNotEmpty) {
    final throttle = PinThrottle.forCloud(cloud);
    List<BackupCandidate> found = const [];
    final ok = await KeyBackupPinDialog.show(
      context,
      KeyBackupPinDialog(
        title: tr('Enter your backup PIN'),
        message: tr(
            'Enter the PIN you chose when you backed up your key to '
            '{provider}.',
            {'provider': cloud.label}),
        submitLabel: tr('Unlock'),
        busyLabel: tr('Unlocking…'),
        throttle: throttle,
        onSubmit: (pin) async {
          final key = await session.deriveKey(pin);
          try {
            found = await session.candidates(key, entries);
          } catch (e) {
            return _errorMessage(e, cloud);
          } finally {
            wipeBytes(key);
          }
          if (found.isEmpty) {
            throttle.fail();
            return tr('Wrong PIN');
          }
          throttle.reset();
          return null;
        },
      ),
    );
    if (!ok || found.isEmpty || !context.mounted) return false;
    var chosen = found.first;
    if (found.length > 1) {
      final picked = await showBackupCandidatePicker(context, found);
      if (picked == null) return false;
      chosen = picked;
    }
    found = const [];
    await signIn(chosen.secretHex);
    return true;
  }

  String? created;
  final ok = await KeyBackupPinDialog.show(
    context,
    KeyBackupPinDialog(
      title: tr('Set a backup PIN'),
      message: tr(
          'No Nymchat key is backed up in this {provider} account yet. '
          'Nymchat will create a new key on this device and back it up '
          'encrypted with a PIN you choose.',
          {'provider': cloud.label}),
      warning: _pinWarning(cloud),
      submitLabel: tr('Create and back up'),
      busyLabel: tr('Encrypting…'),
      create: true,
      onSubmit: (pin) async {
        final sk = generatePrivateKey();
        final secretHex = bytesToHex(sk);
        wipeBytes(sk);
        final key = await session.deriveKey(pin);
        try {
          await session.upload(key, secretHex);
        } catch (e) {
          return _errorMessage(e, cloud);
        } finally {
          wipeBytes(key);
        }
        created = secretHex;
        return null;
      },
    ),
  );
  final secret = created;
  if (!ok || secret == null || !context.mounted) return false;
  await signIn(secret);
  return true;
}

Future<bool> runKeyBackupCreate(
  BuildContext context,
  WidgetRef ref,
  KeyBackupStore store, {
  required String secretHex,
  required String pubkeyHex,
}) async {
  final cloud = store.cloud;
  final opened = await _openSession(context, ref, store);
  if (opened == null || !context.mounted) return false;
  final (session, entries) = opened;
  var canceled = false;
  final ok = await KeyBackupPinDialog.show(
    context,
    KeyBackupPinDialog(
      title: tr('Set a backup PIN'),
      message: tr(
          'Choose a PIN to encrypt your key before it is stored in your '
          '{provider} account.',
          {'provider': cloud.label}),
      warning: _pinWarning(cloud),
      submitLabel: tr('Back up'),
      busyLabel: tr('Encrypting…'),
      create: true,
      onSubmit: (pin) async {
        final key = await session.deriveKey(pin);
        try {
          final existing = entries.isEmpty
              ? const <BackupEntry>[]
              : await session.entriesFor(key, entries, pubkeyHex);
          if (existing.isNotEmpty) {
            if (!context.mounted) return null;
            final replace = await showAppConfirm(
              context,
              tr('This key is already backed up to {provider} with this PIN. '
                  'Replace the existing backup?',
                  {'provider': cloud.label}),
              title: tr('Replace backup?'),
              okLabel: tr('Replace'),
            );
            if (!replace) {
              canceled = true;
              return null;
            }
          }
          await session.upload(key, secretHex);
          await session.deleteEntries(existing);
        } catch (e) {
          return _errorMessage(e, cloud);
        } finally {
          wipeBytes(key);
        }
        return null;
      },
    ),
  );
  if (!ok || canceled || !context.mounted) return false;
  await showAppAlert(
    context,
    tr('Your key is backed up to {provider}. Use "Continue with {provider}" '
        'and your PIN to sign in on another device.',
        {'provider': cloud.label}),
    title: tr('Backup complete'),
  );
  return true;
}

Future<bool> runKeyBackupRemove(
  BuildContext context,
  WidgetRef ref,
  KeyBackupStore store, {
  required String pubkeyHex,
}) async {
  final cloud = store.cloud;
  final opened = await _openSession(context, ref, store);
  if (opened == null || !context.mounted) return false;
  final (session, entries) = opened;
  if (entries.isEmpty) {
    await showAppAlert(
      context,
      tr('There are no Nymchat backups in this {provider} account.',
          {'provider': cloud.label}),
    );
    return false;
  }
  final throttle = PinThrottle.forCloud(cloud);
  var matches = const <BackupEntry>[];
  final ok = await KeyBackupPinDialog.show(
    context,
    KeyBackupPinDialog(
      title: tr('Remove backups'),
      message: tr(
          'Enter the backup PIN. Every backup of this key in your {provider} '
          'account that opens with it will be deleted.',
          {'provider': cloud.label}),
      submitLabel: tr('Continue'),
      busyLabel: tr('Unlocking…'),
      throttle: throttle,
      onSubmit: (pin) async {
        final key = await session.deriveKey(pin);
        try {
          matches = await session.entriesFor(key, entries, pubkeyHex);
        } catch (e) {
          return _errorMessage(e, cloud);
        } finally {
          wipeBytes(key);
        }
        if (matches.isEmpty) {
          throttle.fail();
          return tr('Wrong PIN, or no backup of this key uses it.');
        }
        throttle.reset();
        return null;
      },
    ),
  );
  if (!ok || matches.isEmpty || !context.mounted) return false;
  final confirmed = await showAppConfirm(
    context,
    tr('Delete {count} backup(s) of this key from {provider}? This device '
        'keeps working, but you will not be able to restore from them.',
        {'count': matches.length, 'provider': cloud.label}),
    title: tr('Remove backups'),
    okLabel: tr('Delete'),
    danger: true,
  );
  if (!confirmed || !context.mounted) return false;
  try {
    await session.deleteEntries(matches);
  } catch (e) {
    if (context.mounted) await showAppAlert(context, _errorMessage(e, cloud));
    return false;
  }
  if (!context.mounted) return true;
  await showAppAlert(
    context,
    tr('Backups removed from {provider}.', {'provider': cloud.label}),
  );
  return true;
}

class KeyBackupSignInButtons extends ConsumerStatefulWidget {
  const KeyBackupSignInButtons({super.key, required this.onSecret});

  final Future<void> Function(String secretHex) onSecret;

  @override
  ConsumerState<KeyBackupSignInButtons> createState() =>
      _KeyBackupSignInButtonsState();
}

class _KeyBackupSignInButtonsState
    extends ConsumerState<KeyBackupSignInButtons> {
  BackupCloud? _busy;

  Future<void> _run(KeyBackupStore store) async {
    if (_busy != null) return;
    setState(() => _busy = store.cloud);
    try {
      await runKeyBackupSignIn(context, ref, store, widget.onSecret);
    } catch (_) {
      if (mounted) {
        await showAppAlert(
            context, tr('Something went wrong. Please try again.'));
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final stores = ref.watch(keyBackupStoresProvider);
    if (stores.isEmpty) return const SizedBox.shrink();
    final c = context.nym;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final store in stores) ...[
          KeyedSubtree(
            key: Key('keyBackupContinue_${store.cloud.name}'),
            child: ModalChrome.sendButton(
              c,
              keyBackupContinueLabel(store.cloud),
              _busy == null ? () => _run(store) : null,
              fullWidth: true,
              child: _busy == store.cloud
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: c.primary),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          stores.length == 1
              ? tr('Your key stays yours. {provider} only keeps an encrypted '
                  "copy that it can't read without your PIN.",
                  {'provider': stores.first.cloud.label})
              : tr('Your key stays yours. Google and Apple only keep an '
                  "encrypted copy that they can't read without your PIN."),
          style: TextStyle(color: c.textDim, fontSize: 11),
        ),
      ],
    );
  }
}
