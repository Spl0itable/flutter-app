# PWA→Flutter parity — re-audit + remaining work

A fresh line-by-line re-audit of the Flutter app against the **live PWA source**
(`Spl0itable/NYM` `js/`, `css/`, `index.html`) was run across all 10 slices plus a
dedicated settings, Nymbot-chat, stub, and CSS sweep. Contrary to the earlier
`STATUS.md` ("COMPLETE / nothing deferred"), the re-audit found the port is *high
fidelity* but **not** 1:1 — there are real, verified gaps. Each item below was
confirmed by reading BOTH sides; line refs are exact.

## Fixed in this pass (verified: `flutter analyze` clean, 675 tests green)

- **Nymbot premium chat UI** now flows through the canonical message bubble
  (`message_row`/`MessageContent`): full markdown/link/emoji/mention/code
  formatting (was raw `Text`), correct fills (bot white@0.14 / self primary@0.25),
  16px+4px-tail radius, 32px avatar + blue (#1DA1F2) verified name line, in-bubble
  relative timestamp, borderless, settings-driven text size, same-author grouping.
- **Slash-command modal hooks** wired into the composer (were registered as a bare
  system-message sink, so every modal command silently no-opped): `/poll` (also
  added the missing `case 'poll'` — the poll editor had zero call sites), `/zap`,
  `/pm`, `/group`, `/addmember`, `/invite`, `/groupinfo`, `/kick`, `/ban`,
  `/addmod`, `/removemod`, `/transferowner`.
- **Settings — Proof of Work Difficulty**: now threaded into both
  `publishChannelMessage` call sites (was saved/synced but never read).
- **Settings — Cache PMs & Group Chats**: disabling now wipes the existing cached
  PM/group rows (`clearPmGroupCache`), honoring the hint (was flag-only).
- **Chat — custom-emoji-only enlarge**: `:customcode:`-only messages now render at
  2.75em (ported `isCustomEmojiOnly`).
- **Chat — inline `code`** now a rounded pill (padding 2×6, radius 5) via WidgetSpan.
- **Chat — supporter author nym** no longer gold-tinted (`.message-header` is a dead
  PWA selector; only `.message-content` golds).
- **Context menu — profile-only** now shows Edit Profile for self (PWA keeps it).
- **Setup invite banner** decodes the group name (`…join "<name>".`).
- Corrected misleading "stub/TODO/no-op" comments on already-wired features (NIP-56
  report publish, gift-credits observer).

## Remaining — prioritized (verified gaps, with fix approach)

### High value
- **Nymbot hardcore keypair mode** — `keypairMode=='hardcore'` collapses to
  per-session rotation; the PWA rotates the keypair + nym after EVERY send, but only
  in ephemeral connection mode (messages.js:2399). Needs a per-message identity
  rotate in the channel send path (touches IdentityService — do carefully).
- **Wallpaper "Upload"** — the custom-image render path exists
  (`wallpaper_layer.dart:134`, reads `wallpaperCustomUrl`) but nothing writes it.
  Wire an image picker on the Upload tile → copy to app dir → store path → render
  `FileImage` (renderer currently assumes a remote URL).
- **Self-zap → own badge** (zaps.js `_recordOwnMessageZap`) — `zap_modal._markPaid`
  only haptics; should `recordMessageZap` for `widget.messageId`. CAUTION: verify
  the dedupKey matches the public kind-9735 receipt ingestion path or it will
  double-count.
- **Private (PM/group) zap announce** (zaps.js `_publishOwnPrivateZapEvent`) — no
  Flutter equivalent; peers never see PM/group zaps.
- **Columns mode loses header + composer** — `home_shell.dart:178` swaps the whole
  `ChatPane` for `ColumnsDeck`; the PWA keeps the chat header (pills/notif/nav/
  favorite/share/call) and the composer, driven by the focused column. Render the
  deck in place of the message list inside `ChatPane`.
- **Public-channel/geohash mention notifications** — `nostr_controller.dart:902`
  only records `group`/`pm`; channel mentions are never recorded, and
  `notifications_panel._openEntry` has no geohash/channel route (falls to PM).
- **Globe heatmap ignores D1 activity** — `geohash_channel.dart:46` counts only
  locally-loaded messages (drops count<1); thread the D1 activity buckets in +
  refetch on explorer open / 30s tick.

### Medium
- Shop: owned styles/flair/special show ACTIVATE not GIFT on non-inventory tabs
  (shop_modal:883); limited soon/ended/soldout footer still shows the ⚡ price row;
  bundles missing GIFT + show a spurious "Owned" chip; IRC-layout auras miss the
  inset ring/glow; redacted author treatment; guard empty Limited/Bundles titles.
- Chat: clickable timestamp → full-date popup; Read-more height truncation (>400/600
  chars → 300px max); image/video tap → fullscreen + gallery nav; `nm-mention` tap →
  user context menu; blockquote tap → jump-to-source; optimistic pending/failed send
  states; `(edited)` IRC marker should span the full row.
- Composer: gate input + Image/File/Emoji/GIF buttons on the same connect flag as
  SEND (inert until relays connect); `:`-autocomplete custom-emoji recents render as
  text not image + show `::code::`; `?`-bot PM subcommands; SEND anon eligibility via
  `ref.watch`.
- Context menu: `addToGroup` should open the New-Group modal seeded with the peer,
  not immediately create an empty 2-person group; add-members picker needs
  autocomplete.
- Calls: file-offer card shows no live %/speed; blocking a peer mid-call has no
  effect (1:1 end / group drop + grid filter); in-call chat rows lack sender shop
  cosmetics.
- Zaps: quick-zap is cache-only (wrongly says "cannot receive zaps" before the LN
  address resolves); zap-burst animation; poll voters modal omits each voter's
  choice; zap tooltip "(N unverified)" suffix.
- Settings: Low Data Mode should be the `.nym-switch` toggle, not a dropdown
  (promote the modal-private `_NymSwitch` to `lib/widgets/common/`).

### Low / cosmetic
- Sidebar "view more" should step by 500 (currently expands fully); shared
  navigation history across single + columns; remove-column confirm dialog;
  add-column search field; tutorial card placement should fall back when it doesn't
  fit; `bubble-snap` insert animation; reaction-badge hover tooltip (desktop).

## Platform-limited (correct to stub — not gaps)
WebTorrent large-file seeding (native fallback to direct-WebRTC), WebAuthn-PRF vault
key (biometric device-secret stand-in), FCM push (the PWA has no push at all),
Nymbot/shop live-host settlement (real calls wired; host unreachable in dev).
