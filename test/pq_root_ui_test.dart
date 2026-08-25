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
