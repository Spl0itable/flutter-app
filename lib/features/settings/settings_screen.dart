import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/theme/nym_theme.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/channel.dart';
import '../../models/settings.dart';
import '../../services/api/storage_sync.dart';
import '../notifications/notifications_service.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/app_dialog.dart';
import '../emoji/emoji_picker.dart';
import '../identity/vault_settings_modal.dart';
import 'settings_helpers.dart';
import 'settings_widgets.dart';

/// The Settings modal (`#settingsModal`, docs/specs/02 §5.10, §04-features §9).
///
/// Presented as a centered `.modal-content` dialog (bg `--bg-secondary`,
/// radius xl, 1px glass border, max-width 500, padding 32). Sections mirror the
/// PWA collapsible `.settings-section`s in order: Appearance, Privacy &
/// Security, Messaging & Display, Channels, Mobile Gestures, Data & Backup.
///
/// Each control's label text, option order and option labels are copied
/// verbatim from `index.html`'s `#settingsModal` markup.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  /// Opens the settings dialog as a modal route.
  static Future<void> open(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => const SettingsScreen(),
    );
  }

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _searchController = TextEditingController();
  final _keywordController = TextEditingController();
  final _transferPubkeyController = TextEditingController();
  final _landingController = TextEditingController();
  final _landingFocus = FocusNode();
  String _search = '';

  /// Inline error under the transfer field (F9 / shop.js settingsTransferError).
  String? _transferError;

  /// Whether an outbound settings transfer is in flight (F9). Disables the Send
  /// button + relabels it "Sending…" while the gift wrap publishes.
  bool _transferSending = false;

  /// The current landing-channel selection (F8). Seeded from the store.
  LandingChannel _landing = LandingChannel.defaultChannel;

  /// Whether the landing-channel suggestions overlay is open.
  bool _landingOpen = false;

  /// The on-device cache readout shown in Data & Backup (F7). Null while the
  /// first `cacheSizeBytes()` read is in flight (renders the PWA's
  /// "Calculating…" placeholder); otherwise a formatted human string.
  String? _cacheReadout;

  // Section open/collapsed state (all expanded by default, matching the PWA's
  // aria-expanded="true").
  final Map<String, bool> _open = {
    'appearance': true,
    'privacy': true,
    'messaging': true,
    'channels': true,
    'mobile': true,
    'data': true,
  };

  // Live text-size preview value (commits to the controller on change end).
  double? _textSizePreview;

  @override
  void initState() {
    super.initState();
    // Seed the landing-channel field from the persisted value (F8).
    final kv = ref.read(keyValueStoreProvider);
    _landing = readLandingChannel(kv);
    _landingController.text = _landing.label;
    _landingFocus.addListener(() {
      if (!_landingFocus.hasFocus && _landingOpen) {
        setState(() => _landingOpen = false);
      }
    });
    // Kick off the real on-device cache-size read (F7; refreshAppCacheSize is
    // run on settings open in the PWA, app.js:3625).
    _loadCacheSize();
    // Pull any inbound pending settings transfers (F17).
    ref.read(nostrControllerProvider).refreshPendingSettingsTransfers();
  }

  /// Reads the real on-device cache size from the controller and formats it as
  /// MB into [_cacheReadout] (F7). Mirrors the PWA's `refreshAppCacheSize`
  /// (app.js:3681): show "Calculating…" until the async read resolves, then the
  /// byte total (or the honest empty-state string when nothing is cached).
  Future<void> _loadCacheSize() async {
    final controller = ref.read(nostrControllerProvider);
    try {
      final bytes = await controller.cacheSizeBytes();
      if (!mounted) return;
      setState(() {
        _cacheReadout = bytes <= 0
            ? 'No cached data on device yet'
            : '${formatCacheMb(bytes)} cached on device';
      });
    } catch (_) {
      if (!mounted) return;
      // Fall back to the honest empty-state rather than a perpetual spinner.
      setState(() => _cacheReadout = 'No cached data on device yet');
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _keywordController.dispose();
    _transferPubkeyController.dispose();
    _landingController.dispose();
    _landingFocus.dispose();
    super.dispose();
  }

  bool _matches(String haystack) {
    if (_search.isEmpty) return true;
    return haystack.toLowerCase().contains(_search.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final settings = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    // Watch the moderation Sets so the Friends/Blocked/Keywords/Hidden/Blocked
    // lists (F1) re-render on add/remove.
    ref.watch(appStateProvider);
    // Watch inbound settings-transfer offers so the Pending Settings Transfers
    // list (F17) re-renders as offers arrive or are accepted/declined.
    ref.watch(pendingSettingsTransfersProvider);

    // `.settings-section.mobile-only` is `display:none` by default and revealed
    // only `@media (max-width:768px)` (styles-components.css:215 +
    // styles-themes-responsive.css:70). Gate the Mobile Gestures section the
    // same way so wide windows/tablets don't over-render it.
    final isMobileWidth = MediaQuery.of(context).size.width <= 768;

    final sections = <_SectionSpec>[
      _SectionSpec(
        key: 'appearance',
        title: 'Appearance',
        keywords: 'appearance theme color mode chat view wallpaper '
            'message layout transparency text size',
        builder: () => _appearance(settings, ctrl),
      ),
      _SectionSpec(
        key: 'privacy',
        title: 'Privacy & Security',
        keywords: 'privacy security identity encryption keypair proof of work '
            'accept private messages calls disappearing pm forward secrecy '
            'read receipts typing indicators status cache blur images blocked '
            'keywords friends blocked users',
        builder: () => _privacy(settings, ctrl),
      ),
      _SectionSpec(
        key: 'messaging',
        title: 'Messaging & Display',
        keywords: 'messaging display translation language notification sound '
            'auto-scroll show timestamps time format date format random '
            'nickname style ephemeral',
        builder: () => _messaging(settings, ctrl),
      ),
      _SectionSpec(
        key: 'channels',
        title: 'Channels',
        keywords: 'channels group chats pms only proximity landing channel '
            'hide non-favorited hidden blocked',
        builder: () => _channels(settings, ctrl),
      ),
      // Mobile Gestures — only on a mobile-width viewport (PWA mobile-only).
      if (isMobileWidth)
        _SectionSpec(
          key: 'mobile',
          title: 'Mobile Gestures',
          keywords: 'mobile gestures swipe left right action react emoji '
              'sensitivity threshold',
          builder: () => _mobile(settings, ctrl),
        ),
      _SectionSpec(
        key: 'data',
        title: 'Data & Backup',
        keywords: 'data backup low data mode transfer settings pending '
            'transfers cache clear reset defaults',
        builder: () => _data(settings, ctrl),
      ),
    ];

    final visibleSections = sections
        .where((s) => _matches(s.title) || _matches(s.keywords))
        .toList();

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: c.bgSecondary,
                borderRadius: NymRadius.rxl,
                border: Border.all(color: c.glassBorder),
                // `.modal-content` box-shadow: --shadow-lg (0 8 32 black@.5)
                // + --shadow-glow (faint primary) + 1px white@.05 ring.
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 32,
                    offset: const Offset(0, 8),
                  ),
                  BoxShadow(
                    color: c.primaryA(0.12),
                    blurRadius: 24,
                  ),
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.05),
                    spreadRadius: 1,
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.9,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _header(c),
                    Flexible(
                      child: SingleChildScrollView(
                        // Sections are full-bleed; the search bar / no-results
                        // text carry the `.modal-content { padding: 32px }`
                        // horizontal inset themselves.
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 32),
                              child: _searchBar(c),
                            ),
                            if (visibleSections.isEmpty)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
                                child: Text(
                                  'No settings match your search.',
                                  style: TextStyle(
                                      color: c.textDim, fontSize: 13),
                                ),
                              ),
                            for (final s in visibleSections)
                              SettingsSection(
                                title: s.title,
                                open: _open[s.key] ?? true,
                                onToggle: () => setState(
                                    () => _open[s.key] = !(_open[s.key] ?? true)),
                                children: [s.builder()],
                              ),
                          ],
                        ),
                      ),
                    ),
                    _actions(c),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- Chrome ---------------------------------------------------------------

  Widget _header(NymColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 18, 14),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'SETTINGS',
              style: TextStyle(
                color: c.primary,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ),
          InkWell(
            onTap: () => Navigator.of(context).maybePop(),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // `.modal-close`: bg white@.05, 1px glass border.
                color: Colors.white.withValues(alpha: 0.05),
                shape: BoxShape.circle,
                border: Border.all(color: c.glassBorder),
              ),
              child: Icon(Icons.close, size: 18, color: c.textDim),
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchBar(NymColors c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FormInput(
        controller: _searchController,
        hint: 'Search settings...',
        onChanged: (v) => setState(() => _search = v),
      ),
    );
  }

  Widget _actions(NymColors c) {
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 12, 32, 20),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          NymOutlineButton(
            label: 'Cancel',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 10),
          // `.send-btn`: primary-tinted (bg primary@0.1, border primary@0.3),
          // primary uppercase text with wide letter-spacing, height 42.
          InkWell(
            onTap: _onSave,
            borderRadius: NymRadius.rsm,
            child: Container(
              height: 42,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 22),
              decoration: BoxDecoration(
                color: c.primaryA(0.10),
                borderRadius: NymRadius.rsm,
                border: Border.all(color: c.primaryA(0.30)),
              ),
              child: Text(
                'SAVE',
                style: TextStyle(
                  color: c.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Actions / wiring -----------------------------------------------------

  /// Emits a transient in-conversation system pill (the PWA's
  /// `displaySystemMessage`), then optionally closes the modal. Scheduled
  /// post-frame so it runs after the dialog pops.
  void _systemMessage(String text) {
    final notifier = ref.read(appStateProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      notifier.addSystemMessage(text);
    });
  }

  /// SAVE (F3): commit the non-write-on-change controls (landing channel,
  /// proximity geolocation), confirm with a "Settings saved" system message,
  /// then close. Most controls already persist on-change.
  Future<void> _onSave() async {
    final kv = ref.read(keyValueStoreProvider);
    // Commit the landing channel (F8 — not write-on-change).
    writeLandingChannel(kv, _landing);

    // Proximity geolocation prompt (F13) is handled by its own setter flow on
    // change; nothing extra to do here.
    if (!mounted) return;
    _systemMessage('Settings saved');
    Navigator.of(context).maybePop();
  }

  /// Add Keyword (F4): persist + render the new row + confirm.
  void _addKeyword(SettingsController ctrl) {
    final raw = _keywordController.text.trim();
    if (raw.isEmpty) return;
    final added = ref.read(appStateProvider.notifier).addBlockedKeyword(raw);
    _persistBlockedKeywords();
    _keywordController.clear();
    if (added != null) {
      _systemMessage('Blocked keyword: "$added"');
    }
    setState(() {});
  }

  /// Persists the live blocked-keyword Set to `nym_blocked_keywords` as the
  /// JSON array the PWA uses (saveBlockedKeywords). The store has no typed
  /// set-setter, so we serialize through `setString`.
  void _persistBlockedKeywords() {
    final kws = ref.read(appStateProvider).blockedKeywords.toList();
    ref
        .read(keyValueStoreProvider)
        .setString(StorageKeys.blockedKeywords, jsonEncode(kws));
  }

  /// Quick React emoji "Change" (F5): open the emoji picker; on pick commit via
  /// the existing `setSwipeReactEmoji` setter (which persists + updates state).
  void _openSwipeReactPicker(SettingsController ctrl) {
    final c = context.nym;
    final recents = ref.read(recentEmojisProvider);
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x66000000),
      builder: (dialogCtx) => Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 360, maxHeight: 420),
          width: MediaQuery.of(context).size.width * 0.9,
          margin: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: c.bgSecondary,
            border: Border.all(color: c.glassBorder),
            borderRadius: NymRadius.rmd,
          ),
          clipBehavior: Clip.antiAlias,
          child: EmojiPicker(
            recents: recents,
            onSelect: (emoji) {
              Navigator.of(dialogCtx).maybePop();
              ctrl.setSwipeReactEmoji(emoji);
              ref.read(recentEmojisProvider.notifier).record(emoji);
            },
          ),
        ),
      ),
    );
  }

  /// Notification-sound change: persist the choice, then play it as an audible
  /// preview (the PWA's `soundSelect.onchange` → `nym.playSound(value)`,
  /// app.js:3480-3484). `'none'`/unknown is silent. The PWA zeroes its 2s
  /// replay-dedupe before the preview (app.js:3481-3483) so back-to-back
  /// previews always sound — without it a second change within 2s is swallowed
  /// by the guard.
  void _onSoundChanged(SettingsController ctrl, String value) {
    ctrl.setSound(value);
    final svc = ref.read(notificationsServiceProvider);
    svc.resetSoundDedupe();
    svc.playSound(value);
  }

  /// Clear Local Storage Cache (F10): danger confirm with the PWA copy, wipe the
  /// real on-device cache via the controller, then re-read the size so the
  /// readout updates in place and toast (app.js:4001 `clearLocalStorageCache`).
  /// The modal stays open so the freshly-cleared "No cached data on device yet"
  /// readout is observable.
  Future<void> _clearCache() async {
    final ok = await showAppConfirm(
      context,
      'Clear cached channel history, PMs, group chats, profiles, and '
      'reactions? This will not log you out or change your settings.',
      okLabel: 'Clear',
      danger: true,
    );
    if (!ok || !mounted) return;
    final controller = ref.read(nostrControllerProvider);
    // Reflect the in-flight wipe in the readout immediately.
    setState(() => _cacheReadout = null);
    try {
      await controller.clearCache();
    } catch (_) {
      // Best-effort; still re-read so the readout reflects the true state.
    }
    if (!mounted) return;
    await _loadCacheSize();
    _systemMessage(
        'Local storage cache cleared. Settings, group memberships, and login '
        'preserved.');
  }

  /// Reset Settings to Defaults (F11): danger confirm, wipe the exact settings
  /// keys (+ image-blur prefixes), reset moderation Sets, reload Settings from
  /// the now-cleared store so theme/layout/wallpaper revert live, then toast +
  /// close.
  Future<void> _resetSettings() async {
    final ok = await showAppConfirm(
      context,
      'Reset all settings and preferences to defaults? This will reset theme, '
      'layout, wallpaper, sound, favorited/hidden/blocked channels, blocked '
      'users, and blocked keywords. Your login, group memberships, and PMs '
      'will be preserved.',
      okLabel: 'Reset',
      danger: true,
    );
    if (!ok) return;
    final kv = ref.read(keyValueStoreProvider);
    for (final key in kSettingsResetKeys) {
      kv.remove(key);
    }
    // Per-pubkey image-blur keys (`nym_image_blur_<pubkey>`): the store can't
    // enumerate keys, so clear the self entry explicitly (the only one this
    // device writes via setBlurImages).
    final self = ref.read(appStateProvider).selfPubkey;
    if (self.isNotEmpty) kv.remove(StorageKeys.imageBlurFor(self));

    // Reset the in-memory moderation Sets (pinned/hidden/blocked/keywords).
    final notifier = ref.read(appStateProvider.notifier);
    for (final pk in ref.read(appStateProvider).blockedUsers.toList()) {
      notifier.removeBlockedUser(pk);
    }
    for (final kw in ref.read(appStateProvider).blockedKeywords.toList()) {
      notifier.removeBlockedKeyword(kw);
    }
    for (final key in ref.read(appStateProvider).hiddenChannels.toList()) {
      notifier.removeHiddenChannel(key);
    }
    for (final key in ref.read(appStateProvider).blockedChannels.toList()) {
      notifier.removeBlockedChannel(key);
    }

    // F11 follow-up: rebuild Settings from the now-cleared store so every
    // synced/visual default (theme, color-mode, message layout, wallpaper,
    // text size, transparency, …) reverts immediately without a relaunch.
    // This mirrors the PWA's post-reset re-apply of color-mode/wallpaper('none')
    // /layout('bubbles') (app.js:4095-4100): rebuilding `Settings.fromStore`
    // drives all of those reactively here.
    ref.read(settingsProvider.notifier).reloadFromStore();

    if (!mounted) return;
    _systemMessage(
        'Settings reset to defaults. Cache, group memberships, and login '
        'preserved.');
    Navigator.of(context).maybePop();
  }

  /// Transfer → Send (F9): client-side validate the recipient pubkey and show
  /// the matching inline error (shop.js:1767 `executeSettingsTransfer`). On a
  /// valid recipient, publish the gift-wrapped kind-30078 settings transfer via
  /// the controller, then mirror the PWA's success/error states: clear the input
  /// + "Settings transfer sent to <8>...!" system message on success, or the
  /// "Failed to send settings transfer." inline error otherwise.
  Future<void> _sendTransfer() async {
    if (_transferSending) return;
    final raw = _transferPubkeyController.text.trim().toLowerCase();
    final err = validateTransferPubkey(
      raw,
      selfPubkey: ref.read(appStateProvider).selfPubkey,
    );
    if (err != null) {
      setState(() => _transferError = err);
      return;
    }
    setState(() {
      _transferError = null;
      _transferSending = true;
    });
    bool ok = false;
    try {
      ok = await ref.read(nostrControllerProvider).sendSettingsTransfer(raw);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _transferSending = false);
    if (ok) {
      // PWA success path: clear the input + confirm with the truncated pubkey.
      _transferPubkeyController.clear();
      _systemMessage('Settings transfer sent to ${raw.substring(0, 8)}...!');
    } else {
      setState(() => _transferError =
          'Failed to send settings transfer. Please try again.');
    }
  }

  /// Proximity toggle (F13): on enable, request location permission; on grant
  /// resolve a position and keep it enabled, on deny revert the dropdown to
  /// Disabled and persist false. Mirrors saveSettings' geolocation branch.
  Future<void> _onProximityChanged(bool enabled, SettingsController ctrl) async {
    if (!enabled) {
      ctrl.setSortByProximity(false);
      ref.read(userLocationProvider.notifier).state = null;
      return;
    }
    // Optimistically reflect the choice while we ask for permission.
    ctrl.setSortByProximity(true);
    setState(() {});
    try {
      var status = await Permission.locationWhenInUse.status;
      if (!status.isGranted) {
        status = await Permission.locationWhenInUse.request();
      }
      if (!mounted) return;
      if (status.isGranted) {
        _systemMessage(
            'Location access granted. Geohash channels sorted by proximity.');
      } else {
        ctrl.setSortByProximity(false);
        ref.read(userLocationProvider.notifier).state = null;
        _systemMessage('Location access denied. Proximity sorting disabled.');
        setState(() {});
      }
    } catch (_) {
      if (!mounted) return;
      ctrl.setSortByProximity(false);
      _systemMessage('Location access denied. Proximity sorting disabled.');
      setState(() {});
    }
  }

  // --- Appearance -----------------------------------------------------------

  Widget _appearance(Settings s, SettingsController ctrl) {
    final c = context.nym;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Color mode segment.
        FormGroup(
          hint: 'Auto matches your system preference',
          child: SegmentGroup<ColorMode>(
            value: s.colorMode,
            segments: const [
              (value: ColorMode.light, label: 'Light'),
              (value: ColorMode.auto, label: 'Auto'),
              (value: ColorMode.dark, label: 'Dark'),
            ],
            onChanged: ctrl.setColorMode,
          ),
        ),
        // Theme picker (each swatch shows its real accent).
        FormGroup(
          label: 'Theme',
          child: _ThemePicker(
            value: s.theme,
            onChanged: ctrl.setTheme,
          ),
        ),
        // Chat View (single / columns) — two preview cards (.view-option).
        FormGroup(
          label: 'Chat View',
          hint: 'Single shows one conversation at a time. Column view shows '
              'channels, PMs, and group chats side by side in scrollable '
              'columns you can add, remove, and drag to reorder.',
          child: _ViewPicker(
            value: s.useColumns ? 'columns' : 'single',
            onChanged: ctrl.setChatViewMode,
          ),
        ),
        // Reset columns to defaults (PWA index.html:1406, `resetColumnView`).
        // `.nm-h-58` (btn-small): 11px text-dim, NOT uppercase.
        if (s.useColumns)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: NymOutlineButton(
                label: 'Reset columns to defaults',
                uppercase: false,
                onPressed: ctrl.resetColumns,
              ),
            ),
          ),
        // Column Message Wallpaper (cv-only).
        if (s.useColumns)
          FormGroup(
            label: 'Column Message Wallpaper',
            hint: 'In column view, let your chat wallpaper show through the '
                'message area of each column instead of a solid background.',
            child: FormSelect<bool>(
              value: s.columnsWallpaper,
              items: const [
                (value: false, label: 'Solid background'),
                (value: true, label: 'Show wallpaper through messages'),
              ],
              onChanged: ctrl.setColumnsWallpaper,
            ),
          ),
        // Chat Wallpaper grid.
        FormGroup(
          label: 'Chat Wallpaper',
          hint: 'Choose a background pattern or upload your own image '
              '(min 1920x1080)',
          child: _WallpaperPicker(
            value: s.wallpaperType,
            onChanged: ctrl.setWallpaperType,
          ),
        ),
        // Message Layout (bubbles / irc).
        FormGroup(
          label: 'Message Layout',
          hint: 'Choose between classic IRC-style or modern chat bubbles',
          child: _LayoutPicker(
            value: s.chatLayout,
            onChanged: ctrl.setChatLayout,
          ),
        ),
        // Visual Transparency.
        FormGroup(
          label: 'Visual Transparency',
          hint: 'Choose between Solid or Glass, where messages, modals, '
              'sidebars, and other surfaces are rendered with either solid '
              'backgrounds or a translucent "Glass" look.',
          child: FormSelect<bool>(
            value: s.transparencyEnabled,
            items: const [
              (value: false, label: 'Solid'),
              (value: true, label: 'Glass'),
            ],
            onChanged: ctrl.setTransparencyEnabled,
          ),
        ),
        // Text Size slider with live preview + reset.
        FormGroup(
          label: 'Text Size',
          hint: 'Adjust the size of all text across the app',
          child: _TextSizeRow(
            value: (_textSizePreview ?? s.textSize.toDouble()),
            previewColor: c.primary,
            onChanged: (v) => setState(() => _textSizePreview = v),
            onChangeEnd: (v) {
              ctrl.setTextSize(v.round());
              setState(() => _textSizePreview = null);
            },
            onReset: () {
              ctrl.setTextSize(NymTextSize.defaultSize.round());
              setState(() => _textSizePreview = null);
            },
          ),
        ),
      ],
    );
  }

  // --- Privacy & Security ---------------------------------------------------

  Widget _privacy(Settings s, SettingsController ctrl) {
    // The moderation sets (friends / blocked users / blocked keywords) live on
    // AppState, not Settings.
    final app = ref.watch(appStateProvider);
    // `isNostrLoggedIn()` (app.js:4960): a durable Nostr identity is logged in
    // (loginMethod != null; null = ephemeral). Locks the keypair-rotation
    // control to 'persistent'.
    final nostrLoggedIn =
        ref.read(nostrControllerProvider).identity?.loginMethod != null;
    final keypairValue = nostrLoggedIn ? 'persistent' : ctrl.keypairMode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormGroup(
          label: 'Identity Encryption',
          hint: "Optionally protect your saved identity's (nsec) private key "
              'with a password, PIN, passkey, or biometric (Face/Touch ID) so '
              "it can't be read from this device without unlocking. Passkeys "
              '(synced or hardware security keys) and biometrics use WebAuthn '
              'where supported, with password/PIN as the universal fallback.',
          child: NymOutlineButton(
            label: 'Encrypt identity (nsec) key on this device…',
            // F18: open the existing vault-settings modal (identity slice).
            onPressed: () => VaultSettingsModal.open(context),
          ),
        ),
        FormGroup(
          label: 'Generate Random Keypair Per Session',
          hint: 'Generate a new random keypair on every session restart for '
              'improved pseudonymity. When disabled, your generated keypair '
              'persists across reloads.',
          warning: keypairValue == 'hardcore'
              ? '⚠ Hardcore mode changes your identity after every sent '
                  'message. PMs and group chats will not work reliably since '
                  'recipients cannot reply to a constantly changing pubkey. '
                  'Settings will not sync across devices.'
              : null,
          child: FormSelect<String>(
            value: keypairValue,
            // Locked at 'persistent' while logged in with a Nostr identity —
            // rotation would conflict with it (app.js:3237-3241).
            disabled: nostrLoggedIn,
            tooltip: 'Not available while logged in with a Nostr identity',
            items: const [
              (value: 'persistent', label: 'Disabled (reuse same keypair)'),
              (value: 'random', label: 'Enabled (new identity each session)'),
              (value: 'hardcore', label: 'Hardcore (new keypair every message)'),
            ],
            onChanged: (v) => setState(() => ctrl.setKeypairMode(v)),
          ),
        ),
        FormGroup(
          label: 'Proof of Work Difficulty',
          hint: 'Enable for anti-spam to require messages have a minimum PoW',
          child: FormSelect<int>(
            value: ctrl.powDifficulty,
            items: const [
              (value: 0, label: 'Disabled'),
              (value: 8, label: 'Very Low (8 bits)'),
              (value: 12, label: 'Low (12 bits)'),
              (value: 16, label: 'Medium (16 bits)'),
              (value: 20, label: 'High (20 bits)'),
              (value: 24, label: 'Very High (24 bits)'),
            ],
            onChanged: (v) => setState(() => ctrl.setPowDifficulty(v)),
          ),
        ),
        FormGroup(
          label: 'Accept Private Messages & Group Chat Requests',
          hint: 'Control who can send you PMs and group chat invites. '
              '"Friends only" filters messages from non-friends.',
          child: FormSelect<String>(
            value: s.acceptPMs,
            items: const [
              (value: 'enabled', label: 'Enabled'),
              (value: 'friends', label: 'Friends only'),
              (value: 'disabled', label: 'Disabled'),
            ],
            onChanged: ctrl.setAcceptPMs,
          ),
        ),
        FormGroup(
          label: 'Accept Audio & Video Calls',
          hint: 'Control who can ring you with an audio or video call. '
              '"Friends only" silently ignores calls from non-friends.',
          warning: '⚠ Audio/video calls and P2P file sharing connect peers '
              'directly over WebRTC, which can reveal your true IP address to '
              'the other party. Use a VPN or Tor to help conceal it.',
          child: FormSelect<String>(
            value: s.acceptCalls,
            items: const [
              (value: 'enabled', label: 'Enabled'),
              (value: 'friends', label: 'Friends only'),
              (value: 'disabled', label: 'Disabled'),
            ],
            onChanged: ctrl.setAcceptCalls,
          ),
        ),
        FormGroup(
          label: 'Disappearing PM (forward secrecy)',
          hint: 'When enabled, your private messages include an "expiration" '
              'tag (NIP‑40) so relays/clients can delete them after the period '
              'chosen when enabled.',
          child: FormSelect<bool>(
            value: s.dmForwardSecrecyEnabled,
            items: const [
              (value: false, label: 'Disabled'),
              (value: true, label: 'Enabled'),
            ],
            onChanged: ctrl.setDmForwardSecrecy,
          ),
        ),
        // Disappear After (TTL) — shown when forward secrecy is enabled.
        if (s.dmForwardSecrecyEnabled)
          FormGroup(
            label: 'Disappear After',
            hint: 'This sets the "expiration" timestamp on each outgoing '
                'gift‑wrapped PM.',
            child: FormSelect<int>(
              value: s.dmTtlSeconds,
              items: const [
                (value: 3600, label: '1 hour'),
                (value: 21600, label: '6 hours'),
                (value: 86400, label: '1 day'),
                (value: 259200, label: '3 days'),
                (value: 604800, label: '7 days'),
              ],
              onChanged: ctrl.setDmTtlSeconds,
            ),
          ),
        FormGroup(
          label: 'Read Receipts',
          hint: "Choose where senders can see when you've read their messages "
              '(✓✓). "Enabled everywhere" includes PMs, group chats, and '
              'public channels.',
          child: FormSelect<String>(
            value: s.readReceiptsScope,
            items: const [
              (value: 'everywhere', label: 'Enabled everywhere'),
              (value: 'pms-groups', label: 'Both PMs and group chats'),
              (value: 'pms', label: 'Only PMs'),
              (value: 'groups', label: 'Only group chats'),
              (value: 'disabled', label: 'Disabled completely'),
            ],
            onChanged: ctrl.setReadReceiptsScope,
          ),
        ),
        FormGroup(
          label: 'Typing Indicators',
          hint: "Choose where others can see when you're typing. "
              '"Enabled everywhere" includes PMs, group chats, and public '
              'channels.',
          child: FormSelect<String>(
            value: s.typingIndicatorsScope,
            items: const [
              (value: 'everywhere', label: 'Enabled everywhere'),
              (value: 'pms-groups', label: 'Both PMs and group chats'),
              (value: 'pms', label: 'Only PMs'),
              (value: 'groups', label: 'Only group chats'),
              (value: 'disabled', label: 'Disabled completely'),
            ],
            onChanged: ctrl.setTypingIndicatorsScope,
          ),
        ),
        FormGroup(
          label: 'Show Status Indicators',
          hint: 'When enabled, online/away/offline status dots are shown on '
              'avatars and in user profiles. "Friends only" broadcasts a '
              'hidden status publicly while privately sharing your real status '
              "with people you've marked as friends, so only they can see it. "
              'When disabled, your status is hidden from everyone, but you can '
              "still see other people's status indicators.",
          child: FormSelect<String>(
            value: s.showStatus,
            items: const [
              (value: 'true', label: 'Enabled'),
              (value: 'friends', label: 'Friends only'),
              (value: 'false', label: 'Disabled'),
            ],
            onChanged: ctrl.setShowStatus,
          ),
        ),
        FormGroup(
          label: 'Cache PMs & Group Chats On Device',
          hint: 'When enabled, decrypted private messages and group chats are '
              'stored on this device so they appear instantly on app launch. '
              "Disable if you'd rather not have decrypted message content kept "
              'at rest in app storage. Toggling off clears the existing cached '
              'PM/group data.',
          child: FormSelect<bool>(
            value: s.cachePMs,
            items: const [
              (value: true, label: 'Enabled'),
              (value: false, label: 'Disabled'),
            ],
            onChanged: ctrl.setCachePMs,
          ),
        ),
        FormGroup(
          label: 'Blur Images from Others',
          hint: 'Blur images shared by others until clicked. Your own images '
              'are never blurred. "Friends only" shows images from friends '
              'unblurred.',
          child: FormSelect<String>(
            value: ctrl.blurImages,
            items: const [
              (value: 'true', label: 'Enabled (blur by default)'),
              (value: 'friends', label: 'Disabled (for friends only)'),
              (value: 'false', label: 'Disabled (show all images)'),
            ],
            onChanged: (v) => setState(() => ctrl.setBlurImages(
                  v,
                  pubkey: ref.read(appStateProvider).selfPubkey,
                )),
          ),
        ),
        FormGroup(
          label: 'Blocked Keywords/Phrases',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FormInput(
                controller: _keywordController,
                hint: 'Add keyword or phrase to block',
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: NymOutlineButton(
                  label: 'Add Keyword',
                  onPressed: () => _addKeyword(ctrl),
                ),
              ),
              const SizedBox(height: 8),
              _removableList(
                entries: app.blockedKeywords,
                emptyText: 'No blocked keywords',
                buttonLabel: 'Remove',
                labelFor: (kw) => kw,
                onRemove: (kw) {
                  ref.read(appStateProvider.notifier).removeBlockedKeyword(kw);
                  _persistBlockedKeywords();
                },
              ),
            ],
          ),
        ),
        FormGroup(
          label: 'Friends',
          hint: 'Friends can have special privileges like bypassing image '
              'blur and message filters. Add friends from the context menu on '
              'any user.',
          child: _removableList(
            entries: app.friends,
            emptyText: 'No friends added',
            buttonLabel: 'Remove',
            labelFor: _nymLabelFor,
            onRemove: (pk) =>
                ref.read(appStateProvider.notifier).removeFriend(pk),
          ),
        ),
        FormGroup(
          label: 'Blocked Users',
          child: _removableList(
            entries: app.blockedUsers,
            emptyText: 'No blocked users',
            buttonLabel: 'Unblock',
            labelFor: _nymLabelFor,
            onRemove: (pk) =>
                ref.read(appStateProvider.notifier).removeBlockedUser(pk),
          ),
        ),
      ],
    );
  }

  // --- Messaging & Display --------------------------------------------------

  Widget _messaging(Settings s, SettingsController ctrl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormGroup(
          label: 'Translation Language',
          hint: 'Choose your preferred language for translating messages via '
              'the context menu.',
          child: FormSelect<String>(
            value: s.translateLanguage,
            items: _translationLanguages,
            onChanged: ctrl.setTranslateLanguage,
          ),
        ),
        FormGroup(
          label: 'Notification Sound',
          child: FormSelect<String>(
            value: s.sound,
            items: _soundOptions,
            // Persist + play an audible preview of the chosen tone.
            onChanged: (v) => _onSoundChanged(ctrl, v),
          ),
        ),
        FormGroup(
          label: 'Auto-scroll Messages',
          child: FormSelect<bool>(
            value: s.autoscroll,
            items: const [
              (value: true, label: 'Enabled'),
              (value: false, label: 'Disabled'),
            ],
            onChanged: ctrl.setAutoscroll,
          ),
        ),
        FormGroup(
          label: 'Show Timestamps',
          child: FormSelect<bool>(
            value: s.showTimestamps,
            items: const [
              (value: true, label: 'Show'),
              (value: false, label: 'Hide'),
            ],
            onChanged: ctrl.setShowTimestamps,
          ),
        ),
        FormGroup(
          label: 'Time Format',
          child: FormSelect<String>(
            value: s.timeFormat,
            items: const [
              (value: '24hr', label: '24-hour (14:30)'),
              (value: '12hr', label: '12-hour (2:30 PM)'),
            ],
            onChanged: ctrl.setTimeFormat,
          ),
        ),
        FormGroup(
          label: 'Date Format',
          hint: 'Used in the full timestamp shown when tapping a message time',
          child: FormSelect<String>(
            value: s.dateFormat,
            items: const [
              (value: 'default', label: 'Default (May 28, 2026)'),
              (value: 'mdy', label: 'MM/DD/YYYY (05/28/2026)'),
              (value: 'dmy', label: 'DD/MM/YYYY (28/05/2026)'),
              (value: 'ymd', label: 'YYYY-MM-DD (2026-05-28)'),
            ],
            onChanged: ctrl.setDateFormat,
          ),
        ),
        FormGroup(
          label: 'Random Nickname Style',
          hint: 'Style used when generating random nicknames',
          child: FormSelect<String>(
            value: s.nickStyle,
            items: const [
              (value: 'fancy', label: 'Fancy (adjective_noun)'),
              (value: 'simple', label: 'Simple (nym1234)'),
            ],
            onChanged: ctrl.setNickStyle,
          ),
        ),
        // NOTE: #autoEphemeralSettingGroup is hidden by default in the PWA
        // (nm-hidden) and only shown in ephemeral-login context, so it is
        // omitted here to match the default rendering.
      ],
    );
  }

  // --- Channels -------------------------------------------------------------

  Widget _channels(Settings s, SettingsController ctrl) {
    final state = ref.watch(appStateProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormGroup(
          label: 'Group Chats & PMs Only Mode',
          hint: 'Hides all geohash channels and focuses the app on group '
              'chats and private messages only. Reduces bandwidth by skipping '
              'channel subscriptions.',
          child: FormSelect<bool>(
            value: s.groupChatPMOnlyMode,
            items: const [
              (value: false, label: 'Disabled (show geohash channels)'),
              (value: true, label: 'Enabled (group chats & PMs only)'),
            ],
            onChanged: ctrl.setGroupChatPMOnlyMode,
          ),
        ),
        // Geohash-specific settings (data-geohash-setting) are hidden in
        // group-chat/PM-only mode (F6; app.js:3598-3607).
        if (!s.groupChatPMOnlyMode) ...[
          FormGroup(
            label: 'Sort Geohash Channels by Proximity',
            hint: 'Sort geohash channels by distance from your location',
            child: FormSelect<bool>(
              value: s.sortByProximity,
              items: const [
                (value: false, label: 'Disabled'),
                (value: true, label: 'Enabled (requires location access)'),
              ],
              onChanged: (v) => _onProximityChanged(v, ctrl),
            ),
          ),
          FormGroup(
            label: 'Default Landing Channel',
            hint: 'Channel to load when you first open or reload the app',
            child: _landingChannelField(state.channels),
          ),
          FormGroup(
            label: 'Hide All Non-Favorited Channels',
            hint: 'When enabled, only your favorited channels will appear in '
                'the sidebar',
            child: FormSelect<bool>(
              value: s.hideNonPinned,
              items: const [
                (value: false, label: 'Disabled'),
                (value: true, label: 'Enabled (only show favorited channels)'),
              ],
              onChanged: ctrl.setHideNonPinned,
            ),
          ),
          FormGroup(
            label: 'Hidden Channels',
            child: _removableList(
              entries: state.hiddenChannels,
              emptyText: 'No hidden channels',
              buttonLabel: 'Unhide',
              labelFor: (key) => '#$key',
              onRemove: (key) =>
                  ref.read(appStateProvider.notifier).removeHiddenChannel(key),
            ),
          ),
          FormGroup(
            label: 'Blocked Channels',
            child: _removableList(
              entries: state.blockedChannels,
              emptyText: 'No blocked channels',
              buttonLabel: 'Unblock',
              labelFor: (key) => '#$key',
              onRemove: (key) =>
                  ref.read(appStateProvider.notifier).removeBlockedChannel(key),
            ),
          ),
        ],
      ],
    );
  }

  /// Default-landing-channel searchable field (F8): a text input that, when
  /// focused/typed, shows a grouped suggestions overlay (Common / Joined
  /// geohash channels). Picking an option seeds the field + `_landing`; SAVE
  /// persists it.
  Widget _landingChannelField(List<ChannelEntry> channels) {
    final c = context.nym;
    final options = buildLandingChannelOptions(channels);
    final query = _landingController.text;
    final filterLower = query.toLowerCase().replaceFirst(RegExp(r'^#'), '');
    final filtered = (query.isEmpty || query == _landing.label)
        ? options
        : options.where((o) => o.searchText.contains(filterLower)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormInput(
          controller: _landingController,
          focusNode: _landingFocus,
          hint: 'Type to search or select a channel...',
          onChanged: (_) => setState(() => _landingOpen = true),
          onTap: () => setState(() => _landingOpen = true),
        ),
        if (_landingOpen)
          Container(
            margin: const EdgeInsets.only(top: 4),
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(
              color: c.bgTertiary,
              borderRadius: NymRadius.rsm,
              border: Border.all(color: c.glassBorder),
            ),
            clipBehavior: Clip.antiAlias,
            child: filtered.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('No channels found',
                        style: TextStyle(color: c.textDim, fontSize: 12)),
                  )
                : ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: _buildLandingRows(filtered, c),
                  ),
          ),
      ],
    );
  }

  List<Widget> _buildLandingRows(
      List<LandingChannelOption> options, NymColors c) {
    final rows = <Widget>[];
    String? lastGroup;
    for (final o in options) {
      if (o.group != lastGroup) {
        lastGroup = o.group;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Text(
            o.group,
            style: TextStyle(
              color: c.textDim,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ));
      }
      final selected = o.value == _landing;
      rows.add(InkWell(
        onTap: () {
          setState(() {
            _landing = o.value;
            _landingController.text = o.label;
            _landingOpen = false;
          });
          _landingFocus.unfocus();
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          color: selected ? c.primaryA(0.10) : null,
          child: Text(
            o.label,
            style: TextStyle(
              color: selected ? c.primary : c.text,
              fontSize: 13,
            ),
          ),
        ),
      ));
    }
    return rows;
  }

  // --- Mobile Gestures ------------------------------------------------------

  Widget _mobile(Settings s, SettingsController ctrl) {
    const swipeActions = <({String value, String label})>[
      (value: 'quote', label: 'Quote Reply'),
      (value: 'translate', label: 'Translate'),
      (value: 'copy', label: 'Copy Message'),
      (value: 'react', label: 'Quick React'),
      (value: 'zap', label: 'Zap Bitcoin'),
      (value: 'slap', label: 'Slap with Trout'),
      (value: 'hug', label: 'Give Warm Hug'),
      (value: 'none', label: 'None'),
    ];
    // Swipe-right's options list leads with Translate in the PWA markup.
    const swipeRightActions = <({String value, String label})>[
      (value: 'translate', label: 'Translate'),
      (value: 'quote', label: 'Quote Reply'),
      (value: 'copy', label: 'Copy Message'),
      (value: 'react', label: 'Quick React'),
      (value: 'zap', label: 'Zap Bitcoin'),
      (value: 'slap', label: 'Slap with Trout'),
      (value: 'hug', label: 'Give Warm Hug'),
      (value: 'none', label: 'None'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormGroup(
          label: 'Swipe Gestures (Mobile)',
          hint: 'Swipe a message horizontally to trigger an action. Disable '
              'to turn off all swipe gestures on messages.',
          child: FormSelect<bool>(
            value: s.gesturesEnabled,
            items: const [
              (value: true, label: 'Enabled'),
              (value: false, label: 'Disabled'),
            ],
            onChanged: ctrl.setGesturesEnabled,
          ),
        ),
        // Swipe sub-settings hide when gestures are disabled (F16;
        // app.js:3305 updateSwipeSubsettings).
        if (s.gesturesEnabled) ...[
          FormGroup(
            label: 'Swipe Left Action',
            hint: 'Action triggered when swiping a message to the left.',
            child: FormSelect<String>(
              value: s.swipeLeftAction,
              items: swipeActions,
              onChanged: ctrl.setSwipeLeftAction,
            ),
          ),
          FormGroup(
            label: 'Swipe Right Action',
            hint: 'Action triggered when swiping a message to the right.',
            child: FormSelect<String>(
              value: s.swipeRightAction,
              items: swipeRightActions,
              onChanged: ctrl.setSwipeRightAction,
            ),
          ),
          // The Quick-React-emoji group only shows when a swipe action is set
          // to "Quick React" (the PWA's `needsEmoji`).
          if (s.swipeLeftAction == 'react' || s.swipeRightAction == 'react')
            FormGroup(
              label: 'Quick React Emoji',
              hint: 'Emoji always used when a swipe gesture is set to "Quick '
                  'React". Tap to choose from the full emoji picker.',
              child: Align(
                alignment: Alignment.centerLeft,
                child: NymOutlineButton(
                  label: '${s.swipeReactEmoji}   Change',
                  uppercase: false,
                  onPressed: () => _openSwipeReactPicker(ctrl),
                ),
              ),
            ),
          FormGroup(
            label: 'Swipe Sensitivity',
            hint: 'How far you need to swipe before the action fires. Higher '
                'sensitivity means a shorter swipe.',
            child: FormSelect<int>(
              value: s.swipeThreshold,
              items: const [
                (value: 40, label: 'High (40px)'),
                (value: 60, label: 'Medium (60px)'),
                (value: 80, label: 'Low (80px)'),
                (value: 100, label: 'Very Low (100px)'),
              ],
              onChanged: ctrl.setSwipeThreshold,
            ),
          ),
        ],
      ],
    );
  }

  // --- Data & Backup --------------------------------------------------------

  Widget _data(Settings s, SettingsController ctrl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormGroup(
          label: 'Low Data Mode',
          hint: 'Reduces bandwidth by connecting to only 5 default relays and '
              'loading geo relays on-demand when entering channels',
          child: FormSelect<bool>(
            value: s.lowDataMode,
            items: const [
              (value: false, label: 'Disabled'),
              (value: true, label: 'Enabled'),
            ],
            onChanged: ctrl.setLowDataMode,
          ),
        ),
        FormGroup(
          label: 'Transfer Settings to Another User',
          hint: 'Transfers your nickname, avatar, and all preferences to the '
              'specified pubkey',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: FormInput(
                      controller: _transferPubkeyController,
                      hint: 'Recipient hex pubkey (64 chars)',
                      onChanged: (_) {
                        if (_transferError != null) {
                          setState(() => _transferError = null);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  NymOutlineButton(
                    label: _transferSending ? 'Sending…' : 'Send',
                    onPressed: _transferSending ? () {} : _sendTransfer,
                  ),
                ],
              ),
              // Inline validation error (F9; #settingsTransferError).
              if (_transferError != null) ...[
                const SizedBox(height: 6),
                Text(
                  _transferError!,
                  style: TextStyle(
                      color: context.nym.danger, fontSize: 11, height: 1.4),
                ),
              ],
            ],
          ),
        ),
        FormGroup(
          label: 'Pending Settings Transfers',
          child: _pendingTransfers(),
        ),
        FormGroup(
          hint: 'Clears the on-device app cache (channel history, PMs, group '
              'chats, profiles, reactions). Preserves your login, settings, '
              'group memberships, and flair purchases.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Real on-device cache readout (F7; refreshAppCacheSize). Shows
              // the PWA's "Calculating…" placeholder until the async
              // `cacheSizeBytes()` read resolves, then the formatted MB total.
              Text(
                _cacheReadout ?? 'Calculating…',
                style: TextStyle(color: context.nym.textDim, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: NymOutlineButton(
                  label: 'Clear Local Storage Cache',
                  onPressed: _clearCache,
                ),
              ),
            ],
          ),
        ),
        FormGroup(
          hint: 'Resets preferences (theme, layout, wallpaper, sound, '
              'favorited/hidden/blocked channels, blocked users, blocked '
              'keywords) to defaults. Preserves your login, group '
              'memberships, PM history, and flair purchases.',
          child: Align(
            alignment: Alignment.centerLeft,
            child: NymOutlineButton(
              label: 'Reset Settings to Defaults',
              onPressed: _resetSettings,
            ),
          ),
        ),
      ],
    );
  }

  /// The list container chrome shared by the moderation lists and the
  /// pending-transfers list (`.blocked-list,.keyword-list`): `padding:10px;
  /// border:1px glass-border; border-radius:var(--radius-sm); background:
  /// rgba(255,255,255,.03); max-height:200px; overflow-y:auto`.
  Widget _listBox({required Widget child}) {
    final c = context.nym;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        color: c.isLight
            ? c.bg
            : Colors.white.withValues(alpha: 0.03),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(10),
        child: child,
      ),
    );
  }

  Widget _emptyListBox(String text) {
    final c = context.nym;
    // Empty state: the dim `.nm-dim12` text inside the same padded list box.
    return _listBox(
      child: Text(
        text,
        style: TextStyle(color: c.textDim, fontSize: 12),
      ),
    );
  }

  /// A populated moderation list (`.keyword-list` / `.blocked-list`): one row
  /// per entry with a trailing Remove/Unblock button, falling back to the dim
  /// empty placeholder when [entries] is empty (F1). Each row resolves a
  /// display label via [labelFor]. Rows are borderless (PWA `.blocked-item`/
  /// `.keyword-item` have no dividers), `padding:5px; margin:2px 0`.
  Widget _removableList({
    required Iterable<String> entries,
    required String emptyText,
    required String buttonLabel,
    required String Function(String entry) labelFor,
    required void Function(String entry) onRemove,
  }) {
    final items = entries.toList();
    if (items.isEmpty) return _emptyListBox(emptyText);
    final c = context.nym;
    return _listBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < items.length; i++)
            Padding(
              // `.blocked-item/.keyword-item { padding: 5px; margin: 2px 0 }`.
              padding: EdgeInsets.only(
                top: i == 0 ? 0 : 4,
                bottom: 4,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      labelFor(items[i]),
                      style: TextStyle(color: c.text, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // `.icon-btn` (Remove/Unblock/Unhide) is uppercase.
                  NymOutlineButton(
                    label: buttonLabel,
                    onPressed: () => onRemove(items[i]),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Pending Settings Transfers list (F17; shop.js:1996
  /// `renderPendingSettingsTransfers`): one card per inbound offer (sender nym +
  /// verified-sender-key + date + an "Includes:" summary) with Accept/Decline
  /// buttons wired to the provider's notifier. Falls back to the dim placeholder
  /// when there are no offers.
  Widget _pendingTransfers() {
    final transfers = ref.watch(pendingSettingsTransfersProvider);
    if (transfers.isEmpty) return _emptyListBox('No pending transfers');
    final c = context.nym;
    final controller = ref.read(nostrControllerProvider);
    void accept(String id) => controller.acceptSettingsTransfer(id);
    void decline(String id) => controller.declineSettingsTransfer(id);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: c.bg.withValues(alpha: c.isLight ? 1 : 0.3),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < transfers.length; i++)
            _transferRow(
              transfers[i],
              isFirst: i == 0,
              onAccept: accept,
              onDecline: decline,
            ),
        ],
      ),
    );
  }

  Widget _transferRow(
    SettingsTransferOffer t, {
    required bool isFirst,
    required void Function(String id) onAccept,
    required void Function(String id) onDecline,
  }) {
    final c = context.nym;
    final count = t.payload.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        border:
            isFirst ? null : Border(top: BorderSide(color: c.glassBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The settings section the offer carries (appearance, privacy, …).
          Text(
            '${_humanizeSection(t.section)} settings',
            style: TextStyle(
                color: c.text, fontSize: 13, fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          // Publishing device's wall-clock for the category.
          Text(
            'Updated ${formatTransferTimestamp(t.updatedAt)}',
            style: TextStyle(color: c.textDim, fontSize: 11),
          ),
          if (count > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Includes: $count ${count == 1 ? 'preference' : 'preferences'}',
                style: TextStyle(color: c.textDim, fontSize: 11),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // `.icon-btn` (Accept/Decline) is uppercase.
              NymOutlineButton(
                label: 'Accept',
                onPressed: () => onAccept(t.id),
              ),
              const SizedBox(width: 8),
              NymOutlineButton(
                label: 'Decline',
                danger: true,
                onPressed: () => onDecline(t.id),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Humanizes a settings-transfer category (`nymchat-settings-appearance` →
  /// `Appearance`) for the pending-transfers list.
  String _humanizeSection(String s) {
    final base =
        s.replaceAll('nymchat-settings-', '').replaceAll('nymchat-', '').trim();
    if (base.isEmpty) return 'Synced';
    return base[0].toUpperCase() + base.substring(1);
  }

  /// Resolves a `base#suffix` display nym for a pubkey, preferring a known user
  /// entry and falling back to the abbreviated pubkey (users.js
  /// `getNymFromPubkey`).
  String _nymLabelFor(String pubkey) {
    final user = ref.read(appStateProvider).users[pubkey];
    if (user != null && user.nym.isNotEmpty) return user.nym;
    return getNymFromPubkey('anon', pubkey);
  }
}

/// Section descriptor for search filtering.
class _SectionSpec {
  _SectionSpec({
    required this.key,
    required this.title,
    required this.keywords,
    required this.builder,
  });
  final String key;
  final String title;
  final String keywords;
  final Widget Function() builder;
}

// === Pickers ================================================================

/// Theme picker showing each of the six themes with its real accent dot.
class _ThemePicker extends ConsumerWidget {
  const _ThemePicker({required this.value, required this.onChanged});
  final NymThemeKey value;
  final ValueChanged<NymThemeKey> onChanged;

  static const _labels = {
    NymThemeKey.bitchat: 'Bitchat (Multicolor)',
    NymThemeKey.matrix: 'Matrix Green',
    NymThemeKey.amber: 'Amber Terminal',
    NymThemeKey.cyber: 'Cyberpunk',
    NymThemeKey.hacker: 'Hacker Blue',
    NymThemeKey.ghost: 'Ghost (B&W)',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final brightness = c.brightness;
    return Column(
      children: [
        for (final t in NymThemeKey.values)
          () {
            final accent = resolveNymColors(
              theme: t,
              brightness: brightness,
              solidUi: true,
            ).primary;
            final selected = t == value;
            return InkWell(
              onTap: () => onChanged(t),
              borderRadius: NymRadius.rsm,
              child: Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: selected
                      ? c.primaryA(0.10)
                      : c.bg.withValues(alpha: c.isLight ? 1 : 0.3),
                  borderRadius: NymRadius.rsm,
                  border: Border.all(
                    color: selected ? c.primaryA(0.5) : c.glassBorder,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: c.glassBorder),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _labels[t]!,
                        style: TextStyle(
                          color: selected ? c.primary : c.text,
                          fontSize: 13,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (selected)
                      Icon(Icons.check, size: 16, color: c.primary),
                  ],
                ),
              ),
            );
          }(),
      ],
    );
  }
}

/// Wallpaper picker: 3-column grid of the 8 built-in patterns + Upload, with
/// the selected option ringed in the accent color.
class _WallpaperPicker extends StatelessWidget {
  const _WallpaperPicker({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  static const _options = <({String id, String label})>[
    (id: 'none', label: 'None'),
    (id: 'geometric', label: 'Geometric'),
    (id: 'circuit', label: 'Circuit'),
    (id: 'dots', label: 'Dots'),
    (id: 'waves', label: 'Waves'),
    (id: 'topography', label: 'Topography'),
    (id: 'hexagons', label: 'Hexagons'),
    (id: 'diamonds', label: 'Diamonds'),
    (id: 'custom', label: 'Upload'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 1.4,
      children: [
        for (final o in _options)
          GestureDetector(
            onTap: () => onChanged(o.id),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: c.bg.withValues(alpha: c.isLight ? 1 : 0.4),
                      borderRadius: NymRadius.rxs,
                      border: Border.all(
                        color: o.id == value ? c.primary : c.glassBorder,
                        width: o.id == value ? 2 : 1,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      o.id == 'none'
                          ? Icons.close
                          : o.id == 'custom'
                              ? Icons.file_upload_outlined
                              : Icons.texture,
                      size: 18,
                      color: c.textDim,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  o.label,
                  style: TextStyle(
                    color: o.id == value ? c.primary : c.textDim,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A selectable preview card shared by the Chat-View (`.view-option`) and
/// Message-Layout (`.layout-option`) pickers: a 2px-bordered card (radius sm)
/// whose preview area sits above a label; selecting it switches the border to
/// solid `--primary`, adds a `0 0 12px primary@.25` glow, and tints the label
/// primary.
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.selected,
    required this.label,
    required this.preview,
    required this.onTap,
  });

  final bool selected;
  final String label;
  final Widget preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          // `.view-option/.layout-option { border: 2px solid glass-border;
          //   border-radius: var(--radius-sm); padding: 8px }`.
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: NymRadius.rsm,
            border: Border.all(
              color: selected ? c.primary : c.glassBorder,
              width: 2,
            ),
            // `.selected { box-shadow: 0 0 12px primary@.25 }`.
            boxShadow: selected
                ? [BoxShadow(color: c.primaryA(0.25), blurRadius: 12)]
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              preview,
              // `.view-label/.layout-label { padding-top: 6px; font-size: 11px;
              //   color: text-dim }`; selected → primary.
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected ? c.primary : c.textDim,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One faux column in the Chat-View preview (`.vp-col`): a `bg-tertiary` box of
/// dim bars; `bars` is the list of bar widths where `true` = full, `false` =
/// 60% (`.vp-bar.short`). The caller controls width (Expanded for columns,
/// FractionallySizedBox for the centered single column).
class _VpCol extends StatelessWidget {
  const _VpCol({required this.bars});
  final List<bool> bars;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      // `.vp-col { padding: 5px; gap: 4px; background: bg-tertiary;
      //   border: 1px glass-border; border-radius: 4px }`.
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < bars.length; i++) ...[
            if (i > 0) const SizedBox(height: 4),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              // `.vp-bar.short { width: 60% }` else 100%.
              widthFactor: bars[i] ? 1.0 : 0.6,
              child: Container(
                // `.vp-bar { height: 5px; border-radius: 3px; background:
                //   text-dim; opacity: .5 }`.
                height: 5,
                decoration: BoxDecoration(
                  color: c.textDim.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Chat-View picker: two `.view-option` cards with miniature column-layout
/// previews (single = one 60%-width column; columns = three columns), mirroring
/// index.html:1389-1404.
class _ViewPicker extends StatelessWidget {
  const _ViewPicker({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;

    // `.view-preview { min-height: 90px; padding: 8px; gap: 4px; background:
    //   rgba(0,0,0,.3); border-radius: var(--radius-xs) }`; selected →
    //   primary@.08.
    Widget previewBox(bool selected, MainAxisAlignment align,
        List<Widget> cols) {
      return Container(
        constraints: const BoxConstraints(minHeight: 90),
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: selected
              ? c.primaryA(0.08)
              : Colors.black.withValues(alpha: c.isLight ? 0.06 : 0.3),
          borderRadius: NymRadius.rxs,
        ),
        child: Row(
          mainAxisAlignment: align,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: cols,
        ),
      );
    }

    final singleSel = value == 'single';
    final columnsSel = value == 'columns';
    // `.view-grid { display: flex; gap: 12px }` with equal-height cards.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PreviewCard(
            selected: singleSel,
            label: 'Single Chat (Default)',
            onTap: () => onChanged('single'),
            // Single: one centered column at 60% width (`.vp-col{flex:0 0 60%}`)
            // — flex 1:3:1 spacers give the 3/5 = 60% centered column.
            preview: previewBox(singleSel, MainAxisAlignment.center, const [
              Spacer(),
              Expanded(flex: 3, child: _VpCol(bars: [true, false, true, false])),
              Spacer(),
            ]),
          ),
          const SizedBox(width: 12),
          _PreviewCard(
            selected: columnsSel,
            label: 'Column View',
            onTap: () => onChanged('columns'),
            // Columns: three equal-flex columns (`.vp-col{flex:1}`).
            preview: previewBox(columnsSel, MainAxisAlignment.start, const [
              Expanded(child: _VpCol(bars: [true, false])),
              SizedBox(width: 4),
              Expanded(child: _VpCol(bars: [false, true])),
              SizedBox(width: 4),
              Expanded(child: _VpCol(bars: [true])),
            ]),
          ),
        ],
      ),
    );
  }
}

/// Message-layout picker (Bubbles / IRC) as two `.layout-option` cards, each
/// previewing a realistic 3-line mini chat (bubbles or IRC), mirroring
/// index.html:1481-1496.
class _LayoutPicker extends StatelessWidget {
  const _LayoutPicker({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  // The mock messages the PWA hardcodes into the preview.
  static const _rows = <({String nick, String suffix, String msg, bool self})>[
    (nick: 'alice', suffix: '#e45f', msg: 'hey there!', self: false),
    (nick: 'you', suffix: '#6si9', msg: 'hello!', self: true),
    (nick: 'bob', suffix: '#2t5g', msg: "what's up?", self: false),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final bubblesSel = value == 'bubbles';
    final ircSel = value == 'irc';
    // `.layout-grid { display: flex; gap: 12px }` with equal-height cards.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PreviewCard(
            selected: bubblesSel,
            label: 'Bubbles (Default)',
            onTap: () => onChanged('bubbles'),
            preview: _layoutPreviewBox(c, bubbles: true),
          ),
          const SizedBox(width: 12),
          _PreviewCard(
            selected: ircSel,
            label: 'IRC Style',
            onTap: () => onChanged('irc'),
            preview: _layoutPreviewBox(c, bubbles: false),
          ),
        ],
      ),
    );
  }

  /// `.layout-preview { min-height: 72px; padding: 8px; background:
  /// rgba(0,0,0,.3); border-radius: var(--radius-xs); gap: 3px }` (bubbles
  /// variant: padding 6/4, gap 4).
  Widget _layoutPreviewBox(NymColors c, {required bool bubbles}) {
    return Container(
      constraints: const BoxConstraints(minHeight: 72),
      width: double.infinity,
      padding: bubbles
          ? const EdgeInsets.symmetric(horizontal: 4, vertical: 6)
          : const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: c.isLight ? 0.06 : 0.3),
        borderRadius: NymRadius.rxs,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < _rows.length; i++) ...[
            if (i > 0) SizedBox(height: bubbles ? 4 : 3),
            bubbles ? _bubble(c, _rows[i]) : _ircLine(c, _rows[i]),
          ],
        ],
      ),
    );
  }

  /// A mini chat bubble (`.lp-bubble`): other = left `white@.14`, self = right
  /// `primary@.2`; nick block in `--secondary`, text in `--text`.
  Widget _bubble(
      NymColors c, ({String nick, String suffix, String msg, bool self}) r) {
    final bubble = Container(
      // `.lp-bubble { padding: 3px 7px; border-radius: 8px; max-width: 80% }`.
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: r.self
            ? c.primaryA(0.2)
            : Colors.white.withValues(alpha: 0.14),
        // radius 8, with the inner top corner squared to 2px.
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(r.self ? 8 : 2),
          topRight: Radius.circular(r.self ? 2 : 8),
          bottomLeft: const Radius.circular(8),
          bottomRight: const Radius.circular(8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // `.lp-bubble-nick { color: secondary; font-size: 7px; weight: 600 }`
          // + the dim `.nym-suffix`.
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: r.nick),
                TextSpan(
                  text: r.suffix,
                  style: TextStyle(
                    color: c.secondary.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w100,
                  ),
                ),
              ],
            ),
            style: TextStyle(
              color: c.secondary,
              fontSize: 7,
              fontWeight: FontWeight.w600,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 1),
          // `.lp-bubble-text { color: text; font-size: 8px }`.
          Text(
            r.msg,
            style: TextStyle(color: c.text, fontSize: 8, height: 1.3),
          ),
        ],
      ),
    );
    // `max-width: 80%` of the preview, aligned left (other) / right (self).
    return FractionallySizedBox(
      widthFactor: 0.8,
      alignment: r.self ? Alignment.centerRight : Alignment.centerLeft,
      child: Align(
        alignment: r.self ? Alignment.centerRight : Alignment.centerLeft,
        child: bubble,
      ),
    );
  }

  /// An IRC preview line (`.layout-line`): `<nick#suffix> msg`, mono 9px, nick
  /// in `--secondary` (self → `--primary`), msg in `--text`.
  Widget _ircLine(
      NymColors c, ({String nick, String suffix, String msg, bool self}) r) {
    final nickColor = r.self ? c.primary : c.secondary;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '<${r.nick}',
            style: TextStyle(color: nickColor, fontWeight: FontWeight.w600),
          ),
          TextSpan(
            text: r.suffix,
            style: TextStyle(
              color: nickColor.withValues(alpha: 0.7),
              fontWeight: FontWeight.w100,
            ),
          ),
          TextSpan(
            text: '> ',
            style: TextStyle(color: nickColor, fontWeight: FontWeight.w600),
          ),
          TextSpan(text: r.msg, style: TextStyle(color: c.text)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.clip,
      softWrap: false,
      style: TextStyle(
        fontFamily: kMonoFont,
        fontSize: 9,
        height: 1.4,
      ),
    );
  }
}

/// Text-size slider row: small "A", slider, large "A", value badge, Reset.
class _TextSizeRow extends StatelessWidget {
  const _TextSizeRow({
    required this.value,
    required this.previewColor,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onReset,
  });

  final double value;
  final Color previewColor;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Row(
      children: [
        Text('A', style: TextStyle(color: c.textDim, fontSize: 12)),
        Expanded(
          child: SliderTheme(
            // `.form-range`: track height 4px, uniform `glass-border` (no
            // active/inactive split); thumb 16px (radius 8) `--primary`.
            data: SliderThemeData(
              activeTrackColor: c.glassBorder,
              inactiveTrackColor: c.glassBorder,
              thumbColor: c.primary,
              overlayColor: c.primaryA(0.2),
              trackHeight: 4,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 8),
            ),
            child: Slider(
              value: value.clamp(
                  NymTextSize.min, NymTextSize.max),
              min: NymTextSize.min,
              max: NymTextSize.max,
              divisions: (NymTextSize.max - NymTextSize.min).round(),
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ),
        Text('A', style: TextStyle(color: c.textDim, fontSize: 20)),
        const SizedBox(width: 8),
        Text(
          '${value.round()}px',
          style: TextStyle(color: previewColor, fontSize: 12),
        ),
        const SizedBox(width: 8),
        NymOutlineButton(
            label: 'Reset', onPressed: onReset, uppercase: false),
      ],
    );
  }
}

// === Static option lists ====================================================

/// Notification-sound options, verbatim and in order from `#soundSelect`.
const List<({String value, String label})> _soundOptions = [
  (value: 'beep', label: 'Classic Beep'),
  (value: 'low', label: 'Low Tone'),
  (value: 'high', label: 'High Ping'),
  (value: 'uhoh', label: 'ICQ Uh-Oh'),
  (value: 'msnding', label: 'MSN Alert'),
  (value: 'nudge', label: 'MSN Nudge'),
  (value: 'nokia', label: 'Nokia SMS'),
  (value: 'nokiatune', label: 'Nokia Tune'),
  (value: 'dialup', label: 'Dial-Up Modem'),
  (value: 'coin', label: 'Mario Coin'),
  (value: 'oneup', label: 'Mario 1-Up'),
  (value: 'powerup', label: 'Mario Power-Up'),
  (value: 'secret', label: 'Zelda Secret'),
  (value: 'gameboy', label: 'Game Boy Boot'),
  (value: 'tetris', label: 'Tetris'),
  (value: 'pokeheal', label: 'Pokémon Heal'),
  (value: 'chirp', label: 'Communicator Chirp'),
  (value: 'f1', label: 'F1 Radio'),
  (value: 'none', label: 'Silent'),
];

/// Translation-language options, verbatim and in order from
/// `#translateLanguageSelect` (empty value = Disabled).
const List<({String value, String label})> _translationLanguages = [
  (value: '', label: 'Disabled'),
  (value: 'en', label: 'English'),
  (value: 'es', label: 'Spanish'),
  (value: 'fr', label: 'French'),
  (value: 'de', label: 'German'),
  (value: 'it', label: 'Italian'),
  (value: 'pt', label: 'Portuguese'),
  (value: 'ru', label: 'Russian'),
  (value: 'zh', label: 'Chinese'),
  (value: 'ja', label: 'Japanese'),
  (value: 'ko', label: 'Korean'),
  (value: 'ar', label: 'Arabic'),
  (value: 'hi', label: 'Hindi'),
  (value: 'tr', label: 'Turkish'),
  (value: 'nl', label: 'Dutch'),
  (value: 'pl', label: 'Polish'),
  (value: 'uk', label: 'Ukrainian'),
  (value: 'vi', label: 'Vietnamese'),
  (value: 'th', label: 'Thai'),
  (value: 'id', label: 'Indonesian'),
  (value: 'sv', label: 'Swedish'),
  (value: 'af', label: 'Afrikaans'),
  (value: 'bg', label: 'Bulgarian'),
  (value: 'bn', label: 'Bengali'),
  (value: 'ca', label: 'Catalan'),
  (value: 'cs', label: 'Czech'),
  (value: 'da', label: 'Danish'),
  (value: 'el', label: 'Greek'),
  (value: 'et', label: 'Estonian'),
  (value: 'fa', label: 'Persian'),
  (value: 'fi', label: 'Finnish'),
  (value: 'fil', label: 'Filipino'),
  (value: 'he', label: 'Hebrew'),
  (value: 'hr', label: 'Croatian'),
  (value: 'hu', label: 'Hungarian'),
  (value: 'lt', label: 'Lithuanian'),
  (value: 'lv', label: 'Latvian'),
  (value: 'ms', label: 'Malay'),
  (value: 'no', label: 'Norwegian'),
  (value: 'ro', label: 'Romanian'),
  (value: 'sk', label: 'Slovak'),
  (value: 'sl', label: 'Slovenian'),
  (value: 'sr', label: 'Serbian'),
  (value: 'sw', label: 'Swahili'),
  (value: 'ta', label: 'Tamil'),
  (value: 'te', label: 'Telugu'),
  (value: 'ur', label: 'Urdu'),
];
