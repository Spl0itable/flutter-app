import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/theme/nym_colors.dart';
import '../core/theme/nym_metrics.dart';
import '../features/calls/call_overlay.dart';
import '../features/calls/call_providers.dart';
import '../features/calls/incoming_call.dart';
import '../features/nymbot/bot_credits_modal.dart';
import '../features/onboarding/tutorial_overlay.dart';
import '../services/location/geolocation.dart';
import '../state/app_state.dart';
import '../state/nostr_controller.dart';
import '../state/settings_provider.dart';
import '../widgets/context_menu/interaction_hooks.dart';
import '../widgets/chat/chat_pane.dart';
import '../widgets/sidebar/sidebar.dart';
import '../widgets/wallpaper/wallpaper_layer.dart';

/// The responsive root of the app shell (`.container`, docs/specs/02 §1.1–1.2).
///
/// Wide (width > 1024): a Row of [Sidebar 290px, Expanded(ChatPane)].
/// Mobile/tablet (<= 1024): the ChatPane fills the width with an off-canvas
/// 300px drawer sidebar that slides in over 150ms behind a dim 0.6 black
/// backdrop; the chat-header hamburger opens it. The PWA gates the off-canvas
/// drawer on `innerWidth <= 1024` (`app.js:45,98,137,178` +
/// `styles-themes-responsive.css:442-476`), so tablets/split-screen get the
/// hamburger drawer + mobile header, not the fixed two-pane layout.
///
/// The call overlay + incoming-call modal are mounted above everything, and
/// the CallService is read on mount so inbound call signals are handled even
/// before any call UI appears.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  /// A stable key BootGate can attach (`HomeShell(key: HomeShell.tutorialKey)`)
  /// and read back as the [TutorialSidebarDriver]
  /// (`HomeShell.tutorialKey.currentState`) to pass to
  /// `TutorialOverlay(sidebar: …)`. Exposed here (this file is owned by the
  /// shell slice) so the BootGate wiring is a single line — see CROSS-FILE
  /// NEEDS. [HomeShellState] implements [TutorialSidebarDriver].
  static final GlobalKey<HomeShellState> tutorialKey =
      GlobalKey<HomeShellState>();

  @override
  ConsumerState<HomeShell> createState() => HomeShellState();
}

class HomeShellState extends ConsumerState<HomeShell>
    implements TutorialSidebarDriver {
  bool _drawerOpen = false;

  /// True while a narrow (<=1024) layout is mounted, so the tutorial driver
  /// knows whether opening/closing the drawer is meaningful.
  bool _narrow = false;

  /// The sidebar edge-swipe threshold: a DEDICATED constant, `this.
  /// swipeThreshold = 50` (app.js:1053-1054) — NOT the user-tunable message
  /// `settings.swipeThreshold` (default 60, options 40-100).
  static const double _sidebarSwipeThreshold = 50;

  /// The touch pointer being tracked by the edge-swipe listener, or null when
  /// no touch is armed. The PWA's `swipeStartX` doubles as this flag — it is
  /// non-null only while a touch that began at `clientX < 50` is down and has
  /// not yet toggled the drawer (ui-context.js:8-30).
  int? _edgeSwipePointer;

  /// Global x of the arming touch-down (the PWA's `swipeStartX`).
  double _edgeSwipeStartX = 0;

  @override
  void initState() {
    super.initState();
    // Fresh tutorial-target keys for this shell instance (prevents a disposed
    // shell's GlobalKeys from reparenting into a newly-mounted one).
    TutorialTargets.reset();
    // Constructing the CallService registers the inbound call-signal handler.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(callServiceProvider);
      _maybeBootProximityLocation();
    });
  }

  /// Boot-time GPS fetch (the PWA's app.js:6855 startup branch): if proximity
  /// sort was already enabled in a prior session AND location permission is
  /// still granted, fetch the fix so the Haversine channel sort engages without
  /// the user re-opening Settings. Best-effort + silent; a denial/timeout simply
  /// leaves `userLocation` null (proximity then falls back to activity order).
  Future<void> _maybeBootProximityLocation() async {
    if (!ref.read(settingsProvider).sortByProximity) return;
    if (ref.read(userLocationProvider) != null) return; // already located
    final status = await Permission.locationWhenInUse.status;
    if (!status.isGranted) return;
    final loc = await fetchCurrentUserLocation();
    if (loc != null && mounted) {
      ref.read(userLocationProvider.notifier).state = loc;
    }
  }

  void _startCall(String peer, {required bool video}) {
    ref.read(callServiceProvider).startCall(peer, video: video);
  }

  void _startGroupCall(String groupId, {required bool video}) {
    ref.read(callServiceProvider).startGroupCall(groupId, video: video);
  }

  // --- TutorialSidebarDriver (narrow-layout drawer open/close per step) ------
  // Mirrors `ensureSidebarOpenOnMobile` / `ensureSidebarClosedOnMobile`
  // (app.js:97-175): on wide layouts these are no-ops; on narrow ones they
  // slide the drawer and resolve once the ~300ms settle window has passed.

  /// The drawer state to restore once the tour ends (`restoreSidebarAfterTutorial`).
  bool? _drawerStateBeforeTour;

  void _rememberDrawerState() {
    _drawerStateBeforeTour ??= _drawerOpen;
  }

  @override
  Future<void> openSidebar() async {
    if (!_narrow) return;
    _rememberDrawerState();
    if (!_drawerOpen && mounted) setState(() => _drawerOpen = true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  @override
  Future<void> closeSidebar() async {
    if (!_narrow) return;
    _rememberDrawerState();
    if (_drawerOpen && mounted) setState(() => _drawerOpen = false);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  @override
  void restore() {
    final prev = _drawerStateBeforeTour;
    _drawerStateBeforeTour = null;
    if (prev == null || !mounted) return;
    if (prev != _drawerOpen) setState(() => _drawerOpen = prev);
  }

  // --- Left-edge swipe (`setupMobileGestures`, ui-context.js:5-32) ----------
  // Raw pointer listeners, NOT gesture-arena recognizers: the PWA binds
  // passive document-level touchstart/touchmove with no axis locking, so the
  // gesture fires on ANY touch (even a sloppy diagonal one that is also
  // scrolling the list) and never steals events from what's underneath —
  // message swipe-left still works inside the edge zone (the message gesture
  // itself abandons only RIGHT swipes starting there, messages.js:2196-2201).

  /// `touchstart`: only a touch landing within 50px of the left edge arms the
  /// gesture (`if (touch.clientX < 50) this.swipeStartX = touch.clientX`).
  void _edgePointerDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.touch) return;
    if (_edgeSwipePointer != null) return;
    if (e.position.dx >= 50) return;
    _edgeSwipePointer = e.pointer;
    _edgeSwipeStartX = e.position.dx;
  }

  /// `touchmove`: net rightward displacement from the touch-down point
  /// (`swipeDistance = clientX - swipeStartX`) past the fixed 50px threshold
  /// calls `toggleSidebar()`, then tracking stops for the rest of the touch
  /// (ui-context.js:16-25). Toggle, not open: the same left-edge right-swipe
  /// CLOSES an open drawer.
  void _edgePointerMove(PointerMoveEvent e) {
    if (e.pointer != _edgeSwipePointer) return;
    if (e.position.dx - _edgeSwipeStartX > _sidebarSwipeThreshold) {
      _edgeSwipePointer = null;
      setState(() => _drawerOpen = !_drawerOpen);
    }
  }

  /// `touchend`/`touchcancel` → `this.swipeStartX = null` (unconditionally —
  /// the PWA resets on any touch lift, ui-context.js:27-29).
  void _edgePointerEnd(PointerEvent e) {
    if (e.kind != PointerDeviceKind.touch) return;
    _edgeSwipePointer = null;
  }

  @override
  Widget build(BuildContext context) {
    // Always-mounted "Gift Nymbot Credits" listener (PWA `showBotCreditsModal`
    // opens from ANYWHERE, not just inside the bot PM). The context menu posts
    // the recipient to `giftCreditsRequestProvider`; here we bind the bot chat
    // (so the paid gift action authenticates), open the gift-credit modal
    // prefilled with the recipient, then consume the one-shot request.
    ref.listen<GiftCreditsRequest?>(giftCreditsRequestProvider, (prev, next) {
      if (next == null) return;
      // Consume immediately so a rebuild can't re-open the modal.
      ref.read(giftCreditsRequestProvider.notifier).consume();
      ref.read(nostrControllerProvider).bindBotChat();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        BotCreditsModal.show(
          context,
          colors: context.nym,
          giftRecipientPubkey: next.pubkey,
          giftRecipientNym: next.nym,
        );
      });
    });

    final c = context.nym;
    final width = MediaQuery.of(context).size.width;
    // Off-canvas drawer governs the whole 0–1024 range; fixed two-pane is
    // >1024 only (PWA `app.js` gates on `innerWidth > 1024`).
    final isWide = width > NymDimens.tabletBreakpoint;
    _narrow = !isWide;

    // Deck (multi-column) vs single chat view (`nym_chat_view_mode`).
    final useColumns =
        ref.watch(settingsProvider.select((s) => s.useColumns));
    // Ghost swaps the ambient glow to white tints with no vignette
    // (`body.theme-ghost::before`).
    final isGhost = ref.watch(
        settingsProvider.select((s) => s.theme == NymThemeKey.ghost));

    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          // `body::before` — always-on ambient corner glows + center vignette,
          // painted beneath the wallpaper (styles-core.css:130-144, with
          // ghost/light overrides). pointer-events:none.
          Positioned.fill(child: _AmbientGlow(c: c, isGhost: isGhost)),
          // `#wallpaperLayer` — fixed, behind all content, pointer-events:none.
          const Positioned.fill(child: WallpaperLayer()),
          Positioned.fill(
            child: isWide
                ? _wide(context, useColumns)
                : _mobile(context, useColumns),
          ),
          // Active-call UI and incoming-call modal render nothing when idle.
          const Positioned.fill(child: CallOverlay()),
          const Positioned.fill(child: IncomingCallModal()),
        ],
      ),
    );
  }

  /// The main content region: always the ChatPane. In columns mode the deck
  /// replaces the messages list INSIDE the pane (so the chat header + composer
  /// stay mounted), matching the PWA, which hides only `#messagesScroller` and
  /// shows `#columnsStrip` in its place (styles-columns.css:9-15) — never the
  /// `.chat-header` or `.input-container`.
  Widget _content(BuildContext context, bool useColumns, {bool compact = false}) {
    return ChatPane(
      compact: compact,
      useColumns: useColumns,
      onOpenSidebar:
          compact ? () => setState(() => _drawerOpen = true) : null,
      onStartCall: _startCall,
      onStartGroupCall: _startGroupCall,
    );
  }

  Widget _wide(BuildContext context, bool useColumns) {
    return Row(
      children: [
        const SizedBox(width: NymDimens.sidebarWidth, child: Sidebar()),
        Expanded(child: _content(context, useColumns)),
      ],
    );
  }

  Widget _mobile(BuildContext context, bool useColumns) {
    // The edge-swipe gesture is phone-only (`if (window.innerWidth <= 768)`,
    // ui-context.js:6).
    final phone = MediaQuery.of(context).size.width <= 768;
    // Left-edge swipe to TOGGLE the drawer (`setupMobileGestures`,
    // ui-context.js:5-32): only on phones (innerWidth <= 768, NOT tablets),
    // a touch starting within 50px of the left edge that travels right past
    // the fixed 50px threshold calls `toggleSidebar()`. A raw Listener over
    // the whole shell mirrors the PWA's passive document-level touch
    // listeners: it never enters the gesture arena, so it cannot lose the
    // swipe to the vertical scrollable (no axis lock) and never swallows the
    // gestures underneath it (message swipe-left still works from the edge).
    // Because it wraps the drawer too, it fires either way and toggles an
    // open drawer closed, like the PWA's document listener.
    final stack = Stack(
      children: [
        Positioned.fill(
          child: _content(context, useColumns, compact: true),
        ),

        // Dim backdrop (`.mobile-overlay`): rgba(0,0,0,0.6) that snaps between
        // display:none/block with NO fade (styles-shell.css:1-14). Only with
        // solid-ui (default ON — Transparency off) does light mode drop the
        // alpha to 0.35 (`body.solid-ui.light-mode .mobile-overlay`,
        // styles-themes-responsive.css:1638-1646); with Transparency enabled
        // it stays 0.6 in both modes. Tap to close.
        if (_drawerOpen)
          GestureDetector(
            onTap: () => setState(() => _drawerOpen = false),
            child: Container(
              color: Colors.black.withValues(
                alpha: ref.watch(settingsProvider
                            .select((s) => s.solidUi)) &&
                        context.nym.isLight
                    ? 0.35
                    : 0.6,
              ),
            ),
          ),

        // Off-canvas drawer: translateX(-100%) → 0 over 150ms linear.
        AnimatedSlide(
          duration: NymMotion.slide,
          curve: Curves.linear,
          offset: _drawerOpen ? Offset.zero : const Offset(-1, 0),
          child: SizedBox(
            width: NymDimens.sidebarDrawerWidth,
            height: double.infinity,
            // `.sidebar.open { box-shadow: 10px 0 40px rgba(0,0,0,0.5) }` — a
            // directional (rightward-only) drop shadow, not a Material ambient
            // elevation (styles-themes-responsive.css:198-201). The edge-swipe
            // Listener above wraps the drawer too, so a left-edge right-swipe
            // over the open drawer toggles it CLOSED, like the PWA's
            // document-level listener.
            child: DecoratedBox(
              decoration: BoxDecoration(
                boxShadow: _drawerOpen
                    ? [
                        BoxShadow(
                          offset: const Offset(10, 0),
                          blurRadius: 40,
                          color: Colors.black.withValues(alpha: 0.5),
                        ),
                      ]
                    : const [],
              ),
              child: Sidebar(
                compact: true,
                onItemSelected: () => setState(() => _drawerOpen = false),
              ),
            ),
          ),
        ),
      ],
    );
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: phone ? _edgePointerDown : null,
      onPointerMove: phone ? _edgePointerMove : null,
      onPointerUp: phone ? _edgePointerEnd : null,
      onPointerCancel: phone ? _edgePointerEnd : null,
      child: stack,
    );
  }
}

/// `body::before`: the always-on ambient layer — two corner radial glows plus a
/// center→edge vignette (styles-core.css:130-144). Ghost swaps to white tints
/// with no vignette (`body.theme-ghost::before`, :520-524); light mode lowers
/// the corner alphas and also drops the vignette (`body.light-mode::before`,
/// :540-544). pointer-events:none.
class _AmbientGlow extends StatelessWidget {
  const _AmbientGlow({required this.c, required this.isGhost});
  final NymColors c;
  final bool isGhost;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _AmbientGlowPainter(c: c, isGhost: isGhost),
      ),
    );
  }
}

class _AmbientGlowPainter extends CustomPainter {
  _AmbientGlowPainter({required this.c, required this.isGhost});
  final NymColors c;
  final bool isGhost;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Corner glow colors per variant. CSS specificity ties resolve by source
    // order, so for ghost-LIGHT `body.light-mode::before` (line 540) wins over
    // `body.theme-ghost::before` (line 520) → the light primary/secondary tints,
    // not white. Hence: light first (covers ghost-light), then ghost-dark white,
    // then dark non-ghost.
    //   Light: primary@0.03 / secondary@0.02; ghost-dark: white@0.02 / 0.015;
    //   dark: primary@0.04 / secondary@0.03.
    final Color glow20, glow80;
    if (c.isLight) {
      glow20 = c.primary.withValues(alpha: 0.03);
      glow80 = c.secondary.withValues(alpha: 0.02);
    } else if (isGhost) {
      glow20 = Colors.white.withValues(alpha: 0.02);
      glow80 = Colors.white.withValues(alpha: 0.015);
    } else {
      glow20 = c.primary.withValues(alpha: 0.04);
      glow80 = c.secondary.withValues(alpha: 0.03);
    }

    // `radial-gradient(ellipse at 20% 20%, color 0%, transparent 50%)`. Flutter
    // stretches the radial to the rect (→ ellipse); stops [0,0.5] put the fade
    // halfway out, matching CSS `transparent 50%`. radius 1.0 ≈ farthest-corner.
    void corner(Alignment center, Color color) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            center: center,
            radius: 1.0,
            colors: [color, color.withValues(alpha: 0)],
            stops: const [0.0, 0.5],
          ).createShader(rect),
      );
    }

    corner(const Alignment(-0.6, -0.6), glow20); // 20% 20%
    corner(const Alignment(0.6, 0.6), glow80); // 80% 80%

    // Center vignette (dark non-ghost only): rgba(0,0,0,0) center → 0.2 edge.
    if (!isGhost && !c.isLight) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            center: Alignment.center,
            radius: 0.75,
            colors: [
              const Color(0x00000000),
              Colors.black.withValues(alpha: 0.2),
            ],
            stops: const [0.0, 1.0],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(_AmbientGlowPainter old) =>
      old.c.primary != c.primary ||
      old.c.secondary != c.secondary ||
      old.c.isLight != c.isLight ||
      old.isGhost != isGhost;
}
