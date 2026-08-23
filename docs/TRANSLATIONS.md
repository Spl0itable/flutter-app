# Interface translations

The app's interface is available in 132 languages. This document is about where
those translations come from, because the answer is "not this repository".

## How it works

Every string the app shows in a non-English language reaches it one of two ways:

1. **A pre-translated pack**, fetched once when a language is selected:
   `https://web.nymchat.app/i18n/<lang>.json`, a flat map of English source to
   translated string. This is the fast path, and it answers almost everything.
2. **On demand**, through the translation proxy, one request per string, cached
   on the device. This is the fallback for anything the pack does not carry — a
   string added since the last translation run, or one the extractor could not
   see.

Before the packs existed, (2) was the only path: picking a language meant
re-translating around 1300 strings on the device, filling in over tens of
seconds, and every user paid again for work every user before them had already
paid for. The packs turn that into a single fetch.

`LocalizationService._primeFromPack` does the fetching. A missing, malformed or
unreachable pack is not an error — it leaves the on-demand path exactly as it
was — and an on-device translation is never overwritten by one from a pack,
since the device's copy is either from the pack already or newer than it.

## Refreshing them

**The pipeline lives in the NYM repository, not here.** This is a Dart project
with no Node toolchain, so there is no `npm run i18n` to run in it:

```sh
# in the NYM repo, NOT flutter-app
npm run i18n            # translate anything not already cached
npm run i18n -- --list  # coverage report, no network
npm run build           # emit dist/i18n/<lang>.json
```

The results are committed there under `i18n/cache/`, so a language is paid for
once by whoever runs the sync rather than once per user who selects it.

## The one thing to remember

The source strings are collected from two places, and one of them is this
repository's `lib/features/i18n/app_strings_catalog.dart` — read through the
NYM repo's `android-ios-app/` directory, which is a **mirror** of this one
synced at release time.

So: **sync `android-ios-app/` in the NYM repo from here before running the
translation**, or the packs are built from the previous release's copy of the
catalog. Nothing breaks if you forget — those strings simply fall back to the
on-demand path — but they arrive slowly instead of instantly.

Adding a string to `kAppStringsCatalog` is what makes it eligible. A string
passed to `tr()` but absent from the catalog still works and still gets
translated on demand; it just never makes it into a pack.
