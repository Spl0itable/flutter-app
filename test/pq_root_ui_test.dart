/// The recovery code has to be reachable, or the root is generated, stored and
/// never shown: no second device can be linked, and a lost device takes the
/// post-quantum history with it.
///
/// Source-level, like pq_own_echo_test.dart — the modal needs a whole provider
/// graph to pump, and what these guard is the wiring, not the pixels.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/i18n/app_strings_catalog.dart';

void main() {
  final modal =
      File('lib/features/identity/nick_edit_modal.dart').readAsStringSync();
  final controller = File('lib/state/nostr_controller.dart').readAsStringSync();

  group('the recovery code is reachable', () {
    test('the modal reads it through pqRootCode', () {
      expect(modal.contains('ctrl.pqRootCode'), isTrue);
    });

    test('it sits in the same slideout as the nsec', () {
      expect(modal.indexOf('_pqRootRow(c)'),
          greaterThan(modal.indexOf('_nsecRow(c),')));
    });

    test('it renders masked until revealed', () {
      expect(modal.contains('_pqRootVisible ? code :'), isTrue);
    });

    test('and can be copied', () {
      expect(modal.contains('Post-quantum recovery code copied'), isTrue);
    });

    // Reveal and link are mutually exclusive: showing both would ask a device
    // that already holds the code to paste one.
    test('a device holding the code sees no paste box', () {
      expect(
          modal.contains(
              'code == null ? _pqRootLinkRow(c) : _pqRootCodeRow(c, code)'),
          isTrue);
    });

    test('linking goes through the checked controller path', () {
      expect(modal.contains('linkPqRootFromCode'), isTrue);
    });

    test('a rejected code says so rather than failing silently', () {
      expect(modal.contains('does not match this account'), isTrue);
    });

    test('the text controller is disposed', () {
      expect(modal.contains('_pqRootLink.dispose()'), isTrue);
    });

    test('the toggle names both halves, not just the private key', () {
      expect(
          modal.contains("Reveal this nym's private key and recovery code"),
          isTrue);
      expect(modal.contains('tr("Reveal this nym\'s private key")'), isFalse);
    });
  });

  group('the record identifies its root', () {
    // A record without a fingerprint reads in the PWA as no record at all, and
    // a device that believes there is no record generates a second root.
    test('both publish paths stamp one', () {
      expect(controller.contains('PqRootRecord.forRoot(root)'), isTrue);
      expect(controller.contains('PqRootRecord.forRoot(held)'), isTrue);
      expect(controller.contains('sync.pqRootRecordSet(const PqRootRecord())'),
          isFalse,
          reason: 'an empty record carries no fingerprint');
    });

    test('the republish path does not invent a root it does not hold', () {
      expect(controller.contains('final held = _pqRoot;\n        if (held == null) return;'),
          isTrue);
    });
  });

  group('the post-quantum notice', () {
    final gate =
        File('lib/features/onboarding/boot_gate.dart').readAsStringSync();
    final tutorial = File('lib/features/onboarding/tutorial_overlay.dart')
        .readAsStringSync();

    // Two explanations of the same thing back to back is worse than one.
    test('it is suppressed while the tutorial is still ahead', () {
      expect(gate.contains('if (!seen) {'), isTrue);
      expect(
          gate.contains(
              'unawaited(ref.read(nostrControllerProvider).dismissPqUpgradeNotice())'),
          isTrue,
          reason: 'dismissed, not deferred, so the tour never shows it twice');
    });

    test('the tutorial is what covers it instead', () {
      expect(tutorial.contains('post-quantum recovery code'), isTrue);
      expect(tutorial.contains('nympq1'), isTrue);
      // The whole point of the code is that losing it is unrecoverable.
      expect(tutorial.contains('cannot be recovered'), isTrue);
    });

    test('it fires only once', () {
      expect(gate.contains('if (_pqNoticeShown) return;'), isTrue);
      expect(gate.contains('await ctrl.dismissPqUpgradeNotice();'), isTrue);
    });

    // A returning user on a new device is not covered, and telling them they
    // are would be false.
    test('a device needing the code is told to link, not that it is covered',
        () {
      expect(gate.contains('final linkNeeded = ctrl.pqRootLinkNeeded;'), isTrue);
      expect(gate.contains('Add your post-quantum recovery code'), isTrue);
      expect(gate.contains('this device does not have it yet'), isTrue);
    });

    test('and the timer is cancelled on dispose', () {
      expect(gate.contains('_pqNoticeDelay?.cancel();'), isTrue);
    });
  });

  // The modal is the "view" half as much as the "edit" half, so the pubkey is
  // read on open rather than discovered by tapping four characters.
  group('the Nym details modal', () {
    test('it is titled for viewing as well as editing', () {
      expect(modal.contains("View or Edit Nym's Details"), isTrue);
      expect(modal.contains("Change Nym's Details"), isFalse);
    });

    test('the pubkey panel is open, not behind a tap', () {
      expect(modal.contains('_pubkeySlideout(c),'), isTrue);
      expect(modal.contains('if (_pubkeyOpen)'), isFalse);
      expect(modal.contains('_pubkeyOpen'), isFalse,
          reason: 'the toggle state is gone entirely, not just unused');
    });

    test('the suffix no longer advertises a reveal that does not exist', () {
      expect(modal.contains('Click to view full pubkey'), isFalse);
      expect(modal.contains('Click the #'), isFalse);
    });

    test('copy and swap read the same as the context menu', () {
      expect(modal.contains("tr('Copy npub')"), isTrue);
      expect(modal.contains("tr('Copy hex pubkey')"), isTrue);
      expect(modal.contains("tr('Show hex')"), isTrue);
      expect(modal.contains("tr('Show npub')"), isTrue);
    });

    test('the swap button carries the same glyph as the context-menu row', () {
      expect(modal.contains('icon: NymIcons.ctxSwapFormat'), isTrue);
      final icons = File('lib/widgets/nym_icons.dart').readAsStringSync();
      expect(icons.contains('ctxSwapFormat'), isTrue);
      // Same path data as the PWA's #ctxTogglePubkeyFormat.
      expect(icons.contains('M 2 6 L 12 6'), isTrue);
    });

    test('the format switch still writes the shared preference', () {
      expect(modal.contains('writePubkeyFormat(prefs, next)'), isTrue,
          reason: 'one preference, so the context menu agrees');
    });

    // The panel explains where the nickname's #suffix comes from, so it has to
    // come first: the nickname field below it is the thing being explained.
    test('the pubkey panel is built above the nickname group', () {
      final pk = modal.indexOf('_pubkeySlideout(c),');
      final nick = modal.indexOf('_nicknameGroup(c),');
      expect(pk, greaterThan(-1));
      expect(nick, greaterThan(-1));
      expect(pk, lessThan(nick));
    });

    test('the nickname field carries no hint of its own', () {
      expect(modal.contains('ephemeral pseudonym'), isFalse,
          reason: 'the panel above explains the suffix now');
      expect(
          kAppStringsCatalog.any(
              (s) => s.contains('the start of your public key')),
          isFalse,
          reason: 'and the sentence that said so is gone from the catalog');
    });

    test('the panel explains the suffix, and gets it the right way round', () {
      final para = kAppStringsCatalog.firstWhere(
          (s) => s.startsWith('A "pubkey" aka "public key"'));
      expect(
          para,
          endsWith('The four characters after the # in a nickname are the '
              'last four of the hex spelling.'));
      expect(modal.contains('last four of the hex '), isTrue);
    });
  });

  group('every new string is translatable', () {
    // A string missing from the catalog stays English in every other language,
    // silently, and only in this one panel.
    test('the recovery-code strings are in the sweep catalog', () {
      for (final s in const [
        'Post-quantum recovery code',
        'Post-quantum recovery code copied',
        "Reveal this nym's private key and recovery code",
        'Link',
        'Linked. This device can now read your quantum-resistant messages.',
        'That code does not match this account. Check it and try again.',
      ]) {
        expect(kAppStringsCatalog, contains(s), reason: s);
      }
    });

    test('so are the two long ones, exactly as concatenated', () {
      expect(
          kAppStringsCatalog,
          contains('This code, not your nsec, is what makes your messages '
              'quantum-resistant. Copy it to any other device you use this '
              'account on. Store it with your nsec and never share it.'));
      expect(
          kAppStringsCatalog,
          contains('This device has no recovery code yet. Paste the one from a '
              'device that already has it — you will find it in this same '
              'panel there — so both can read the same quantum-resistant '
              'messages.'));
    });
  });
}
