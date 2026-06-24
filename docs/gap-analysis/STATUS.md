# Implementation status — UI/UX fidelity pass

Of the ~157 gaps in this folder, the large majority are **implemented, verified, and
pushed** across three commits (Batch 1, Batch 2, integration wiring). The whole project
passes `flutter analyze` (0 errors / 0 warnings) and the full **554-test suite**.

## Landed (all blockers + the great majority of high/medium)
- **Cosmetics now render on messages**: auras (gold/neon/prism/phoenix/cosmic/hologram/
  frost), glitch chromatic shadows, per-glyph glow, supporter gold, Genesis edition stamp
  + bold nym, `redacted`; tiled style watermarks (satoshi/matrix/eclipse/CRT).
- **Chat**: `/me` action lines, in-list system/action pills, horizontal link-preview card,
  reader-avatar receipts, emoji-only enlarge, IRC `(edited)`, gallery geometry,
  blur-others-images, in-message **P2P file-offer card**.
- **Context menu**: full profile card (banner/status/bio/dev-bot/owner-mod/verified/friend/
  real avatar), **Report submit publishes** (NIP-56), **quick-context-menu** on long-press
  (Slap/Hug/Zap/Quote/Copy/Translate/Edit/Delete), action icons, dim, recents in pickers.
- **Composer**: quote/edit chips (prepend at send), mention rows with badges, geohash
  location, emoji favorites, image+video upload, in-composer translate, popout.
- **Shell**: 1024 tablet breakpoint + off-canvas drawer, desktop header pills + notif badge,
  whole-sidebar scroll, PM long-press menu, mobile toggles, sidebar globe/new-PM, section
  collapse+reorder persistence, per-column unread + scroll-to-bottom, PM/group deck columns.
- **Settings**: live removable Blocked/Friends/Keywords/Hidden lists, Add-Keyword/Clear-
  Cache/Reset wired, About version + links + contact form, PM-only mode row hiding, cache
  readout, landing-channel field, proximity prompt, vault launcher.
- **Calls**: flying reactions (both directions), presenter/screenshare menu, in-call chat
  reactions, status toasts → **notification-history panel**, @mention autocomplete, read
  receipts + typing, decorated nyms, video-grid breakpoints, switch-cam gating, transfer
  speed+retry, missed-call entries, incoming-call pulse.
- **Globe**: per-pixel heatmap palette accumulation, info panel, hover, legend, narrow select.
- **Modals**: nick-edit prefill (no bio wipe), new-PM group section, shared confirm/prompt,
  devNsec reserved-nick, setup file pickers.
- **Onboarding/Nymbot/Zaps**: tutorial element spotlight, bot `?`-command palette + welcome
  bubble + price labels, zap "I've paid" verify button + success pop.

## Deferred (documented; reasons are real — bigger rewrites or missing inputs)
- **Columns deck**: mobile snap-carousel + desktop drag-reorder (large rewrite; deck renders
  the horizontal column scroller at all widths). Exact `.channel-header-controls` 2-col grid.
- **Globe**: admin-1 state borders + city labels — need `ne_50m_*` datasets not bundled
  (`assets/data/` has only `countries-110m.json`).
- **Shop**: full per-style SVG watermark fidelity (shipped the 4 highest-value); inset
  box-shadow rings approximated as outset glows (Flutter has no inset BoxShadow).
- **Chat**: flood-dim (no flooding tracker in native state); inline video playback (media slice).
- **Calls**: stale-invite (>60s) missed-call needs `created_at` in the rumor map.
- **Settings**: real on-disk cache byte-wipe (needs a CacheStore hook); About contact PM
  send (needs `NostrController.sendContactMessage`); pending-settings-transfers list (no
  data source surfaced).
- **Not-yet-wired cross-slice hooks** (optional; features work without): BootGate → tutorial
  sidebar driver (mobile only; tutorial centers gracefully); `SettingsController.reloadFromStore`
  for live reset revert; `createGroup` avatar/banner/description/allowInvites threading;
  encrypt-at-rest prompt trigger; gift-credits modal observer.

See each `NN-*.md` report for the precise PWA references and fix recipes for the deferrals.
