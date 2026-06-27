import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/channels/channel_share.dart';
import '../../features/notifications/notifications_panel.dart';
import '../../features/onboarding/tutorial_overlay.dart';
import '../../features/p2p/p2p_transfers_modal.dart';
import '../../features/settings/about_screen.dart';
import '../../features/settings/settings_helpers.dart' show geohashLocationLabel;
import '../../features/settings/settings_screen.dart';
import '../../features/shop/cosmetics.dart';
import '../../features/shop/shop_modal.dart';
import '../../models/channel.dart';
import '../../models/group.dart';
import '../../models/user.dart';
import '../../services/api/api_client.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../common/app_dialog.dart';
import '../common/nym_avatar.dart';
import '../nym_icons.dart';
import '../context_menu/context_menu_actions.dart' show CtxTarget;
import '../context_menu/context_menu_panel.dart' show ContextMenuPanel;
import '../context_menu/group_context_menu_panel.dart'
    show GroupContextMenuPanel;
import '../columns/columns_deck.dart';
import 'message_row.dart' show formatRelativeTime;
import 'composer.dart';
import 'messages_list.dart';

/// Signature for the call-start hook the calls feature wires later. [peer] is
/// the PM peer pubkey (or '' for a channel/group), [video] selects video vs
/// audio. The header never implements calls itself — it only invokes this.
typedef OnStartCall = void Function(String peer, {required bool video});

/// Signature for starting a group call (group id + video flag).
typedef OnStartGroupCall = void Function(String groupId, {required bool video});

/// The main chat column: header + messages list + composer
/// (`main.main-content`, docs/specs/02 §1.1, §5.4–5.5).
class ChatPane extends ConsumerWidget {
  const ChatPane({
    super.key,
    this.onOpenSidebar,
    this.compact = false,
    this.onStartCall,
    this.onStartGroupCall,
    this.useColumns = false,
  });

  /// Mobile/tablet: opens the off-canvas sidebar drawer (hamburger).
  final VoidCallback? onOpenSidebar;

  /// Mobile/tablet chrome (hamburger + stacked composer). Driven by
  /// `width <= 1024` so the mobile header shows across the whole 0–1024 range.
  final bool compact;

  /// Optional call-start hooks (wired by the calls feature; null = no calls).
  final OnStartCall? onStartCall;
  final OnStartGroupCall? onStartGroupCall;

  /// Columns (deck) mode (`body.columns-mode`). The PWA hides ONLY
  /// `#messagesScroller` (styles-columns.css:9-11) and shows `#columnsStrip` in
  /// its place — the `.chat-header` and `.input-container` stay mounted, driven
  /// by the focused column (`_cvFocusColumn` points the shared composer at the
  /// focused column's conversation, columns.js:542-559). So in columns mode we
  /// substitute the deck for the messages region only, keeping the header above
  /// and the composer below.
  final bool useColumns;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      // `.main-content` is TRANSPARENT (styles-shell.css:730 — no background) so
      // the fixed `#wallpaperLayer` (mounted behind this pane in `home_shell`)
      // shows through. The opaque base comes from the Scaffold (`c.bg`); the
      // header/composer paint their own `--glass-bg` surfaces and the messages
      // area paints only a translucent wash (`rgba(0,0,0,0.15)` / light
      // `rgba(255,255,255,0.3)`), so the wallpaper reads through the message
      // region in both single-chat and columns views. Painting an opaque `c.bg`
      // here (the old behaviour) covered the wallpaper everywhere.
      color: Colors.transparent,
      child: Column(
        children: [
          _ChatHeader(
            onOpenSidebar: onOpenSidebar,
            compact: compact,
            onStartCall: onStartCall,
            onStartGroupCall: onStartGroupCall,
          ),
          // `#messagesContainer` (single view) / `#columnsStrip` (columns mode)
          // — the deck replaces only the messages list, not the header/composer.
          Expanded(
            // Tap-outside dismisses the soft keyboard (01-B3): a translucent
            // GestureDetector over the messages region drops focus when a tap
            // isn't consumed by an interactive child (message rows / buttons
            // still win the arena). Swipe-down dismissal lives in `MessagesList`
            // (`keyboardDismissBehavior: onDrag`). On the web/browser PWA this is
            // native browser behaviour; Flutter needs it wired explicitly.
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => FocusScope.of(context).unfocus(),
              child: KeyedSubtree(
                key: TutorialTargets.keyFor(TutorialTarget.messagesContainer),
                child: useColumns ? const ColumnsDeck() : const MessagesList(),
              ),
            ),
          ),
          // `.input-container` — tutorial spotlight target. Stays mounted in
          // columns mode; sends to the focused column's conversation (the deck
          // re-points `currentViewProvider` on focus, mirroring `_cvFocusColumn`).
          KeyedSubtree(
            key: TutorialTargets.keyFor(TutorialTarget.composer),
            child: Composer(compact: compact),
          ),
        ],
      ),
    );
  }
}

/// `.chat-header`: title (primary, textSize+3, weight700) + meta line + nav and
/// action icon buttons. Mobile shows the hamburger + a notification toggle.
class _ChatHeader extends ConsumerStatefulWidget {
  const _ChatHeader({
    this.onOpenSidebar,
    required this.compact,
    this.onStartCall,
    this.onStartGroupCall,
  });
  final VoidCallback? onOpenSidebar;
  final bool compact;
  final OnStartCall? onStartCall;
  final OnStartGroupCall? onStartGroupCall;

  @override
  ConsumerState<_ChatHeader> createState() => _ChatHeaderState();
}

class _ChatHeaderState extends ConsumerState<_ChatHeader> {
  // A simple back/forward navigation history (channels.js `navigationHistory` /
  // `navigationIndex`). Each entry is a [ChatView]. Forward is disabled when at
  // the tip; back is disabled at the start (like the PWA).
  final List<ChatView> _history = [];
  int _index = -1;
  bool _navigating = false;

  // Per-geohash reverse-geocoded place-name cache feeding `.channel-location`
  // (mirrors `_geohashPlaceCache`, channels.js:1058/1070). Keyed by lowercased
  // geohash → resolved "city, country" (or "Unknown location"). A monotonic
  // token (mirrors `_geocodeToken`, geohash_explorer.dart:382) guards against a
  // stale response overwriting the cache after the active view has changed.
  final ApiClient _api = ApiClient();
  final Map<String, String> _placeCache = {};
  // Geohashes with a resolve already in flight, so the build path doesn't fire
  // a duplicate request every rebuild.
  final Set<String> _placePending = {};
  int _geocodeToken = 0;

  bool get _canBack => _index > 0;
  bool get _canForward => _index >= 0 && _index < _history.length - 1;

  void _recordView(ChatView view) {
    if (_navigating) return;
    if (_index >= 0 && _history[_index] == view) return;
    // Truncate any forward entries, then push.
    if (_index < _history.length - 1) {
      _history.removeRange(_index + 1, _history.length);
    }
    _history.add(view);
    if (_history.length > 50) _history.removeAt(0);
    _index = _history.length - 1;
  }

  void _back() {
    if (!_canBack) return;
    _index--;
    _go(_history[_index]);
  }

  void _forward() {
    if (!_canForward) return;
    _index++;
    _go(_history[_index]);
  }

  void _go(ChatView view) {
    _navigating = true;
    ref.read(appStateProvider.notifier).switchView(view);
    // Reset the flag after the frame so didChangeDependencies doesn't re-record.
    WidgetsBinding.instance.addPostFrameCallback((_) => _navigating = false);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final compact = widget.compact;
    final settings = ref.watch(settingsProvider);
    final app = ref.watch(appStateProvider);
    final view = ref.watch(currentViewProvider);
    _recordView(view);

    final title = _titleFor(app, view);
    final meta = _metaFor(app, view);
    final metaText = meta.text;
    final titleSize = settings.textSize + 3.0;

    final isChannel = view.kind == ViewKind.channel;
    final channelKey = isChannel ? view.id.toLowerCase() : '';
    final isPinned = isChannel && app.pinnedChannels.contains(channelKey);
    final isDefault = channelKey == kDefaultChannel;

    // `.channel-info { gap: 15 }` (controls→title) + `.channel-title-wrap`
    // margins: 20/20 on desktop, 10/0 below 768px (the PWA phone breakpoint —
    // narrower than the ≤1024 `compact` chrome, so key off the real width).
    final phone = MediaQuery.of(context).size.width <= NymDimens.mobileBreakpoint;
    final titleLeftGap = 15.0 + (phone ? 10.0 : 20.0);
    final titleRightGap = phone ? 0.0 : 20.0;
    // `.channel-title { min-height: calc((user-text-size + 3) * 1.4 + 19px) }`
    // reserves room for the title line + the meta line beneath it.
    final headerMinHeight = titleSize * 1.4 + 19;

    // `.chat-header`: padding 16/24 (mobile 15/10, top 12); bg --glass-bg,
    // bottom hairline.
    return Container(
      decoration: BoxDecoration(
        color: c.glassBg,
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      padding: compact
          ? const EdgeInsets.fromLTRB(10, 12, 10, 15)
          : const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: SafeArea(
        bottom: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: headerMinHeight),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // `.channel-header-controls`: the back/forward + favorite/share
              // (channel) or audio/video (PM/group) cluster, LEFT of the title
              // at ALL widths (no breakpoint hides it; the PWA shows it on
              // mobile too — gap, MISSING). 28×28 desktop / 24×24 compact.
              _channelControls(
                view: view,
                isChannel: isChannel,
                channelKey: channelKey,
                isPinned: isPinned,
                isDefault: isDefault,
              ),
              SizedBox(width: titleLeftGap),
              Expanded(
                // `.channel-title-wrap`: 20px (desktop) / 10px (phone) side gaps.
                child: Padding(
                  padding: EdgeInsets.only(right: titleRightGap),
                  child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // `.channel-title` (#currentChannel): a plain `#name` for a
                    // channel; `.pm-header-row` (26px avatar + status dot + name)
                    // for a PM; `.group-header-row` (group glyph + stacked member
                    // avatars + name) for a group. The PWA nests a second
                    // `.channel-location` line (12px) inside `#currentChannel`
                    // beneath the title row, so it lives in this same block.
                    _titleLine(c, app, view, title, titleSize),
                    _locationLine(c, app, view),
                    // `.channel-meta` (#channelMeta): the 11px line below the
                    // title block — online-nym count (channel) or the E2E lock
                    // notice (PM/group).
                    if (metaText.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Lock glyph prefix for E2E PM/group meta (PWA
                          // `lockSvg`, 12px). Channel meta has no glyph.
                          if (meta.svg != null) ...[
                            NymSvgIcon(meta.svg!, size: 12, color: c.textDim),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: Text(
                              metaText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: c.textDim, fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                ),
              ),
              if (compact)
                _mobileActions()
              else
                // `.header-actions`: bounded so the text pills can wrap
                // (`flex-wrap:wrap`) rather than overflow on narrow desktops.
                Flexible(child: _headerActionPills()),
            ],
          ),
        ),
      ),
    );
  }

  /// The `.channel-title` content (`#currentChannel`). Channel → bare `#name`.
  /// PM → `.pm-header-row`: a 26px avatar with a status dot + the nym. Group →
  /// `.group-header-row`: the group glyph + up to four overlapping 18px member
  /// avatars (or the custom group avatar) + the name. The title text itself is
  /// primary / weight-700 / +3px in all three.
  Widget _titleLine(
    NymColors c,
    AppState app,
    ChatView view,
    String title,
    double titleSize,
  ) {
    final titleStyle = TextStyle(
      color: c.primary,
      fontSize: titleSize,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
    );
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: titleStyle,
    );

    switch (view.kind) {
      case ViewKind.channel:
        return titleText;

      case ViewKind.pm:
        final user = app.users[view.id];
        final status = user?.effectiveStatus() ?? UserStatus.offline;
        // `.pm-header-row`: `.pm-name-text` (base nym) + a dimmed `.nym-suffix`
        // (`#abcd`, 0.9em / w100 / opacity 0.7) + flair/supporter + verified ✓ +
        // friend badge, mirroring the PWA `displayNym` markup (pms.js:2920).
        final base = stripPubkeySuffix(title);
        final suffix = getPubkeySuffix(view.id);
        final nameRich = Text.rich(
          TextSpan(
            style: titleStyle,
            children: [
              TextSpan(text: base),
              if (suffix.isNotEmpty)
                TextSpan(
                  text: '#$suffix',
                  style: titleStyle.copyWith(
                    color: c.primary.withValues(alpha: 0.7),
                    fontSize: titleSize * 0.9,
                    fontWeight: FontWeight.w100,
                  ),
                ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );

        final controller = ref.read(nostrControllerProvider);
        final isDev = controller.isVerifiedDeveloper(view.id);
        final isBot = !isDev && controller.isVerifiedBot(view.id);
        final isFriend = app.friends.contains(view.id);
        final cosmetics = ref.watch(userCosmeticsProvider(view.id));

        // `.pm-header-avatar`: 26px round, margin-right 10, with a 7px status dot
        // (bottom-right -2) ringed by the bg. Hidden status drops the dot.
        final row = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                NymAvatar(
                  seed: view.id,
                  size: 26,
                  imageUrl: user?.profile?.picture,
                ),
                if (status != UserStatus.hidden)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: statusColor(status),
                        shape: BoxShape.circle,
                        border: Border.all(color: c.bg, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 10),
            Flexible(child: nameRich),
            // `.flair-badge` (20px, margin-left 5), `.verified-badge` (20×20,
            // margin-left 4), `.friend-badge` (20×20 svg) — the PWA sizes these
            // independently of the title text, so they stay 20px in the header.
            CosmeticNymBadges(
              cosmetics: cosmetics,
              flairSize: 20,
              supporterHeight: 20,
            ),
            if (isDev || isBot) ...[
              const SizedBox(width: 4),
              const _VerifiedBadge(size: 20),
            ],
            if (isFriend) ...[
              const SizedBox(width: 4),
              const _FriendBadge(size: 20),
            ],
          ],
        );
        // `.pm-header-row.header-clickable`: tap opens the contact's profile
        // context menu (pms.js:2931 `showContextMenu(..., profileOnly=true)`).
        return _HeaderClickable(
          onTap: () => _openPMProfile(view.id, '$base#$suffix', isBot),
          child: row,
        );

      case ViewKind.group:
        Group? found;
        for (final cand in app.groups) {
          if (cand.id == view.id) {
            found = cand;
            break;
          }
        }
        if (found == null) return titleText;
        final g = found;
        final customAvatar = g.avatar;
        final hasCustom = customAvatar != null && customAvatar.isNotEmpty;
        final others =
            g.members.where((pk) => pk != app.selfPubkey).take(4).toList();

        if (hasCustom) {
          // `.group-header-custom-wrap`: a 26px round custom avatar with
          // margin-right 4 (styles-features.css:5365-5377). The name carries no
          // extra margin in the custom-avatar case (`nameCls` is empty).
          return _HeaderClickable(
            onTap: () => GroupContextMenuPanel.show(context, g.id),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                NymAvatar(seed: g.id, size: 26, imageUrl: customAvatar),
                const SizedBox(width: 4),
                Flexible(child: titleText),
              ],
            ),
          );
        }

        // `.group-header-icon` (18px glyph) + stacked 18px `.group-header-avatar`s
        // (overlap −4, 1px bg ring) + name. The PWA clips this row
        // (`.group-header-row { overflow: hidden }`); to avoid a RenderFlex
        // overflow on a very narrow header we instead drop trailing avatars that
        // wouldn't fit, then let the name ellipsize in the remainder.
        return LayoutBuilder(
          builder: (context, constraints) {
            const double iconW = 18 + 5; // glyph + its 5px gap
            const double avatarStep = 14; // 18px avatar minus the 4px overlap
            // Reserve room for the glyph + a minimum name width; fit as many
            // avatars as the rest allows (cap 4).
            final avail = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 9999.0;
            final budget = avail - iconW - 40; // 40 ≈ minimum name slot
            var fit = others.length;
            if (budget < fit * avatarStep) {
              fit = (budget / avatarStep).floor().clamp(0, others.length);
            }
            final shown = others.take(fit).toList();

            final prefix = <Widget>[
              // `.group-header-icon` → `.group-header-svg` (18×18, stroke-width
              // 1.75, currentColor = `.channel-title` `--primary`), margin-right
              // 5 (groups.js:2910, styles-features.css:2480-2491).
              NymSvgIcon(NymIcons.groupGlyph, size: 18, color: c.primary),
              const SizedBox(width: 5),
            ];
            for (var i = 0; i < shown.length; i++) {
              prefix.add(Transform.translate(
                offset: Offset(i == 0 ? 0 : -4.0 * i, 0),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    // `.group-header-avatar { border: 1px solid var(--bg-primary) }`
                    // — `--bg-primary` is undefined in the PWA, so the declaration
                    // is invalid-at-computed-value and `border-color` falls back to
                    // `currentColor` = the `.channel-title` `--primary`.
                    border: Border.all(color: c.primary, width: 1),
                  ),
                  child: NymAvatar(
                    seed: shown[i],
                    size: 18,
                    imageUrl: app.users[shown[i]]?.profile?.picture,
                  ),
                ),
              ));
            }
            // `.nm-grp-ml8`: 8px gap before the name when avatars are shown
            // (offset by the cumulative overlap so the name doesn't drift right).
            if (shown.isNotEmpty) {
              prefix.add(SizedBox(
                  width: (8 - 4.0 * (shown.length - 1)).clamp(0.0, 8.0)));
            }
            // `.group-header-row.header-clickable`: tap opens the group context
            // menu (groups.js:2982 `showGroupContextMenu`).
            return _HeaderClickable(
              onTap: () => GroupContextMenuPanel.show(context, g.id),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...prefix,
                  Flexible(child: titleText),
                ],
              ),
            );
          },
        );
    }
  }

  /// Opens the PM contact's profile context menu (PWA `header-clickable` →
  /// `showContextMenu(..., profileOnly=true)`, pms.js:2931).
  void _openPMProfile(String pubkey, String nym, bool isBot) {
    if (pubkey.isEmpty) return;
    final state = ref.read(appStateProvider);
    ContextMenuPanel.show(
      context,
      target: CtxTarget(
        pubkey: pubkey,
        nym: stripPubkeySuffix(nym),
        isSelf: pubkey == state.selfPubkey,
        isBot: isBot,
        profileOnly: true,
      ),
    );
  }

  /// The `.channel-location` line nested inside `#currentChannel` beneath the
  /// title row (12px, text-dim, margin-top 2px). Per variant:
  /// - Channel (geohash): the resolved place name + optional ` (N.Nkm)` proximity
  ///   distance (channels.js `_renderChannelTitle`, 996-1032). We render the
  ///   coordinate label (`getGeohashLocation`) the PWA shows as its pre-resolve
  ///   fallback — async place-name resolution is owned by the channels service.
  /// - Channel (non-geohash): "Not a geohash".
  /// - PM: the live presence / last-seen line (pms.js `_pmLastSeenText`).
  /// - Group: "{N} members" (groups.js:2927).
  Widget _locationLine(NymColors c, AppState app, ChatView view) {
    final loc = _locationFor(app, view);
    if (loc.text.isEmpty) return const SizedBox.shrink();
    // `.channel-location`: font-size 12, color --text-dim, margin-top 2px.
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Flexible(
            child: Text(
              loc.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.textDim, fontSize: 12),
            ),
          ),
          // `.channel-location-dist`: never shrinks (`flex:0 0 auto`).
          if (loc.dist.isNotEmpty)
            Text(
              loc.dist,
              maxLines: 1,
              style: TextStyle(color: c.textDim, fontSize: 12),
            ),
        ],
      ),
    );
  }

  ({String text, String dist}) _locationFor(AppState app, ChatView view) {
    switch (view.kind) {
      case ViewKind.channel:
        final ch = app.channels.firstWhere(
          (c) => c.key == view.id,
          orElse: () => ChannelEntry(channel: view.id),
        );
        final gh = ch.isGeohash ? ch.geohash : view.id;
        if (!isValidGeohash(gh)) {
          // `loc-country` → "Not a geohash" for a named channel.
          return (text: 'Not a geohash', dist: '');
        }
        // `.channel-location` text (channels.js:1005-1006,1029): the resolved
        // reverse-geocoded place name when cached, "Loading location…" while a
        // geocode is in flight, and the coordinate label (`getGeohashLocation`)
        // only as the catch fallback. Kick off resolution for this geohash.
        final ghKey = gh.toLowerCase();
        final cached = _placeCache[ghKey];
        final String place;
        if (cached != null) {
          place = cached;
        } else {
          _resolvePlaceName(ghKey);
          place = 'Loading location…';
        }
        // ` (N.Nkm)` proximity, only with a known location + sortByProximity on.
        var dist = '';
        final settings = ref.watch(settingsProvider);
        final userLoc = ref.watch(userLocationProvider);
        if (settings.sortByProximity && userLoc != null) {
          try {
            final coords = decodeGeohash(gh);
            final km = calculateDistance(
                userLoc.lat, userLoc.lng, coords.lat, coords.lng);
            dist = ' (${km.toStringAsFixed(1)}km)';
          } catch (_) {}
        }
        return (text: place, dist: dist);
      case ViewKind.pm:
        return (text: _pmLastSeenText(app, view.id), dist: '');
      case ViewKind.group:
        for (final g in app.groups) {
          if (g.id == view.id) {
            return (
              text: '${_abbreviateCount(g.members.length)} members',
              dist: '',
            );
          }
        }
        return (text: '', dist: '');
    }
  }

  /// Reverse-geocodes a geohash → "city, country" and caches it under [ghKey]
  /// (lowercased geohash), mirroring `_resolveGeohashPlaceName`
  /// (channels.js:1058) + the explorer's `_fetchLocation`
  /// (geohash_explorer.dart:393-413). De-duped via [_placePending] so each
  /// geohash resolves once; a monotonic [_geocodeToken] (mirrors
  /// geohash_explorer.dart:382) keyed on the resolve order guards the rebuild so
  /// a stale response never forces a redundant setState after the view moved on.
  Future<void> _resolvePlaceName(String ghKey) async {
    if (_placeCache.containsKey(ghKey) || _placePending.contains(ghKey)) return;
    if (!isValidGeohash(ghKey)) return;
    _placePending.add(ghKey);
    final token = ++_geocodeToken;
    String result;
    try {
      final coords = decodeGeohash(ghKey);
      final data = await _api.geocode(coords.lat, coords.lng, zoom: 10);
      final addr = (data['address'] as Map?) ?? const {};
      String s(Object? v) => v is String ? v : '';
      final city = [
        s(addr['city']),
        s(addr['town']),
        s(addr['village']),
        s(addr['county']),
      ].firstWhere((x) => x.isNotEmpty, orElse: () => '');
      final country = s(addr['country']);
      result = [city, country].where((x) => x.isNotEmpty).join(', ');
      if (result.isEmpty) result = 'Unknown location';
    } catch (_) {
      // Catch fallback: the PWA drops to the raw coordinate label on geocode
      // failure (channels.js:1029).
      result = geohashLocationLabel(ghKey);
    }
    _placePending.remove(ghKey);
    // The result is cached by geohash (never the wrong key), so always store it;
    // only rebuild if still mounted and this was the latest resolve requested.
    _placeCache[ghKey] = result;
    if (!mounted || token != _geocodeToken) return;
    setState(() {});
  }

  /// PWA `_pmLastSeenText` (pms.js:36): bot → "Always at your service";
  /// hidden → ""; online → "Active now"; away → "Away"; else the relative
  /// last-seen ("Last seen 5m ago") or "Last seen unknown".
  String _pmLastSeenText(AppState app, String pubkey) {
    if (ref.read(nostrControllerProvider).isVerifiedBot(pubkey)) {
      return 'Always at your service';
    }
    final user = app.users[pubkey];
    final status = user?.effectiveStatus() ?? UserStatus.offline;
    if (status == UserStatus.hidden) return '';
    if (status == UserStatus.online) return 'Active now';
    if (status == UserStatus.away) return 'Away';
    final lastSeen = user?.lastSeen ?? 0;
    if (lastSeen > 0) {
      return 'Last seen '
          '${formatRelativeTime(DateTime.fromMillisecondsSinceEpoch(lastSeen))}';
    }
    return 'Last seen unknown';
  }

  /// `.mobile-header-actions`: the `.icon-btn`-class notif + hamburger toggles,
  /// gap 8, margin-left 12 (gap F14). The notif toggle carries the unread badge.
  Widget _mobileActions() {
    final unread =
        ref.watch(notificationHistoryProvider.select((s) => s.unread));
    final settings = ref.watch(settingsProvider);
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // `#p2pTransfersModal` trigger — present only while transfers/seeds
          // exist (`openP2PTransfersModal`, p2p.js:732).
          _transfersMobileToggle(),
          _MobileToggle(
            svg: settings.notificationsEnabled
                ? NymIcons.bell
                : NymIcons.bellOff,
            tooltip: 'Notifications',
            badge: unread,
            onTap: _openNotifications,
          ),
          const SizedBox(width: 8),
          _MobileToggle(
            svg: NymIcons.menu,
            tooltip: 'Menu',
            onTap: widget.onOpenSidebar,
          ),
        ],
      ),
    );
  }

  /// `.channel-header-controls` (LEFT of the title, all widths): a 2-column grid
  /// (`grid-template-columns:auto auto; row-gap:12; column-gap:2`) into which
  /// `.channel-nav-buttons` (back/forward) and `.channel-action-buttons` flow
  /// (both `display:contents`). The action buttons are **favorite + share** in a
  /// channel; **audio + video** in a PM/group (the PWA `calls.js` keeps the call
  /// buttons hidden unless `inPMMode && (currentPM||currentGroup)` — they are
  /// `nm-call-hidden` in channel view). No discover/new-PM/poll buttons live
  /// here — those are sidebar/composer actions in the PWA.
  Widget _channelControls({
    required ChatView view,
    required bool isChannel,
    required String channelKey,
    required bool isPinned,
    required bool isDefault,
  }) {
    final controller = ref.read(nostrControllerProvider);
    final isCall = view.kind == ViewKind.pm || view.kind == ViewKind.group;

    final buttons = <Widget>[
      // `.channel-nav-buttons` — boxed (28×28, radius 4, hover bg), dimmed.
      _NavBtn(
        svg: NymIcons.chevronLeft,
        tooltip: 'Go back',
        onTap: _canBack ? _back : null,
        disabled: !_canBack,
      ),
      _NavBtn(
        svg: NymIcons.chevronRight,
        tooltip: 'Go forward',
        onTap: _canForward ? _forward : null,
        disabled: !_canForward,
      ),
      // `.channel-action-buttons` — no box; hover scales 1.1 + tints primary.
      if (isChannel) ...[
        _ActionBtn(
          // `.favorite-channel-btn`: outline star (text-dim) → FILLED gold
          // (#f5c518) when `.active`.
          svg: isPinned ? NymIcons.starFilled : NymIcons.starOutline,
          tooltip: isDefault
              ? '#nymchat is always favorited'
              : (isPinned ? 'Unfavorite channel' : 'Favorite channel'),
          activeColor: isPinned ? const Color(0xFFF5C518) : null,
          disabled: isDefault,
          onTap: isDefault ? null : () => controller.togglePin(channelKey),
        ),
        _ActionBtn(
          key: TutorialTargets.keyFor(TutorialTarget.shareButton),
          // `.share-channel-btn`: the filled share-NODES glyph (not iOS share).
          svg: NymIcons.shareNodes,
          tooltip: 'Share channel URL',
          onTap: () => ShareChannelModal.open(context, channelKey),
        ),
      ] else if (isCall) ...[
        // PM/group only: audio + video (mirrors `_refreshCallButtons`).
        _ActionBtn(
          svg: NymIcons.phone,
          tooltip: 'Start audio call',
          onTap: () => _startCall(view, video: false),
        ),
        _ActionBtn(
          svg: NymIcons.video,
          tooltip: 'Start video call',
          onTap: () => _startCall(view, video: true),
        ),
      ],
    ];

    // `.channel-header-controls` is a FIXED 2-column CSS grid
    // (`grid-template-columns: auto auto; row-gap: 12; column-gap: 2`), so the
    // four buttons always form a 2×2 quadrant square — back/forward on top,
    // favorite/share (or audio/video) beneath. A `Wrap` would keep them on one
    // row whenever the header is wide enough, so stack explicit 2-up Rows in a
    // Column instead to force the 2×2 grid at every width.
    final rows = <Widget>[
      for (var i = 0; i < buttons.length; i += 2)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            buttons[i],
            if (i + 1 < buttons.length) ...[
              const SizedBox(width: 2), // column-gap
              buttons[i + 1],
            ],
          ],
        ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start, // justify-content: start
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 12), // row-gap
          rows[i],
        ],
      ],
    );
  }

  /// `.header-actions` (desktop, RIGHT): the text-pill group (Notifications +
  /// badge / Flair / Settings / About / Logout), wrapped (`flex-wrap:wrap`) —
  /// tutorial `mainMenu` target.
  Widget _headerActionPills() {
    final unread =
        ref.watch(notificationHistoryProvider.select((s) => s.unread));
    return KeyedSubtree(
      key: TutorialTargets.keyFor(TutorialTarget.mainMenu),
      child: Wrap(
        spacing: 5,
        runSpacing: 5,
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // `#p2pTransfersModal` trigger (`openP2PTransfersModal`, p2p.js:732):
          // only present while there are active transfers or seeds; the pill
          // appears/disappears live as the service notifies.
          _transfersPill(),
          _HeaderPill(
            svg: NymIcons.bell,
            label: 'Notifications',
            badge: unread,
            onTap: _openNotifications,
          ),
          _HeaderPill(
            svg: NymIcons.starFlair,
            label: 'Flair',
            onTap: () => ShopModal.open(context),
          ),
          _HeaderPill(
            svg: NymIcons.settings,
            label: 'Settings',
            onTap: () => SettingsScreen.open(context),
          ),
          _HeaderPill(
            svg: NymIcons.info,
            label: 'About',
            onTap: () => AboutScreen.open(context),
          ),
          _HeaderPill(
            svg: NymIcons.logout,
            label: 'Logout',
            // `data-action="signOut"` → confirm, then real sign-out (app.js
            // `signOut`, 6740-6741). `signOut()` clears the identity and bumps
            // the boot generation so the app remounts the first-run gate.
            onTap: _confirmSignOut,
          ),
        ],
      ),
    );
  }

  /// Confirms then signs out (app.js `signOut`: `showAppConfirm('Sign out and
  /// disconnect from Nymchat?', { okLabel: 'Sign out', danger: true })`).
  Future<void> _confirmSignOut() async {
    final ok = await showAppConfirm(
      context,
      'Sign out and disconnect from Nymchat?',
      okLabel: 'Sign out',
      danger: true,
    );
    if (!ok) return;
    await ref.read(nostrControllerProvider).signOut();
  }

  /// Opens the notifications modal and marks history viewed. The modal UI is
  /// owned by the calls/notifications slice; until it lands this clears the
  /// unread badge and surfaces a lightweight summary so the bell is functional.
  void _openNotifications() {
    showNotificationsPanel(context);
    ref.read(notificationHistoryProvider.notifier).markAllViewed();
  }

  /// Opens `#p2pTransfersModal` (`openP2PTransfersModal`, p2p.js:732), driven
  /// live by [P2PService]. The modal `AnimatedBuilder`s on the service, so it
  /// auto-refreshes as transfers progress / stop / cancel.
  void _openTransfers() {
    P2PTransfersModal.open(context, ref.read(p2pServiceProvider));
  }

  /// The desktop `.header-actions` "Transfers" pill, present only while there
  /// are active transfers or seeds (`service.transfers.isNotEmpty ||
  /// service.seeding.isNotEmpty`). Listens to the service so it appears /
  /// disappears as the transfer/seed set changes.
  Widget _transfersPill() {
    final service = ref.watch(p2pServiceProvider);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        if (service.transfers.isEmpty && service.seeding.isEmpty) {
          return const SizedBox.shrink();
        }
        return _HeaderPill(
          svg: NymIcons.transfers,
          label: 'Transfers',
          onTap: _openTransfers,
        );
      },
    );
  }

  /// The mobile `.mobile-header-actions` transfers toggle, present only while
  /// there are active transfers or seeds. A trailing 8px gap keeps the row gap
  /// consistent when shown.
  Widget _transfersMobileToggle() {
    final service = ref.watch(p2pServiceProvider);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        if (service.transfers.isEmpty && service.seeding.isEmpty) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: _MobileToggle(
            svg: NymIcons.transfers,
            tooltip: 'Transfers',
            onTap: _openTransfers,
          ),
        );
      },
    );
  }

  void _startCall(ChatView view, {required bool video}) {
    switch (view.kind) {
      case ViewKind.pm:
        widget.onStartCall?.call(view.id, video: video);
      case ViewKind.group:
        widget.onStartGroupCall?.call(view.id, video: video);
      case ViewKind.channel:
        // Channel calls aren't a thing in the PWA; ignore.
        break;
    }
  }

  String _titleFor(AppState app, ChatView view) {
    switch (view.kind) {
      case ViewKind.channel:
        final ch = app.channels.firstWhere(
          (c) => c.key == view.id,
          orElse: () => ChannelEntry(channel: view.id),
        );
        return '#${ch.isGeohash ? ch.geohash : ch.channel}';
      case ViewKind.pm:
        return app.users[view.id]?.nym ?? 'PM';
      case ViewKind.group:
        for (final g in app.groups) {
          if (g.id == view.id) return g.name;
        }
        return 'Group';
    }
  }

  /// The `#channelMeta` line (11px text-dim). Channel: the live online-nym count
  /// `"<n> online nyms"` (users.js `_renderUserList`, 1451). PM: lock glyph +
  /// `"End-to-end encrypted private message"` (pms.js:2940). Group: lock glyph +
  /// `"End-to-end encrypted group chat"` (groups.js:3264).
  ({String? svg, String text}) _metaFor(AppState app, ChatView view) {
    switch (view.kind) {
      case ViewKind.channel:
        // `channelUserCount` (users.js:1387): channel-SCOPED — counts only users
        // seen in THIS channel within the active window, non-hidden, excluding
        // self. The bare-lowercased `view.id` is the membership key the store
        // populates (`u.channels` ← `(geohash||channel).toLowerCase()`). PWA gates
        // on `isRecent` (lastSeen < ACTIVE_THRESHOLD), not `==online`, so an
        // away-but-recent member in-channel still counts — mirror with the raw
        // lastSeen check.
        final now = DateTime.now().millisecondsSinceEpoch;
        final key = view.id.toLowerCase();
        final count = app.users.values.where((u) {
          if (u.pubkey == app.selfPubkey) return false;
          if (!u.channels.contains(key)) return false;
          // `statusHidden = getEffectiveUserStatus(pk) === 'hidden'`
          // (users.js:1387) — computed with the verified-bot override (CC-2) so
          // the hidden gate matches the PWA's single effective-status read.
          // NOTE: `channelUserCount` does NOT carry the bot always-online
          // bypass that `activeCount` does — it gates purely on `isRecent`
          // (users.js:1387 has no `|| verifiedBotSet`), so the recency check
          // below is intentionally left to stand for bots too.
          if (u.effectiveStatus(
                  isVerifiedBot: kVerifiedBotPubkeys.contains(u.pubkey)) ==
              UserStatus.hidden) {
            return false;
          }
          return now - u.lastSeen < kActiveThresholdMs;
        }).length;
        return (svg: null, text: '${_abbreviateCount(count)} online nyms');
      case ViewKind.pm:
        return (
          svg: NymIcons.lock,
          text: 'End-to-end encrypted private message',
        );
      case ViewKind.group:
        return (
          svg: NymIcons.lock,
          text: 'End-to-end encrypted group chat',
        );
    }
  }

  /// Mirrors the PWA `abbreviateNumber` (users.js:2069): <1000 raw; <1M → "N.Nk"
  /// (1 decimal under 10k, 0 above); else "N.NM".
  String _abbreviateCount(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k';
    }
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }
}

/// `.channel-nav-btn`: 28×28 desktop / 24×24 compact, radius 4, textDim →
/// primary; hover paints a white@0.08 fill (gap F18). Disabled buttons render at
/// 0.3 opacity (PWA `.channel-nav-btn:disabled`).
/// `.channel-nav-btn` (back / forward): a 28×28 box with radius 4, dim glyph,
/// hover → bg `hoverOverlay` + primary tint, disabled → 0.3 opacity. Renders the
/// exact PWA feather chevron SVG.
class _NavBtn extends StatefulWidget {
  const _NavBtn({
    required this.svg,
    this.onTap,
    this.tooltip,
    this.disabled = false,
  });
  final String svg;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool disabled;

  @override
  State<_NavBtn> createState() => _NavBtnState();
}

class _NavBtnState extends State<_NavBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `.channel-nav-btn` is 28×28; only the ≤768 phone breakpoint shrinks it to
    // 24×24 (styles-themes-responsive.css:316, inside the max-width:768 block) —
    // the 769–1024 tablet range keeps 28×28.
    final phone =
        MediaQuery.of(context).size.width <= NymDimens.mobileBreakpoint;
    final size = phone ? 24.0 : 28.0;

    final color = widget.disabled
        ? c.textDim.withValues(alpha: 0.3)
        : (_hover ? c.primary : c.textDim);

    final btn = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: widget.disabled ? null : (widget.onTap ?? () {}),
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // `.channel-nav-btn:hover` is white@0.08 (dark) / black@0.06
            // (`body.light-mode …`, styles-themes-responsive.css:1288) — exactly
            // `hoverOverlay`, so the hover stays visible in light mode.
            color: (_hover && !widget.disabled)
                ? c.hoverOverlay
                : Colors.transparent,
            borderRadius: const BorderRadius.all(Radius.circular(4)),
          ),
          child: NymSvgIcon(widget.svg, size: 18, color: color),
        ),
      ),
    );
    return widget.tooltip != null
        ? Tooltip(message: widget.tooltip!, child: btn)
        : btn;
  }
}

/// `.favorite-channel-btn` / `.share-channel-btn` / `.call-channel-btn`: no box —
/// just a 5px-padded 18px glyph that scales to 1.1 and tints `--primary` on
/// hover. [activeColor] paints the resting glyph a fixed colour (the favorite
/// star's gold `#f5c518` when pinned); otherwise it rests at `--text-dim`.
/// Disabled rests dim and ignores taps (the always-favorited `#nymchat`).
class _ActionBtn extends StatefulWidget {
  const _ActionBtn({
    super.key,
    required this.svg,
    this.onTap,
    this.tooltip,
    this.activeColor,
    this.disabled = false,
  });
  final String svg;
  final VoidCallback? onTap;
  final String? tooltip;
  final Color? activeColor;
  final bool disabled;

  @override
  State<_ActionBtn> createState() => _ActionBtnState();
}

class _ActionBtnState extends State<_ActionBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final phone =
        MediaQuery.of(context).size.width <= NymDimens.mobileBreakpoint;
    // 18px glyph + 5px padding = 28px footprint (24px on phones), matching the
    // `.channel-nav-btn` cells so the 2-column grid stays aligned.
    final pad = phone ? 3.0 : 5.0;

    final color = widget.disabled
        ? c.textDim.withValues(alpha: 0.3)
        : (widget.activeColor ?? (_hover ? c.primary : c.textDim));

    final btn = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.disabled ? null : widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: (_hover && !widget.disabled) ? 1.1 : 1.0,
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          child: Padding(
            padding: EdgeInsets.all(pad),
            child: NymSvgIcon(widget.svg, size: 18, color: color),
          ),
        ),
      ),
    );
    return widget.tooltip != null
        ? Tooltip(message: widget.tooltip!, child: btn)
        : btn;
  }
}

/// Resolved `.icon-btn` fill/border/foreground for the current mode + hover.
@immutable
class _IconBtnStyle {
  const _IconBtnStyle({
    required this.fill,
    required this.border,
    required this.foreground,
  });
  final Color fill;
  final Color border;
  final Color foreground;
}

/// The shared `.icon-btn` token set (`styles-shell.css:912-935` +
/// `styles-themes-responsive.css:595-605`). Used by both `_HeaderPill` and
/// `_MobileToggle`.
///
/// - Dark base: fill white@0.05, border `--glass-border`, fg `--text`.
/// - Dark hover: fill `--primary`@0.12, border `--primary`@0.3, fg `--primary`.
/// - Light base: fill black@0.03, border black@0.1, fg `--primary`.
/// - Light hover: fill black@0.06, border `--primary`, fg `--primary`.
_IconBtnStyle _iconBtnStyle(NymColors c, bool hover) {
  if (c.isLight) {
    return _IconBtnStyle(
      fill: hover
          ? Colors.black.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.03),
      border: hover ? c.primary : Colors.black.withValues(alpha: 0.1),
      foreground: c.primary,
    );
  }
  return _IconBtnStyle(
    fill: hover ? c.primaryA(0.12) : Colors.white.withValues(alpha: 0.05),
    border: hover ? c.primaryA(0.30) : c.glassBorder,
    foreground: hover ? c.primary : c.text,
  );
}

/// `.icon-btn` text pill in `.header-actions` (gap F6): white@0.05 fill, 1px
/// glass border, radius xs, padding 7/14, 12px w500 uppercase ls 0.8, icon 14 +
/// 5 gap. Hover → primary@12 fill / primary text / primary@30 border / glow.
/// Light mode mirrors `body.light-mode .icon-btn` (black@0.03 fill / black@0.1
/// border / `--primary` text). An optional unread [badge] overlays the top-right.
class _HeaderPill extends StatefulWidget {
  const _HeaderPill({
    required this.svg,
    required this.label,
    required this.onTap,
    this.badge = 0,
  });
  final String svg;
  final String label;
  final VoidCallback onTap;
  final int badge;

  @override
  State<_HeaderPill> createState() => _HeaderPillState();
}

class _HeaderPillState extends State<_HeaderPill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final style = _iconBtnStyle(c, _hover);
    final fg = style.foreground;
    final pill = AnimatedContainer(
      duration: NymMotion.transition,
      curve: NymMotion.curve,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: style.fill,
        borderRadius: NymRadius.rxs,
        border: Border.all(color: style.border),
        boxShadow: _hover
            ? [BoxShadow(color: c.primaryA(0.10), blurRadius: 15)]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          NymSvgIcon(widget.svg, size: 14, color: fg),
          const SizedBox(width: 5),
          Text(
            widget.label.toUpperCase(),
            style: TextStyle(
              color: fg,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: widget.label,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: NymRadius.rxs,
          child: widget.badge > 0
              ? _withBadge(pill, widget.badge)
              : pill,
        ),
      ),
    );
  }
}

/// `.mobile-menu-toggle` / `.mobile-notif-toggle` in `.mobile-header-actions`
/// (gap F14): these are plain `.icon-btn`-class buttons — bg white@0.05 (dark) /
/// black@0.03 (light), 1px glass/black@0.1 border, **radius xs (8)**, color
/// `--text`/`--primary`, padding `7px 14px`, icon 20. (NOT a fixed 40×40
/// square, NOT rgba(20,20,35,0.8), NOT radius-sm — those were inventions.)
/// Optional unread [badge] overlay.
class _MobileToggle extends StatelessWidget {
  const _MobileToggle({
    required this.svg,
    this.tooltip,
    this.onTap,
    this.badge = 0,
  });
  final String svg;
  final String? tooltip;
  final VoidCallback? onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final style = _iconBtnStyle(c, false);
    final box = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: style.fill,
        borderRadius: NymRadius.rxs,
        border: Border.all(color: style.border),
      ),
      child: NymSvgIcon(svg, size: 20, color: style.foreground),
    );
    final child = InkWell(
      onTap: onTap,
      borderRadius: NymRadius.rxs,
      child: badge > 0 ? _withBadge(box, badge) : box,
    );
    return tooltip != null ? Tooltip(message: tooltip!, child: child) : child;
  }
}

/// `.notification-count-badge`: absolute top/right −4px, danger bg, white 10px
/// w700, min 16×16 pill. Wraps [child] in a clip-free stack with the badge.
Widget _withBadge(Widget child, int count) {
  return Stack(
    clipBehavior: Clip.none,
    children: [
      child,
      Positioned(
        top: -4,
        right: -4,
        child: _CountBadge(count: count),
      ),
    ],
  );
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.danger,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

/// `.header-clickable`: the PM/group title row becomes a pointer-cursor tap
/// target (pms.js:2613 / groups.js:2982) that opens the contact-profile or
/// group context menu. A bare wrapper so the row's intrinsic min-size layout is
/// preserved (no extra padding/ink box — the PWA only sets `cursor:pointer`).
class _HeaderClickable extends StatelessWidget {
  const _HeaderClickable({required this.child, required this.onTap});
  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
      ),
    );
  }
}

/// `.verified-badge` (styles-components.css:1382-1414): a #1DA1F2 circle with a
/// centered white ✓ (font-weight 700). Sized to the surrounding nym.
class _VerifiedBadge extends StatelessWidget {
  const _VerifiedBadge({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: Color(0xFF1DA1F2),
        shape: BoxShape.circle,
      ),
      child: Text(
        '✓',
        style: TextStyle(
          color: const Color(0xFFFFFFFF),
          fontSize: size * 0.6,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

/// `.friend-badge` (styles-features.css:1483-1495): a people-with-check glyph in
/// #4fc3f7 (light-mode #0288d1, `body.light-mode .friend-badge`). Mirrors the
/// call surface's friend badge so the glyph matches the rest of the app.
class _FriendBadge extends StatelessWidget {
  const _FriendBadge({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = context.nym.isLight
        ? const Color(0xFF0288D1)
        : const Color(0xFF4FC3F7);
    return NymSvgIcon(NymIcons.friendBadge, size: size, color: color);
  }
}
