import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../core/theme/nym_colors.dart';
import '../../../core/theme/nym_metrics.dart';
import '../../i18n/i18n.dart';

/// The disclosure Apple requires before an app sends a buyer to an external
/// website to pay for digital goods.
///
/// The wording is Apple's, not ours, and is deliberately left as a single
/// non-negotiable string: an app that paraphrases it fails review. The buyer
/// must be able to back out, so Cancel is a real choice and returns false.
///
/// SCOPE — worth being precise about, because it is easy to over-read what this
/// gives you. Apple's External Purchase Link Entitlement expects the SYSTEM
/// sheet, shown by StoreKit's `ExternalPurchaseLink.open(url:)`. That is a
/// native API `in_app_purchase` does not expose, so reaching it needs a platform
/// channel and a Swift shim, which this is not. What this IS: the in-app
/// disclosure modal in the shape Apple's external-link rules describe, with
/// their prescribed copy — the same pattern reader apps ship under the External
/// Link Account Entitlement. You still need the entitlement granted for the
/// storefronts you ship to, and if App Review asks specifically for the StoreKit
/// sheet, that shim is the follow-up.
///
/// Android does not require any of this, so the modal is iOS-only; elsewhere
/// [confirmExternalPurchase] returns true without showing anything.
Future<bool> confirmExternalPurchase(BuildContext context) async {
  var isIos = false;
  try {
    isIos = !kIsWeb && Platform.isIOS;
  } catch (_) {
    isIos = false;
  }
  if (!isIos) return true;

  final result = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.7),
    builder: (ctx) {
      final c = ctx.nym;
      return AlertDialog(
        backgroundColor: c.bgSecondary,
        shape: const RoundedRectangleBorder(borderRadius: NymRadius.rmd),
        title: Text(
          tr('Continue to the web?'),
          style: TextStyle(
              color: c.text, fontSize: 16, fontWeight: FontWeight.w700),
        ),
        content: Text(
          // Apple's prescribed disclosure. Do not paraphrase.
          tr("You're about to go to an external website. Apple is not "
              'responsible for the privacy or security of purchases made on '
              'the web.'),
          style: TextStyle(color: c.textDim, fontSize: 13, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr('Cancel'),
                style: TextStyle(color: c.textDim, fontSize: 14)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr('Continue'),
                style: TextStyle(
                    color: c.primary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      );
    },
  );
  return result == true;
}
