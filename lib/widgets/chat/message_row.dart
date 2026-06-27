import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/autocomplete/pending_edit.dart';
import '../../features/messages/flood_tracker.dart';
import '../../features/messages/format/message_content.dart';
import '../../features/settings/about_screen.dart';
import '../../features/p2p/p2p_models.dart';
import '../../features/p2p/p2p_service.dart';
import '../../features/shop/cosmetics.dart';
import '../../features/reactions/quick_context_items.dart';
import '../../features/reactions/quick_react_popup.dart';
import '../../features/reactions/reaction_burst.dart';
import '../../features/reactions/reactors_modal.dart';
import '../../features/translate/message_translation.dart';
import '../../features/zaps/zap_badge.dart';
import '../../features/zaps/zap_modal.dart';
import '../../models/message.dart';
import '../../models/settings.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../common/nym_avatar.dart';
import '../nym_icons.dart';
import 'bitchat_user_color.dart';
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

const List<String> _shortMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// The full "date, time" label shown when a message timestamp is tapped
/// (`_formatFullTimestamp`, messages.js:3328): seconds-precision time in the
/// user's 12/24h format, with the date per the `dateFormat` setting
/// (`mdy`/`dmy`/`ymd`, else "Mon D, YYYY").
String formatFullTimestamp(DateTime t, String timeFormat, String dateFormat) {
  final h24 = t.hour;
  final m = t.minute.toString().padLeft(2, '0');
  final s = t.second.toString().padLeft(2, '0');
  final String timeStr;
  if (timeFormat == '24hr') {
    timeStr = '${h24.toString().padLeft(2, '0')}:$m:$s';
  } else {
    final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
    final ampm = h24 < 12 ? 'AM' : 'PM';
    timeStr = '${h12.toString().padLeft(2, '0')}:$m:$s $ampm';
  }
  final y = t.year;
  final mo = t.month.toString().padLeft(2, '0');
  final d = t.day.toString().padLeft(2, '0');
  final String dateStr;
  switch (dateFormat) {
    case 'mdy':
      dateStr = '$mo/$d/$y';
    case 'dmy':
      dateStr = '$d/$mo/$y';
    case 'ymd':
      dateStr = '$y-$mo-$d';
    default:
      dateStr = '${_shortMonths[t.month - 1]} ${t.day}, $y';
  }
  return '$dateStr, $timeStr';
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
  /// hologram) composed onto the bubble/row, resolved for the current brightness
  /// (the PWA swaps gold — and a derived tone for the rest — in `light-mode`).
  List<CosmeticAura> _resolveAuras(BuildContext context) =>
      resolveCosmeticAuras(_cosmetics, isLight: context.nym.isLight);

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
    // `.message-author.cosmetic-redacted { color:#fff; opacity:0.8 }`
    // (styles-features.css:1419-1422) — the redacted privacy cosmetic dims the
    // author nym as well as blanking the body. Light mode swaps to a dark nym
    // (`body.light-mode … .message-author.cosmetic-redacted { color:#1a1a1a;
    // opacity:0.75 }`, styles-themes-responsive.css:949), since white@0.8 is
    // invisible on a light surface.
    final color = _cosmetics.isRedacted
        ? (c.isLight
            ? const Color(0xFF1A1A1A).withValues(alpha: 0.75)
            : Colors.white.withValues(alpha: 0.8))
        : (self ? c.primary : (_bitchatColor(c) ?? c.secondary));
    return TextStyle(
      color: color,
      fontSize: size,
      fontWeight: genesis ? FontWeight.w700 : FontWeight.w600,
      // `.message-author { letter-spacing: 0.2px }` (styles-chat.css:697).
      letterSpacing: 0.2,
    );
  }

  /// The per-user "bitchat-user" color for a NON-self author, or null when it
  /// doesn't apply. The PWA only assigns the deterministic 1-of-1000 hue when
  /// `settings.theme === 'bitchat'` and the author isn't self (`getUserColorClass`,
  /// `users.js:11-18`); in every other theme `.message-author` keeps `--secondary`.
  /// The same class is applied to the author span AND `.message-content`
  /// (`messages.js:937-938`), so the body uses this too. (C06-1/2.)
  Color? _bitchatColor(NymColors c) {
    if (message.isOwn) return null;
    if (settings.theme != NymThemeKey.bitchat) return null;
    return bitchatUserColor(message.pubkey, isLight: c.isLight);
  }

  /// The message body: a P2P file-offer card when this is an offer, a redacted
  /// block when the redacted cosmetic is active, else the rich-formatted content
  /// tinted by the active style.
  Widget _bodyContent(
    BuildContext context,
    Color color,
    double fontSize, {
    MessageStyleDecoration? deco,
    bool bubble = false,
  }) {
    if (message.isFileOffer && message.fileOffer != null) {
      final p2p = ref.read(p2pServiceProvider);
      // Resolve the channel currently open so the inline Stop broadcasts the
      // unseeded event with the matching wire tag — `g` for a geohash channel,
      // `d` for a named one — like the PWA's `stopSeeding`, which reads
      // `this.currentGeohash` regardless of where Stop fires (p2p.js:828). F06-B3.
      final app = ref.read(appStateProvider);
      final v = app.view;
      final isGeoChannel = v.kind == ViewKind.channel &&
          app.channels
              .any((ch) => ch.key == v.id.toLowerCase() && ch.isGeohash);
      final isNamedChannel = v.kind == ViewKind.channel && !isGeoChannel;
      return FileOfferCard(
        offer: FileOffer.fromJson(message.fileOffer!),
        isOwn: message.isOwn,
        service: p2p,
        seedGeohash: isGeoChannel ? v.id : null,
        seedChannelName: isNamedChannel ? v.id : null,
      );
    }
    // cosmetic-redacted (`shop.js:498-512`): the REAL text shows for 10s, then a
    // `.cosmetic-redacted-message` translucent bar replaces it (bg white@0.15,
    // radius-xs, min-width 120, min-height 1.2em, content hidden).
    if (_cosmetics.isRedacted) {
      return _RedactedReveal(
        fontSize: fontSize,
        child: _content(context, color, fontSize, deco: deco, bubble: bubble),
      );
    }
    return _content(context, color, fontSize, deco: deco, bubble: bubble);
  }

  @override
  Widget build(BuildContext context) {
    // Centered system / action pill (`displaySystemMessage`).
    if (message.isSystemRow) return _buildSystemMessage(context);
    // `/me …` emote → italic "* author action *" line.
    if (message.isMeAction) return _buildActionMessage(context);
    Widget row =
        settings.useBubbles ? _buildBubble(context) : _buildIrc(context);
    // `.message.flooded { opacity: 0.2 }` — a flooding (others') pubkey in the
    // current conversation is dimmed (`messages.js:652-656`). Own messages are
    // never flooded.
    if (!message.isOwn &&
        ref.watch(floodTrackerProvider).isFlooding(message.pubkey)) {
      row = Opacity(opacity: 0.2, child: row);
    }
    // `.message-scroll-flash`: a tapped blockquote scrolls to its quoted source
    // and flashes it (`_scrollToQuotedMessage`, messages.js:2775). Watch the
    // transient flash signal and pulse this row's highlight halo when it targets
    // us (the `::after` primary-tinted overlay, styles-chat.css:1285-1306).
    final flashing = ref.watch(flashedMessageProvider) == message.id;
    return _ScrollFlashOverlay(active: flashing, child: row);
  }

  /// A centered `.system-message` (or `.action-message`) pill injected into the
  /// conversation flow (`styles-chat.css:1334-1360`). Text-dim, rounded-20,
  /// `white@0.03` bg, glass border, `textSize-3`; the action variant is
  /// purple-italic. When the row carries a [Message.systemAction] (e.g. the spam
  /// false-positive notice) an inline action button is rendered under the text.
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
    final action = message.systemAction;
    // The pill body: just the text, or text + an inline action button (the
    // `.spam-false-positive-btn` of messages.js:645).
    final Widget pillChild = action == null
        ? text
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              text,
              const SizedBox(height: 8),
              _SystemActionButton(
                label: action.label,
                onTap: () => _runSystemAction(context, action),
              ),
            ],
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
                child: pillChild,
              ),
      ),
    );
  }

  /// Dispatches a system-row [SystemAction]. For the spam false-positive notice
  /// this opens the About contact form pre-filled with topic 'Spam false
  /// positive' and the flagged message in a code block — a 1:1 port of
  /// `reportSpamFalsePositive(content)` (app.js:4399-4404).
  void _runSystemAction(BuildContext context, SystemAction action) {
    switch (action.kind) {
      case SystemActionKind.reportSpamFalsePositive:
        final content = action.payload;
        final body = content.isNotEmpty
            ? 'The following message was incorrectly flagged by the spam '
                'filter:\n\n```\n$content\n```'
            : 'A message was incorrectly flagged by the spam filter.';
        AboutScreen.open(
          context,
          initialTopic: 'Spam false positive',
          initialMessage: body,
        );
    }
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
                        // `.flair-badge { font-size: 20px }` applies in the main
                        // chat including `/me` lines (only call surfaces scale it
                        // down) — match the IRC/bubble author lines at 20px.
                        _nymBadges(context, flairSize: 20),
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
                        // `/me` action mentions get inline avatars + flair
                        // (PWA `_enrichActionMentions`, messages.js:1369-1403):
                        // each `@nym#xxxx` inside the emote is decorated with the
                        // mentioned user's avatar. `enrichMentionAvatars` threads
                        // through `MessageContent` to `_MentionChip(withAvatar:)`.
                        child: MessageContent(
                          content: action,
                          fontSize: fontSize,
                          enrichMentionAvatars: true,
                        ),
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
    // A 135deg gradient painted on the IRC row (supporter's gold wash + the
    // gold/neon/phoenix/cosmic aura gradients). Takes precedence over the flat
    // [bg] in the row decoration below.
    List<Color>? bgGradient;
    // IRC layout paints the message-style accents on the row itself
    // (`body:not(.chat-bubbles) .message.supporter-style { background; border-left }`).
    if (deco?.borderAccent != null) {
      barColor = deco!.borderAccent;
      // Supporter paints a gold linear-gradient on the IRC row (not a flat fill);
      // a plain style background (none today in IRC) would use contentBackground.
      bgGradient = deco.backgroundGradient ?? bgGradient;
      if (deco.backgroundGradient == null) bg = deco.contentBackground ?? bg;
    }
    // Special cosmetic auras also paint a left bar + background tint on the row.
    // The PWA paints `background: linear-gradient(135deg,…)` on the IRC row for
    // gold/neon/phoenix/cosmic, and a flat fill for frost — read BOTH here (the
    // old code read only `aura.background`, dropping the 4 gradient auras).
    final auras = _resolveAuras(context);
    final strongestAura = auras.isNotEmpty ? auras.last : null;
    if (strongestAura?.borderAccent != null) {
      barColor = strongestAura!.borderAccent;
    }
    if (strongestAura?.gradient != null) {
      bgGradient = strongestAura!.gradient;
    } else if (strongestAura?.background != null) {
      bg = strongestAura!.background;
    }
    // The aura whose overlay (prism ring / hologram sheen) must paint on the IRC
    // row — the same painter the bubble path uses (was bubble-only, so IRC
    // rainbow/hologram rendered nothing but a glow).
    final overlayAura =
        auras.where((a) => a.hasOverlay && (a.prismRing || a.hologram)).isNotEmpty
            ? auras.firstWhere((a) => a.prismRing || a.hologram)
            : null;
    // The watermark + whether it tiles edge-only — both read off the SAME aura
    // (the first with a watermark) so a frost+other combination stays consistent.
    final styleWatermark = deco?.watermark;
    final CosmeticAura? auraWatermark = styleWatermark != null
        ? null
        : auras.where((a) => a.watermark != null).fold<CosmeticAura?>(
            null, (prev, a) => prev ?? a);
    final watermark = styleWatermark ?? auraWatermark?.watermark;
    final edgeWatermark = auraWatermark?.edgeWatermark ?? false;

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
                // `data-action="showFullTimestamp"`: tapping the clock shows the
                // full date+time popup (messages.js:936-938, showTimestampPopup).
                Tooltip(
                  message: formatFullTimestamp(message.dateTime,
                      settings.timeFormat, settings.dateFormat),
                  triggerMode: TooltipTriggerMode.tap,
                  child: Text(
                    formatTime(message.dateTime, settings.timeFormat),
                    style: TextStyle(color: c.textDim, fontSize: 12),
                  ),
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
              _bodyContent(context, _bitchatColor(c) ?? c.text, fontSize,
                  deco: deco),
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
        // `.edited-indicator-irc { display:block; text-align:right; margin-left:
        // auto }` — the PWA appends `editedIRC` as a TOP-LEVEL sibling AFTER
        // `.message-content` (messages.js:939), so it right-aligns across the
        // WHOLE message row, not just the (possibly short) content column.
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
                Positioned.fill(
                    child: StyleWatermarkLayer(
                        watermark: watermark, edgeOnly: edgeWatermark)),
                rowChildren,
              ],
            )
          : rowChildren,
    );
    // The IRC row inset ring is approximated by a 1px border — but suppress it
    // for an overlay aura (prism/hologram), whose ring the painter strokes (else
    // a double ring). gold/neon/phoenix/cosmic keep the border approximation.
    final rowRing = (strongestAura?.insetColor != null &&
            strongestAura != overlayAura)
        ? strongestAura!.insetColor
        : null;
    final rowGlowBlur = strongestAura?.glowBlurFor(bubble: false) ?? 0;
    final hasBg = bg != null || bgGradient != null;
    final content = Container(
      // `.message` is a block-level flex row filling `.messages-container` (no
      // shrink-wrap), so it spans the full list width. A full-width row is what
      // lets `.message-translation` (`width:100%`) and the `.group-readers`
      // (`flex-basis:100%`, right-aligned) line up across the whole message
      // rather than clamping to the (possibly short) content.
      width: double.infinity,
      decoration: BoxDecoration(
        color: bgGradient == null ? bg : null,
        // The 135deg gold/aura gradient on the row (`linear-gradient(135deg,…)`).
        gradient: bgGradient != null
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: bgGradient,
              )
            : null,
        borderRadius: hasBg ? NymRadius.rsm : null,
        // IRC-layout auras add an inset 1px ring + an outer glow on the whole
        // row (`body:not(.chat-bubbles) .message.cosmetic-aura-* { box-shadow:
        // inset 0 0 0 1px <ring>, 0 0 Npx <glow> }`, styles-features.css:1099+).
        // The bubble path routes these through CosmeticOverlayPainter/_decorate
        // Bubble; here we approximate the inset ring with a 1px border.
        border: rowRing != null ? Border.all(color: rowRing, width: 1) : null,
        boxShadow:
            (strongestAura?.glowColor != null && rowGlowBlur > 0)
                ? [
                    BoxShadow(
                        color: strongestAura!.glowColor!,
                        blurRadius: rowGlowBlur),
                  ]
                : null,
      ),
      clipBehavior: hasBg ? Clip.antiAlias : Clip.none,
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
    // The prism ring / holographic sheen — the same painter the bubble uses,
    // now wired into the IRC ROW (rainbow/hologram in IRC previously rendered
    // only a glow). Painted over the full row bounds (clipped to the row radius)
    // so the ring sits at the row edge, not inside the content padding.
    final decorated = overlayAura == null
        ? content
        : Stack(
            children: [
              content,
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: NymRadius.rsm,
                    child: CustomPaint(
                      painter: CosmeticOverlayPainter(
                        aura: overlayAura,
                        radius: NymRadius.rsm,
                        bubble: false,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
    return _SwipeToAct(
      settings: settings,
      onAction: (a) => _dispatchSwipeAction(context, a),
      // Desktop double-click → quote-reply (setupDoubleClickToReply).
      onDoubleTap: _quoteReply,
      onLongPress: () => _onMessageLongPress(context),
      // Desktop right-click → context menu (PWA `contextmenu` handler).
      onSecondaryTap: () => _openContextMenu(context),
      child: decorated,
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
    final auras = _resolveAuras(context);
    final lastAura = auras.isNotEmpty ? auras.last : null;
    // The aura gradient is painted as the bubble FILL only for auras whose PWA
    // bubble actually has a background (gold). neon/phoenix/cosmic are
    // box-shadow-only in the bubble (their gradient is the IRC row's only), so
    // they must NOT over-paint a fill here. (P1#4.)
    final bubbleGradient = (lastAura != null && lastAura.bubblePaintsGradient)
        ? lastAura.bubbleFillGradient
        : null;
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
    // content — followed by the crypto lock). The PM `.delivery-status` ticks are
    // NOT here: the PWA emits them as a TOP-LEVEL sibling AFTER `.message-content`
    // (`messages.js:940`, `flex-basis:100%; text-align:right`), so they render as
    // a full-width right-aligned line BELOW the bubble — see [stack] below. The
    // `.message-translation` is likewise a sibling after `.message-content`.
    final innerContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _bodyContent(context, _bitchatColor(c) ?? c.text, fontSize,
            deco: deco, bubble: true),
        // `.bubble-time-inner { display:block; width:fit-content; margin-left:
        // auto; margin-top:4px; text-align:right }` — the relative time sits 4px
        // below the body, pinned to the bottom-RIGHT INSIDE the bubble. The Row
        // shrink-wraps (`width:fit-content`); an [Align] supplies the
        // `margin-left:auto` (right-edge pin) the bare Row's `mainAxisAlignment`
        // can't, since a min-size Row in a `start`-aligned ≥180px Column would
        // otherwise sit bottom-LEFT.
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (message.isEdited)
                Text(
                  '(edited) ',
                  style: TextStyle(
                      color: c.textDim,
                      fontSize: 10,
                      fontStyle: FontStyle.italic),
                ),
              // `.bubble-time-text`: RELATIVE time ("now"/"2m ago"), not clock.
              // Tapping it shows the full date+time popup (showTimestampPopup).
              Tooltip(
                message: formatFullTimestamp(
                    message.dateTime, settings.timeFormat, settings.dateFormat),
                triggerMode: TooltipTriggerMode.tap,
                child: Text(
                  formatRelativeTime(message.dateTime),
                  style: TextStyle(color: c.textDim, fontSize: 10, height: 1),
                ),
              ),
              // `.crypto-lock-bubble`: the verification lock follows the in-bubble
              // time (PM/group only).
              if (_cryptoState != null) CryptoVerifiedBadge(state: _cryptoState!),
            ],
          ),
        ),
      ],
    );

    // Re-render the relative time on a cadence (cheap; matches the PWA timer).
    _ensureRelativeTimer();

    final bubble = _SwipeToAct(
      settings: settings,
      onAction: (a) => _dispatchSwipeAction(context, a),
      // Desktop double-click → quote-reply (setupDoubleClickToReply).
      onDoubleTap: _quoteReply,
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
          // Only gold paints its gradient as the bubble fill; neon/phoenix/
          // cosmic are box-shadow-only in the bubble (gradient is IRC-only).
          gradient: bubbleGradient,
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
        // PM sent/delivered/read receipt (`.delivery-status`). The PWA emits it as
        // a TOP-LEVEL sibling AFTER `.message-content` (`messages.js:940`), and the
        // base rule `flex-basis:100%; text-align:right; padding-right:4px`
        // (styles-chat.css:665-671) wraps it onto its OWN full-width line BELOW the
        // bubble, right-aligned — NOT inside the bubble next to the time. Identical
        // placement to the IRC layout (which also appends it as a sibling).
        if (self && message.isPM && !message.isGroup) _deliveryTicks(context),
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
      // border below) + the outer glow (the bubble blur, e.g. gold 12px not 18).
      final blur = a.glowBlurFor(bubble: true);
      if (a.glowColor != null && blur > 0) {
        shadows.add(BoxShadow(color: a.glowColor!, blurRadius: blur));
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

    // Watermark from the active style or a frost/cosmic aura — and whether that
    // watermark tiles edge-only (frost) rather than across the whole box.
    final styleWatermark = _styleDecoration(context)?.watermark;
    final CosmeticAura? auraWatermark = styleWatermark != null
        ? null
        : auras.where((a) => a.watermark != null).fold<CosmeticAura?>(
            null, (prev, a) => prev ?? a);
    final watermark = styleWatermark ?? auraWatermark?.watermark;
    final edgeWatermark = auraWatermark?.edgeWatermark ?? false;

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
              Positioned.fill(
                  child: StyleWatermarkLayer(
                      watermark: watermark, edgeOnly: edgeWatermark)),
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
      // The PWA buzzes on every successful add (`nymHapticTap`, reactions.js:968).
      HapticFeedback.selectionClick();
      final center = _globalCenterOfContext(context);
      if (center != null) ReactionBurst.play(context, center, r.emoji);
    }
  }

  void _showReactors(BuildContext context, MessageReaction r, Rect rect) {
    // Long-press on a reaction badge buzzes before the reactors modal opens
    // (`nymHapticTap`, reactions.js:526).
    HapticFeedback.selectionClick();
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
    // The PWA buzzes as the quick-react popup is built (`nymHapticTap`,
    // ui-context.js:1279); a raw GestureDetector.onLongPress is otherwise silent.
    HapticFeedback.selectionClick();
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
      // The PWA buzzes on every successful add (`nymHapticTap`, reactions.js:968).
      HapticFeedback.selectionClick();
      final center = _globalCenterOfContext(context);
      if (center != null) ReactionBurst.play(context, center, emoji);
    }
  }

  /// Runs the committed swipe action (`_getSwipeActionConfig(action).run`,
  /// messages.js:2031-2126). Mirrors the long-press quick-context dispatch
  /// (`buildQuickContextItems`) so swipe and menu share identical engine paths:
  /// `quote` → composer mailbox, `translate` → inline render, `copy` → clipboard
  /// + system confirm, `react` → the configured swipe emoji, `zap` → zap modal,
  /// `slap`/`hug` → the rate-limited `/me` command, `none` → no-op.
  void _dispatchSwipeAction(BuildContext context, String action) {
    final controller = ref.read(nostrControllerProvider);
    final baseNym = _baseNym(message.author);
    final fullNym = '$baseNym#${getPubkeySuffix(message.pubkey)}';
    switch (action) {
      case 'quote':
        if (message.content.isEmpty) return;
        ref
            .read(pendingComposerActionProvider.notifier)
            .requestQuote(fullNym: fullNym, content: message.content);
        return;
      case 'translate':
        if (message.content.isEmpty) return;
        setState(() => _showTranslation = true);
        return;
      case 'copy':
        if (message.content.isEmpty) return;
        Clipboard.setData(ClipboardData(text: message.content));
        ref
            .read(appStateProvider.notifier)
            .addSystemMessage('Message copied to clipboard');
        return;
      case 'react':
        _quickReact(context, settings.swipeReactEmoji);
        return;
      case 'zap':
        if (message.isOwn || message.pubkey.isEmpty) return;
        _zapMessage(context, baseNym);
        return;
      case 'slap':
        if (message.isOwn || message.pubkey.isEmpty) return;
        controller.sendCurrent(
            '/me slaps @$fullNym around a bit with a large trout 🐟');
        return;
      case 'hug':
        if (message.isOwn || message.pubkey.isEmpty) return;
        controller.sendCurrent('/me gives @$fullNym a warm hug 🫂');
        return;
      case 'none':
      default:
        return;
    }
  }

  /// Opens the zap modal for this message's author (the swipe `zap` action and a
  /// 1:1 mirror of `quick_context_items._zap`): resolves the author's lightning
  /// address from `usersProvider`, or emits a system message when none is set.
  Future<void> _zapMessage(BuildContext context, String baseNym) async {
    final lnAddr =
        ref.read(usersProvider)[message.pubkey]?.profile?.lightningAddress;
    if (lnAddr == null || lnAddr.isEmpty) {
      ref.read(appStateProvider.notifier).addSystemMessage(
          '@$baseNym cannot receive zaps (no lightning address set)');
      return;
    }
    if (!context.mounted) return;
    await ZapModal.show(
      context,
      recipientPubkey: message.pubkey,
      recipientNym: baseNym,
      lightningAddress: lnAddr,
      messageId: message.id,
      originalKind:
          inferOriginalKind(message, view: ref.read(currentViewProvider)),
    );
  }

  /// The quote-reply dispatch shared by double-tap-to-reply (desktop,
  /// `setupDoubleClickToReply`, messages.js:2280-2307) and the swipe `quote`
  /// action — sets the composer quote preview to this message.
  void _quoteReply() {
    if (message.content.isEmpty) return;
    final baseNym = _baseNym(message.author);
    final fullNym = '$baseNym#${getPubkeySuffix(message.pubkey)}';
    ref
        .read(pendingComposerActionProvider.notifier)
        .requestQuote(fullNym: fullNym, content: message.content);
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
    bool bubble = false,
  }) {
    final blur = _shouldBlurImages();
    final body = MessageContent(
      content: message.content,
      // fire/ice paint a brighter glyph in the bubble than IRC (`#ff6600`/
      // `#00ccff` vs `#ffaa00`/`#00ccee`) — `textColorFor` returns the override.
      baseColor: deco?.textColorFor(bubble: bubble) ?? color,
      fontSize: fontSize,
      blurImages: blur,
      glyphShadows: deco?.textShadows,
      monospace: deco?.monospace ?? false,
    );
    final gradient = deco?.gradient;
    if (gradient != null && gradient.length >= 2) {
      // `.message.style-aurora .message-content` clips a gradient to the text,
      // at 120deg (diagonal, lower-left → upper-right), with a blue glow behind
      // it (`text-shadow 0 0 10px rgba(91,140,255,.3)`). srcIn would clip a glyph
      // shadow away, so the glow is a separate shadow-only copy painted under it.
      final clipped = ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (rect) => LinearGradient(
          // 120deg ≈ lower-left → upper-right diagonal.
          begin: const Alignment(-0.87, 0.5),
          end: const Alignment(0.87, -0.5),
          colors: gradient,
        ).createShader(rect),
        child: MessageContent(
          content: message.content,
          baseColor: Colors.white,
          fontSize: fontSize,
          blurImages: blur,
        ),
      );
      final glow = deco?.gradientGlow;
      if (glow == null) return clipped;
      return Stack(
        children: [
          // The blue glow halo: transparent glyphs whose only paint is the
          // shadow, sitting behind the gradient-clipped text.
          MessageContent(
            content: message.content,
            baseColor: const Color(0x00000000),
            fontSize: fontSize,
            blurImages: false,
            glyphShadows: [glow],
          ),
          clipped,
        ],
      );
    }
    return body;
  }

  /// The full-width PM `.delivery-status` line below the message: right-aligned,
  /// `margin-top:2px; padding-right:4px` (styles-chat.css:665-671). Shared by the
  /// IRC and bubble layouts (both append it as a sibling after the content).
  Widget _deliveryTicks(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, right: 4),
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
        // `.delivery-status.failed { color:#f44336; cursor:pointer; font-weight:
        // bold }` (styles-chat.css:685-689); the PWA renders the `!` as a
        // clickable retry affordance (`<span … nm-pointer title="Failed to send
        // - click to retry" data-retry-event-id>`, messages.js:842) wired to
        // `manualRetryDM(message.id)` (ui-context.js:851-855). Tap drops the
        // failed bubble and re-sends a fresh copy — see [_retryFailedPm].
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _retryFailedPm,
            child: Tooltip(
              message: 'Failed to send - click to retry',
              child: Text(
                '!',
                style: TextStyle(
                  color: c.danger,
                  fontSize: 10,
                  height: 1,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        );
      case DeliveryStatus.sending:
        return const SizedBox.shrink();
    }
    return Text(
      glyph,
      style: TextStyle(color: color, fontSize: 10, height: 1),
    );
  }

  /// Manually re-sends a failed PM (PWA `manualRetryDM`, pms.js:179-196): drop
  /// the failed bubble, ensure the PM thread with the original recipient is the
  /// active view, then send a fresh copy of its content. The recipient is the
  /// message's stored peer (`conversationPubkey`, populated for own PMs at
  /// app_state.dart:2481), falling back to the active PM view's peer (the PWA's
  /// `msg.conversationPubkey || this.currentPM`).
  void _retryFailedPm() {
    final content = message.content;
    if (content.trim().isEmpty) return;
    final view = ref.read(currentViewProvider);
    final peer = message.conversationPubkey ??
        (view.kind == ViewKind.pm ? view.id : null);
    if (peer == null || peer.isEmpty) return;
    final appState = ref.read(appStateProvider.notifier);
    final controller = ref.read(nostrControllerProvider);
    // Remove the failed bubble before re-sending so the retry produces a single
    // fresh optimistic echo (mirrors the PWA splice + re-`sendPM`).
    appState.removeMessage(message.id);
    // Make the recipient's PM thread the active view, then send — `sendCurrent`
    // publishes to whatever view is current (nostr_controller.dart:2113), and
    // `startPM` opens/switches to it (nostr_controller.dart:2720).
    controller.startPM(peer);
    controller.sendCurrent(content);
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

/// A small inline action button for a system-message pill (the PWA's
/// `.spam-false-positive-btn`, messages.js:645): a primary-tinted rounded pill
/// with a subtle press-state, sized for the muted system row.
class _SystemActionButton extends StatefulWidget {
  const _SystemActionButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_SystemActionButton> createState() => _SystemActionButtonState();
}

class _SystemActionButtonState extends State<_SystemActionButton> {
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
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _pressed ? c.primaryA(0.16) : c.primaryA(0.10),
            borderRadius: const BorderRadius.all(Radius.circular(20)),
            border: Border.all(color: c.primaryA(_pressed ? 0.5 : 0.3)),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: c.primary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
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
    // `.cosmetic-redacted-message { background: rgba(255,255,255,.15) }`; light
    // mode → `rgba(0,0,0,.12)` (styles-themes-responsive.css:954), since a
    // translucent white bar is invisible on a light surface.
    final isLight = context.nym.isLight;
    return Container(
      constraints: BoxConstraints(
        minWidth: 120,
        minHeight: widget.fontSize * 1.2,
      ),
      decoration: BoxDecoration(
        color: isLight
            ? const Color(0x1F000000) // black @ 0.12
            : Colors.white.withValues(alpha: 0.15),
        borderRadius: NymRadius.rxs,
      ),
    );
  }
}

/// The `.message-scroll-flash` highlight pulse (`styles-chat.css:1285-1306`): a
/// non-interactive primary-tinted overlay (`::after`, primary@0.18 fill + 1px
/// primary@0.5 border, radius-sm) that fades in then out over the
/// `messageScrollFlash` keyframes (0→1 at 8%, hold to 45%, →0 at 100%) across
/// 1.8s. Wraps a message row and plays once each time [active] rises (the row's
/// `flashedMessageProvider` match), mirroring the class the PWA adds to a
/// jumped-to message after `_scrollToQuotedMessage`.
class _ScrollFlashOverlay extends StatefulWidget {
  const _ScrollFlashOverlay({required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  State<_ScrollFlashOverlay> createState() => _ScrollFlashOverlayState();
}

class _ScrollFlashOverlayState extends State<_ScrollFlashOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    // `animation: messageScrollFlash 1.8s ease-out forwards`.
    duration: const Duration(milliseconds: 1800),
    vsync: this,
  );

  // The `@keyframes messageScrollFlash` opacity curve: 0% → 0, 8% → 1, 45% → 1,
  // 100% → 0 (ease-out). A TweenSequence reproduces the in/hold/out timeline.
  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 0.0, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOut)),
      weight: 8,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 37), // 8% → 45%
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 0.0)
          .chain(CurveTween(curve: Curves.easeOut)),
      weight: 55, // 45% → 100%
    ),
  ]).animate(_controller);

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.forward(from: 0);
  }

  @override
  void didUpdateWidget(_ScrollFlashOverlay old) {
    super.didUpdateWidget(old);
    // Re-trigger the pulse each time the flash newly targets this row.
    if (widget.active && !old.active) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Stack(
      children: [
        widget.child,
        // `position: absolute; inset: 0; pointer-events: none; z-index: 5`.
        Positioned.fill(
          child: IgnorePointer(
            child: FadeTransition(
              opacity: _opacity,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: c.primaryA(0.18),
                  border: Border.all(color: c.primaryA(0.5)),
                  borderRadius: NymRadius.rsm,
                ),
              ),
            ),
          ),
        ),
      ],
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
    this.seedGeohash,
    this.seedChannelName,
  });

  final FileOffer offer;
  final bool isOwn;
  final P2PService service;

  /// Wire key of the channel currently open, so the inline Stop broadcasts the
  /// unseeded event with the right channel tag — `['g', geohash]` for a geohash
  /// channel via [seedGeohash], `['d', name]` for a named channel via
  /// [seedChannelName] — exactly like the PWA's `stopSeeding`, which reads
  /// `this.currentGeohash` regardless of where Stop was clicked (p2p.js:828).
  /// Both null (PM/group/no channel) → no tag. F06-B3.
  final String? seedGeohash;
  final String? seedChannelName;

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
          _StopBtn(
              onTap: () => service.stopSeeding(offer.offerId,
                  geohash: seedGeohash, channelName: seedChannelName)),
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

/// Folds a chronological (oldest-first) [messages] list into the PWA's
/// `.message-group` runs: consecutive same-author bubble messages share one
/// gliding avatar. In IRC mode ([useBubbles] false) every message is its own
/// group; system / `/me` rows always stand alone, and an author or >5min time
/// break splits a run. Mirrors [MessagesList]'s inline fold so the single-chat
/// and columns views group — and so render avatars — identically (the columns
/// view previously rendered a flat row list with no avatars at all).
List<List<MessageGroupEntry>> buildMessageGroups(
  List<Message> messages, {
  required Map<String, List<MessageReaction>> reactions,
  required bool useBubbles,
  String mentionToken = '',
}) {
  // Same predicate as messages_list `_groupsWith` (5-minute window).
  bool groupsWith(Message prev, Message cur) =>
      !prev.isSystemRow &&
      !cur.isSystemRow &&
      !prev.isMeAction &&
      !cur.isMeAction &&
      prev.pubkey == cur.pubkey &&
      (cur.createdAt - prev.createdAt).abs() <= 300;
  final groups = <List<MessageGroupEntry>>[];
  for (final m in messages) {
    final entry = MessageGroupEntry(
      message: m,
      reactions: reactions[m.id] ?? const [],
      mentioned:
          mentionToken.isNotEmpty && !m.isOwn && m.content.contains(mentionToken),
    );
    if (useBubbles &&
        groups.isNotEmpty &&
        groupsWith(groups.last.last.message, m)) {
      groups.last.add(entry);
    } else {
      groups.add([entry]);
    }
  }
  return groups;
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

/// Swipe-to-act wrapper around a message row (`setupSwipeToReply`,
/// messages.js:2129-2278). A dominantly-horizontal drag follows the finger (the
/// content slides up to 100px), reveals a directional action icon, fires a
/// threshold haptic once, and on release past the threshold runs the configured
/// action; a short swipe springs back. Also hosts double-tap-to-reply
/// (`setupDoubleClickToReply`, messages.js:2280-2307).
///
/// Mirrors the PWA constants: SWIPE_START 16px, EDGE_ZONE 50px (a right-swipe
/// starting near the left screen edge is abandoned so the drawer-open gesture
/// wins), follow cap 100px, threshold clamped 30-120. Armed only on touch
/// platforms with `gesturesEnabled` (desktop keeps right-click + double-tap; the
/// PWA likewise only attaches the touch handlers on touch devices).
class _SwipeToAct extends StatefulWidget {
  const _SwipeToAct({
    required this.settings,
    required this.onAction,
    required this.onDoubleTap,
    required this.onLongPress,
    required this.onSecondaryTap,
    required this.child,
  });

  final Settings settings;

  /// Runs the committed action string ('quote'/'translate'/'copy'/'react'/
  /// 'zap'/'slap'/'hug'/'none').
  final ValueChanged<String> onAction;
  final VoidCallback onDoubleTap;
  final VoidCallback onLongPress;
  final VoidCallback onSecondaryTap;
  final Widget child;

  @override
  State<_SwipeToAct> createState() => _SwipeToActState();
}

class _SwipeToActState extends State<_SwipeToAct>
    with SingleTickerProviderStateMixin {
  static const double _swipeStart = 16; // SWIPE_START_THRESHOLD
  static const double _edgeZone = 50; // EDGE_ZONE
  static const double _followCap = 100; // max |translateX|

  // Created in initState (NOT a lazy `late final = …`): a row that is never
  // swiped would otherwise first touch `_settle` in dispose(), lazily creating
  // a ticker during teardown and throwing. (Caught by `flutter test`.)
  late final AnimationController _settle;

  double _dx = 0;
  bool _active = false; // a horizontal-dominant drag has been claimed
  bool _abandoned = false; // started in the left edge zone (defer to drawer)
  bool _thresholdFired = false; // one-shot threshold haptic latch
  double _startX = 0; // global x where the drag began (for EDGE_ZONE)

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(
      vsync: this,
      // `transition: transform 0.25s ease-out` on release (messages.js:2253).
      duration: const Duration(milliseconds: 250),
    );
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  /// `threshold = clamp(parseInt(swipeThreshold||60), 30, 120)` (messages.js:2147).
  double get _threshold =>
      widget.settings.swipeThreshold.clamp(30, 120).toDouble();

  bool get _enabled {
    if (!widget.settings.gesturesEnabled) return false;
    final p = Theme.of(context).platform;
    return p == TargetPlatform.android || p == TargetPlatform.iOS;
  }

  void _onStart(DragStartDetails d) {
    _active = false;
    _abandoned = false;
    _thresholdFired = false;
    _startX = d.globalPosition.dx;
    _settle.stop();
    _dx = 0;
  }

  void _onUpdate(DragUpdateDetails d) {
    if (_abandoned) return;
    final next = _dx + d.delta.dx;
    // Claim the gesture once travel passes the start threshold. A RIGHT swipe
    // (next > 0) that began within EDGE_ZONE of the left edge is abandoned so
    // the sidebar-open edge-swipe wins (messages.js:2198-2201).
    if (!_active && next.abs() > _swipeStart) {
      if (next > 0 && _startX < _edgeZone) {
        _abandoned = true;
        return;
      }
      _active = true;
    }
    if (!_active) {
      _dx = next;
      return;
    }
    // Follow the finger, capped at ±100px (messages.js:2212-2219).
    final double capped = next.clamp(-_followCap, _followCap).toDouble();
    final pastNow = capped.abs() >= _threshold;
    final wasPast = _dx.abs() >= _threshold;
    if (pastNow && !_thresholdFired) {
      // One-shot threshold haptic (messages.js:2239-2241).
      HapticFeedback.selectionClick();
      _thresholdFired = true;
    }
    setState(() => _dx = capped);
    // Keep the latch honest if the user retreats back under the threshold.
    if (!pastNow && wasPast) _thresholdFired = false;
  }

  void _onEnd(DragEndDetails d) {
    final committed = _active && !_abandoned && _dx.abs() >= _threshold;
    if (committed) {
      // dx < 0 (swipe LEFT) → swipeLeftAction; dx > 0 (swipe RIGHT) → right.
      final action = _dx < 0
          ? widget.settings.swipeLeftAction
          : widget.settings.swipeRightAction;
      widget.onAction(action);
    }
    _springBack();
  }

  void _onCancel() => _springBack();

  void _springBack() {
    _active = false;
    _abandoned = false;
    _thresholdFired = false;
    final from = _dx;
    if (from == 0) {
      setState(() {});
      return;
    }
    final anim =
        CurvedAnimation(parent: _settle, curve: Curves.easeOut);
    void tick() => setState(() => _dx = from * (1 - anim.value));
    anim.addListener(tick);
    _settle.forward(from: 0).whenCompleteOrCancel(() {
      anim.removeListener(tick);
      if (mounted) setState(() => _dx = 0);
    });
  }

  /// The action that WOULD fire for the current drag direction — drives the
  /// revealed indicator icon.
  String get _pendingAction => _dx < 0
      ? widget.settings.swipeLeftAction
      : widget.settings.swipeRightAction;

  String? _actionSvg(String action) {
    switch (action) {
      case 'quote':
        return ctxActionSvg(CtxAction.quote);
      case 'translate':
        return ctxActionSvg(CtxAction.translate);
      case 'copy':
        return ctxActionSvg(CtxAction.copyMessage);
      case 'react':
        return null; // emoji glyph, rendered as text below
      case 'zap':
        return ctxActionSvg(CtxAction.zap);
      case 'slap':
        return ctxActionSvg(CtxAction.slap);
      case 'hug':
        return ctxActionSvg(CtxAction.hug);
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final gestures = GestureDetector(
      onDoubleTap: widget.onDoubleTap,
      onLongPress: widget.onLongPress,
      onSecondaryTap: widget.onSecondaryTap,
      onHorizontalDragStart: _enabled ? _onStart : null,
      onHorizontalDragUpdate: _enabled ? _onUpdate : null,
      onHorizontalDragEnd: _enabled ? _onEnd : null,
      onHorizontalDragCancel: _enabled ? _onCancel : null,
      child: Transform.translate(
        offset: Offset(_dx, 0),
        child: widget.child,
      ),
    );
    if (_dx == 0) return gestures;
    final c = context.nym;
    final action = _pendingAction;
    if (action == 'none') return gestures;
    final past = _dx.abs() >= _threshold;
    final color = past ? c.primary : c.textDim;
    final svg = _actionSvg(action);
    final indicator = action == 'react'
        ? Text(widget.settings.swipeReactEmoji,
            style: const TextStyle(fontSize: 20))
        : (svg != null
            ? NymSvgIcon(svg, size: 22, color: color)
            : const SizedBox.shrink());
    // The icon trails into view from the edge the content is leaving: a LEFT
    // swipe (dx<0) reveals it on the right; a RIGHT swipe (dx>0) on the left.
    final onRight = _dx < 0;
    return Stack(
      children: [
        // Vertically centered against the row via top:0/bottom:0 + Center.
        Positioned(
          top: 0,
          bottom: 0,
          left: onRight ? null : 12,
          right: onRight ? 12 : null,
          child: Center(
            child: AnimatedOpacity(
              opacity: past ? 1 : 0.5,
              duration: const Duration(milliseconds: 120),
              child: indicator,
            ),
          ),
        ),
        gestures,
      ],
    );
  }
}
