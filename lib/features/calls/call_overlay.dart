// call_overlay.dart - #callOverlay port: full-screen active-call UI.
//
// Layout mirrors index.html #callOverlay:
//   - top: call title (peer / group) + status (status text or m:ss timer)
//   - body: participant video grid (RTCVideoView) + self preview + chat panel
//   - floating reactions overlay + reactions bar + presenter menu
//   - controls row: mute, camera, screenshare, presenter(mod), react, chat,
//     switch-cam, end (red)
//
// Renders nothing unless there is an active call.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../state/app_state.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/context_menu/context_menu_actions.dart';
import '../../widgets/context_menu/context_menu_panel.dart';
import '../../widgets/nym_icons.dart';
import '../emoji/emoji_picker.dart';
import '../messages/format/message_content.dart';
import '../shop/cosmetics.dart';
import '../reactions/quick_react_popup.dart';
import 'call_nym.dart';
import 'call_providers.dart';
import 'call_service.dart';
import 'call_signaling.dart';
import 'call_state.dart';

/// Opens the shared user context menu (block / friend / PM / report …) from a
/// nickname tapped in the call overlay or call chat — a 1:1 port of the PWA's
/// `showCallUserMenu` (calls.js:41), which calls `showContextMenu(..., /*
/// profileOnly */ true)`. [profileOnly] trims the message-only actions that
/// don't apply during a call (React/Quote/Copy/Translate/Slap/Hug/Edit), leaving
/// PM / Create Group / Gift Credits / Friend / Report / Block. No-op for self /
/// empty pubkey (calls.js:42). `ContextMenuPanel` re-derives the live
/// friend/block flags from app_state, so only pubkey + base nym are needed.
void showCallUserMenu(BuildContext context, String pubkey, {String? nym}) {
  if (pubkey.isEmpty) return;
  // Resolve the display base nym: prefer a caller-supplied nym, else the live
  // `usersProvider` entry (the call chat-from line carries no nym), else fall
  // back to the pubkey (`_nymForPubkey`, calls.js).
  final container = ProviderScope.containerOf(context);
  final resolved = (nym != null && nym.isNotEmpty)
      ? nym
      : (container.read(usersProvider)[pubkey]?.nym ?? pubkey);
  ContextMenuPanel.show(
    context,
    target: CtxTarget(
      pubkey: pubkey,
      nym: stripPubkeySuffix(resolved),
      isSelf: false,
      profileOnly: true,
    ),
  );
}

class CallOverlay extends ConsumerStatefulWidget {
  const CallOverlay({super.key});

  @override
  ConsumerState<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends ConsumerState<CallOverlay> {
  bool _chatOpen = false;
  bool _reactionsOpen = false;
  bool _presenterOpen = false;
  final _chatController = TextEditingController();

  @override
  void dispose() {
    _chatController.dispose();
    super.dispose();
  }

  /// Opens the full emoji picker (reactions-bar "+" / chat-react "more") as a
  /// bottom sheet over the call overlay; [onPick] receives the chosen emoji.
  void _openEmojiPicker(ValueChanged<String> onPick) {
    final recents = ref.read(recentEmojisProvider);
    final c = context.nym;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) => SafeArea(
        child: Container(
          height: MediaQuery.of(sheetCtx).size.height * 0.55,
          decoration: BoxDecoration(
            color: c.bgSecondary,
            border: Border(top: BorderSide(color: c.glassBorder)),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          clipBehavior: Clip.antiAlias,
          child: EmojiPicker(
            recents: recents,
            onSelect: (emoji) {
              Navigator.of(sheetCtx).maybePop();
              onPick(emoji);
            },
          ),
        ),
      ),
    );
  }

  /// Builds the call-chat panel (`#callChatPanel`). On wide layouts it is a
  /// fixed-320px flex sibling of the grid (so the grid resizes); on narrow
  /// layouts it fills the body.
  Widget _buildChatPanel(CallService service) {
    final call = ref.watch(currentCallStateProvider);
    return _ChatPanel(
      call: call,
      controller: _chatController,
      onClose: () => setState(() => _chatOpen = false),
      onSend: (t) {
        service.sendChat(t);
        _chatController.clear();
      },
      onTyping: service.sendTyping,
      onReact: service.toggleChatReaction,
      onMorePicker: (mid) =>
          _openEmojiPicker((e) => service.toggleChatReaction(mid, e)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(currentCallStateProvider);
    if (!call.isActiveCall) return const SizedBox.shrink();

    final service = ref.read(callServiceProvider);

    return Material(
      // `.call-overlay`: dark rgba(5,5,10,0.96) (#05050a @ 0.96); light mode
      // flips to rgba(245,245,242,0.95) (`body.light-mode .call-overlay`,
      // styles-features.css:4799). The Material is the parent of SafeArea so
      // the fill still reaches the screen edges (under the notch/status bar).
      color: context.nym.isLight
          ? const Color(0xF2F5F5F2)
          : const Color(0xF505050A),
      child: SafeArea(
        child: Column(
          children: [
            _Top(call: call),
            Expanded(
              child: Stack(
                children: [
                  // `.call-body` is `display:flex`: on wide layouts (>640) the
                  // grid and the 320px chat panel are siblings, so opening chat
                  // SHRINKS the grid; on narrow layouts the panel goes
                  // fullscreen over the grid.
                  if (_chatOpen && MediaQuery.of(context).size.width > 640)
                    Row(
                      children: [
                        Expanded(child: _Grid(call: call, service: service)),
                        _buildChatPanel(service),
                      ],
                    )
                  else
                    _Grid(call: call, service: service),
                  // Floating reactions overlay (`#callReactionsFly`).
                  Positioned.fill(
                    child: IgnorePointer(
                      child: _FlyLayer(reactions: call.flyReactions),
                    ),
                  ),
                  // Switch-camera button: top-right, gated on >1 video input,
                  // hidden while the chat panel is open or sharing.
                  if (call.kind == CallKind.video &&
                      !call.sharing &&
                      !_chatOpen &&
                      call.videoInputCount > 1)
                    Positioned(
                      top: 14,
                      right: 14,
                      child: _SwitchCamButton(
                        disabled: call.switchingCamera,
                        facingMode: call.facingMode,
                        onTap: service.switchCamera,
                      ),
                    ),
                  if (_presenterOpen && call.isMod)
                    Positioned(
                      // `.call-presenter-menu`: right 16, bottom 92 (clear of
                      // the controls row).
                      right: 16,
                      bottom: 92,
                      child: _PresenterMenu(
                        call: call,
                        selfPubkey:
                            ref.read(appStateProvider).selfPubkey,
                        onToggleRestrict: () => service
                            .setScreenShareRestricted(!call.shareRestricted),
                        onAssign: service.assignPresenter,
                      ),
                    ),
                  if (_reactionsOpen)
                    Positioned(
                      // `.call-reactions-bar`: bottom 92 (floats above the
                      // 56px controls).
                      left: 0,
                      right: 0,
                      bottom: 92,
                      child: _ReactionsBar(
                        recents: ref.watch(recentEmojisProvider),
                        onPick: (e) {
                          service.sendReaction(e);
                          setState(() => _reactionsOpen = false);
                        },
                        onMore: () {
                          setState(() => _reactionsOpen = false);
                          _openEmojiPicker(service.sendReaction);
                        },
                      ),
                    ),
                  // Narrow (<=640): the panel is `position:absolute; inset:0`
                  // (fullscreen) over the grid.
                  if (_chatOpen && MediaQuery.of(context).size.width <= 640)
                    Positioned.fill(child: _buildChatPanel(service)),
                ],
              ),
            ),
            _Controls(
              call: call,
              chatOpen: _chatOpen,
              reactionsOpen: _reactionsOpen,
              presenterOpen: _presenterOpen,
              onMute: service.toggleMute,
              onCamera: service.toggleCamera,
              onShare: service.toggleScreenShare,
              onReact: () => setState(() {
                _reactionsOpen = !_reactionsOpen;
                _presenterOpen = false;
              }),
              onPresenter: () => setState(() {
                _presenterOpen = !_presenterOpen;
                _reactionsOpen = false;
              }),
              onChat: () {
                setState(() => _chatOpen = !_chatOpen);
                if (_chatOpen) service.markChatRead();
              },
              onEnd: service.end,
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Title (#callTitle) — `_callTitleHtml`
// =============================================================================

class _Top extends ConsumerWidget {
  const _Top({required this.call});
  final CallState call;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final kindLabel = call.kind == CallKind.video ? 'Video call' : 'Audio call';

    Widget id;
    if (call.isGroup) {
      // Resolve groupId → group name (literal "Group call" fallback).
      final groups = ref.watch(appStateProvider).groups;
      String name = 'Group call';
      for (final g in groups) {
        if (g.id == call.groupId) {
          if (g.name.isNotEmpty) name = g.name;
          break;
        }
      }
      // Up to 4 member avatars (`group-header-avatar`) between the group icon
      // and the name (`_callTitleHtml` group branch). self + remote members.
      final selfPk = ref.watch(appStateProvider).selfPubkey;
      final users = ref.watch(usersProvider);
      final members = <(String pubkey, String seed)>[
        if (selfPk.isNotEmpty) (selfPk, selfPk),
        for (final p in call.participants) (p.pubkey, p.pubkey),
      ].take(4).toList();
      id = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // `.group-header-svg` (calls.js:740) — the three-figure group glyph.
          NymSvgIcon(NymIcons.groupGlyph, size: 18, color: c.textBright),
          if (members.isNotEmpty) ...[
            const SizedBox(width: 6),
            for (final m in members)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: NymAvatar(
                  seed: m.$2,
                  size: 20,
                  imageUrl: users[m.$1]?.profile?.picture, // Rule 4
                ),
              ),
          ],
          const SizedBox(width: 6),
          Flexible(
            child: Text(name,
                style: TextStyle(
                    color: c.textBright,
                    fontSize: 16,
                    fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      );
    } else if (call.peerPubkey != null && call.peerPubkey!.isNotEmpty) {
      final users = ref.watch(usersProvider);
      id = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          NymAvatar(
            seed: call.peerPubkey!,
            size: 22,
            imageUrl: users[call.peerPubkey!]?.profile?.picture, // Rule 4
          ),
          const SizedBox(width: 6),
          Flexible(
            child: CallNym(
              pubkey: call.peerPubkey!,
              nym: call.peerNym,
              baseColor: c.textBright,
              baseStyle:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      );
    } else {
      id = Text(call.peerNym ?? 'Call',
          style: TextStyle(
              color: c.textBright, fontSize: 16, fontWeight: FontWeight.w600));
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // `.call-title-kind`: dim, weight 500.
              Text('$kindLabel · ',
                  style: TextStyle(
                      color: c.textDim,
                      fontSize: 16,
                      fontWeight: FontWeight.w500)),
              Flexible(child: id),
            ],
          ),
          const SizedBox(height: 2),
          Text(call.statusText, style: TextStyle(color: c.textDim, fontSize: 13)),
        ],
      ),
    );
  }
}

// =============================================================================
// Video grid (#callGrid) — breakpoints from styles-features.css:4699-4722
// =============================================================================

class _Grid extends StatelessWidget {
  const _Grid({required this.call, required this.service});
  final CallState call;
  final CallService service;

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      _Tile(
        pubkey: '',
        label: 'You',
        renderer: service.localRenderer,
        hasVideo:
            (call.kind == CallKind.video && !call.cameraOff) || call.sharing,
        seed: 'You',
        self: true,
        mirror: !call.sharing && call.facingMode == 'user',
        sharing: call.sharing,
      ),
      for (final p in call.participants)
        _Tile(
          pubkey: p.pubkey,
          label: p.nym,
          renderer: service.rendererFor(p.pubkey),
          hasVideo: p.hasVideo,
          seed: p.pubkey,
          sharing: p.sharing,
        ),
    ];

    final count = tiles.length;
    final width = MediaQuery.of(context).size.width;
    final wide = width >= 700;

    // PWA mapping: narrow → 1/2:1col, 3/4:2col, 5-9:3col; wide → 2col base
    // (1/2 centred max 1100). Tiles have min-height 160 (no forced aspect).
    final int columns;
    if (wide) {
      columns = 2;
    } else if (count <= 2) {
      columns = 1;
    } else if (count <= 4) {
      columns = 2;
    } else {
      columns = 3;
    }

    final grid = GridView.count(
      crossAxisCount: columns,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      // min-height 160 with cover video: a ~4:3 cell reads close to the PWA's
      // flexible rows without a forced portrait squish.
      childAspectRatio: 4 / 3,
      shrinkWrap: true,
      physics: const ClampingScrollPhysics(),
      children: tiles,
    );

    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: wide && count <= 2 ? 1100 : double.infinity,
            ),
            child: grid,
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.pubkey,
    required this.label,
    required this.renderer,
    required this.hasVideo,
    required this.seed,
    this.self = false,
    this.mirror = false,
    this.sharing = false,
  });

  final String pubkey;
  final String label;
  final RTCVideoRenderer? renderer;
  final bool hasVideo;
  final String seed;
  final bool self;
  final bool mirror;
  final bool sharing;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 160),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            color: c.bgTertiary,
            // `.call-tile` border = `var(--border)` (primary@0.20), primary
            // when presenting.
            border: Border.all(
                color: sharing ? c.primary : c.border, width: 1),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (hasVideo && renderer != null)
                RTCVideoView(
                  renderer!,
                  mirror: mirror,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              else
                Center(child: NymAvatar(seed: seed, size: 84)),
              if (sharing)
                Positioned(
                  top: 8,
                  right: 8,
                  child: _Badge(text: 'Presenting', color: c.primary, fg: c.bg),
                ),
              // `.call-tile-name`: bottom-left, black@0.55, radius 8, decorated.
              Positioned(
                left: 8,
                bottom: 8,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 220),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: self || pubkey.isEmpty
                      ? const Text('You',
                          style: TextStyle(color: Colors.white, fontSize: 12))
                      // Tile name → shared user context menu (PWA
                      // `callNickMenu` / `showCallUserMenu`, calls.js:1566).
                      : GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () =>
                              showCallUserMenu(context, pubkey, nym: label),
                          child: CallNym(
                            pubkey: pubkey,
                            nym: label,
                            baseColor: Colors.white,
                            baseStyle: const TextStyle(fontSize: 12),
                            badgeSize: 12,
                          ),
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

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color, this.fg});
  final String text;
  final Color color;
  final Color? fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: TextStyle(
              color: fg ?? Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600)),
    );
  }
}

// =============================================================================
// Floating reactions (#callReactionsFly) — `.call-react-fly-item` callReactFly
// =============================================================================

class _FlyLayer extends StatelessWidget {
  const _FlyLayer({required this.reactions});
  final List<CallFlyReaction> reactions;

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            for (final r in reactions)
              Positioned(
                left: (r.leftPercent / 100) * constraints.maxWidth,
                bottom: constraints.maxHeight * 0.04,
                child: _FlyItem(key: ValueKey(r.id), reaction: r),
              ),
          ],
        );
      },
    );
  }
}

/// A single flying reaction: rises 0→-260px, scales 0.6→1, fades in then out
/// over 3.1s (`@keyframes callReactFly`).
class _FlyItem extends StatefulWidget {
  const _FlyItem({super.key, required this.reaction});
  final CallFlyReaction reaction;

  @override
  State<_FlyItem> createState() => _FlyItemState();
}

class _FlyItemState extends State<_FlyItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3100),
  )..forward();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = _ctrl.value;
        // @keyframes callReactFly: translateY 0→-26px(12%)→-260px(100%) [linear
        // between keyframes], scale .6→1 by 12%, opacity 0→1 by 12%, hold to
        // 80%, then 1→0 by 100%.
        final double dy;
        final double scale;
        if (t < 0.12) {
          final k = t / 0.12;
          dy = -26 * k; // 12%: -10% of a phone tile height
          scale = 0.6 + 0.4 * k;
        } else {
          final k = (t - 0.12) / 0.88;
          dy = -26 - (260 - 26) * k;
          scale = 1;
        }
        final double opacity;
        if (t < 0.12) {
          opacity = t / 0.12;
        } else if (t < 0.80) {
          opacity = 1;
        } else {
          opacity = 1 - (t - 0.80) / 0.20;
        }
        return Opacity(
          opacity: opacity.clamp(0, 1),
          child: Transform.translate(
            offset: Offset(0, dy),
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // `.call-react-emoji` 2.5rem ≈ 40px on a phone. A custom `:shortcode:`
          // fly-reaction renders as its image (PWA `renderReactionEmoji`,
          // calls.js:1177); unicode falls through to a plain Text.
          InlineEmojiText(
              text: widget.reaction.emoji,
              style: const TextStyle(fontSize: 40),
              emojiSize: 40),
          const SizedBox(height: 2),
          // `.call-react-who`: white on black@0.5, radius 8.
          Container(
            constraints: const BoxConstraints(maxWidth: 160),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: widget.reaction.pubkey != null &&
                    widget.reaction.pubkey!.isNotEmpty
                ? CallNym(
                    pubkey: widget.reaction.pubkey!,
                    baseColor: Colors.white,
                    baseStyle: const TextStyle(fontSize: 11),
                    badgeSize: 11,
                  )
                : Text(widget.reaction.who ?? '',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Reactions bar (#callReactionsBar) — recents-first + "+" more
// =============================================================================

class _ReactionsBar extends StatelessWidget {
  const _ReactionsBar({
    required this.recents,
    required this.onPick,
    required this.onMore,
  });
  final List<String> recents;
  final ValueChanged<String> onPick;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // recents-first padded with the 8 defaults. Keep a custom `:shortcode:`
    // recent when its pack is still known (PWA `_callReactionBarEmojis`,
    // calls.js:1106-1118 → `known()`); without the predicate every custom code
    // is treated as unknown and dropped.
    final codeToUrl =
        ProviderScope.containerOf(context).read(liveCustomEmojiProvider).codeToUrl;
    final emojis = callReactionBarEmojis(recents,
        isKnownCustom: (code) => codeToUrl.containsKey(code));
    return Center(
      child: Container(
        constraints: BoxConstraints(
          maxWidth: math.min(MediaQuery.of(context).size.width * 0.92, 420),
        ),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          color: c.bgTertiary,
          // `.call-reactions-bar` border = `var(--border)` (primary@0.20).
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(22),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 30, offset: Offset(0, 8)),
          ],
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final e in emojis)
              InkWell(
                onTap: () => onPick(e),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  // Known custom `:shortcode:` recents render as their image
                  // (PWA `renderReactionEmoji`, calls.js:1130); unicode falls
                  // through `InlineEmojiText`'s fast path to a plain Text.
                  child: InlineEmojiText(
                      text: e,
                      style: const TextStyle(fontSize: 28),
                      emojiSize: 28),
                ),
              ),
            // `.call-react-more`: dim "+" opens the full picker.
            InkWell(
              onTap: onMore,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Text('＋',
                    style: TextStyle(fontSize: 24, color: c.textDim)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Chat panel (#callChatPanel)
// =============================================================================

class _ChatPanel extends ConsumerWidget {
  const _ChatPanel({
    required this.call,
    required this.controller,
    required this.onClose,
    required this.onSend,
    required this.onTyping,
    required this.onReact,
    required this.onMorePicker,
  });

  final CallState call;
  final TextEditingController controller;
  final VoidCallback onClose;
  final ValueChanged<String> onSend;
  final VoidCallback onTyping;
  final void Function(String mid, String emoji) onReact;
  final ValueChanged<String> onMorePicker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final width = MediaQuery.of(context).size.width;
    final fullscreen = width <= 640;
    return Container(
      width: fullscreen ? width : 320,
      constraints: BoxConstraints(maxWidth: width * 0.84),
      decoration: BoxDecoration(
        color: c.bgSecondary,
        border: Border(left: BorderSide(color: c.glassBorder)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.glassBorder)),
            ),
            child: Row(
              children: [
                Text('Chat',
                    style: TextStyle(
                        color: c.textBright, fontWeight: FontWeight.w600)),
                const Spacer(),
                // `.call-chat-close` is a literal "✕" char in the PWA — render as
                // styled text, not an SVG glyph.
                IconButton(
                  icon: Text('✕',
                      style: TextStyle(
                          color: c.textDim, fontSize: 20, height: 1)),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              itemCount: call.chatLog.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (ctx, i) => _ChatRow(
                msg: call.chatLog[i],
                isGroup: call.isGroup,
                onReact: onReact,
                onMorePicker: onMorePicker,
              ),
            ),
          ),
          if (call.typingPubkeys.isNotEmpty) _TypingLine(pubkeys: call.typingPubkeys),
          _InputRow(
            call: call,
            controller: controller,
            onSend: onSend,
            onTyping: onTyping,
          ),
        ],
      ),
    );
  }
}

/// One chat row: decorated from-line (non-self) + mention-highlighted text +
/// reaction badges, with long-press → quick-react, plus a self read receipt.
class _ChatRow extends ConsumerWidget {
  const _ChatRow({
    required this.msg,
    required this.isGroup,
    required this.onReact,
    required this.onMorePicker,
  });

  final CallChatMessage msg;
  final bool isGroup;
  final void Function(String mid, String emoji) onReact;
  final ValueChanged<String> onMorePicker;

  void _openQuickReact(BuildContext context, Rect anchor) {
    final recents = ProviderScope.containerOf(context)
        .read(recentEmojisProvider);
    // A non-self chat row's quick-react popup exposes a "User options" affordance
    // (PWA `_showCallChatQuickReact` 3-dot `data-qr="menu"`, calls.js:1526,1566)
    // that opens the shared user context menu. Rendered as the inline
    // quick-context-menu card below the pill (the native popup has no in-pill
    // ⋮ slot; `showQuickReactPopup.contextItems` is the supported channel).
    final contextItems = (!msg.isSelf && msg.pubkey.isNotEmpty)
        ? [
            QuickContextItem(
              label: 'User options',
              svg: NymIcons.info,
              onTap: () => showCallUserMenu(context, msg.pubkey),
            ),
          ]
        : const <QuickContextItem>[];
    showQuickReactPopup(
      context,
      anchorRect: anchor,
      emojis: quickReactEmojis(recents),
      onReact: (e) => onReact(msg.mid, e),
      onMore: () => onMorePicker(msg.mid),
      contextItems: contextItems,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    var base = TextStyle(color: c.textBright, fontSize: 14, height: 1.3);

    // Carry the sender's purchased message flair (style / supporter) onto the
    // call-chat text, mirroring `_appendCallChat` (calls.js:1407-1414) which
    // adds `shop.style` / `supporter-style` classes that the `.call-chat-text`
    // rules (styles-features.css:4901-4946) tint with a colour + glow. Kept
    // lightweight (text colour + text-shadow only); supporter wins over a base
    // message style, matching the CSS cascade order.
    if (msg.pubkey.isNotEmpty) {
      final cosmetics = ref.watch(userCosmeticsProvider(msg.pubkey));
      final deco = cosmetics.supporter
          ? supporterStyleDecoration
          : messageStyleDecoration(cosmetics.styleId);
      if (deco != null) {
        base = base.copyWith(
          color: deco.textColor,
          shadows: deco.textShadows,
        );
      }
    }

    return Stack(
      children: [
        _buildRow(context, c, base),
        // `.call-chat-react-btn`: always-present 24×24 ＋ affordance, top-right.
        Positioned(
          top: 0,
          right: 0,
          child: _ChatReactBtn(
            onTap: () {
              final box = context.findRenderObject() as RenderBox?;
              if (box == null || !box.hasSize) return;
              final offset = box.localToGlobal(Offset.zero);
              _openQuickReact(context, offset & box.size);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRow(BuildContext context, NymColors c, TextStyle base) {
    return GestureDetector(
      onLongPress: () {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;
        final offset = box.localToGlobal(Offset.zero);
        _openQuickReact(context, offset & box.size);
      },
      // `.call-chat-msg` is a left-aligned IRC-style log row (no align-self /
      // text-align:right for self in the CSS); self ONLY dims the from-line.
      // The receipt (`.call-chat-readers`) is the sole right-aligned element.
      // Right padding clears the absolute react ＋ button.
      child: Padding(
        padding: const EdgeInsets.only(right: 28),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // `.call-chat-from`: decorated nym (non-self primary, self dim "You").
          if (msg.isSelf)
            Text('You',
                style: TextStyle(
                    color: c.textDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w600))
          else
            // Chat-from nym → shared user context menu (PWA `callNickMenu` →
            // `showCallUserMenu`, inline-bindings.js:289).
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => showCallUserMenu(context, msg.pubkey),
              child: CallNym(
                pubkey: msg.pubkey,
                baseColor: c.primary,
                baseStyle:
                    const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                badgeSize: 11,
              ),
            ),
          const SizedBox(height: 2),
          // Bubble with @mention highlighting (`_formatCallChatText`).
          Text.rich(
            callChatTextSpans(msg.text, base, c.primary),
            textAlign: TextAlign.left,
          ),
          // Reaction count badges.
          if (msg.reactions.isNotEmpty) ...[
            const SizedBox(height: 3),
            _ReactionBadges(msg: msg, onReact: onReact),
          ],
          // Read receipt (self only): right-aligned ✓/✓✓ in 1:1, reader
          // avatars in group (`.call-chat-readers { justify-content:flex-end }`).
          if (msg.isSelf) _Receipt(msg: msg, isGroup: isGroup),
        ],
        ),
      ),
    );
  }
}

/// `.call-chat-react-btn`: a 24×24 ＋ button, top-right of each chat row,
/// bordered (`var(--border)`) over `--bg-tertiary`, radius 8; opacity 0.65 → 1 +
/// primary glyph on hover. Opens the same quick-react popup as long-press.
class _ChatReactBtn extends StatefulWidget {
  const _ChatReactBtn({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_ChatReactBtn> createState() => _ChatReactBtnState();
}

class _ChatReactBtnState extends State<_ChatReactBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: Opacity(
        opacity: _hover ? 1 : 0.65,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.bgTertiary,
              border: Border.all(color: c.border),
              borderRadius: NymRadius.rxs,
            ),
            child: Text(
              '＋',
              style: TextStyle(
                color: _hover ? c.primary : c.textDim,
                fontSize: 14,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReactionBadges extends StatelessWidget {
  const _ReactionBadges({required this.msg, required this.onReact});
  final CallChatMessage msg;
  final void Function(String mid, String emoji) onReact;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final selfPk =
        ProviderScope.containerOf(context).read(appStateProvider).selfPubkey;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final entry in msg.reactions.entries)
          if (entry.value.isNotEmpty)
            GestureDetector(
              onTap: () => onReact(msg.mid, entry.key),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  // `.call-chat-reaction.self`: primary 22% bg + primary border.
                  color: entry.value.contains(selfPk)
                      ? c.primary.withValues(alpha: 0.22)
                      : c.bgTertiary,
                  border: Border.all(
                      // `.call-chat-reaction` border = `var(--border)`
                      // (primary@0.20); self adds the solid primary border.
                      color: entry.value.contains(selfPk)
                          ? c.primary
                          : c.border),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Custom `:shortcode:` reaction renders as its image (PWA
                    // `renderReactionEmoji`, calls.js:1689); unicode falls
                    // through to a plain Text.
                    InlineEmojiText(
                        text: entry.key,
                        style: const TextStyle(fontSize: 13),
                        emojiSize: 16),
                    const SizedBox(width: 3),
                    Text('${entry.value.length}',
                        style: TextStyle(color: c.textDim, fontSize: 11)),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

class _Receipt extends StatelessWidget {
  const _Receipt({required this.msg, required this.isGroup});
  final CallChatMessage msg;
  final bool isGroup;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    if (isGroup) {
      // Reader avatars (`.call-chat-readers`, justify-end); empty until read.
      if (msg.readers.isEmpty) return const SizedBox.shrink();
      final readers = msg.readers.entries.take(5).toList();
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final r in readers)
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: NymAvatar(seed: r.key, size: 14),
                ),
            ],
          ),
        ),
      );
    }
    // 1:1 ✓ (sent) / ✓✓ (read) — right-aligned receipt.
    final read = msg.delivery == CallChatDelivery.read || msg.readers.isNotEmpty;
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          read ? '✓✓' : '✓',
          style: TextStyle(
              color: read ? c.primary : c.textDim, fontSize: 11),
        ),
      ),
    );
  }
}

class _TypingLine extends StatelessWidget {
  const _TypingLine({required this.pubkeys});
  final List<String> pubkeys;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final style = TextStyle(
        color: c.textDim, fontSize: 12, fontStyle: FontStyle.italic);
    // Bound each decorated nym so its internal Flexible has finite width inside
    // the unbounded Wrap.
    Widget nym(String pk) => ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 140),
          child: CallNym(
            pubkey: pk,
            baseColor: c.textDim,
            baseStyle: style,
            badgeSize: 11,
          ),
        );

    final List<Widget> parts;
    if (pubkeys.length == 1) {
      parts = [nym(pubkeys[0]), Text(' is typing', style: style)];
    } else if (pubkeys.length == 2) {
      parts = [
        nym(pubkeys[0]),
        Text(' and ', style: style),
        nym(pubkeys[1]),
        Text(' are typing', style: style),
      ];
    } else {
      parts = [Text('${pubkeys.length} people are typing', style: style)];
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 3,
        children: parts,
      ),
    );
  }
}

class _InputRow extends ConsumerStatefulWidget {
  const _InputRow({
    required this.call,
    required this.controller,
    required this.onSend,
    required this.onTyping,
  });
  final CallState call;
  final TextEditingController controller;
  final ValueChanged<String> onSend;
  final VoidCallback onTyping;

  @override
  ConsumerState<_InputRow> createState() => _InputRowState();
}

class _InputRowState extends ConsumerState<_InputRow> {
  /// Active mention matches (pubkeys) for the autocomplete overlay.
  List<String> _mentionMatches = const [];

  void _onChanged(String value) {
    final sel = widget.controller.selection.baseOffset;
    final cursor = sel < 0 ? value.length : sel;
    final before = value.substring(0, cursor.clamp(0, value.length));
    final m = RegExp(r'(?:^|\s)@([^\s@]*)$').firstMatch(before);
    if (m != null) {
      _updateMentions(m.group(1) ?? '');
    } else if (_mentionMatches.isNotEmpty) {
      setState(() => _mentionMatches = const []);
    }
    if (value.trim().isNotEmpty) widget.onTyping();
  }

  void _updateMentions(String search) {
    final s = search.toLowerCase();
    final blocked = ref.read(appStateProvider).blockedUsers;
    final selfPk = ref.read(appStateProvider).selfPubkey;
    final users = ref.read(usersProvider);
    final matches = widget.call.participants
        .map((p) => p.pubkey)
        .where((pk) => pk != selfPk && !blocked.contains(pk))
        .where((pk) {
      final base = stripPubkeySuffix(users[pk]?.nym ?? pk);
      final sfx = getPubkeySuffix(pk);
      return '$base#$sfx'.toLowerCase().contains(s);
    }).toList()
      ..sort();
    setState(() => _mentionMatches = matches.take(8).toList());
  }

  void _insertMention(String pubkey) {
    final users = ref.read(usersProvider);
    final base = stripPubkeySuffix(users[pubkey]?.nym ?? pubkey);
    final sfx = getPubkeySuffix(pubkey);
    final value = widget.controller.text;
    final sel = widget.controller.selection.baseOffset;
    final cursor = sel < 0 ? value.length : sel;
    final before = value.substring(0, cursor.clamp(0, value.length));
    final after = value.substring(cursor.clamp(0, value.length));
    final atIdx = before.lastIndexOf('@');
    if (atIdx < 0) {
      setState(() => _mentionMatches = const []);
      return;
    }
    final insert = '@$base#$sfx ';
    final next = before.substring(0, atIdx) + insert + after;
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: atIdx + insert.length),
    );
    setState(() => _mentionMatches = const []);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  style: TextStyle(color: c.textBright, fontSize: 14),
                  minLines: 1,
                  maxLines: 4,
                  onChanged: _onChanged,
                  decoration: InputDecoration(
                    hintText: 'Message',
                    hintStyle: TextStyle(color: c.textDim),
                    filled: true,
                    fillColor: c.bgTertiary,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    // `.call-chat-input` border = `var(--border)` (primary@0.20).
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: c.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: c.border),
                    ),
                  ),
                  onSubmitted: (t) {
                    if (_mentionMatches.isNotEmpty) {
                      _insertMention(_mentionMatches.first);
                      return;
                    }
                    if (t.trim().isNotEmpty) widget.onSend(t);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: c.primary,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () {
                    final t = widget.controller.text;
                    if (t.trim().isNotEmpty) widget.onSend(t);
                  },
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: NymSvgIcon(NymIcons.send, color: c.bg, size: 18),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // `.call-mention-autocomplete`: anchored above the input.
        if (_mentionMatches.isNotEmpty)
          Positioned(
            left: 12,
            right: 12,
            bottom: 60,
            child: _MentionAutocomplete(
              pubkeys: _mentionMatches,
              onPick: _insertMention,
            ),
          ),
      ],
    );
  }
}

class _MentionAutocomplete extends StatelessWidget {
  const _MentionAutocomplete({required this.pubkeys, required this.onPick});
  final List<String> pubkeys;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 200),
        decoration: BoxDecoration(
          color: c.bgSecondary,
          // `.call-mention-autocomplete` border = `var(--border)` (primary@0.20).
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(10),
          boxShadow: const [
            BoxShadow(color: Color(0x59000000), blurRadius: 16, offset: Offset(0, -4)),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            for (final pk in pubkeys)
              InkWell(
                onTap: () => onPick(pk),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Row(
                    children: [
                      NymAvatar(seed: pk, size: 22),
                      const SizedBox(width: 8),
                      Flexible(
                        child: DefaultTextStyle(
                          style: TextStyle(
                              color: c.textBright,
                              fontSize: 14,
                              fontWeight: FontWeight.w600),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('@', style: TextStyle(color: c.textBright)),
                              Flexible(
                                child: CallNym(
                                  pubkey: pk,
                                  baseColor: c.textBright,
                                  baseStyle: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600),
                                  badgeSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Presenter menu (#callPresenterMenu) — `_renderPresenterMenu`
// =============================================================================

class _PresenterMenu extends ConsumerWidget {
  const _PresenterMenu({
    required this.call,
    required this.selfPubkey,
    required this.onToggleRestrict,
    required this.onAssign,
  });

  final CallState call;
  final String selfPubkey;
  final VoidCallback onToggleRestrict;

  /// Assign a presenter, or pass null to clear.
  final ValueChanged<String?> onAssign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final users = ref.watch(usersProvider);
    // Participants = self + remote members (call.participants excludes self).
    final members = <String>[
      selfPubkey,
      ...call.participants.map((p) => p.pubkey),
    ];
    final requests =
        call.presentRequests.where(members.contains).toList();

    String nameOf(String pk) =>
        pk == selfPubkey ? 'You' : stripPubkeySuffix(users[pk]?.nym ?? pk);

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 280,
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width - 32,
          maxHeight: MediaQuery.of(context).size.height * 0.5,
        ),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: c.bgTertiary,
          // `.call-presenter-menu` border = `var(--border)` (primary@0.20).
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 30, offset: Offset(0, 8)),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // "Only the presenter can share" checkbox row.
              InkWell(
                onTap: onToggleRestrict,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: Checkbox(
                          value: call.shareRestricted,
                          onChanged: (_) => onToggleRestrict(),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('Only the presenter can share',
                            style: TextStyle(
                                color: c.textBright, fontSize: 14)),
                      ),
                    ],
                  ),
                ),
              ),
              if (requests.isNotEmpty) ...[
                _Head(text: 'Requests'),
                for (final pk in requests)
                  _PresenterRow(
                    name: nameOf(pk),
                    isPresenter: call.presenter == pk,
                    actionLabel: 'Approve',
                    onAction: () => onAssign(pk),
                    onClear: () => onAssign(null),
                  ),
              ],
              _Head(text: 'Participants'),
              for (final pk in members)
                _PresenterRow(
                  name: nameOf(pk) +
                      (call.presenter == pk ? ' · presenter' : ''),
                  isPresenter: call.presenter == pk,
                  actionLabel: 'Make presenter',
                  onAction: () => onAssign(pk),
                  onClear: () => onAssign(null),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Head extends StatelessWidget {
  const _Head({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: c.textDim,
          fontSize: 11,
          letterSpacing: 0.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PresenterRow extends StatelessWidget {
  const _PresenterRow({
    required this.name,
    required this.isPresenter,
    required this.actionLabel,
    required this.onAction,
    required this.onClear,
  });

  final String name;
  final bool isPresenter;
  final String actionLabel;
  final VoidCallback onAction;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(name,
                style: TextStyle(color: c.textBright, fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          if (isPresenter)
            _PresenterAction(
                label: 'Clear', color: c.danger, onTap: onClear)
          else
            _PresenterAction(
                label: actionLabel, color: c.primary, onTap: onAction),
        ],
      ),
    );
  }
}

class _PresenterAction extends StatelessWidget {
  const _PresenterAction(
      {required this.label, required this.color, required this.onTap});
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label, style: TextStyle(color: color, fontSize: 12)),
      ),
    );
  }
}

// =============================================================================
// Switch-camera button (#callSwitchCamBtn)
// =============================================================================

class _SwitchCamButton extends StatelessWidget {
  const _SwitchCamButton({
    required this.disabled,
    required this.facingMode,
    required this.onTap,
  });
  final bool disabled;
  final String facingMode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Tooltip(
      message: facingMode == 'environment'
          ? 'Switch to front camera'
          : 'Switch to rear camera',
      child: Opacity(
        opacity: disabled ? 0.5 : 1,
        child: Material(
          color: Colors.black.withValues(alpha: 0.6),
          // `.call-switch-cam-btn` border = `var(--border)` (primary@0.20).
          shape: CircleBorder(side: BorderSide(color: c.border)),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: disabled ? null : onTap,
            child: SizedBox(
              width: 42,
              height: 42,
              child: Center(
                child: NymSvgIcon(NymIcons.callSwitchCam,
                    color: c.textBright, size: 20),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Controls (#callControls)
// =============================================================================

class _Controls extends StatelessWidget {
  const _Controls({
    required this.call,
    required this.chatOpen,
    required this.reactionsOpen,
    required this.presenterOpen,
    required this.onMute,
    required this.onCamera,
    required this.onShare,
    required this.onReact,
    required this.onPresenter,
    required this.onChat,
    required this.onEnd,
  });

  final CallState call;
  final bool chatOpen;
  final bool reactionsOpen;
  final bool presenterOpen;
  final VoidCallback onMute;
  final VoidCallback onCamera;
  final VoidCallback onShare;
  final VoidCallback onReact;
  final VoidCallback onPresenter;
  final VoidCallback onChat;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final isVideo = call.kind == CallKind.video;
    // `.call-controls`: no background (transparent over the overlay backdrop),
    // gap 20.
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 20,
        runSpacing: 10,
        children: [
          _CtrlBtn(
            // PWA toggles `.active` (red) on the SAME mic glyph when muted.
            svg: NymIcons.callMic,
            active: call.muted,
            tooltip: call.muted ? 'Unmute microphone' : 'Mute microphone',
            onTap: onMute,
          ),
          if (isVideo)
            _CtrlBtn(
              // PWA `#callVideoBtn` keeps the same video glyph and goes `.active`
              // (red) when the camera is off.
              svg: NymIcons.video,
              active: call.cameraOff,
              tooltip: call.cameraOff ? 'Turn on camera' : 'Turn off camera',
              onTap: onCamera,
            ),
          _CtrlBtn(
            svg: NymIcons.callScreenShare,
            active: call.sharing,
            // request-mode: primary outline when we can't share (calls.js).
            requestMode: !call.sharing && !call.canShareScreen,
            tooltip: call.sharing
                ? 'Stop sharing screen'
                : (call.canShareScreen ? 'Share screen' : 'Request to present'),
            onTap: onShare,
          ),
          // Presenter button — mods only, badge = pending requests.
          if (call.isMod)
            _CtrlBtn(
              svg: NymIcons.callPresenter,
              active: presenterOpen,
              tooltip: 'Presenter controls',
              badge: call.presentRequests.length,
              onTap: onPresenter,
            ),
          _CtrlBtn(
            svg: NymIcons.callReact,
            active: reactionsOpen,
            tooltip: 'React',
            onTap: onReact,
          ),
          _CtrlBtn(
            svg: NymIcons.callChat,
            active: chatOpen,
            tooltip: 'Chat',
            badge: call.chatUnread,
            onTap: onChat,
          ),
          _CtrlBtn(
            // `#callHangupBtn` — the feather phone ROTATED 135° (the hang-up
            // glyph), danger bg, white icon.
            svg: NymIcons.phone,
            rotation: 0.375,
            tooltip: 'End call',
            background: c.danger,
            foreground: Colors.white,
            onTap: onEnd,
          ),
        ],
      ),
    );
  }
}

class _CtrlBtn extends StatelessWidget {
  const _CtrlBtn({
    required this.svg,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.requestMode = false,
    this.badge = 0,
    this.background,
    this.foreground,
    this.rotation = 0,
  });

  final String svg;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final bool requestMode;
  final int badge;
  final Color? background;
  final Color? foreground;

  /// Glyph rotation in turns. The hangup button is the feather phone rotated
  /// 135° (`.call-control-btn.hangup svg { transform: rotate(135deg) }`):
  /// 135/360 = 0.375.
  final double rotation;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final bg = background ?? (active ? c.danger : c.bgTertiary);
    final fg = foreground ?? (active ? Colors.white : c.textBright);
    // `.call-control-btn` border = `var(--border)` (primary@0.20); request-mode
    // gets the solid primary outline.
    final borderColor = requestMode ? c.primary : c.border;
    final iconColor = requestMode ? c.primary : fg;
    return Tooltip(
      message: tooltip,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Material(
            color: bg,
            shape: CircleBorder(side: BorderSide(color: borderColor)),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: 54,
                height: 54,
                child: Center(
                  child: rotation == 0
                      ? NymSvgIcon(svg, color: iconColor, size: 22)
                      : Transform.rotate(
                          angle: rotation * 2 * math.pi,
                          child: NymSvgIcon(svg, color: iconColor, size: 22),
                        ),
                ),
              ),
            ),
          ),
          if (badge > 0)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration:
                    BoxDecoration(color: c.danger, shape: BoxShape.circle),
                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                child: Text(
                  badge > 9 ? '9+' : '$badge',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
