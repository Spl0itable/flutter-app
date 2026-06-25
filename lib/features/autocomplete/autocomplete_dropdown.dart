// The composer autocomplete dropdown (`.autocomplete-dropdown` /
// `#emojiAutocomplete` / `#channelAutocomplete` / `#kaomojiAutocomplete`). One
// widget renders whichever of the four query types is active, anchored above
// the input. Selection + keyboard nav are owned by the parent (the composer),
// which holds the selected index and splices the chosen token into the field.

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../models/user.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/context_menu/profile_badges.dart';
import '../emoji/custom_emoji.dart';
import '../shop/cosmetics.dart';
import '../shop/shop_widgets.dart';
import 'autocomplete_queries.dart';

/// Per-pubkey badge flags resolved by the host (the composer holds `ref`):
/// whether the pubkey is a verified developer/bot and/or a friend. The pure
/// query layer can't reach the controller, so these are looked up at render
/// time (mirrors autocomplete.js:406-414 `isVerifiedDeveloper`/`isVerifiedBot`/
/// `getFriendBadgeHtml`).
///
/// [verifiedTitle] is the verified badge's tooltip — `verifiedDeveloper.title`
/// ("Nymchat Developer") for a dev, "Nymchat Bot" for the bot (autocomplete.js
/// :430 `badge.title = isDev ? this.verifiedDeveloper.title : 'Nymchat Bot'`).
/// Null when [verified] is false.
typedef MentionBadges = ({bool verified, bool friend, String? verifiedTitle});

/// Which dropdown content to render + its flat selectable items.
class AutocompleteView {
  const AutocompleteView.mentions(this.mentions)
      : kind = AutocompleteKind.mention,
        channels = const [],
        emoji = const [],
        kaomojiSections = const [];
  const AutocompleteView.channels(this.channels)
      : kind = AutocompleteKind.channel,
        mentions = const [],
        emoji = const [],
        kaomojiSections = const [];
  const AutocompleteView.emoji(this.emoji)
      : kind = AutocompleteKind.emoji,
        mentions = const [],
        channels = const [],
        kaomojiSections = const [];
  const AutocompleteView.kaomoji(this.kaomojiSections)
      : kind = AutocompleteKind.kaomoji,
        mentions = const [],
        channels = const [],
        emoji = const [];

  final AutocompleteKind kind;
  final List<MentionResult> mentions;
  final List<ChannelResult> channels;
  final List<EmojiResult> emoji;
  final List<KaomojiSection> kaomojiSections;

  /// Flat list of the selectable kaomoji strings (headers are not selectable).
  List<String> get kaomojiItems =>
      [for (final s in kaomojiSections) ...s.items];

  /// Number of navigable items.
  int get itemCount {
    switch (kind) {
      case AutocompleteKind.mention:
        return mentions.length;
      case AutocompleteKind.channel:
        return channels.length;
      case AutocompleteKind.emoji:
        return emoji.length;
      case AutocompleteKind.kaomoji:
        return kaomojiItems.length;
    }
  }

  bool get isEmpty => itemCount == 0;
}

enum AutocompleteKind { mention, channel, emoji, kaomoji }

class AutocompleteDropdown extends StatelessWidget {
  const AutocompleteDropdown({
    super.key,
    required this.view,
    required this.selectedIndex,
    required this.onSelectMention,
    required this.onSelectChannel,
    required this.onSelectEmoji,
    required this.onSelectKaomoji,
    this.custom = CustomEmojiState.empty,
    this.badgesFor,
    this.cosmeticsFor,
  });

  final AutocompleteView view;
  final int selectedIndex;
  final void Function(MentionResult) onSelectMention;
  final void Function(ChannelResult) onSelectChannel;
  final void Function(EmojiResult) onSelectEmoji;
  final void Function(String kaomoji) onSelectKaomoji;
  final CustomEmojiState custom;

  /// Resolves the verified/friend badge flags for a mention-row pubkey. When
  /// null (e.g. tests), rows render avatar + name without badges.
  final MentionBadges Function(String pubkey)? badgesFor;

  /// Resolves the active shop flair/supporter cosmetics for a mention-row pubkey
  /// (`getFlairForUser`, autocomplete.js:405). The pure query layer can't reach
  /// the shop/user state, so the host (composer, holds `ref`) supplies it. When
  /// null (e.g. tests) the flair glyph is omitted.
  final UserCosmetics Function(String pubkey)? cosmeticsFor;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // The kaomoji palette (`.command-palette.kaomoji-autocomplete`) is taller and
    // padded (max-height 200, padding 6); the mention/channel/emoji dropdowns are
    // max-height 150 with no padding (styles-components.css:849-863).
    final isKaomoji = view.kind == AutocompleteKind.kaomoji;
    return Container(
      constraints: BoxConstraints(maxHeight: isKaomoji ? 200 : 150),
      margin: const EdgeInsets.only(bottom: 8),
      padding: isKaomoji ? const EdgeInsets.all(6) : null,
      decoration: BoxDecoration(
        // `.autocomplete-dropdown`: bg-tertiary, glass border, top-rounded.
        color: c.bgTertiary,
        border: Border.all(color: c.glassBorder),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        // `--shadow-lg`: 0 8px 32px rgba(0,0,0,0.5).
        boxShadow: const [
          BoxShadow(color: Color(0x80000000), blurRadius: 32, offset: Offset(0, 8)),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _rows(c),
        ),
      ),
    );
  }

  List<Widget> _rows(NymColors c) {
    switch (view.kind) {
      case AutocompleteKind.mention:
        return [
          for (var i = 0; i < view.mentions.length; i++)
            _mentionRow(c, view.mentions[i], i == selectedIndex),
        ];
      case AutocompleteKind.channel:
        return [
          for (var i = 0; i < view.channels.length; i++)
            _channelRow(c, view.channels[i], i == selectedIndex),
        ];
      case AutocompleteKind.emoji:
        return [
          for (var i = 0; i < view.emoji.length; i++)
            _emojiRow(c, view.emoji[i], i == selectedIndex),
        ];
      case AutocompleteKind.kaomoji:
        var idx = -1;
        final widgets = <Widget>[];
        for (final section in view.kaomojiSections) {
          widgets.add(_header(c, section.label));
          for (final k in section.items) {
            idx++;
            widgets.add(_kaomojiRow(c, k, idx == selectedIndex));
          }
        }
        return widgets;
    }
  }

  Widget _selectable(NymColors c,
      {required bool selected, required VoidCallback onTap, required Widget child}) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            // `.autocomplete-item.selected` highlight (white@0.08 dark;
            // mode-aware so the selected row stays visible in light mode).
            color: selected ? c.hoverOverlay : null,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: child,
        ),
      ),
    );
  }

  /// 18×18 avatar with the status dot overlaid bottom-right
  /// (`.user-avatar-wrap` + `.user-status-dot`, styles-components.css:745-750).
  /// When the user is `hidden` the PWA marks the wrap `.no-status` (no dot).
  Widget _mentionAvatar(NymColors c, MentionResult m) {
    final hidden = m.status == UserStatus.hidden;
    return SizedBox(
      width: 18,
      height: 18,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          NymAvatar(seed: m.pubkey, size: 18, imageUrl: m.avatarUrl, label: m.baseNym.isNotEmpty ? m.baseNym[0] : null),
          if (!hidden)
            Positioned(
              right: -1,
              bottom: -1,
              // `.user-status-dot`: 8×8, `border: 2px solid #0a0a0f` (=--bg)
              // (styles-features.css:2346-2369).
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: statusColor(m.status),
                  shape: BoxShape.circle,
                  border: Border.all(color: c.bg, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _mentionRow(NymColors c, MentionResult m, bool selected) {
    final badges = badgesFor?.call(m.pubkey);
    final cosmetics = cosmeticsFor?.call(m.pubkey);
    // FLAIR ONLY. The dropdown row's `<strong>` is built from flair
    // (`getFlairForUser`) + verified + friend — it NEVER reads
    // `getUserShopItems().supporter` (autocomplete.js:404-438). The supporter
    // pill appears only on other surfaces (context menu / PM rows). Rendering it
    // here is the `.std-badge`-class over-render; emit the flair glyph only.
    final flairId = cosmetics?.flairId;
    final hasFlair = flairId != null && flairId.isNotEmpty;
    return _selectable(
      c,
      selected: selected,
      onTap: () => onSelectMention(m),
      child: Row(
        children: [
          _mentionAvatar(c, m),
          const SizedBox(width: 4),
          Flexible(
            child: RichText(
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                style: TextStyle(color: c.primary, fontWeight: FontWeight.bold),
                children: [
                  TextSpan(text: '@${m.baseNym}'),
                  TextSpan(
                    text: '#${m.suffix}',
                    style: TextStyle(
                      color: c.primary.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w100,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Shop flair glyph after the nym (before verified), matching the PWA's
          // `getFlairForUser` insertion (autocomplete.js:407). `.flair-badge` is
          // 20px (styles-features.css:316). No supporter pill here.
          if (hasFlair) ...[
            const SizedBox(width: 4),
            FlairBadge(
              flairId: flairId,
              edition: cosmetics?.genesisEdition,
              size: 20,
            ),
          ],
          // `.verified-badge` / `.friend-badge svg` are 20×20 in this dropdown.
          // The badge title distinguishes dev ("Nymchat Developer") from bot
          // ("Nymchat Bot") — autocomplete.js:430.
          if (badges != null && badges.verified) ...[
            const SizedBox(width: 4),
            VerifiedBadge(size: 20, tooltip: badges.verifiedTitle),
          ],
          if (badges != null && badges.friend) ...[
            const SizedBox(width: 2),
            const FriendBadge(size: 20),
          ],
        ],
      ),
    );
  }

  Widget _channelRow(NymColors c, ChannelResult ch, bool selected) {
    return _selectable(
      c,
      selected: selected,
      onTap: () => onSelectChannel(ch),
      // Flat `.channel-ac-item` row (gap 8). The name + location + count are all
      // tight `Expanded` (weighted) so they ellipsize within their share and the
      // row can never overflow at a tight width; the count is right-aligned so it
      // hugs the right edge (`.channel-ac-count { margin-left:auto }`). The badge
      // is the only fixed child.
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text('#${ch.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style:
                    TextStyle(color: c.primary, fontWeight: FontWeight.bold)),
          ),
          if (ch.isCurrent) ...[
            // `.channel-ac-badge`: margin-left 4px.
            const SizedBox(width: 4),
            // `.channel-ac-badge`: 0.7em, primary bg, bg text, radius-xs.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: c.primary,
                borderRadius: const BorderRadius.all(Radius.circular(8)),
              ),
              child: Text('current',
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  softWrap: false,
                  style: TextStyle(color: c.bg, fontSize: 10)),
            ),
          ],
          // `.channel-ac-location`: 0.8em, opacity 0.5 — decoded place.
          if (ch.location.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: Text(
                ch.location,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: TextStyle(
                  color: c.textDim.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              ),
            ),
          ],
          // `.channel-ac-count { margin-left:auto }` — right-aligned in its share.
          if (ch.messageCount > 0) ...[
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: Text(
                '${ch.messageCount} msg${ch.messageCount != 1 ? 's' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                softWrap: false,
                style: TextStyle(
                  color: c.textDim.withValues(alpha: 0.4),
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _emojiRow(NymColors c, EmojiResult e, bool selected) {
    final glyph = e.isCustom
        ? Image.network(
            proxiedEmojiUrl(e.customUrl!, null),
            width: 23,
            height: 23,
            errorBuilder: (_, __, ___) => const SizedBox(width: 23, height: 23),
          )
        : Text(e.emoji, style: const TextStyle(fontSize: 23));
    // `name` may already be a `:shortcode:` token (custom-emoji recents) — strip
    // wrapping colons so the label isn't shown as `::shortcode::`. Mirrors the
    // PWA's defensive strip at render time (autocomplete.js:129-131,
    // `name.replace(/^:+|:+$/g, '')`).
    final label = e.name.replaceAll(RegExp(r'^:+|:+$'), '');
    return _selectable(
      c,
      selected: selected,
      onTap: () => onSelectEmoji(e),
      child: Row(
        children: [
          SizedBox(width: 23, height: 23, child: Center(child: glyph)),
          const SizedBox(width: 10),
          Flexible(
            // `.emoji-item` is dim; `.selected/:hover` brightens to `--text`
            // (styles-components.css:760-802).
            child: Text(':$label:',
                style: TextStyle(
                    color: selected ? c.text : c.textDim, fontSize: 12),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _kaomojiRow(NymColors c, String k, bool selected) {
    return _selectable(
      c,
      selected: selected,
      onTap: () => onSelectKaomoji(k),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(k, style: TextStyle(color: c.text, fontSize: 14)),
      ),
    );
  }

  Widget _header(NymColors c, String label) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: c.textDim,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      );
}
