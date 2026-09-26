// Nymbot's greeting is the first thing a new user reads, and it has to be in
// the language they just picked at signup.
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/nymbot/nymbot_providers.dart';
import 'package:nym_bar/features/translate/translate_target.dart';

void main() {
  group('localizeBotWelcome', () {
    test('routes both welcome messages through the UI-string cache', () {
      // English (no active language) is a pass-through, so the assertion here
      // is that the welcome ids are the ones recognized — the transient
      // in-chat welcome and the persisted first-contact PM.
      expect(localizeBotWelcome('nymbot-welcome', botWelcomeText),
          botWelcomeText);
      expect(
        localizeBotWelcome('nymbot-welcome-1750000000', botFirstContactText),
        botFirstContactText,
      );
    });

    test('leaves every other message untouched', () {
      const peerText = 'a message from another person';
      expect(localizeBotWelcome('some-event-id', peerText), peerText);
      expect(localizeBotWelcome('nymbot-info-123-4', peerText), peerText);
    });
  });

  test('the primeable copy is exactly the two welcome strings', () {
    // What gets pre-translated when the language is chosen at signup.
    expect(botWelcomeSourceStrings(),
        containsAll(<String>[botWelcomeText, botFirstContactText]));
    expect(botWelcomeSourceStrings(), hasLength(2));
  });
}
