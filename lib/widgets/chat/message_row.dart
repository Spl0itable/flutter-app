import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/messages/format/message_content.dart';
import '../../features/p2p/p2p_models.dart';
import '../../features/p2p/p2p_service.dart';
import '../../features/shop/cosmetics.dart';
import '../../features/reactions/quick_react_popup.dart';
import '../../features/reactions/reaction_burst.dart';
import '../../features/reactions/reactors_modal.dart';
import '../../features/translate/message_translation.dart';
import '../../models/message.dart';
import '../../models/settings.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../common/nym_avatar.dart';
import '../context_menu/context_menu_actions.dart';
import '../context_menu/context_menu_panel.dart';
import '../context_menu/interaction_hooks.dart';

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

  Message get message => widget.message;
  Settings get settings => widget.settings;
  List<MessageReaction> get reactions => widget.reactions;

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
    // cosmetic-redacted: content replaced with █ blocks (`shop.js:498-503`).
    // TODO(ui-parity): the PWA reveals for 10s then blanks; we redact upfront.
    if (_cosmetics.isRedacted) {
      return Text(
        '████████',
        style: TextStyle(
          color: color.withValues(alpha: 0.5),
          fontSize: fontSize,
          letterSpacing: 1,
        ),
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
    return settings.useBubbles ? _buildBubble(context) : _buildIrc(context);
  }

  /// A centered `.system-message` (or `.action-message`) pill injected into the
  /// conversation flow (`styles-chat.css:1334-1360`). Text-dim, rounded-20,
  /// `white@0.03` bg, glass border, `textSize-3`; the action variant is
  /// purple-italic.
  Widget _buildSystemMessage(BuildContext context) {
    final c = context.nym;
    final isAction = message.kind == MessageKind.action;
    final size = settings.textSize.toDouble() - 3;
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
          child: Text(
            message.content,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isAction ? c.purple : c.textDim,
              fontSize: size,
              fontStyle: isAction ? FontStyle.italic : FontStyle.normal,
              fontWeight: FontWeight.w400,
              height: 1.3,
            ),
          ),
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
                NymAvatar(seed: message.author, size: fontSize + 2),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () => _openContextMenu(context),
                  child: Text.rich(TextSpan(children: [
                    TextSpan(
                      text: message.author,
                      style: TextStyle(
                        color: c.secondary,
                        fontWeight: FontWeight.w600,
                        fontStyle: FontStyle.normal,
                      ),
                    ),
                    if (suffix.isNotEmpty)
                      TextSpan(
                        text: '#$suffix',
                        style: TextStyle(
                          color: c.secondaryA(0.6),
                          fontStyle: FontStyle.normal,
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
          constraints: const BoxConstraints(minWidth: 120, maxWidth: 200),
          child: GestureDetector(
            onTap: () => _openContextMenu(context),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    message.author,
                    overflow: TextOverflow.ellipsis,
                    style: _authorStyle(c, self: self, size: fontSize),
                  ),
                ),
                _nymBadges(context),
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
              if (reactions.isNotEmpty || widget.onReactionPicker != null)
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

    final content = Container(
      decoration: BoxDecoration(
        color: bg,
        border: barColor != null
            ? Border(left: BorderSide(color: barColor, width: 3))
            : null,
      ),
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
    return GestureDetector(
      onLongPress: () => _onMessageLongPress(context),
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
            Text(
              formatTime(message.dateTime, settings.timeFormat),
              style: TextStyle(color: c.textDim, fontSize: 10),
            ),
            if (self && message.isPM && !message.isGroup) ...[
              const SizedBox(width: 4),
              _ticksGlyph(context),
            ],
          ],
        ),
      ],
    );

    final bubble = GestureDetector(
      onLongPress: () => _onMessageLongPress(context),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: 0,
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        child: _decorateBubble(
          radius: radius,
          bubbleColor: bubbleColor,
          glow: deco?.glow,
          gradient: lastAura?.gradient,
          auras: auras,
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      message.author,
                      overflow: TextOverflow.ellipsis,
                      style: _authorStyle(c, self: self, size: 11),
                    ),
                  ),
                  _nymBadges(context, flairSize: 14),
                ],
              ),
            ),
          ),
        bubble,
        if (_showReaderAvatars) _readerAvatars(context),
        if (reactions.isNotEmpty || widget.onReactionPicker != null)
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
                    child: NymAvatar(seed: message.author, size: 32),
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
    // The strongest inset ring (last aura) is drawn as a hairline inner border.
    final inset = auras.isNotEmpty ? auras.last : null;

    // Watermark from the active style or a frost/cosmic aura.
    final watermark = _styleDecoration?.watermark ??
        auras
            .map((a) => a.watermark)
            .firstWhere((w) => w != null, orElse: () => null);

    final overlays =
        auras.where((a) => a.prismRing || a.hologram).toList();
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
        border: inset?.insetColor != null
            ? Border.all(color: inset!.insetColor!, width: inset.insetWidth)
            : null,
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
                    child: NymAvatar(seed: visible[i].value, size: 14),
                  ),
                ),
              ),
            if (overflow > 0)
              Padding(
                padding: const EdgeInsets.only(left: 3),
                child: Text(
                  '+$overflow',
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
    final reactors = <ReactorEntry>[
      for (final e in message.readers.entries)
        ReactorEntry(
          pubkey: e.key,
          nym: _baseNym(e.value),
          suffix: getPubkeySuffix(e.key),
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
        for (final r in reactions)
          _ReactionBadge(
            reaction: r,
            onTap: (rect) => _toggleReaction(context, r),
            onLongPress: (rect) => _showReactors(context, r, rect),
          ),
        // `.add-reaction-btn` affordance (always present so users can react).
        if (widget.onReactionPicker != null)
          _AddReactionBtn(onTap: () => widget.onReactionPicker!(message)),
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
    // The engine exposes only aggregate tallies publicly (count + userReacted),
    // so we render the self row when applicable plus an anonymous count.
    // TODO(verify): show real reactor nyms once AppState exposes the reactor
    // pubkey/nym map (`_reactors`) publicly.
    final self = ref.read(appStateProvider);
    final reactors = <ReactorEntry>[
      if (r.userReacted)
        ReactorEntry(
          pubkey: self.selfPubkey,
          nym: _baseNym(self.selfNym),
          suffix: getPubkeySuffix(self.selfPubkey),
          isYou: true,
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
      onMenu: message.isOwn ? null : () => _openContextMenu(context),
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
            '${r.emoji} ${r.count}',
            style: TextStyle(
              color: r.userReacted ? c.primary : c.text,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}

/// The `.add-reaction-btn` affordance (a dim "+ smiley" pill that opens the
/// emoji picker).
class _AddReactionBtn extends StatelessWidget {
  const _AddReactionBtn({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: 0.6,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: const BorderRadius.all(Radius.circular(20)),
            border: Border.all(color: c.glassBorder),
          ),
          child: Icon(Icons.add_reaction_outlined, size: 16, color: c.text),
        ),
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
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: const BorderRadius.all(Radius.circular(8)),
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
                  Icon(iconData, color: iconColor, size: 28),
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
            ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(10)),
              child: LinearProgressIndicator(
                value: pct <= 0 ? null : pct / 100,
                minHeight: 5,
                backgroundColor: Colors.white.withValues(alpha: 0.05),
                valueColor: AlwaysStoppedAnimation(c.primary),
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
      return _OfferBtn(label: 'Downloaded', color: c.secondary, onTap: null);
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
          borderRadius: const BorderRadius.all(Radius.circular(6)),
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
          borderRadius: const BorderRadius.all(Radius.circular(6)),
        ),
        child: Text('Stop',
            style: TextStyle(color: c.danger, fontSize: 10)),
      ),
    );
  }
}
