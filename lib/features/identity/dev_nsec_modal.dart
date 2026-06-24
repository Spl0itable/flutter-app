import 'package:flutter/material.dart';

import '../../core/crypto/bech32_codec.dart';
import '../../core/crypto/keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';

/// The reserved developer pubkey ("Luxas"), `verifiedDeveloper.pubkey`
/// (app.js:1092). Picking a reserved nickname requires proving ownership of the
/// matching nsec before the name is allowed.
const String kVerifiedDeveloperPubkey =
    'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df';

/// Reserved nicknames (`isReservedNick`, users.js:66-69): a name is reserved
/// when its base (lower-cased, `#suffix` stripped, trimmed) is in this set.
const Set<String> kReservedNicks = {'luxas', 'nymbot'};

/// Whether [nick] is a reserved nickname (matches the PWA's `isReservedNick`).
bool isReservedNick(String nick) {
  final base = nick.toLowerCase().replaceFirst(RegExp(r'#.*$'), '').trim();
  return kReservedNicks.contains(base);
}

/// Result of a successful developer-nsec verification.
class DevNsecResult {
  const DevNsecResult({required this.nsec, required this.pubkey});

  /// The verified nsec (as entered), so callers can persist it for auto-login
  /// (`nymSecretSet('nym_dev_nsec', cmdResult.nsec)`, app.js:2702).
  final String nsec;

  /// The derived developer pubkey (equals [kVerifiedDeveloperPubkey]).
  final String pubkey;
}

/// Verifies [nsec] maps to the developer pubkey (`verifyDeveloperNsec`,
/// users.js:75-86). Returns the result on a match, or null otherwise.
DevNsecResult? verifyDeveloperNsec(String nsec) {
  try {
    final bytes = decodeNsec(nsec.trim());
    if (bytes.length != 32) return null;
    final derived = getPublicKeyHex(bytes);
    if (derived == kVerifiedDeveloperPubkey) {
      return DevNsecResult(nsec: nsec.trim(), pubkey: derived);
    }
  } catch (_) {}
  return null;
}

/// "Reserved Nickname" verification modal (`#devNsecModal`, index.html:995-1014
/// + `showDevNsecModal`/`verifyDevNsec`, app.js:3159-3190).
///
/// Shown when a user picks a reserved nickname ("Luxas" is the developer
/// handle): a password field for the nsec, an inline error when it doesn't
/// match, and Cancel/Verify actions. Resolves a [DevNsecResult] on success, or
/// null on cancel.
class DevNsecModal extends StatefulWidget {
  const DevNsecModal({super.key});

  /// Opens the modal, resolving the verified result or null (cancel).
  static Future<DevNsecResult?> open(BuildContext context) {
    return showDialog<DevNsecResult>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => const DevNsecModal(),
    );
  }

  @override
  State<DevNsecModal> createState() => _DevNsecModalState();
}

class _DevNsecModalState extends State<DevNsecModal> {
  final _nsec = TextEditingController();
  bool _error = false;

  @override
  void dispose() {
    _nsec.dispose();
    super.dispose();
  }

  void _verify() {
    final result = verifyDeveloperNsec(_nsec.text);
    if (result != null) {
      Navigator.of(context).pop(result);
    } else {
      setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // `.modal-header`.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Reserved Nickname',
                            style: TextStyle(
                              color: c.text,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.close, color: c.textDim),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '"Luxas" is reserved for the Nymchat developer.',
                          style: TextStyle(
                            color: c.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Paste your nsec to verify your identity:',
                          style: TextStyle(color: c.textDim, fontSize: 12),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _nsec,
                          obscureText: true,
                          autofocus: true,
                          onChanged: (_) {
                            if (_error) setState(() => _error = false);
                          },
                          onSubmitted: (_) => _verify(),
                          style: TextStyle(color: c.text, fontSize: 13),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'nsec1...',
                            hintStyle: TextStyle(color: c.textDim),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 11),
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
                        if (_error) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Invalid nsec - does not match the developer pubkey.',
                            style: TextStyle(color: c.danger, fontSize: 12),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // `.modal-actions`.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 16, 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text('Cancel',
                              style: TextStyle(color: c.textDim)),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          style:
                              FilledButton.styleFrom(backgroundColor: c.primary),
                          onPressed: _verify,
                          child: const Text('Verify'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
