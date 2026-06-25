# PWA→Flutter parity — re-audit + remaining work

A fresh line-by-line re-audit of the Flutter app against the **live PWA source**
(`Spl0itable/NYM` `js/`, `css/`, `index.html`) was run across all 10 slices plus a
dedicated settings, Nymbot-chat, stub, and CSS sweep. The port was high-fidelity
but **not** 1:1; this pass then implemented the great majority of the verified
gaps, slice by slice. Each change below was confirmed against BOTH sides and ships
with `flutter analyze` clean + the full **675-test** suite green.

## Implemented in the slice-by-slice pass

- **Nymbot chat** flows through the canonical message bubble (MessageContent
  formatting, fills, 16+4 tail, avatar + blue ✓ name line, in-bubble timestamp,
  grouping).
- **Slash commands** (`/poll /zap /pm /group /addmember /invite /groupinfo /kick
  /ban /addmod /removemod /transferowner`) un-stubbed — the composer now passes
  the modal hooks; `/poll` reaches the (previously unreachable) editor.
- **Settings**: PoW difficulty wired into the send path; Cache-PMs disable wipes
  cached rows; **custom wallpaper upload** (image picker → app-dir file → render);
  **Low Data Mode** is the `.nym-switch` iOS toggle (promoted to a shared widget).
- **Chat**: custom-emoji-only enlarge; inline-`code` pill; **tap-to-zoom fullscreen
  image viewer** with gallery paging; tappable full-timestamp popup; **read-more
  height truncation**; IRC `(edited)` hoisted to full-row width; **tappable
  `@mention` → user context menu**.
- **Shop**: owned→GIFT (not ACTIVATE); limited footer label-only; bundle gifting +
  no spurious "Owned" chip; empty section-title guards; IRC-layout aura ring+glow;
  redacted author white@0.8; per-card descriptions on every tab.
- **Composer**: inert until relays connect; `:` custom-emoji recents render as
  images (no `::code::`); `?`-bot PM subcommand palette; reactive ANON
  eligibility; mention dev/bot tooltip.
- **Calls/P2P**: live transfer %/speed; block-in-call (1:1 end / group drop + grid
  filter + chat hide); in-call chat shop cosmetics.
- **Zaps**: instant self-zap badge (dedup-safe); poll-voter choices + tap-to-PM;
  **live ⚡ zap-burst** when a total ticks up.
- **Context menu / setup**: profile-only Edit Profile (self); invite-banner group
  name; corrected misleading "stub/TODO" comments on already-wired features
  (NIP-56 report publish, gift-credits observer, custom-emoji live stream).
- **Notifications**: channel/geohash @-mentions route to the channel
  (switchChannel), not the sender's PM.
- **Globe**: D1-discovered activity feeds the heatmap (presence floor — the native
  store folds D1 hourly buckets into a single last-seen ms, so an exact per-bucket
  count is unavailable); seed geohashes are candidates; refetch on explorer open +
  30s tick; isJoined unions favorites.
- **Shell**: **columns mode keeps the chat header + composer** (deck substitutes
  only the messages-list region; focusing a column re-targets the shared
  composer); remove-column confirm + "don't ask again"; add-column search; sidebar
  nyms "view more" steps by 500.

## Genuinely remaining (hard / niche — need careful design, intentionally not rushed)

- **Hardcore keypair mode** (`keypairMode == 'hardcore'`): the PWA rotates the
  *durable* ephemeral identity + nym after EVERY send (messages.js:2399), only in
  ephemeral-login mode. The fresh-per-message keypair primitive exists (the ANON
  path), but rotating the live identity mid-session + refreshing presence/sidebar/
  the signer is correctness-sensitive identity work; it currently behaves like
  `random` (per-session). Needs an IdentityService rotate + a post-send hook.
- **Private (PM/group) zap announce** (zaps.js `_publishOwnPrivateZapEvent`): peers
  don't see PM/group zaps — needs a gift-wrapped own-message zap publish.
- **Quick-zap LN resolve** (zaps.js `handleQuickZap`): the badge quick-zap reads
  only the cached lightning address; if uncached it wrongly says "cannot receive
  zaps". Needs an awaitable profile/LN-address resolve (the relay model has no
  request/response fetch today).
- **Unverified-zap tooltip suffix** (`(N unverified)`): needs `MessageZaps` to
  track unverified sats + the receipt parser to mark verified vs not.
- **Blockquote tap-to-jump** and **spam false-positive actionable row**: status
  tracked in the latest chat round — deferred if the scroll-to-message anchor
  infra / local own-message spam flag don't exist yet (do not half-build).
- A message that is *purely* one long blockquote isn't height-truncated (the
  read-more path keys off the reply body); rare edge.

## Platform-limited (correct to stub — not gaps)
WebTorrent large-file seeding (native fallback to direct-WebRTC), WebAuthn-PRF
vault key (biometric device-secret stand-in), FCM push (the PWA has no push at
all), Nymbot/shop live-host settlement (real calls wired; host unreachable in dev).
