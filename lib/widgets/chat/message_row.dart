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
import '../nym_icons.dart';
import 'crypto_verified_badge.dart';
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
    this.inGroup = false,
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

  /// Bubble layout: this row is rendered INSIDE a [MessageGroup], which owns the
  /// group's horizontal padding and the single sticky [_StickyGroupAvatar]. When
  /// true, [_buildBubble] emits just the content stack (name / bubble /
  /// translation / readers / reactions) plus the per-row vertical rhythm — no
  /// avatar gutter, no self-contained row — so the group can lay the bubbles in
  /// one column beside the gliding avatar (PWA `.message-group-stack`).
  final bool inGroup;

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

  /// The cryptographic-verification lock state for this message, or null when no
  /// lock should render. The PWA only shows the `.crypto-verified-badge` on
  /// sealed (NIP-17/NIP-59) PM/group messages (`messages.js:752` gates on
  /// `message.isPM`); public channel messages carry no seal and show nothing.
  /// Within sealed messages: `senderVerified == true` → verified, `false` →
  /// unverified, `null` → unknown (seal unavailable, e.g. restored history).
  CryptoVerifyState? get _cryptoState {
    if (!message.isPM && !message.isGroup) return null;
    switch (message.senderVerified) {
      case true:
        return CryptoVerifyState.verified;
      case false:
        return CryptoVerifyState.unverified;
      case null:
        return CryptoVerifyState.unknown;
    }
  }

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
  MessageStyleDecoration? _styleDecoration(BuildContext context) {
    final cos = _cosmetics;
    final isLight = context.nym.isLight;
    final styled = messageStyleDecoration(cos.styleId, isLight: isLight);
    if (styled != null) return styled;
    if (cos.supporter) {
      return isLight ? supporterStyleDecorationLight : supporterStyleDecoration;
    }
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
    // `message.author` carries the stored nym which already includes its
    // `#suffix` (User.nym / the `anon#xxxx` fallback). Strip it so the canonical
    // suffix below isn't appended twice (PWA renders the base nym + a separate
    // `.nym-suffix` span — `parseNymFromDisplay`, `messages.js:1781`).
    final baseNym = stripPubkeySuffix(message.author);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (brackets)
          Text('<', style: TextStyle(color: bracketColor, fontSize: size)),
        Flexible(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: baseNym, style: style),
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
  /// The PWA only bold-weights the Genesis author line; supporters get gold on
  /// the `.message-content`, NOT the author nym — `.message.supporter-style
  /// .message-header` (styles-features.css:1478) is a DEAD selector (no JS ever
  /// emits `.message-header`; the author element is `.message-author`), so the
  /// author nym keeps the normal self/other color.
  TextStyle _authorStyle(NymColors c, {required bool self, required double size}) {
    final genesis = hasGenesisFlair(_cosmetics);
    // `.message-author.cosmetic-redacted { color:#fff !important; opacity:0.8 }`
    // (styles-features.css:1419-1422) — the redacted privacy cosmetic dims the
    // author nym to white@0.8 as well as blanking the body.
    final color = _cosmetics.isRedacted
        ? Colors.white.withValues(alpha: 0.8)
        : (self ? c.primary : c.secondary);
    return TextStyle(
      color: color,
      fontSize: size,
      fontWeight: genesis ? FontWeight.w700 : FontWeight.w600,
      // `.message-author { letter-spacing: 0.2px }` (styles-chat.css:697).
      letterSpacing: 0.2,
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
    // The pill's usable content width = screen − outer padding (8·2) − pill
    // padding (16·2). Both the author header and the action are capped to it so
    // a long nym ellipsises and a long action wraps onto its own line (the PWA
    // renders `* author flair action *` as inline text in a wrapping pill) —
    // never overflowing the centered `.me-message` pill.
    final maxW =
        (MediaQuery.of(context).size.width - 48).clamp(120.0, double.infinity);
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
            // `.me-message` is inline text in a wrapping pill (`* author flair
            // action *`). A `Wrap` reproduces that: the author header is one
            // width-capped unit (a long nym ellipsises) and the action flows
            // onto the next line when the two can't sit together — so neither
            // the fixed flair/supporter badges nor a long action can overflow.
            child: Wrap(
              spacing: 4,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxW),
                  child: GestureDetector(
                    onTap: () => _openContextMenu(context),
                    // The whole `/me` line (incl. the nym + suffix) is italic
                    // (`.system-message.me-message { font-style: italic }`); the
                    // author keeps secondary/600 but inherits the italic.
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Text('* '),
                        NymAvatar(
                            seed: message.pubkey,
                            size: fontSize + 2,
                            imageUrl: _authorPicture),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text.rich(
                            TextSpan(children: [
                              TextSpan(
                                text: stripPubkeySuffix(message.author),
                                style: TextStyle(
                                  color: c.secondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (suffix.isNotEmpty)
                                TextSpan(
                                  text: '#$suffix',
                                  style: TextStyle(color: c.secondaryA(0.6)),
                                ),
                            ]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        _nymBadges(context, flairSize: fontSize + 2),
                      ],
                    ),
                  ),
                ),
                // The action text (formatted), capped so it wraps within the
                // pill; the closing star trails it.
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxW),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(
                        child:
                            MessageContent(content: action, fontSize: fontSize),
                      ),
                      const Text(' *'),
                    ],
                  ),
                ),
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

    final deco = _styleDecoration(context);

    Color? bg;
    Color? barColor;
    if (self) {
      bg = c.secondaryA(0.05);
      // `.message.self::before` accent bar: white@0.3 dark; light-mode →
      // black@0.25.
      barColor = c.isLight
          ? const Color(0x40000000) // black @ 0.25
          : const Color(0x4DFFFFFF); // white @ 0.30
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

    // The `.message` flex-wrap row: `.message-time` (FIRST), then
    // `.message-author`, then `.message-content` — mirroring the PWA HTML order
    // (messages.js:936-938). Full-width siblings that the PWA wraps onto their
    // own lines (`.message-translation` width:100%, `.group-readers`/
    // `.channel-readers` flex-basis:100%) are hoisted OUT of the content column
    // into the outer Column below so they span the whole message, right-aligned,
    // rather than being clamped to the content's width.
    final messageRow = Wrap(
      crossAxisAlignment: WrapCrossAlignment.start,
      spacing: 10,
      runSpacing: 4,
      children: [
        // `.message-time { color:--text-dim; font-size:12px; min-width:50px }` —
        // the FIRST element, the left column, BEFORE the author. The clock
        // reserves a 50px column so author/content left-edges line up.
        if (settings.showTimestamps)
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 50),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatTime(message.dateTime, settings.timeFormat),
                  style: TextStyle(color: c.textDim, fontSize: 12),
                ),
                // `.crypto-lock-irc`: the verification lock sits inside
                // `.message-time` after the clock (PM/group only).
                if (_cryptoState != null)
                  CryptoVerifiedBadge(state: _cryptoState!),
              ],
            ),
          ),
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
                    seed: message.pubkey, size: 18, imageUrl: _authorPicture),
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
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width - 220,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _bodyContent(context, c.text, fontSize, deco: deco),
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
              // `updateMessageReactions` early-returns on an empty reaction set,
              // removing the row entirely unless zaps remain). The zap badge sits
              // at its front; the `.add-reaction-btn` (smiley-plus) is appended at
              // the end but ONLY on rows that already carry reactions — the first
              // react on a bare message is still via long-press quick-react.
              if (reactions.isNotEmpty || _hasZaps)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: _reactionsRow(context),
                ),
            ],
          ),
        ),
      ],
    );

    // The message body + the full-width siblings the PWA wraps below it. The
    // `.message-translation` (`width:100%`) and `.group-readers`/
    // `.channel-readers` (`flex-basis:100%; justify-content:flex-end`) each take
    // a full-message-width line UNDER the content, right-aligned — not clamped
    // to the content column.
    final rowChildren = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        messageRow,
        // `.message-translation`: full-width left-primary-bordered block BELOW
        // the message content (a sibling after `.message-content`, width:100%).
        if (_showTranslation)
          MessageTranslation(
            content: message.content,
            targetLang: _translateLangOverride,
          ),
        // `.channel-readers`/`.group-readers`: a FULL-WIDTH, right-aligned row
        // of 14px reader avatars BELOW the message.
        if (_showReaderAvatars) _readerAvatars(context),
        // PM delivery ticks (`.delivery-status`, right-aligned).
        if (self && message.isPM && !message.isGroup) _deliveryTicks(context),
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
      // `.message` is a block-level flex row filling `.messages-container` (no
      // shrink-wrap), so it spans the full list width. A full-width row is what
      // lets `.message-translation` (`width:100%`) and the `.group-readers`
      // (`flex-basis:100%`, right-aligned) line up across the whole message
      // rather than clamping to the (possibly short) content.
      width: double.infinity,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: bg != null ? NymRadius.rsm : null,
        // IRC-layout auras add an inset 1px ring + an outer glow on the whole
        // row (`body:not(.chat-bubbles) .message.cosmetic-aura-* { box-shadow:
        // inset 0 0 0 1px <ring>, 0 0 Npx <glow> }`, styles-features.css:1099+).
        // The bubble path routes these through CosmeticOverlayPainter/_decorate
        // Bubble; here we approximate the inset ring with a 1px border.
        border: strongestAura?.insetColor != null
            ? Border.all(color: strongestAura!.insetColor!, width: 1)
            : null,
        boxShadow:
            (strongestAura?.glowColor != null && strongestAura!.glowBlur > 0)
                ? [
                    BoxShadow(
                        color: strongestAura.glowColor!,
                        blurRadius: strongestAura.glowBlur),
                  ]
                : null,
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
    final deco = _styleDecoration(context);

    // In bubble mode the CSS applies the message style to `.message-content`
    // (the bubble): a translucent style background plus a soft glow halo.
    final auras = _auras;
    final lastAura = auras.isNotEmpty ? auras.last : null;
    // `.message-content` bubble fill. Dark mode: self primary@0.25, others
    // white@0.14. Light mode (`body.light-mode.chat-bubbles`): self primary@0.20,
    // others/PM black@0.10 — a translucent *white* over a light surface is
    // invisible, so the PWA flips others to a dark wash. A style/aura background
    // still takes precedence.
    final bubbleColor = deco?.contentBackground ??
        lastAura?.background ??
        (self
            ? c.primaryA(c.isLight ? 0.20 : 0.25)
            : (c.isLight
                ? const Color(0x1A000000) // black @ 0.10
                : Colors.white.withValues(alpha: 0.14)));
    final radius = _bubbleRadius(self);

    // The bubble interior = the body, THEN the `.bubble-time-inner` (the
    // timestamp sits at the BOTTOM-RIGHT, INSIDE the bubble background, below the
    // content — followed by the crypto lock). The `.message-translation` is NOT
    // here: the PWA inserts it as a sibling AFTER `.message-content`
    // (`translate.js: contentEl.after(translationEl)`), so it renders as a
    // full-width block BELOW the bubble — see [stack] below.
    final innerContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _bodyContent(context, c.text, fontSize, deco: deco),
        // `.bubble-time-inner { display:block; width:fit-content; margin-left:
        // auto; margin-top:4px; text-align:right }` — the relative time sits 4px
        // below the body, pinned to the bottom-right INSIDE the bubble.
        const SizedBox(height: 4),
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
            // `.bubble-time-text`: RELATIVE time ("now"/"2m ago"), not clock.
            Text(
              formatRelativeTime(message.dateTime),
              style: TextStyle(color: c.textDim, fontSize: 10, height: 1),
            ),
            // `.crypto-lock-bubble`: the verification lock follows the in-bubble
            // time (PM/group only).
            if (_cryptoState != null) CryptoVerifiedBadge(state: _cryptoState!),
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

    // `.message-group-stack` (`flex:1 1 auto; min-width:0`, a flex column). It
    // holds the name, the content bubble, then the full-width siblings the PWA
    // wraps below `.message-content`: `.message-translation` (`width:100%`) and
    // `.group-readers`/`.channel-readers` (`flex-basis:100%; justify-content:
    // flex-end`). The column STRETCHES so those span its full width; the
    // shrink-wrapped items (name / bubble / reactions) are re-aligned per side
    // via [sideAlign] (start, or end for self).
    final sideAlign = self ? Alignment.centerRight : Alignment.centerLeft;
    final stack = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showName && !widget.grouped)
          Align(
            alignment: sideAlign,
            child: Padding(
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
          ),
        Align(alignment: sideAlign, child: bubble),
        // `.message-translation`: a full-width left-primary-bordered block BELOW
        // the bubble (a sibling after `.message-content`, NOT inside it).
        if (_showTranslation)
          MessageTranslation(
            content: message.content,
            targetLang: _translateLangOverride,
          ),
        // `.group-readers`/`.channel-readers`: a FULL-WIDTH, right-aligned row of
        // 14px reader avatars below the message.
        if (_showReaderAvatars) _readerAvatars(context),
        if (reactions.isNotEmpty || _hasZaps)
          Align(
            alignment: sideAlign,
            child: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: _reactionsRow(context),
            ),
          ),
      ],
    );

    // Per-message vertical rhythm. The PWA tightly stacks a group's bubbles and
    // separates groups by ~6px: `.message { margin-bottom: 6px }` for a group
    // lead, while a `.bubble-grouped` member uses `margin-top: -4px` (the first
    // grouped after the lead `-8px`) for a ~2px in-group gap. Flutter list items
    // can't carry negative inter-item margins, so the equivalent EFFECTIVE gaps
    // are driven from the top edge only (bottom 0): a group lead opens 6px of
    // air above it; a continuation member sits 2px below the previous bubble.
    final vPad = EdgeInsets.only(top: widget.grouped ? 2 : 6);

    // Rendered inside a [MessageGroup]: emit ONLY the content stack with its
    // vertical rhythm. The group owns the `.message-group` horizontal padding
    // and the single gliding [_StickyGroupAvatar], laying every bubble of the
    // run in one `.message-group-stack` column beside it.
    if (widget.inGroup) {
      return Padding(padding: vPad, child: stack);
    }

    // Legacy standalone path (direct [MessageRow] use, not via [MessageGroup]):
    // a self-contained `.message-group` row carrying its own 32px avatar.
    // Horizontal inset mirrors `.message-group` padding: an others' group is
    // `padding: 0 14px 0 6px` (the 32px avatar starts 6px from the edge), a
    // self group is `padding: 0 14px` (`group-self`, row-reversed, no avatar).
    final row = Row(
      mainAxisAlignment:
          self ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!self) ...[
          SizedBox(
            width: 32,
            child: widget.showAvatar
                ? GestureDetector(
                    onTap: () => _openContextMenu(context),
                    child: NymAvatar(
                        seed: message.pubkey,
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
      padding: EdgeInsets.fromLTRB(self ? 14 : 6, widget.grouped ? 2 : 6, 14, 0),
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
    final watermark = _styleDecoration(context)?.watermark ??
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
                      seed: visible[i].key,
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
        // The `.add-reaction-btn` (a smiley-plus glyph) is appended at the END
        // of the row, AFTER the reaction badges (`reactions.js:569-581`). The
        // PWA only renders it on rows that already carry reactions — its
        // `updateMessageReactions` early-returns and strips the button when the
        // reaction set is empty (`reactions.js:440-453`), so it is NOT drawn for
        // zero-reaction or zap-only rows. Clicking it opens the full emoji
        // picker (`showEnhancedReactionPicker`) → `widget.onReactionPicker`.
        if (reactions.isNotEmpty && widget.onReactionPicker != null)
          _AddReactionButton(
            onTap: () => widget.onReactionPicker?.call(message),
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
    // Resolve any reactor we lack an avatar for (e.g. reactions restored from
    // cache, never seen live) — the PWA's `ensureListProfiles` on the reactor
    // list. Debounced/guarded; faces fill in on the next open.
    ref.read(nostrControllerProvider).ensureProfiles(map.keys);
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
          // Count abbreviated (`abbreviateNumber`, e.g. `1.2k`). The badge label
          // stays `--text` even when user-reacted (only bg/border/glow change —
          // `styles-chat.css:439-443`). Routed through [InlineEmojiText] so a
          // NIP-30 `:shortcode:` reaction renders as its custom-emoji image, not
          // literal text; unicode reactions stay a plain styled Text.
          child: InlineEmojiText(
            text: '${r.emoji} ${abbreviateNumber(r.count)}',
            style: TextStyle(color: c.text, fontSize: 12),
            emojiSize: 18,
          ),
        ),
      ),
    );
  }
}

/// The `.add-reaction-btn` pill (`styles-chat.css:463-488`, `reactions.js:569`):
/// a 16px smiley-plus glyph in a rounded-20 pill (bg white@0.04, 1px glass
/// border, `4px 8px` padding) resting at `opacity: 0.6`. Tapping it opens the
/// full emoji reaction picker for the message (the PWA's
/// `showEnhancedReactionPicker`). The CSS `:hover` brightens it to opacity 1
/// with a primary-tinted border/background; since touch has no hover, we surface
/// that as a press state (opacity 1 + primary tint while held) and a slight
/// scale-down, mirroring the `.reaction-badge:active` feel.
class _AddReactionButton extends StatefulWidget {
  const _AddReactionButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_AddReactionButton> createState() => _AddReactionButtonState();
}

class _AddReactionButtonState extends State<_AddReactionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Opacity(
          // `.add-reaction-btn { opacity: 0.6 }`, `:hover { opacity: 1 }`.
          opacity: _pressed ? 1.0 : 0.6,
          child: Container(
            // `padding: 4px 8px`.
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              // bg white@0.04; `:hover` → primary@0.08.
              color: _pressed
                  ? c.primaryA(0.08)
                  : Colors.white.withValues(alpha: 0.04),
              // `border-radius: 20px`.
              borderRadius: const BorderRadius.all(Radius.circular(20)),
              // 1px glass border; `:hover` → primary@0.3.
              border: Border.all(
                color: _pressed ? c.primaryA(0.3) : c.glassBorder,
              ),
            ),
            // `.add-reaction-btn svg { width:16px; height:16px; fill:var(--text) }`
            // (reactions.js:570) — the smiley-with-plus glyph, tinted --text.
            child: NymSvgIcon(
              NymIcons.addReaction,
              size: 16,
              color: c.text,
            ),
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
  /// The PWA uses ONE generic file glyph and only re-tints the stroke per
  /// category (default → `--primary`), so this returns the colour alone.
  static Color _category(NymColors c, FileOffer o) {
    final ext = o.name.contains('.') ? o.name.split('.').last.toLowerCase() : '';
    final mime = o.type.toLowerCase();
    bool any(List<String> exts) => exts.contains(ext);
    if (any(['mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a', 'wma']) ||
        mime.startsWith('audio/')) {
      return c.purple; // `.file-offer-icon.audio`
    }
    if (any(['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm']) ||
        mime.startsWith('video/')) {
      return c.danger; // `.file-offer-icon.video`
    }
    if (any(['zip', 'rar', '7z', 'tar', 'gz', 'bz2'])) {
      return c.warning; // `.file-offer-icon.archive`
    }
    if (any(['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'rtf'])) {
      return c.secondary; // `.file-offer-icon.document`
    }
    return c.primary; // default `.file-offer-icon svg { stroke: var(--primary) }`
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final iconColor = _category(c, offer);
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
                  // glass border, radius-xs=8) wrapping the 24px generic file
                  // glyph (styles-features.css:2064-2080). The category re-tints
                  // the stroke (audio/video/archive/document, else --primary).
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      border: Border.all(color: c.glassBorder),
                      borderRadius: NymRadius.rxs,
                    ),
                    child: NymSvgIcon(NymIcons.fileOffer,
                        color: iconColor, size: 24),
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

/// One message inside a [MessageGroup]: the message plus its already-resolved
/// reactions and mention flag (computed once by [MessagesList] so the row needn't
/// re-watch them).
class MessageGroupEntry {
  const MessageGroupEntry({
    required this.message,
    required this.reactions,
    required this.mentioned,
  });

  final Message message;
  final List<MessageReaction> reactions;
  final bool mentioned;
}

/// A `.message-group`: a run of consecutive same-author bubble messages laid out
/// in one `.message-group-stack` column beside a SINGLE avatar — the PWA's
/// `.message-group-avatar` (32px, `align-self: flex-end`, `position: sticky;
/// bottom: 8px`). Grouping consecutive messages into one widget is what lets that
/// avatar span the whole run and GLIDE up the left edge as a tall group scrolls
/// (each message is otherwise its own list item, so a per-row avatar can't move
/// past its row). The glide itself lives in [_StickyGroupAvatar].
///
/// In IRC mode — and for standalone system / `/me` rows — a "group" is always a
/// single entry and renders bare (no avatar gutter, no group chrome), so those
/// paths are byte-for-byte what [MessageRow] produced before grouping existed.
class MessageGroup extends ConsumerWidget {
  const MessageGroup({
    super.key,
    required this.entries,
    required this.settings,
    this.onReactionPicker,
  });

  final List<MessageGroupEntry> entries;
  final Settings settings;
  final ValueChanged<Message>? onReactionPicker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useBubbles = settings.useBubbles;
    final first = entries.first.message;
    final self = first.isOwn;

    // The `.message-group-stack` rows. `grouped`/`showName` track position in the
    // run (only the lead carries a name); `inGroup` strips each row to its content
    // stack so the group can host the one shared avatar.
    List<Widget> buildRows() => [
          for (var i = 0; i < entries.length; i++)
            MessageRow(
              key: ValueKey(entries[i].message.id),
              message: entries[i].message,
              settings: settings,
              reactions: entries[i].reactions,
              mentioned: entries[i].mentioned,
              grouped: useBubbles && i > 0,
              showName: !(useBubbles && i > 0),
              showAvatar: false,
              inGroup: useBubbles,
              onReactionPicker: onReactionPicker,
            ),
        ];

    // IRC layout, or a standalone system / `/me` row → no grouping chrome.
    if (!useBubbles || first.isSystemRow || first.isMeAction) {
      final rows = buildRows();
      return rows.length == 1
          ? rows.first
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
    }

    // `width: double.infinity` forces the column to fill the group's width under
    // the loose constraints a [Padding]/[Stack] hands it — without it a
    // `CrossAxisAlignment.stretch` column shrink-wraps to its widest bubble,
    // collapsing the full-width translation / read-receipt rows and breaking the
    // self side's right-alignment (the old `Flexible`-in-`Row` gave it a tight
    // width). The `.message-group-stack` is `flex: 1 1 auto`, i.e. full width.
    final stack = SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: buildRows(),
      ),
    );

    // Self group: `group-self` is `padding: 0 14px`, row-reversed, no avatar —
    // each row already right-aligns its own content.
    if (self) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: stack,
      );
    }

    // Others group: `.message-group { padding: 0 14px 0 6px; gap: 6px }`. The
    // 32px avatar lives in a Positioned overlay pinned to the left gutter; the
    // stack is inset 38px (32 avatar + 6 gap) to sit where `.message-group-stack`
    // does. The overlay (full group height) lets the avatar glide within the
    // group's bounds without disturbing the bubble column's layout.
    final last = entries.last.message;
    final picture = ref.watch(
        usersProvider.select((m) => m[first.pubkey]?.profile?.picture));
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 14, 0),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 38),
            child: stack,
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 32,
            child: _StickyGroupAvatar(
              pubkey: first.pubkey,
              imageUrl: picture,
              onTap: () => _openAvatarMenu(context, ref, last),
            ),
          ),
        ],
      ),
    );
  }

  /// Tapping the group avatar opens the context menu for the group's LAST message
  /// (PWA `_createMessageGroupWrapper`: the avatar click resolves
  /// `stack.lastElementChild` and calls `showContextMenu`).
  void _openAvatarMenu(BuildContext context, WidgetRef ref, Message last) {
    final app = ref.read(appStateProvider);
    final target = ctxTargetForMessage(last, selfPubkey: app.selfPubkey);
    ContextMenuPanel.show(
      context,
      target: target,
      message: last,
      onReact: () => onReactionPicker?.call(last),
    );
  }
}

/// The single per-group avatar reproducing the PWA's `.message-group-avatar`
/// (`position: sticky; bottom: 8px; align-self: flex-end`). It fills the group's
/// left gutter (a full-height, 32px-wide track) and positions a 32px avatar that:
///   * rests at the group's foot (bottom of the stack) when the group sits above
///     the viewport's bottom edge, and
///   * GLIDES up to stay pinned 8px above the scroll viewport's bottom edge while
///     a tall group spans that edge — clamped to the group's own bounds, exactly
///     like CSS `position: sticky` constrained to its containing block. So a long
///     monologue's avatar tracks the screen bottom as you scroll, then settles
///     once the group's end scrolls into view.
///
/// The glide reads the previous frame's render geometry (the build runs before
/// layout); mid-scroll that one-frame lag is imperceptible, and a post-frame
/// recompute settles the initial (un-scrolled) position. Only this 32px box
/// rebuilds per scroll tick — the [NymAvatar] is hoisted via the builder's
/// `child` so it is built once.
class _StickyGroupAvatar extends StatefulWidget {
  const _StickyGroupAvatar({
    required this.pubkey,
    required this.imageUrl,
    required this.onTap,
  });

  final String pubkey;
  final String? imageUrl;
  final VoidCallback onTap;

  @override
  State<_StickyGroupAvatar> createState() => _StickyGroupAvatarState();
}

class _StickyGroupAvatarState extends State<_StickyGroupAvatar> {
  /// CSS `bottom: 8px` — the avatar floats 8px above the viewport's bottom edge.
  static const double _stickyGap = 8;
  static const double _avatar = 32;

  /// Bumped on every scroll tick to recompute the glide offset (the value is
  /// unused — it only drives the [ValueListenableBuilder] rebuild).
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);
  ScrollPosition? _position;

  @override
  void initState() {
    super.initState();
    // Settle the initial (un-scrolled) position once the first layout exists.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tick.value++;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = Scrollable.maybeOf(context)?.position;
    if (!identical(p, _position)) {
      _position?.removeListener(_onScroll);
      _position = p;
      _position?.addListener(_onScroll);
    }
  }

  void _onScroll() {
    if (mounted) _tick.value++;
  }

  @override
  void dispose() {
    _position?.removeListener(_onScroll);
    _tick.dispose();
    super.dispose();
  }

  /// The avatar's top within its [maxTop]-bounded track — `clamp(desired, 0,
  /// maxTop)` is precisely CSS sticky bounded to the containing block, where
  /// `desired` places the avatar 8px above the viewport bottom.
  double _computeTop(double maxTop) {
    final scrollable = Scrollable.maybeOf(context);
    final track = context.findRenderObject();
    if (scrollable != null && track is RenderBox && track.hasSize) {
      final viewport = scrollable.context.findRenderObject();
      if (viewport is RenderBox && viewport.hasSize) {
        final trackTop =
            track.localToGlobal(Offset.zero, ancestor: viewport).dy;
        final desired =
            viewport.size.height - _stickyGap - _avatar - trackTop;
        return desired.clamp(0.0, maxTop);
      }
    }
    return maxTop; // resting at the group's foot
  }

  @override
  Widget build(BuildContext context) {
    final avatar = GestureDetector(
      onTap: widget.onTap,
      child: NymAvatar(
        seed: widget.pubkey,
        size: _avatar,
        imageUrl: widget.imageUrl,
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxTop =
            (constraints.maxHeight - _avatar).clamp(0.0, double.infinity);
        return ValueListenableBuilder<int>(
          valueListenable: _tick,
          builder: (context, _, child) => Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                top: _computeTop(maxTop),
                width: _avatar,
                height: _avatar,
                child: child!,
              ),
            ],
          ),
          child: avatar,
        );
      },
    );
  }
}
