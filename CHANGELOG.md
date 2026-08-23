# Changelog

All notable changes to Nymchat are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each released version corresponds to a tag on
[github.com/Spl0itable/NYM](https://github.com/Spl0itable/NYM/releases).

## [3.74.533] - 2026-08-23

### Fixed
- Post-quantum keys are now announced on a first connect, not only after a
  reconnect, so a newly signed-in account is discoverable straight away.
- The announcement no longer rides the tail of the archive restore, which
  could skip it for a whole session when that restore was throttled or failed.
- Peers' announced keys survive a relaunch, so the first message after a
  restart is post-quantum instead of falling back to classical while
  discovery re-runs.
- Key lookups check the archive before fanning out to relays, and wait past
  the first "nothing here" answer, both of which could leave a conversation
  classical between two capable clients.

## [3.73.533] - 2026-08-22

### Added
- WYSIWYG text editor for the message composer.
- Inline image and video previews in messages.

## [3.73.532] - 2026-08-21

### Fixed
- All commands now appear in the app's localized language.

## [3.73.531] - 2026-08-20

### Fixed
- Various bug fixes.

## [3.73.530] - 2026-08-20

### Added
- Bluetooth mesh in supporting browsers.

## [3.73.529] - 2026-08-20

### Fixed
- Sidebar bugs.

## [3.73.528] - 2026-08-19

### Fixed
- Multiple bug fixes.

## [3.73.527] - 2026-08-19

### Fixed
- Many bug fixes and performance improvements.

## [3.73.526] - 2026-08-19

### Fixed
- Performance improvements.

## [3.73.525] - 2026-08-19

### Fixed
- Bugs when leaving groups.
- Sidebar now shows channel locations.

## [3.73.524] - 2026-08-18

### Fixed
- Further bug fixes with Nymbot premium models.

## [3.73.523] - 2026-08-18

### Fixed
- Many bugs related to Nymbot premium models.

## [3.73.522] - 2026-08-17

### Changed
- Local message store is now an encrypted SQLite database.

## [3.73.521] - 2026-08-17

### Changed
- Refinements to the encrypted group chats implementation.

## [3.73.520] - 2026-08-14

### Fixed
- Missed inline script breaking CSP.
- Stale messages showing as new.

## [3.73.519] - 2026-07-11

### Added
- Localized translation of the entire app.
- Auto-translate messages into your preferred language.

[3.73.533]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.533
[3.73.532]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.532
[3.73.531]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.531
[3.73.530]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.530
[3.73.529]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.529
[3.73.528]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.528
[3.73.527]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.527
[3.73.526]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.526
[3.73.525]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.525
[3.73.524]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.524
[3.73.523]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.523
[3.73.522]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.522
[3.73.521]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.521
[3.73.520]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.520
[3.73.519]: https://github.com/Spl0itable/NYM/releases/tag/v3.73.519
