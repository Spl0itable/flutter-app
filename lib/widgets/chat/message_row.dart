import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/autocomplete/pending_edit.dart';
import '../../features/messages/flood_tracker.dart';
import '../../features/messages/format/message_content.dart';
import '../../features/p2p/p2p_models.dart';
import '../../features/p2p/p2p_service.dart';
import '../../features/shop/cosmetics.dart';
import '../../features/reactions/quick_context_items.dart';
import '../../features/reactions/quick_react_popup.dart';
import '../../features/reactions/reaction_burst.dart';
import '../../features/reactions/reactors_modal.dart';
import '../../features/translate/message_translation.dart';
import '../../features/zaps/zap_badge.dart';
import '../../models/message.dart';
import '../../models/settings.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../common/nym_avatar.dart';
import '../context_menu/context_menu_actions.dart';
import '../context_menu/context_menu_panel.dart';
import '../context_menu/interaction_hooks.dart';
import '../context_menu/profile_badges.dart';

/// Formats a [DateTime] per the user's time-format setting (docs/specs/02 §4).
String formatTime(DateTime t, String timeFormat) {
  final h24 = t.hour;
  final m = t.minute.toString().padLeft(2, '0');
  if (timeFormat == '24hr') {
    return '${h24.toString().padLeft(2, '0')}:$m';
  }
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  final ampm = h24 < 12 ? 'AM' : 'PM';
  return '$h12:$m $ampm';
}

/// Relative-time label for the in-bubble timestamp (a 1:1 port of
/// `_formatRelativeTime`, `messages.js:3308-3325`): `now` / `1m ago` /
/// `{m}m ago` / `{h}h ago` / `{d}d ago` / `Mon D[, YYYY]`.
String formatRelativeTime(DateTime t, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final diffMs = ref.difference(t).inMilliseconds;
  final s = (diffMs < 0 ? 0 : diffMs) ~/ 1000;
  if (s < 45) return 'now';
  if (s < 90) return '1m ago';
  final m = s ~/ 60;
  if (m < 60) return '${m}m ago';
  final h = m ~/ 60;
  if (h < 24) return '${h}h ago';
  final d = h ~/ 24;
  if (d < 7) return '${d}d ago';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final mo = months[t.month - 1];
  return t.year == ref.year ? '$mo ${t.day}' : '$mo ${t.day}, ${t.year}';
}

/// Abbreviates a count for badges/footers (a 1:1 port of `abbreviateNumber`,
/// `users.js:2069-2073`): `<1000` verbatim, `1.2k` / `12k`, `1.2M`.
String abbreviateNumber(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final v = n / 1000;
    return '${v.toStringAsFixed(n < 10000 ? 1 : 0)}k';
  }
  return '${(n / 1000000).toStringAsFixed(1)}M';
}

/// Renders a single message in either IRC or bubble layout.
///
/// IRC (`!useBubbles`): a wrapping row of [author 120w] [time 50w] [content],
/// with self/mentioned tints + left accent bars. Bubble (`useBubbles`): a
/// name-above-bubble stack, the content boxed with a tail corner, right-aligned
/// for self, with an in-bubble time. (docs/specs/02 §6, docs/specs/03 §2.7)
///
/// Interactions (docs/specs/02 §5.8): reaction badges toggle via
/// [NostrController.toggleReaction] (kind inferred from the message), an
/// "add reaction" affordance opens the picker, long-pressing a badge shows the
/// reactor list, and long-pressing the message (or tapping the author/avatar)
/// opens the quick-react popup / context menu.
class MessageRow extends ConsumerStatefulWidget {
  const MessageRow({
    super.key,
    required this.message,
    required this.settings,
    required this.reactions,
    this.mentioned = false,
    this.grouped = false,
    this.showAvatar = true,
    this.showName = true,
    this.onReactionPicker,
  });

  final Message message;
  final Settings settings;
  final List<MessageReaction> reactions;
  final bool mentioned;

  /// Bubble layout: this message is part of a consecutive same-author group.
  final bool grouped;

  /// Bubble layout: render the 32px sticky avatar (others only).
  final bool showAvatar;

  /// Bubble layout: render the name above the bubble.
  final bool showName;

  /// Opens the full emoji reaction picker for this message (host supplies it).
  /// When null the add-reaction / "more" affordances are no-ops.
  final ValueChanged<Message>? onReactionPicker;

  @override
  ConsumerState<MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends ConsumerState<MessageRow> {
  bool _showTranslation = false;
  String? _translateLangOverride;

  /// Refreshes the in-bubble relative time ("2m ago") on a cadence, mirroring
  /// `_ensureBubbleRelativeTimer` / `_refreshBubbleRelativeTimes`
  /// (`messages.js:1051,3347`).
  Timer? _relativeTimer;

  @override
  void dispose() {
    _relativeTimer?.cancel();
    super.dispose();
  }

  Message get message => widget.message;
  Settings get settings => widget.settings;
  List<MessageReaction> get reactions => widget.reactions;

  /// The author's kind-0 profile picture (`profile.picture`) for [NymAvatar];
  /// null → identicon fallback (Rule 4).
  String? get _authorPicture =>
      ref.watch(usersProvider)[message.pubkey]?.profile?.picture;

  /// True when this message's author is the verified developer or the Nymbot
  /// (`isVerifiedDeveloper` / `isVerifiedBot`) — the blue ✓ badge.
  bool get _isVerified {
    final controller = ref.read(nostrControllerProvider);
    return controller.isVerifiedDeveloper(message.pubkey) ||
        controller.isVerifiedBot(message.pubkey);
  }

  /// True when the author is a (non-self) friend — the cyan friend glyph.
  bool get _isFriendAuthor =>
      !message.isOwn && ref.watch(appStateProvider).isFriend(message.pubkey);

  /// True when this message has accrued zaps (`zapsProvider`), so the reactions
  /// row must render to host the `⚡ N` zap badge even without reactions.
  bool get _hasZaps {
    final z = ref.watch(zapsProvider)[message.id];
    return z != null && z.totalSats > 0;
  }

  /// Starts (once) a low-frequency timer that re-renders the in-bubble relative
  /// time. Recent messages tick every ~10s; older ones drift slowly, so a 30s
  /// cadence is plenty (the PWA refreshes on a similar interval).
  void _ensureRelativeTimer() {
    _relativeTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  /// The author's active flair-shop cosmetics (style / flair / supporter),
  /// resolved from the shop controller (self) or presence (`usersProvider`).
  UserCosmetics get _cosmetics =>
      ref.watch(userCosmeticsProvider(message.pubkey));

  /// The author's active message-style decoration. The supporter badge also
  /// adds a gold "supporter-style" treatment to the message body
  /// (`.message.supporter-style`); an explicit style takes precedence.
  MessageStyleDecoration? get _styleDecoration {
    final cos = _cosmetics;
    final styled = messageStyleDecoration(cos.styleId);
    if (styled != null) return styled;
    if (cos.supporter) return supporterStyleDecoration;
    return null;
  }

  /// The active special-cosmetic auras (gold/neon/prism/frost/phoenix/cosmic/
  /// hologram) composed onto the bubble/row.
  List<CosmeticAura> get _auras => resolveCosmeticAuras(_cosmetics);

  /// The flair + supporter badges that follow the author nym.
  Widget _nymBadges(BuildContext context, {double flairSize = 16}) {
    return CosmeticNymBadges(
      cosmetics: _cosmetics,
      flairSize: flairSize,
      supporterHeight: flairSize,
    );
  }

  /// The author label rendered in BOTH layouts: `<` nym `#suffix` `>` (brackets
  /// IRC-only) followed by the flair, verified ✓, and friend badges. The nym is
  /// ellipsized; the `#suffix` is dimmed (`.nym-suffix` opacity 0.7 / 0.9em /
  /// weight 100), and the `<…>` brackets inherit the author (secondary) color.
  /// (`messages.js:803,937`; `styles-chat.css:706-710`.)
  Widget _authorLine(
    NymColors c, {
    required bool self,
    required double size,
    required double flairSize,
    bool brackets = false,
  }) {
    final style = _authorStyle(c, self: self, size: size);
    final bracketColor = style.color;
    final suffix = getPubkeySuffix(message.pubkey);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (brackets)
          Text('<', style: TextStyle(color: bracketColor, fontSize: size)),
        Flexible(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: message.author, style: style),
              if (suffix.isNotEmpty)
                TextSpan(
                  text: '#$suffix',
                  style: style.copyWith(
                    color: style.color?.withValues(alpha: 0.7),
                    fontSize: size * 0.9,
                    fontWeight: FontWeight.w100,
                  ),
                ),
            ]),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        _nymBadges(context, flairSize: flairSize),
        // Blue ✓ for the verified developer / Nymbot (after flair/supporter).
        if (_isVerified) ...[
          const SizedBox(width: 4),
          VerifiedBadge(size: flairSize),
        ],
        // Cyan friend glyph for non-self friends.
        if (_isFriendAuthor) ...[
          const SizedBox(width: 4),
          FriendBadge(size: flairSize),
        ],
        if (brackets)
          Text('>', style: TextStyle(color: bracketColor, fontSize: size)),
      ],
    );
  }

  /// The author-name [TextStyle], bolding Genesis holders (`.has-genesis-flair`)
  /// and gold-tinting active supporters whose author line should match the
  /// supporter-style gold (`styles-features.css:1478-1481`).
  TextStyle _authorStyle(NymColors c, {required bool self, required double size}) {
    final cos = _cosmetics;
    final genesis = hasGenesisFlair(cos);
    final supporterGold = cos.supporter && cos.styleId == null;
    return TextStyle(
      color: supporterGold ? const Color(0xFFFFD700) : (self ? c.primary : c.secondary),
      fontSize: size,
      fontWeight: genesis ? FontWeight.w700 : FontWeight.w600,
      shadows: supporterGold
          ? const [Shadow(color: Color(0x66FFD700), blurRadius: 10)]
          : null,
    );
  }

  /// The message body: a P2P file-offer card when this is an offer, a redacted
  /// block when the redacted cosmetic is active, else the rich-formatted content
  /// tinted by the active style.
  Widget _bodyContent(
    BuildContext context,
    Color color,
    double fontSize, {
    MessageStyleDecoration? deco,
  }) {
    if (message.isFileOffer && message.fileOffer != null) {
      final p2p = ref.read(p2pServiceProvider);
      return FileOfferCard(
        offer: FileOffer.fromJson(message.fileOffer!),
        isOwn: message.isOwn,
        service: p2p,
      );
    }
    // cosmetic-redacted (`shop.js:498-512`): the REAL text shows for 10s, then a
    // `.cosmetic-redacted-message` translucent bar replaces it (bg white@0.15,
    // radius-xs, min-width 120, min-height 1.2em, content hidden).
    if (_cosmetics.isRedacted) {
      return _RedactedReveal(
        fontSize: fontSize,
        child: _content(context, color, fontSize, deco: deco),
      );
    }
    return _content(context, color, fontSize, deco: deco);
  }

  @override
  Widget build(BuildContext context) {
    // Centered system / action pill (`displaySystemMessage`).
    if (message.isSystemRow) return _buildSystemMessage(context);
    // `/me …` emote → italic "* author action *" line.
    if (message.isMeAction) return _buildActionMessage(context);
    final row =
        settings.useBubbles ? _buildBubble(context) : _buildIrc(context);
    // `.message.flooded { opacity: 0.2 }` — a flooding (others') pubkey in the
    // current conversation is dimmed (`messages.js:652-656`). Own messages are
    // never flooded.
    if (!message.isOwn &&
        ref.watch(floodTrackerProvider).isFlooding(message.pubkey)) {
      return Opacity(opacity: 0.2, child: row);
    }
    return row;
  }

  /// A centered `.system-message` (or `.action-message`) pill injected into the
  /// conversation flow (`styles-chat.css:1334-1360`). Text-dim, rounded-20,
  /// `white@0.03` bg, glass border, `textSize-3`; the action variant is
  /// purple-italic.
  Widget _buildSystemMessage(BuildContext context) {
    final c = context.nym;
    final isAction = message.kind == MessageKind.action;
    final size = settings.textSize.toDouble() - 3;
    // `.action-message` is BARE purple-italic text — no pill bg/border/radius
    // (`styles-chat.css:1357-1360`), distinct from `.system-message`.
    final text = Text(
      message.content,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: isAction ? c.purple : c.textDim,
        fontSize: size,
        fontStyle: isAction ? FontStyle.italic : FontStyle.normal,
        // `.system-message { font-weight: 450 }` (w500 is the nearest weight).
        fontWeight: isAction ? FontWeight.w400 : FontWeight.w500,
        height: 1.3,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      child: Center(
        child: isAction
            ? text
            : Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.03),
                  border: Border.all(color: c.glassBorder),
                  borderRadius: const BorderRadius.all(Radius.circular(20)),
                ),
                child: text,
              ),
      ),
    );
  }

  /// A `/me` emote rendered as a centered italic `* author#suffix action *` line
  /// over the system-message pill (`.system-message.me-message`,
  /// `messages.js:662-683`). The author uses the purple/secondary accent.
  Widget _buildActionMessage(BuildContext context) {
    final c = context.nym;
    final fontSize = settings.textSize.toDouble() - 3;
    final action = message.content.startsWith('/me ')
        ? message.content.substring(4)
        : message.content;
    final suffix = getPubkeySuffix(message.pubkey);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            border: Border.all(color: c.glassBorder),
            borderRadius: const BorderRadius.all(Radius.circular(20)),
          ),
          child: DefaultTextStyle(
            style: TextStyle(
              color: c.textDim,
              fontSize: fontSize,
              fontStyle: FontStyle.italic,
              height: 1.3,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Text('* '),
                NymAvatar(
                    seed: message.author,
                    size: fontSize + 2,
                    imageUrl: _authorPicture),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () => _openContextMenu(context),
                  // The whole `/me` line (incl. the nym + suffix) is italic
                  // (`.system-message.me-message { font-style: italic }`); the
                  // author keeps secondary/600 but inherits the italic.
                  child: Text.rich(TextSpan(children: [
                    TextSpan(
                      text: message.author,
                      style: TextStyle(
                        color: c.secondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (suffix.isNotEmpty)
                      TextSpan(
                        text: '#$suffix',
                        style: TextStyle(
                          color: c.secondaryA(0.6),
                        ),
                      ),
                  ])),
                ),
                _nymBadges(context, flairSize: fontSize + 2),
                const SizedBox(width: 4),
                // The action text (formatted). Kept inline; italic inherited.
                Flexible(
                  child: MessageContent(content: action, fontSize: fontSize),
                ),
                const Text(' *'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- IRC layout ----
  Widget _buildIrc(BuildContext context) {
    final c = context.nym;
    final fontSize = settings.textSize.toDouble();
    final self = message.isOwn;

    final deco = _styleDecoration;

    Color? bg;
    Color? barColor;
    if (self) {
      bg = c.secondaryA(0.05);
      barColor = Colors.white.withValues(alpha: 0.30);
    } else if (widget.mentioned) {
      bg = c.secondaryA(0.06);
      barColor = c.secondary;
    }
    // IRC layout paints the message-style accents on the row itself
    // (`body:not(.chat-bubbles) .message.supporter-style { background; border-left }`).
    if (deco?.borderAccent != null) {
      barColor = deco!.borderAccent;
      bg = deco.contentBackground ?? bg;
    }
    // Special cosmetic auras also paint a left bar + background tint on the row.
    final auras = _auras;
    final strongestAura = auras.isNotEmpty ? auras.last : null;
    if (strongestAura?.borderAccent != null) {
      barColor = strongestAura!.borderAccent;
    }
    bg = strongestAura?.background ?? bg;
    final watermark = deco?.watermark ??
        auras.map((a) => a.watermark).firstWhere((w) => w != null, orElse: () => null);

    final rowChildren = Wrap(
      crossAxisAlignment: WrapCrossAlignment.start,
      spacing: 10,
      runSpacing: 4,
      children: [
        ConstrainedBox(
          // `.message` is `display:flex; flex-wrap:wrap` with no author cap —
          // the author flows inline and the line wraps. We keep a generous cap
          // so the fixed badges (a ~116px supporter pill + flair/verified/friend)
          // always fit and the nym ellipsizes within the remainder; the message
          // body wraps to the next run when the author is wide.
          constraints: const BoxConstraints(minWidth: 120, maxWidth: 320),
          child: GestureDetector(
            onTap: () => _openContextMenu(context),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // IRC author leads with an 18px inline avatar (`.avatar-message`,
                // hidden in bubble mode). 4px gap, then `<nym#suffix flair…>`.
                NymAvatar(
                    seed: message.author, size: 18, imageUrl: _authorPicture),
                const SizedBox(width: 4),
                Flexible(
                  child: _authorLine(
                    c,
                    self: self,
                    size: fontSize,
                    // `.flair-badge { font-size: 20px }` — in-chat flair is 20px.
                    flairSize: 20,
                    brackets: true,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (settings.showTimestamps)
          SizedBox(
            width: 50,
            child: Text(
              formatTime(message.dateTime, settings.timeFormat),
              style: TextStyle(color: c.textDim, fontSize: 12),
            ),
          ),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width - 220,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _bodyContent(context, c.text, fontSize, deco: deco),
              if (_showTranslation)
                MessageTranslation(
                  content: message.content,
                  targetLang: _translateLangOverride,
                ),
              // `.edited-indicator-irc`: right-aligned 10px italic dim (edited).
              if (message.isEdited)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '(edited)',
                      style: TextStyle(
                        color: c.textDim.withValues(alpha: 0.7),
                        fontSize: 10,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ),
              // Reactions row renders only when reactions OR zaps exist (the PWA
              // `updateMessageReactions` early-returns on an empty reaction set;
              // the add-reaction pill is NOT drawn standalone — the first react
              // is via long-press quick-react). The zap badge sits at its front.
              if (reactions.isNotEmpty || _hasZaps)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: _reactionsRow(context),
                ),
              if (_showReaderAvatars) _readerAvatars(context),
              if (self && message.isPM && !message.isGroup)
                _deliveryTicks(context),
            ],
          ),
        ),
      ],
    );

    // `.message` is radius-12; a self/mention/style-tinted row is a 12px-rounded
    // block. The accent is a `::before` bar 3px × 60% height, vertically
    // centered, `border-radius:0 3px 3px 0`; mentions add a secondary glow.
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: watermark != null
          ? Stack(
              children: [
                Positioned.fill(child: StyleWatermarkLayer(watermark: watermark)),
                rowChildren,
              ],
            )
          : rowChildren,
    );
    final content = Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: bg != null ? NymRadius.rsm : null,
      ),
      clipBehavior: bg != null ? Clip.antiAlias : Clip.none,
      child: barColor != null
          ? Stack(
              children: [
                body,
                // 3px × ~60%-height rounded accent bar, vertically centered.
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: FractionallySizedBox(
                      heightFactor: 0.6,
                      child: Container(
                        width: 3,
                        decoration: BoxDecoration(
                          color: barColor,
                          borderRadius: const BorderRadius.only(
                            topRight: Radius.circular(3),
                            bottomRight: Radius.circular(3),
                          ),
                          boxShadow: widget.mentioned
                              ? [BoxShadow(color: c.secondaryA(0.4), blurRadius: 8)]
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : body,
    );
    return GestureDetector(
      onLongPress: () => _onMessageLongPress(context),
      // Desktop right-click → context menu (PWA `contextmenu` handler).
      onSecondaryTap: () => _openContextMenu(context),
      child: content,
    );
  }

  // ---- Bubble layout ----
  Widget _buildBubble(BuildContext context) {
    final c = context.nym;
    final fontSize = settings.textSize.toDouble();
    final self = message.isOwn;
    final align = self ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final deco = _styleDecoration;

    // In bubble mode the CSS applies the message style to `.message-content`
    // (the bubble): a translucent style background plus a soft glow halo.
    final auras = _auras;
    final lastAura = auras.isNotEmpty ? auras.last : null;
    final bubbleColor = deco?.contentBackground ??
        lastAura?.background ??
        (self ? c.primaryA(0.25) : Colors.white.withValues(alpha: 0.14));
    final radius = _bubbleRadius(self);

    final innerContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _bodyContent(context, c.text, fontSize, deco: deco),
        if (_showTranslation)
          MessageTranslation(
            content: message.content,
            targetLang: _translateLangOverride,
          ),
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (message.isEdited)
              Text(
                '(edited) ',
                style: TextStyle(
                    color: c.textDim, fontSize: 10, fontStyle: FontStyle.italic),
              ),
            // `.bubble-time-inner`: RELATIVE time ("now"/"2m ago"), not clock.
            Text(
              formatRelativeTime(message.dateTime),
              style: TextStyle(color: c.textDim, fontSize: 10, height: 1),
            ),
            if (self && message.isPM && !message.isGroup) ...[
              const SizedBox(width: 4),
              _ticksGlyph(context),
            ],
          ],
        ),
      ],
    );

    // Re-render the relative time on a cadence (cheap; matches the PWA timer).
    _ensureRelativeTimer();

    final bubble = GestureDetector(
      onLongPress: () => _onMessageLongPress(context),
      // Desktop right-click → context menu (PWA `contextmenu` handler).
      onSecondaryTap: () => _openContextMenu(context),
      child: ConstrainedBox(
        // `.message-content` bubble: `min-width:180px; max-width:85%`.
        constraints: BoxConstraints(
          minWidth: 180,
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        child: _decorateBubble(
          radius: radius,
          bubbleColor: bubbleColor,
          glow: deco?.glow,
          gradient: lastAura?.gradient,
          auras: auras,
          // `.message.mentioned .message-content`: inset 0 0 0 1px secondary@0.25
          // — rendered as a 1px secondary@0.25 inner border on the bubble.
          mentionRing: widget.mentioned ? c.secondaryA(0.25) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: innerContent,
          ),
        ),
      ),
    );

    final stack = Column(
      crossAxisAlignment: align,
      children: [
        if (widget.showName && !widget.grouped)
          Padding(
            padding: const EdgeInsets.only(bottom: 2, left: 2, right: 2),
            child: GestureDetector(
              onTap: () => _openContextMenu(context),
              // Name above the bubble: nym `#suffix` + flair/verified/friend,
              // no `<…>` brackets (bubble hides them).
              child: _authorLine(
                c,
                self: self,
                size: 11,
                // `.flair-badge { font-size: 20px }` — in-chat flair is 20px.
                flairSize: 20,
              ),
            ),
          ),
        bubble,
        if (_showReaderAvatars) _readerAvatars(context),
        if (reactions.isNotEmpty || _hasZaps)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: _reactionsRow(context),
          ),
      ],
    );

    // `.message-group`: align-end row with a 32px sticky avatar for others.
    final row = Row(
      mainAxisAlignment:
          self ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!self) ...[
          SizedBox(
            width: 32,
            child: widget.showAvatar && !widget.grouped
                ? GestureDetector(
                    onTap: () => _openContextMenu(context),
                    child: NymAvatar(
                        seed: message.author,
                        size: 32,
                        imageUrl: _authorPicture),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: 6),
        ],
        Flexible(child: stack),
      ],
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(14, widget.grouped ? 1 : 4, 14, 1),
      child: row,
    );
  }

  /// Wraps the bubble [child] with the style glow + cosmetic-aura box-shadows,
  /// an optional aura background gradient, a tiled watermark behind the content,
  /// and the prism-ring / hologram overlays painted above it. Everything is
  /// clipped to the bubble [radius].
  Widget _decorateBubble({
    required BorderRadius radius,
    required Color bubbleColor,
    required Color? glow,
    required List<Color>? gradient,
    required List<CosmeticAura> auras,
    required Widget child,
    Color? mentionRing,
  }) {
    final shadows = <BoxShadow>[];
    if (glow != null) {
      shadows.add(BoxShadow(color: glow, blurRadius: 18, spreadRadius: -2));
    }
    for (final a in auras) {
      // Inset ring (approximated as a tight 0-blur spread inside the box via a
      // border below) + the outer glow.
      if (a.glowColor != null && a.glowBlur > 0) {
        shadows.add(BoxShadow(color: a.glowColor!, blurRadius: a.glowBlur));
      }
    }
    // The strongest inset ring (last aura) is drawn as a hairline inner border
    // ONLY when the overlay painter isn't already stroking it: `insetRing` auras
    // route through `CosmeticOverlayPainter` (via `hasOverlay`), so drawing the
    // border here too would double the ring (gold/neon/phoenix/cosmic/frost).
    final lastAura = auras.isNotEmpty ? auras.last : null;
    final inset =
        (lastAura != null && lastAura.insetColor != null && !lastAura.hasOverlay)
            ? lastAura
            : null;

    // Watermark from the active style or a frost/cosmic aura.
    final watermark = _styleDecoration?.watermark ??
        auras
            .map((a) => a.watermark)
            .firstWhere((w) => w != null, orElse: () => null);

    final overlays =
        auras.where((a) => a.hasOverlay).toList();
    final overlayAura = overlays.isNotEmpty ? overlays.first : null;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: gradient == null ? bubbleColor : null,
        gradient: gradient != null
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradient,
              )
            : null,
        borderRadius: radius,
        // The aura inset ring takes precedence; otherwise a @-mention bubble
        // gets a 1px secondary@0.25 inner ring.
        border: inset?.insetColor != null
            ? Border.all(color: inset!.insetColor!, width: inset.insetWidth)
            : (mentionRing != null
                ? Border.all(color: mentionRing, width: 1)
                : null),
        boxShadow: shadows.isEmpty ? null : shadows,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            if (watermark != null)
              Positioned.fill(child: StyleWatermarkLayer(watermark: watermark)),
            child,
            if (overlayAura != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: CosmeticOverlayPainter(
                      aura: overlayAura,
                      radius: radius,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// True when this own message should show the stacked reader-avatar delivery
  /// indicator (own channel or own group message with readers) instead of the
  /// PM tick glyph. (`messages.js:824-847`.)
  bool get _showReaderAvatars =>
      message.isOwn &&
      !message.isPM &&
      (message.isGroup || _isChannelMessage) &&
      message.readers.isNotEmpty;

  /// A channel message: not a PM, not a group, with a 64-hex geohash (the PWA
  /// gate `message.geohash && /^[0-9a-f]{64}$/`).
  bool get _isChannelMessage {
    if (message.isPM || message.isGroup) return false;
    final g = message.geohash ?? '';
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(g);
  }

  /// A right-aligned row of up to 3 overlapping 14px reader avatars + a `+N`
  /// overflow, mirroring `_buildGroupReadersHtmlFromMap` (`groups.js:2624-2641`)
  /// and `.group-readers`/`.group-reader-avatar` (`styles-chat.css:612-654`).
  /// Long-press opens a "seen by" modal.
  Widget _readerAvatars(BuildContext context) {
    const maxVisible = 3;
    final entries = message.readers.entries.toList();
    final visible = entries.take(maxVisible).toList();
    final overflow = entries.length - visible.length;
    final c = context.nym;
    final users = ref.watch(usersProvider);
    return GestureDetector(
      onLongPress: () => _showSeenBy(context),
      child: Padding(
        padding: const EdgeInsets.only(top: 3, right: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.max,
          children: [
            for (var i = 0; i < visible.length; i++)
              Transform.translate(
                offset: Offset(i == 0 ? 0 : -5.0 * i, 0),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: c.bg, width: 1.5),
                  ),
                  child: Opacity(
                    opacity: 0.85,
                    child: NymAvatar(
                      seed: visible[i].value,
                      size: 14,
                      imageUrl: users[visible[i].key]?.profile?.picture,
                    ),
                  ),
                ),
              ),
            if (overflow > 0)
              Padding(
                padding: const EdgeInsets.only(left: 3),
                child: Text(
                  '+${abbreviateNumber(overflow)}',
                  style: TextStyle(
                      color: c.textDim, fontSize: 9, height: 14 / 9),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showSeenBy(BuildContext context) {
    final users = ref.read(usersProvider);
    final reactors = <ReactorEntry>[
      for (final e in message.readers.entries)
        ReactorEntry(
          pubkey: e.key,
          nym: _baseNym(e.value),
          suffix: getPubkeySuffix(e.key),
          imageUrl: users[e.key]?.profile?.picture,
        ),
    ];
    // Reuse the reactors modal as the "seen by" list (mirror the PWA's readers
    // modal); the 👁 glyph in the header reads as "seen by N".
    showReactorsModal(
      context,
      anchorRect: _globalRectOfContext(context) ?? Rect.zero,
      emoji: '👁',
      reactors: reactors,
    );
  }

  // ---- reactions row ----
  Widget _reactionsRow(BuildContext context) {
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // The `⚡ N` zap badge + quick-zap button are inserted at the FRONT of
        // the row (`updateMessageZaps` insertBefore firstChild). Renders nothing
        // until the message has zaps.
        ZapBadge(message: message),
        for (final r in reactions)
          _ReactionBadge(
            reaction: r,
            onTap: (rect) => _toggleReaction(context, r),
            onLongPress: (rect) => _showReactors(context, r, rect),
          ),
      ],
    );
  }

  Future<void> _toggleReaction(BuildContext context, MessageReaction r) async {
    final controller = ref.read(nostrControllerProvider);
    final view = ref.read(currentViewProvider);
    final kind = inferOriginalKind(message, view: view);
    final wasReacted = r.userReacted;
    final ok = await controller.toggleReaction(
      message.id,
      r.emoji,
      target: reactionTargetFor(message),
      kind: kind,
    );
    // Burst on add (not on removal), mirroring `_burstOnBadge` after sendReaction.
    if (ok && !wasReacted && context.mounted) {
      final center = _globalCenterOfContext(context);
      if (center != null) ReactionBurst.play(context, center, r.emoji);
    }
  }

  void _showReactors(BuildContext context, MessageReaction r, Rect rect) {
    // The real reactor map (`reactorsFor` → pubkey → nym), each row carrying its
    // avatar picture so the modal loads faces (mirrors `showReactorsModal`).
    final app = ref.read(appStateProvider);
    final users = ref.read(usersProvider);
    final map =
        ref.read(appStateProvider.notifier).reactorsFor(message.id, r.emoji) ??
            const {};
    final reactors = <ReactorEntry>[
      for (final e in map.entries)
        ReactorEntry(
          pubkey: e.key,
          nym: _baseNym(e.value),
          suffix: getPubkeySuffix(e.key),
          isYou: e.key == app.selfPubkey,
          imageUrl: users[e.key]?.profile?.picture,
        ),
    ];
    showReactorsModal(
      context,
      anchorRect: rect,
      emoji: r.emoji,
      reactors: reactors,
    );
  }

  void _onMessageLongPress(BuildContext context) {
    final rect = _globalRectOfContext(context);
    // Quick-react row = recents-first, padded with the six defaults
    // (`_messageQuickReactDefaults`), deduped (ctx-menu F7).
    final recents = ref.read(recentEmojisProvider);
    showQuickReactPopup(
      context,
      anchorRect: rect ?? Rect.zero,
      emojis: quickReactEmojis(recents),
      onReact: (emoji) => _quickReact(context, emoji),
      onMore: () => widget.onReactionPicker?.call(message),
      // The PWA long-press surface also carries the labelled quick actions
      // (Slap/Hug/Zap/Quote/Copy/Translate/Edit/Delete) below the emoji pill.
      contextItems: buildQuickContextItems(
        context,
        ref,
        message,
        onTranslate: () => setState(() => _showTranslation = true),
        onEdit: () => ref.read(pendingEditProvider.notifier).request(
              messageId: message.id,
              content: message.content,
            ),
      ),
    );
  }

  Future<void> _quickReact(BuildContext context, String emoji) async {
    final controller = ref.read(nostrControllerProvider);
    final view = ref.read(currentViewProvider);
    final already = reactions.any((r) => r.emoji == emoji && r.userReacted);
    // Record the pick into the shared recents store (reactions.js bump).
    ref.read(recentEmojisProvider.notifier).record(emoji);
    final ok = await controller.toggleReaction(
      message.id,
      emoji,
      target: reactionTargetFor(message),
      kind: inferOriginalKind(message, view: view),
    );
    if (ok && !already && context.mounted) {
      final center = _globalCenterOfContext(context);
      if (center != null) ReactionBurst.play(context, center, emoji);
    }
  }

  void _openContextMenu(BuildContext context) {
    final app = ref.read(appStateProvider);
    final target = ctxTargetForMessage(message, selfPubkey: app.selfPubkey);
    ContextMenuPanel.show(
      context,
      target: target,
      message: message,
      onReact: () => widget.onReactionPicker?.call(message),
      onTranslateInline: (lang) => setState(() {
        _translateLangOverride = lang;
        _showTranslation = true;
      }),
    );
  }

  // ---- helpers ----
  Rect? _globalRectOfContext(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final origin = box.localToGlobal(Offset.zero);
    return origin & box.size;
  }

  Offset? _globalCenterOfContext(BuildContext context) {
    final r = _globalRectOfContext(context);
    return r?.center;
  }

  String _baseNym(String nym) {
    final hash = nym.indexOf('#');
    return hash > 0 ? nym.substring(0, hash) : nym;
  }

  BorderRadius _bubbleRadius(bool self) {
    const r = Radius.circular(16);
    const tail = Radius.circular(4);
    if (widget.grouped) return const BorderRadius.all(r);
    if (self) {
      return const BorderRadius.only(
        topLeft: r,
        topRight: tail,
        bottomLeft: r,
        bottomRight: r,
      );
    }
    return const BorderRadius.only(
      topLeft: tail,
      topRight: r,
      bottomLeft: r,
      bottomRight: r,
    );
  }

  /// Renders the message body through the rich formatter pipeline, tinted by the
  /// author's active message style ([deco]) when present.
  ///
  /// The style's glyph colour is threaded via [MessageContent.baseColor]; a
  /// gradient style (aurora) clips the text with a `ShaderMask`. The per-glyph
  /// `text-shadow` glow can't be pushed through `MessageContent`, so the glow is
  /// rendered as the bubble/row halo instead (see TODO(verify) in the report).
  /// Whether to blur this message's images: never for own messages; otherwise
  /// per the `blurOthersImages` setting (`true` → always, `friends` → only when
  /// the sender isn't a friend). Mirrors `messages.js:1267-1274`.
  bool _shouldBlurImages() {
    if (message.isOwn) return false;
    final setting = ref.read(settingsProvider.notifier).blurImages;
    if (setting == 'true') return true;
    if (setting == 'friends') {
      return !ref.read(appStateProvider).isFriend(message.pubkey);
    }
    return false;
  }

  Widget _content(
    BuildContext context,
    Color color,
    double fontSize, {
    MessageStyleDecoration? deco,
  }) {
    final blur = _shouldBlurImages();
    final body = MessageContent(
      content: message.content,
      baseColor: deco?.textColor ?? color,
      fontSize: fontSize,
      blurImages: blur,
      glyphShadows: deco?.textShadows,
      monospace: deco?.monospace ?? false,
    );
    final gradient = deco?.gradient;
    if (gradient != null && gradient.length >= 2) {
      // `.message.style-aurora .message-content` clips a gradient to the text.
      return ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (rect) => LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: gradient,
        ).createShader(rect),
        child: MessageContent(
          content: message.content,
          baseColor: Colors.white,
          fontSize: fontSize,
          blurImages: blur,
        ),
      );
    }
    return body;
  }

  Widget _deliveryTicks(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: _ticksGlyph(context),
      ),
    );
  }

  Widget _ticksGlyph(BuildContext context) {
    final c = context.nym;
    // Glyphs + colors are a 1:1 port of messages.js:837-844 and the
    // `.delivery-status` rules in styles-chat.css:673-686 (those colors are
    // hard-coded hex, not theme vars):
    //   read      → "✓✓" #2196F3 (blue)
    //   delivered → "✓"  #4CAF50 (green)   ← single tick, not double
    //   sent      → "✓"  --text-dim
    //   failed    → "!"  #f44336 (danger)
    // The PWA renders nothing for any other status (e.g. a pending "sending"),
    // so we emit an empty widget rather than an ellipsis.
    String glyph;
    Color color;
    switch (message.deliveryStatus) {
      case DeliveryStatus.read:
        glyph = '✓✓';
        color = const Color(0xFF2196F3);
        break;
      case DeliveryStatus.delivered:
        glyph = '✓';
        color = const Color(0xFF4CAF50);
        break;
      case DeliveryStatus.sent:
        glyph = '✓';
        color = c.textDim;
        break;
      case DeliveryStatus.failed:
        glyph = '!';
        color = c.danger;
        break;
      case DeliveryStatus.sending:
        return const SizedBox.shrink();
    }
    return Text(
      glyph,
      style: TextStyle(color: color, fontSize: 11, height: 1),
    );
  }
}

/// A single `.reaction-badge` pill. Tappable (toggle) with a long-press to show
/// the reactor list; reports its global bounds to the callbacks for anchoring.
/// User-reacted badges get a soft glow halo (`box-shadow 0 0 10px primary@0.1`)
/// and the pill presses/pops on tap (`active scale(0.95)`).
class _ReactionBadge extends StatefulWidget {
  const _ReactionBadge({
    required this.reaction,
    required this.onTap,
    required this.onLongPress,
  });
  final MessageReaction reaction;
  final void Function(Rect) onTap;
  final void Function(Rect) onLongPress;

  @override
  State<_ReactionBadge> createState() => _ReactionBadgeState();
}

class _ReactionBadgeState extends State<_ReactionBadge> {
  bool _pressed = false;

  Rect _rect(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Rect.zero;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final r = widget.reaction;
    return GestureDetector(
      onTap: () => widget.onTap(_rect(context)),
      onLongPress: () => widget.onLongPress(_rect(context)),
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: r.userReacted
                ? c.primaryA(0.12)
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: const BorderRadius.all(Radius.circular(20)),
            border: Border.all(
              color: r.userReacted ? c.primaryA(0.35) : c.glassBorder,
            ),
            boxShadow: r.userReacted
                ? [BoxShadow(color: c.primaryA(0.1), blurRadius: 10)]
                : null,
          ),
          child: Text(
            // Count abbreviated (`abbreviateNumber`, e.g. `1.2k`). The badge
            // label stays `--text` even when user-reacted (only bg/border/glow
            // change — `styles-chat.css:439-443`).
            '${r.emoji} ${abbreviateNumber(r.count)}',
            style: TextStyle(color: c.text, fontSize: 12),
          ),
        ),
      ),
    );
  }
}

/// The cosmetic-redacted body (`shop.js:498-512`): shows the real message
/// [child] for 10 seconds, then swaps to a `.cosmetic-redacted-message`
/// translucent bar (bg white@0.15, radius-xs, min-width 120, min-height 1.2em,
/// content hidden / unselectable).
class _RedactedReveal extends StatefulWidget {
  const _RedactedReveal({required this.child, required this.fontSize});
  final Widget child;
  final double fontSize;

  @override
  State<_RedactedReveal> createState() => _RedactedRevealState();
}

class _RedactedRevealState extends State<_RedactedReveal> {
  Timer? _timer;
  bool _blanked = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _blanked = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_blanked) return widget.child;
    return Container(
      constraints: BoxConstraints(
        minWidth: 120,
        minHeight: widget.fontSize * 1.2,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: NymRadius.rxs,
      ),
    );
  }
}

/// The in-message P2P file-offer card (`.file-offer`, `messages.js:851-917`,
/// `styles-features.css:2087-2290`). Header = category-coloured doc icon + name
/// + meta (`size • type • Torrent?`); status block flips between
/// seeding/unseeded (own) and Download / inline-progress / "No longer available"
/// (peer). Driven live by [P2PService] (a [ChangeNotifier]) keyed by offerId.
class FileOfferCard extends StatelessWidget {
  const FileOfferCard({
    super.key,
    required this.offer,
    required this.isOwn,
    required this.service,
  });

  final FileOffer offer;
  final bool isOwn;
  final P2PService service;

  /// Category → icon stroke colour (`.file-offer-icon.audio/video/archive/…`).
  static (Color, IconData) _category(NymColors c, FileOffer o) {
    final ext = o.name.contains('.') ? o.name.split('.').last.toLowerCase() : '';
    final mime = o.type.toLowerCase();
    bool any(List<String> exts) => exts.contains(ext);
    if (any(['mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a', 'wma']) ||
        mime.startsWith('audio/')) {
      return (c.purple, Icons.audiotrack);
    }
    if (any(['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm']) ||
        mime.startsWith('video/')) {
      return (c.danger, Icons.movie_outlined);
    }
    if (any(['zip', 'rar', '7z', 'tar', 'gz', 'bz2'])) {
      return (c.warning, Icons.folder_zip_outlined);
    }
    if (any(['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'rtf'])) {
      return (c.secondary, Icons.description_outlined);
    }
    return (c.textDim, Icons.insert_drive_file_outlined);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final (iconColor, iconData) = _category(c, offer);
        final isTorrent = offer.isTorrent;
        final unseeded = service.isUnseeded(offer.offerId);
        // The active transfer for this offer, if any.
        P2PTransfer? transfer;
        for (final t in service.transfers) {
          if (t.offerId == offer.offerId) transfer = t;
        }

        return Container(
          constraints: const BoxConstraints(maxWidth: 320),
          // `.file-offer { padding: 14px; border-radius: var(--radius-md)=16 }`
          // (styles-features.css:2051-2052).
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: const BorderRadius.all(Radius.circular(16)),
            border: Border.all(
              color: isTorrent ? c.secondaryA(0.3) : c.glassBorder,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // `.file-offer-icon`: a 40×40 boxed icon (white@0.05 bg, 1px
                  // glass border, radius-xs=8) wrapping a 24px primary-stroke
                  // glyph (styles-features.css:2064-2080). The category colour
                  // still drives the glyph shape; the stroke is primary.
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      border: Border.all(color: c.glassBorder),
                      borderRadius: NymRadius.rxs,
                    ),
                    child: Icon(iconData, color: c.primary, size: 24),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          offer.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${formatFileSize(offer.size)} • '
                          '${offer.type.isEmpty ? 'Unknown type' : offer.type}'
                          '${isTorrent ? ' • Torrent' : ''}',
                          style: TextStyle(color: c.textDim, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _status(context, c, unseeded: unseeded, transfer: transfer),
            ],
          ),
        );
      },
    );
  }

  Widget _status(
    BuildContext context,
    NymColors c, {
    required bool unseeded,
    required P2PTransfer? transfer,
  }) {
    // Own offer: seeding (green dot + Stop) or no-longer-seeding (grey dot).
    if (isOwn) {
      if (unseeded) {
        return _dotRow(c, c.danger.withValues(alpha: 0.6), 'No longer seeding',
            dim: true);
      }
      return Row(
        children: [
          _dot(c.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text('Seeding - available for download',
                style: TextStyle(color: c.primary, fontSize: 11)),
          ),
          _StopBtn(onTap: () => service.stopSeeding(offer.offerId)),
        ],
      );
    }
    // Peer offer, no longer available.
    if (unseeded) {
      return _dotRow(c, c.danger.withValues(alpha: 0.6), 'No longer available',
          dim: true);
    }
    // Active transfer → inline progress bar.
    if (transfer != null && transfer.status != P2PStatus.complete) {
      final pct = transfer.progress;
      final failed = transfer.status == P2PStatus.error;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (failed)
            _OfferBtn(
              label: 'Retry',
              color: c.primary,
              onTap: () => service.requestFile(offer.offerId),
            )
          else ...[
            // `.file-offer-progress-bar`: 5px track white@0.05, radius 10;
            // `.file-offer-progress-fill`: `linear-gradient(90deg, secondary,
            // primary)`, radius 10 (styles-features.css:2139-2152). A
            // LinearProgressIndicator can't gradient, so paint a Stack +
            // FractionallySizedBox like p2p_transfers_modal `_TransferRow`.
            ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(10)),
              child: SizedBox(
                height: 5,
                child: Stack(
                  children: [
                    Container(color: Colors.white.withValues(alpha: 0.05)),
                    FractionallySizedBox(
                      widthFactor: (pct / 100).clamp(0.0, 1.0),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius:
                              const BorderRadius.all(Radius.circular(10)),
                          gradient: LinearGradient(
                            colors: [c.secondary, c.primary],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              transfer.message ?? 'Connecting...',
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textDim, fontSize: 11),
            ),
          ],
        ],
      );
    }
    if (transfer != null && transfer.status == P2PStatus.complete) {
      // The PWA reverts the completed button to the primary-tinted
      // `.file-offer-btn` (NOT a special secondary colour; p2p.js:641).
      return _OfferBtn(label: 'Downloaded', color: c.primary, onTap: null);
    }
    // Available → Download / Download (Torrent).
    return _OfferBtn(
      label: offer.isTorrent ? 'Download (Torrent)' : 'Download',
      color: offer.isTorrent ? c.secondary : c.primary,
      onTap: () => service.requestFile(offer.offerId),
    );
  }

  Widget _dot(Color color) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );

  Widget _dotRow(NymColors c, Color dotColor, String label,
      {bool dim = false}) {
    return Opacity(
      opacity: dim ? 0.7 : 1,
      child: Row(
        children: [
          _dot(dotColor),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: c.textDim, fontSize: 11)),
        ],
      ),
    );
  }
}

/// `.file-offer-btn` — a full-width tinted action pill (Download / Retry /
/// Downloaded). A null [onTap] renders a disabled (terminal) state.
class _OfferBtn extends StatelessWidget {
  const _OfferBtn({required this.label, required this.color, this.onTap});
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          border: Border.all(color: color.withValues(alpha: 0.25)),
          // `.file-offer-btn { border-radius: var(--radius-xs)=8 }` (:2110).
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// `.file-offer-stop-btn` — a small danger-outlined "Stop" pill (own seeding).
class _StopBtn extends StatelessWidget {
  const _StopBtn({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          border: Border.all(color: c.danger),
          // `.file-offer-btn { border-radius: var(--radius-xs)=8 }` (:2110).
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        child: Text('Stop',
            style: TextStyle(color: c.danger, fontSize: 10)),
      ),
    );
  }
}
