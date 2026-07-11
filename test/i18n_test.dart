import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/features/i18n/i18n.dart';
import 'package:nym_bar/features/i18n/language_select.dart';
import 'package:nym_bar/features/i18n/localization_service.dart';

void main() {
  group('tr() in English (unconfigured) mode', () {
    test('returns the source string verbatim', () {
      expect(tr('Settings'), 'Settings');
      expect(tr('All set!'), 'All set!');
    });

    test('substitutes {placeholders} from args', () {
      expect(
        tr('Step {n} of {total}', {'n': 1, 'total': 12}),
        'Step 1 of 12',
      );
      expect(tr('{count} votes', {'count': 3}), '3 votes');
    });

    test('leaves unknown placeholders intact', () {
      expect(tr('Hi {name}', {'other': 'x'}), 'Hi {name}');
    });

    test('no-args templates are returned unchanged', () {
      expect(tr('Plain label'), 'Plain label');
      // A literal brace with no args is left as-is (no substitution attempted).
      expect(tr('Use {braces} literally'), 'Use {braces} literally');
    });

    test('String extension mirrors the function', () {
      expect('Language'.tr(), 'Language');
      expect('Hi {name}'.tr({'name': 'Ada'}), 'Hi Ada');
    });
  });

  group('LocalizationService', () {
    test('is inactive for empty / en language codes', () {
      final svc = LocalizationService.instance;
      svc.setLanguage('');
      expect(svc.isActive, isFalse);
      svc.setLanguage('en');
      expect(svc.isActive, isFalse);
    });
  });

  group('UI language options', () {
    test('English is pinned first and stored as an empty code', () {
      expect(kUiLanguageOptions.first.code, '');
      expect(kUiLanguageOptions.first.name, 'English');
    });

    test('includes many languages, none duplicating the English pin', () {
      expect(kUiLanguageOptions.length, greaterThan(100));
      expect(
        kUiLanguageOptions.where((o) => o.code == 'en'),
        isEmpty,
      );
    });

    test('uiLanguageName resolves codes and defaults to English', () {
      expect(uiLanguageName(''), 'English');
      expect(uiLanguageName('en'), 'English');
      expect(uiLanguageName('es'), 'Spanish');
      expect(uiLanguageName('fr'), 'French');
    });
  });
}
