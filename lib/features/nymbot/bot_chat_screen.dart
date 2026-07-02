import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/chat/message_row.dart' show MessageGroup, MessageGroupEntry;
import '../../widgets/chat/typing_indicator.dart';
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/context_menu/context_menu_actions.dart';
import '../../widgets/context_menu/context_menu_panel.dart';
import '../../widgets/context_menu/interaction_hooks.dart';
import '../../widgets/context_menu/profile_badges.dart' show VerifiedBadge;
import '../../widgets/nym_icons.dart';
import '../emoji/emoji_data.dart';
import '../emoji/emoji_picker.dart';
import '../emoji/gif_picker.dart';
import '../reactions/reaction_picker.dart';
import 'bot_credits_modal.dart';
import 'nymbot_models.dart';
import 'nymbot_providers.dart';

/// The private 1:1 Nymbot chat screen.
///
/// The conversation itself is the CANONICAL PM thread
/// (`AppState.messages['pm-<botPubkey>']`, fed by [BotChatController]), rendered
/// through the same [MessageGroup]/`MessageRow` pipeline as every other PM —
/// IRC/bubble layout setting, 5-minute grouping, sticky group avatar, author
/// headers (incl. self), delivery ticks, crypto locks, reactions, context menu,
/// swipe/double-tap quote-reply, the shared typing-indicator strip and the
/// scroll-to-bottom button. Exactly how the PWA routes the bot PM through
/// `displayMessage()` (pms.js:1291-1339).
///
/// Premium features kept on top of the canonical chat (intentional additions):
///   * the Standard / Pro tier switch + `?model` picker sheet,
///   * `?balance` / `?buy` (shared credits modal),
///   * the `?git` connect modal (typed `?git …` subcommands run in-chat).
class BotChatScreen extends ConsumerStatefulWidget {
  const BotChatScreen({super.key});

  @override
  ConsumerState<BotChatScreen> createState() => _BotChatScreenState();
}

class _BotChatScreenState extends ConsumerState<BotChatScreen> {
  final _scroll = ScrollController();

  /// Whether the floating scroll-to-bottom chevron shows (the PWA's
  /// `distanceFromBottom > 150` gate, app.js:7120-7124). In the reversed list
  /// `offset` IS the distance from the bottom.
  bool _showScrollButton = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScrolled);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Bind the paid surface to the live identity, make the bot PM the active
      // view (receipts / read-marking / typing all key off it, like openPM),
      // then render the empty-thread intro + refresh credits.
      ref.read(nostrControllerProvider).bindBotChat();
      ref
          .read(appStateProvider.notifier)
          .switchView(const ChatView.pm(kNymbotPubkey));
      final engine = ref.read(botChatControllerProvider.notifier);
      engine.ensureIntro();
      engine.refreshBalance();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScrolled() {
    final show = _scroll.hasClients && _scroll.offset > 150;
    if (show != _showScrollButton) {
      setState(() => _showScrollButton = show);
    }
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0,
        duration: NymMotion.transition, curve: NymMotion.curve);
  }

  NymColors _colors(BuildContext context) =>
      Theme.of(context).extension<NymColors>() ?? _fallbackColors;

  @override
  Widget build(BuildContext context) {
    final c = _colors(context);
    final state = ref.watch(botChatControllerProvider);

    // `?buy` / out-of-credits → open the shared credits modal with the right
    // tier preselected (PWA `showBotCreditsModal(null, tier)`).
    ref.listen<BotBuyRequest?>(botBuyRequestProvider, (prev, next) {
      if (next == null) return;
      ref.read(botBuyRequestProvider.notifier).consume();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        BotCreditsModal.show(
          context,
          colors: _colors(context),
          initialTier: next.tier,
        );
      });
    });
    // NOTE: gift requests (`?gift` / context-menu "Gift Nymbot Credits") are
    // handled by the always-mounted listener in home_shell.dart — no second
    // listener here, or the modal would open twice.

    return Scaffold(
      backgroundColor: c.bg,
      appBar: _header(context, c, state),
      body: Column(
        children: [
          _TierSwitch(
            isPro: state.isPro,
            proLabel: state.proModel?.label,
            colors: c,
            onTapStandard: () => ref
                .read(botChatControllerProvider.notifier)
                .setModelDirect(null),
            onTapPro: () => _showModelPicker(context),
          ),
          Expanded(child: _buildMessagesArea(c)),
          // The shared `.typing-indicator` strip pinned above the composer —
          // "Nymbot is thinking" with the 18px avatar + bouncing dots
          // (pms.js `_setBotTyping` → `_renderTypingInto`).
          const TypingIndicatorRow(
              storageKey: 'pm-$kNymbotPubkey'),
          _BotComposer(
            colors: c,
            onSubmit: (content) {
              ref
                  .read(botChatControllerProvider.notifier)
                  .sendUserBotPM(content);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _scrollToBottom();
              });
            },
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Header (`_renderPMHeader`, pms.js:2905-2941)
  // ---------------------------------------------------------------------------

  PreferredSizeWidget _header(
      BuildContext context, NymColors c, BotChatState state) {
    final botUser = ref.watch(usersProvider)[kNymbotPubkey];
    return AppBar(
      backgroundColor: c.bgSecondary,
      foregroundColor: c.textBright,
      titleSpacing: 0,
      toolbarHeight: 68,
      title: Row(
        children: [
          // `.pm-header-avatar`: 26px avatar with a 7px status dot — the bot is
          // always online (pms.js `getEffectiveUserStatus` bot override).
          SizedBox(
            width: 30,
            height: 30,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                NymAvatar(
                  seed: kNymbotPubkey,
                  size: 26,
                  imageUrl: botUser?.profile?.picture,
                ),
                Positioned(
                  // `.pm-header-avatar .user-status-dot`: 7px, bottom/right -2.
                  right: 2,
                  bottom: 2,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      // `.status-online` #22c55e ringed by 2px --bg.
                      color: const Color(0xFF22C55E),
                      shape: BoxShape.circle,
                      border: Border.all(color: c.bg, width: 2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // `.pm-header-row` is `header-clickable`: tapping the name opens
                // the bot's profile context menu (pms.js:2929-2932).
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _openHeaderMenu(context),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text.rich(
                          TextSpan(children: [
                            const TextSpan(text: 'Nymbot'),
                            TextSpan(
                              text: '#${getPubkeySuffix(kNymbotPubkey)}',
                              // `.nym-suffix`: opacity 0.7 / 0.9em / weight 100.
                              style: TextStyle(
                                color: c.textBright.withValues(alpha: 0.7),
                                fontSize: 16 * 0.9,
                                fontWeight: FontWeight.w100,
                              ),
                            ),
                          ]),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: c.textBright,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2),
                        ),
                      ),
                      const SizedBox(width: 4),
                      const VerifiedBadge(size: 16),
                    ],
                  ),
                ),
                // `.pm-last-seen` presence line — the bot's is the fixed
                // 'Always at your service' (pms.js:37).
                Text(
                  'Always at your service',
                  style: TextStyle(color: c.textDim, fontSize: 12, height: 1.2),
                  overflow: TextOverflow.ellipsis,
                ),
                // `#channelMeta` for the bot PM: 12px lock +
                // 'E2E encrypted · <botCreditMeta>' (pms.js:2934-2938).
                Row(
                  children: [
                    NymSvgIcon(NymIcons.lock, size: 12, color: c.textDim),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'E2E encrypted · ${_botCreditMeta(state)}',
                        style: TextStyle(
                            color: c.textDim, fontSize: 11, height: 1.2),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Balance',
          icon: Icon(Icons.account_balance_wallet_outlined, color: c.text),
          onPressed: () => _showBalance(context),
        ),
        IconButton(
          tooltip: 'Connect git repo',
          icon: Icon(Icons.source_outlined,
              color: (state.git?.hasRepo ?? false) ? c.primary : c.text),
          onPressed: () => _showGitConnect(context),
        ),
      ],
    );
  }

  /// The `#botCreditMeta` text (`_renderBotCreditMeta`, pms.js:2361-2380):
  /// Pro pinned → `'<n> Pro credit(s) · <model> [· <repoName>]'`; otherwise the
  /// standard count (`'<n> credit(s) left'`, or both pools when Pro credits
  /// exist). 'checking credits…' until the first balance lands.
  String _botCreditMeta(BotChatState state) {
    final proModel = state.proModel;
    if (proModel != null) {
      final pro = state.balance.proBalance;
      final proText = state.balanceKnown ? '$pro' : '…';
      var meta = '$proText Pro credit${pro == 1 ? '' : 's'} · ${proModel.label}';
      final git = state.git;
      if (git != null && git.hasRepo) {
        meta += ' · ${git.repo.split('/').last}';
      }
      return meta;
    }
    if (!state.balanceKnown) {
      // A failed check with no cached count settles on 'credits unavailable'
      // (`_refreshBotCreditMeta`, pms.js:2382-2389).
      return state.balanceUnavailable ? 'credits unavailable' : 'checking credits…';
    }
    final std = state.balance.balance;
    final pro = state.balance.proBalance;
    return pro > 0
        ? '$std standard · $pro Pro credits left'
        : '$std credit${std == 1 ? '' : 's'} left';
  }

  /// Header name tap → the bot's profile context menu (the PWA's
  /// `showContextMenu(e, nym, pubkey, null, null, true)` — profile mode).
  void _openHeaderMenu(BuildContext context) {
    ContextMenuPanel.show(
      context,
      target: const CtxTarget(
        pubkey: kNymbotPubkey,
        nym: 'Nymbot',
        isSelf: false,
        isBot: true,
        profileOnly: true,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Message list — the canonical `.messages-container` pipeline
  // ---------------------------------------------------------------------------

  static const int _groupWindowSec = 300; // 5 min (messages.js:1557)

  Widget _buildMessagesArea(NymColors c) {
    final app = ref.watch(appStateProvider);
    final settings = ref.watch(settingsProvider);
    final reactions = ref.watch(reactionsProvider);
    final msgs =
        app.messages[BotChatController.conversationKey] ?? const <Message>[];

    // `.messages-container` bg: black@0.15 dark / white@0.3 light.
    final containerColor = c.isLight
        ? const Color(0x4DFFFFFF) // white @ 0.3
        : const Color(0x26000000); // black @ 0.15

    final mentionToken = '@${stripPubkeySuffix(app.selfNym)}';

    // Fold consecutive same-author bubble messages into render groups (the
    // PWA's `.message-group`, 5-minute window) so the group's single avatar can
    // glide over the run — identical fold to `messages_list.dart`.
    final units = <List<MessageGroupEntry>>[];
    for (final m in msgs) {
      final entry = MessageGroupEntry(
        message: m,
        reactions: reactions[m.id] ?? const [],
        mentioned: !m.isOwn && m.content.contains(mentionToken),
      );
      if (settings.useBubbles &&
          units.isNotEmpty &&
          _groupsWith(units.last.last.message, m)) {
        units.last.add(entry);
      } else {
        units.add([entry]);
      }
    }

    return ColoredBox(
      color: containerColor,
      child: Stack(
        children: [
          Positioned.fill(
            child: ListView.builder(
              controller: _scroll,
              reverse: true,
              // Scroller padding (`styles-shell.css:941`).
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              itemCount: units.length,
              itemBuilder: (context, revIndex) {
                final unit = units[units.length - 1 - revIndex];
                final group = MessageGroup(
                  entries: unit,
                  settings: settings,
                  onReactionPicker: (msg) =>
                      showReactionPicker(context, ref, msg),
                );
                final lead = unit.first.message;
                // Bot replies whose model exposed its chain of thought carry
                // the collapsed "💭 Reasoning" section (`.bot-think`,
                // messages.js:796-797 prepends it into the bubble). The
                // canonical MessageRow doesn't render `Message.thinking` yet
                // (see handoffs), so the section is drawn directly above the
                // reply bubble, aligned with the group's stack column.
                if (lead.isBot &&
                    (lead.thinking?.trim().isNotEmpty ?? false)) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: settings.useBubbles
                            // group padding 6 + 32 avatar + 6 gap = 44.
                            ? const EdgeInsets.fromLTRB(44, 6, 14, 0)
                            : const EdgeInsets.fromLTRB(14, 6, 14, 0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.of(context).size.width * 0.85,
                            ),
                            child: _BotThinkSection(
                              reasoning: lead.thinking!,
                              colors: c,
                              // `.bot-think { font-size: 0.88em }` of the user
                              // text size.
                              fontSize: settings.textSize.toDouble() * 0.88,
                            ),
                          ),
                        ),
                      ),
                      group,
                    ],
                  );
                }
                return group;
              },
            ),
          ),
          // `.scroll-to-bottom-btn` — shown >150px from the bottom.
          if (_showScrollButton)
            Positioned(
              right: 24,
              bottom: 16,
              child: _ScrollToBottomButton(onTap: _scrollToBottom),
            ),
        ],
      ),
    );
  }

  /// Whether [cur] bubble-groups onto [prev]: same author within the 5-minute
  /// window, neither a system pill nor a `/me` action (messages.js:1679-1706).
  /// A reasoning-bearing bot reply starts its own group so its `.bot-think`
  /// section can render above the bubble.
  bool _groupsWith(Message prev, Message cur) =>
      !prev.isSystemRow &&
      !cur.isSystemRow &&
      !prev.isMeAction &&
      !cur.isMeAction &&
      (cur.thinking == null || cur.thinking!.trim().isEmpty) &&
      prev.pubkey == cur.pubkey &&
      (cur.createdAt - prev.createdAt).abs() <= _groupWindowSec;

  // ---------------------------------------------------------------------------
  // Modals (premium surfaces kept on top of the canonical chat)
  // ---------------------------------------------------------------------------

  void _showBalance(BuildContext context) {
    final c = _colors(context);
    final b = ref.read(botChatControllerProvider).balance;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.bgSecondary,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Credit balance',
                style: TextStyle(
                    color: c.textBright,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            _balanceRow('Standard', b.balance, '10 sats each', c),
            const SizedBox(height: 8),
            _balanceRow('Pro', b.proBalance, '100 sats each', c,
                accent: c.primary),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  _showBuy(context);
                },
                child: const Text('Buy credits'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _balanceRow(String label, int value, String hint, NymColors c,
      {Color? accent}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
                color: accent ?? c.blue, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        color: c.textBright, fontWeight: FontWeight.w600)),
                Text(hint, style: TextStyle(color: c.textDim, fontSize: 11)),
              ],
            ),
          ),
          Text('$value',
              style: TextStyle(
                  color: c.textBright,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: 4),
          Text('cr', style: TextStyle(color: c.textDim, fontSize: 11)),
        ],
      ),
    );
  }

  void _showBuy(BuildContext context) {
    // Buy mode of the shared credits modal (PWA: same modal as gift, no
    // recipient). Pro tier preselected when a Pro model is pinned.
    final state = ref.read(botChatControllerProvider);
    BotCreditsModal.show(
      context,
      colors: _colors(context),
      initialTier: state.isPro ? CreditTier.pro : CreditTier.standard,
    );
  }

  void _showModelPicker(BuildContext context) {
    final c = _colors(context);
    final current = ref.read(botChatControllerProvider).proModel;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.bgSecondary,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Text('Pro model',
                      style: TextStyle(
                          color: c.textBright,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('100 sats / credit',
                      style: TextStyle(color: c.textDim, fontSize: 11)),
                ],
              ),
            ),
            ListTile(
              leading: Icon(Icons.auto_awesome, color: c.blue),
              title: Text('Standard (auto-routed)',
                  style: TextStyle(color: c.text)),
              subtitle: Text('Best model per task · 10 sats each',
                  style: TextStyle(color: c.textDim, fontSize: 11)),
              trailing: current == null
                  ? Icon(Icons.check, color: c.primary)
                  : null,
              onTap: () {
                ref.read(botChatControllerProvider.notifier).setModelDirect(null);
                Navigator.pop(context);
              },
            ),
            Divider(height: 1, color: c.border),
            for (final m in kProModels)
              ListTile(
                leading: Icon(Icons.bolt, color: c.primary),
                title: Text(m.label, style: TextStyle(color: c.text)),
                // PWA `?model` list: the human price-range phrase, not the id.
                subtitle: Text(
                    m.priceLabel,
                    style: TextStyle(color: c.textDim, fontSize: 11)),
                trailing: current?.key == m.key
                    ? Icon(Icons.check, color: c.primary)
                    : null,
                onTap: () {
                  ref
                      .read(botChatControllerProvider.notifier)
                      .setModelDirect(m);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showGitConnect(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _colors(context).bgSecondary,
      builder: (_) => _GitConnectModal(
        colors: _colors(context),
        existing: ref.read(botChatControllerProvider).git,
        onConnect: (cfg) =>
            ref.read(botChatControllerProvider.notifier).connectGit(cfg),
        onDisconnect: () =>
            ref.read(botChatControllerProvider.notifier).disconnectGit(),
      ),
    );
  }
}

// =============================================================================
// `.scroll-to-bottom-btn` (styles-chat.css:9-43): 40×40 round glass FAB with a
// primary down-chevron, hover glow + scale 1.1; light mode flips the rest fill
// to white@0.85 / border primary@0.2 (styles-themes-responsive.css:607-615).
// =============================================================================

class _ScrollToBottomButton extends StatefulWidget {
  const _ScrollToBottomButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_ScrollToBottomButton> createState() => _ScrollToBottomButtonState();
}

class _ScrollToBottomButtonState extends State<_ScrollToBottomButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final light = c.isLight;
    final fill = _hover
        ? c.primaryA(0.15)
        : (light ? const Color(0xD9FFFFFF) /* white @ 0.85 */ : c.glassBg);
    final border = _hover
        ? c.primaryA(0.30)
        : (light ? c.primaryA(0.20) : c.glassBorder);
    final shadow = light
        ? const BoxShadow(
            color: Color(0x26000000), // black @ 0.15
            offset: Offset(0, 2),
            blurRadius: 12,
          )
        : const BoxShadow(
            color: Color(0x66000000), // black @ 0.4
            offset: Offset(0, 4),
            blurRadius: 16,
          );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.1 : 1.0,
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fill,
              shape: BoxShape.circle,
              border: Border.all(color: border),
              boxShadow: [shadow],
            ),
            child: NymSvgIcon(NymIcons.chevronDown, size: 20, color: c.primary),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Tier switch (Standard / Pro) — intentional premium addition
// =============================================================================

class _TierSwitch extends StatelessWidget {
  const _TierSwitch({
    required this.isPro,
    required this.proLabel,
    required this.colors,
    required this.onTapStandard,
    required this.onTapPro,
  });

  final bool isPro;
  final String? proLabel;
  final NymColors colors;
  final VoidCallback onTapStandard;
  final VoidCallback onTapPro;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          // PWA `.bot-credit-tier-btn.active`: both segments use the lightning
          // accent (orange) — fill @0.12, border @0.5, text --lightning bold.
          _segment('Standard', !isPro, onTapStandard, c),
          _segment(
            isPro && proLabel != null ? 'Pro · $proLabel' : 'Pro',
            isPro,
            onTapPro,
            c,
          ),
        ],
      ),
    );
  }

  Widget _segment(String label, bool active, VoidCallback onTap, NymColors c) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active
                ? c.lightning.withValues(alpha: 0.12)
                // Inactive fill: white@0.04 dark / black@0.04 light. `insetFill`
                // is mode-aware so the pill stays visible in light mode.
                : c.insetFill,
            // `.bot-credit-tier-btn`: radius --radius-sm (12).
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? c.lightning.withValues(alpha: 0.5) : c.border,
              width: 1,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: active ? c.lightning : c.textDim,
              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// `.bot-think` — the collapsed "💭 Reasoning" section (styles-chat.css:1193-1237)
// =============================================================================

/// The collapsible reasoning block: secondary@0.08 fill, 1px glass border with a
/// 3px primary@0.45 left accent, radius-xs (8); the summary row (5px 10px,
/// text-dim, rotating ▸) grows a 1px glass-border divider while open; the body
/// is italic dim at 1.5 line-height, capped at 320px with its own scroll. The
/// whole block renders at 0.88em of the user text size.
class _BotThinkSection extends StatefulWidget {
  const _BotThinkSection({
    required this.reasoning,
    required this.colors,
    required this.fontSize,
  });

  final String reasoning;
  final NymColors colors;

  /// 0.88 × the user text-size setting (`.bot-think { font-size: 0.88em }`).
  final double fontSize;

  @override
  State<_BotThinkSection> createState() => _BotThinkSectionState();
}

class _BotThinkSectionState extends State<_BotThinkSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final fs = widget.fontSize;
    final side = BorderSide(color: c.glassBorder);
    return Container(
      // `.bot-think { margin: 2px 0 8px }`.
      margin: const EdgeInsets.only(top: 2, bottom: 8),
      decoration: BoxDecoration(
        color: c.secondary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          top: side,
          right: side,
          bottom: side,
          left: BorderSide(color: c.primary.withValues(alpha: 0.45), width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Container(
              // `[open] summary { border-bottom: 1px solid var(--glass-border) }`.
              decoration: _expanded
                  ? BoxDecoration(border: Border(bottom: side))
                  : null,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // `summary::before` ▸ marker (rotates 90° when open;
                  // `--transition`: 0.25s cubic-bezier(0.4,0,0.2,1)).
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.fastOutSlowIn,
                    turns: _expanded ? 0.25 : 0,
                    child: Text('▸',
                        style: TextStyle(color: c.textDim, fontSize: fs)),
                  ),
                  const SizedBox(width: 6),
                  // `.bot-think summary` has no font-weight (normal/w400).
                  Text('💭 Reasoning',
                      style: TextStyle(
                          color: c.textDim,
                          fontSize: fs,
                          fontWeight: FontWeight.w400)),
                ],
              ),
            ),
          ),
          if (_expanded)
            // `.bot-think-body`: italic dim, capped at 320px with its own scroll.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Text(
                  widget.reasoning,
                  style: TextStyle(
                      color: c.textDim,
                      fontSize: fs,
                      height: 1.5,
                      fontStyle: FontStyle.italic),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// Composer — the PWA `.input-container` chrome (styles-chat.css:1384-1965)
// =============================================================================

class _BotComposer extends ConsumerStatefulWidget {
  const _BotComposer({
    required this.colors,
    required this.onSubmit,
  });

  final NymColors colors;

  /// Receives the composed outgoing content (quote prefix already applied).
  final ValueChanged<String> onSubmit;

  @override
  ConsumerState<_BotComposer> createState() => _BotComposerState();
}

class _BotComposerState extends ConsumerState<_BotComposer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  /// The currently-filtered `?…` suggestions (empty → palette hidden).
  List<BotPMCommand> _suggestions = const [];

  /// Highlighted palette row — reset to the first row on every input change,
  /// like `showBotCommandPalette` (`commandPaletteIndex = 0`, commands.js:464).
  int _paletteIndex = 0;

  /// Escape hides the palette until the input text changes again
  /// (`hideCommandPalette`; the next input event re-shows it,
  /// ui-context.js:1003-1005).
  bool _suppressPalette = false;

  /// Last seen input text, so selection-only controller notifications don't
  /// count as input events (the PWA palette reacts to `input` only).
  String _lastText = '';

  /// Deferred quote-reply chip (`setQuoteReply`): author + stripped text; the
  /// quote is prepended to the outgoing content only at send.
  ({String author, String text})? _pendingQuote;

  // Emoji / GIF picker popovers, anchored above their toolbar buttons like the
  // PWA's inline `bottom:100%` popups.
  final _emojiPortal = OverlayPortalController();
  final _gifPortal = OverlayPortalController();
  final _emojiAnchor = LayerLink();
  final _gifAnchor = LayerLink();
  SharedPreferences? _prefs;
  List<String> _recents = const [];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<SharedPreferences> _ensurePrefs() async =>
      _prefs ??= await SharedPreferences.getInstance();

  void _onTextChanged() {
    final text = _controller.text;
    final textChanged = text != _lastText;
    _lastText = text;
    final next = text.startsWith('?')
        ? filterBotPMCommands(text)
        : const <BotPMCommand>[];
    if (textChanged) {
      // Every input event re-shows the palette (after an Escape) and
      // re-highlights the first row (showBotCommandPalette).
      _suppressPalette = false;
      _paletteIndex = 0;
    }
    if (!_sameCommands(next, _suggestions)) {
      setState(() => _suggestions = next);
    } else {
      // Rebuild for the SEND-affordance / translate-style hooks keyed on text.
      setState(() {});
    }
  }

  /// Cheap equality on the (small) suggestion lists, by command name+order.
  bool _sameCommands(List<BotPMCommand> a, List<BotPMCommand> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].name != b[i].name) return false;
    }
    return true;
  }

  void _pick(BotPMCommand cmd) {
    final text = '${cmd.name} ';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    // Re-filter so a multi-step command (e.g. `?git `) immediately surfaces its
    // subcommands; a leaf command just hides the palette.
    _onTextChanged();
    _focus.requestFocus();
  }

  // --- Quote-reply chip (mention/quote mailbox from swipe / menu / dbl-tap) ---

  void _applyComposerAction(ComposerAction action) {
    switch (action) {
      case MentionAction(:final fullNym):
        final existing = _controller.text;
        final needsSpace = existing.isNotEmpty && !existing.endsWith(' ');
        _controller.text = '$existing${needsSpace ? ' ' : ''}@$fullNym ';
        _controller.selection =
            TextSelection.collapsed(offset: _controller.text.length);
      case QuoteAction(:final fullNym, :final content):
        _pendingQuote = (author: fullNym, text: _strippedQuoteText(content));
    }
    _focus.requestFocus();
    setState(() {});
  }

  /// Strips nested `>` quote lines (keep only the top level), collapses blank
  /// runs, and trims — the `setQuoteReply` pre-processing (messages.js:1817).
  static String _strippedQuoteText(String text) {
    final kept = <String>[];
    for (final line in text.split('\n')) {
      if (!line.startsWith('>')) kept.add(line);
    }
    return kept
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// The chip's cleaned preview text: strip HTML/markdown punctuation, cap 120
  /// (`cleanText` in setQuoteReply, messages.js:1845-1846).
  static String _quotePreviewText(String text) {
    final clean = text
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'[*_~`>#]'), '');
    return clean.length > 120 ? '${clean.substring(0, 120)}...' : clean;
  }

  void _clearQuote() {
    if (_pendingQuote == null) return;
    setState(() => _pendingQuote = null);
  }

  /// Prepends the pending quote to [typed] ONLY at send (messages.js:2354-2361).
  String _composeOutgoing(String typed) {
    var content = typed;
    final quote = _pendingQuote;
    if (quote != null) {
      final lines = quote.text.split('\n');
      final quoteRest = lines.length > 1
          ? '\n${lines.skip(1).map((l) => '> $l').join('\n')}'
          : '';
      final quoteLine = '> @${quote.author}: ${lines.first}$quoteRest';
      content = content.isNotEmpty ? '$quoteLine\n\n$content' : quoteLine;
      _pendingQuote = null;
    }
    return content;
  }

  void _send() {
    final typed = _controller.text.trim();
    // The PWA allows sending a bare quote: `if (!content && !pendingQuote)`.
    if (typed.isEmpty && _pendingQuote == null) return;
    final content = _composeOutgoing(typed);
    widget.onSubmit(content);
    _controller.clear();
    setState(() {});
    _focus.requestFocus();
  }

  /// With the `?` palette open: ↑/↓ move the highlight (wrapping), Enter/Tab
  /// pick the highlighted command, Escape hides the palette until the input
  /// changes (ui-context.js:992-1005 → navigateCommandPalette/selectCommand).
  /// Otherwise hardware Enter sends; Shift+Enter inserts a newline
  /// (ui-context.js:1007-14). Esc cancels a pending quote chip.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (_suggestions.isNotEmpty && !_suppressPalette) {
      final n = _suggestions.length;
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() => _paletteIndex = (_paletteIndex + 1) % n);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() => _paletteIndex = (_paletteIndex - 1 + n) % n);
        return KeyEventResult.handled;
      }
      if (isEnter || event.logicalKey == LogicalKeyboardKey.tab) {
        _pick(_suggestions[_paletteIndex.clamp(0, n - 1)]);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() => _suppressPalette = true);
        return KeyEventResult.handled;
      }
    }
    if (isEnter && !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        _pendingQuote != null) {
      _clearQuote();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _insertAtCaret(String insert) {
    final text = _controller.text;
    final sel = _controller.selection;
    final at = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final next = text.replaceRange(at, end, insert);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: at + insert.length),
    );
  }

  Future<void> _onEmojiSelected(String emoji) async {
    _insertAtCaret(emoji);
    _emojiPortal.hide();
    final prefs = await _ensurePrefs();
    final next = await EmojiRecentsStore(prefs).add(emoji);
    if (!mounted) return;
    setState(() => _recents = next);
  }

  void _onGifSelected(String url) {
    // PWA appends the GIF URL; the formatter renders it as media.
    _insertAtCaret(url);
    _gifPortal.hide();
  }

  Future<void> _toggleEmojiPicker() async {
    if (_emojiPortal.isShowing) {
      _emojiPortal.hide();
      return;
    }
    _gifPortal.hide();
    final prefs = await _ensurePrefs();
    if (!mounted) return;
    _recents = EmojiRecentsStore(prefs).load();
    _emojiPortal.show();
  }

  Future<void> _toggleGifPicker() async {
    if (_gifPortal.isShowing) {
      _gifPortal.hide();
      return;
    }
    _emojiPortal.hide();
    await _ensurePrefs();
    if (!mounted) return;
    _gifPortal.show();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    // `#sendBtn` is gated on CONNECTION, not input content (relays.js:1040+);
    // the empty-input guard lives inside `_send`. It is NOT disabled while a
    // reply is pending — the PWA lets you keep sending.
    final sendEnabled = ref.watch(
          appStateProvider.select((s) => s.connectedRelays > 0),
        ) ||
        ref.read(nostrControllerProvider).isLive;

    // Apply mention/quote requests published by the context menu / swipe /
    // double-tap (one-shot mailbox).
    ref.listen(pendingComposerActionProvider, (_, action) {
      if (action == null) return;
      _applyComposerAction(action);
      ref.read(pendingComposerActionProvider.notifier).consume();
    });

    final phone =
        MediaQuery.of(context).size.width <= NymDimens.mobileBreakpoint;
    final compact =
        MediaQuery.of(context).size.width <= NymDimens.tabletBreakpoint;

    final input = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // `.quote-preview` chip stacked above the input, sliding in.
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.bottomLeft,
          child: _pendingQuote == null
              ? const SizedBox(height: 0)
              : Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _QuotePreviewChip(
                    author: _pendingQuote!.author,
                    text: _quotePreviewText(_pendingQuote!.text),
                    onClose: _clearQuote,
                  ),
                ),
        ),
        Focus(onKeyEvent: _onKey, child: _textField(context, phone)),
      ],
    );

    final toolbar = _toolbar(context, sendEnabled, compact, phone);

    return Container(
      decoration: BoxDecoration(
        color: c.glassBg,
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      // `.input-container { padding: 12px 16px }`; phones collapse to 10px.
      padding: phone
          ? const EdgeInsets.all(10)
          : const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // `#commandPalette` for the bot-PM `?` commands, above the input
            // (hidden by Escape until the input changes again).
            if (_suggestions.isNotEmpty && !_suppressPalette) _palette(c),
            compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      input,
                      const SizedBox(height: 10),
                      toolbar,
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(child: input),
                      const SizedBox(width: 10),
                      toolbar,
                    ],
                  ),
          ],
        ),
      ),
    );
  }

  /// `.message-input`: white@0.05 fill (black@0.04 light), glass border, ONLY
  /// the bottom corners rounded (radius-md), 10px/16px padding, pure
  /// white/black text at the user size; focus lifts the fill, tints the border
  /// primary@0.3 and paints the 3px primary@0.06 ring (styles-chat.css:1662+).
  Widget _textField(BuildContext context, bool phone) {
    final c = widget.colors;
    final focused = _focus.hasFocus;
    final flatFill = c.isLight
        ? Colors.black.withValues(alpha: focused ? 0.02 : 0.04)
        : Colors.white.withValues(alpha: focused ? 0.07 : 0.05);
    const radius = BorderRadius.vertical(bottom: Radius.circular(NymRadius.md));
    final border = OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: c.glassBorder),
    );
    final field = TextField(
      controller: _controller,
      focusNode: _focus,
      maxLines: 5,
      minLines: 1,
      textInputAction: TextInputAction.newline,
      style: TextStyle(
        color: c.isLight ? Colors.black : Colors.white,
        fontSize: phone ? 16 : 15,
      ),
      cursorColor: c.isLight ? Colors.black : Colors.white,
      decoration: InputDecoration(
        isDense: true,
        // The shared input placeholder (index.html `data-placeholder`).
        hintText: 'Message, / for commands, ? for Nymbot...',
        hintStyle: TextStyle(
            color:
                (c.isLight ? Colors.black : Colors.white).withValues(alpha: 0.4),
            fontSize: phone ? 16 : 15),
        filled: true,
        fillColor: flatFill,
        contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        border: border,
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: c.primaryA(0.30)),
        ),
      ),
    );
    // `.message-input:focus`: a 3px primary@0.06 ring (spread, no blur).
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: focused
            ? [
                BoxShadow(
                  color: c.primaryA(0.06),
                  spreadRadius: 3,
                  blurRadius: 0,
                ),
              ]
            : const [],
      ),
      child: field,
    );
  }

  /// `.input-buttons`: Emoji / GIF icon buttons + the SEND pill. (The PWA row
  /// also carries Image-upload and P2P-file buttons — those live in the
  /// canonical composer's upload plumbing; see handoffs.)
  Widget _toolbar(
      BuildContext context, bool sendEnabled, bool compact, bool phone) {
    final buttons = <Widget>[
      _emojiButton(context, sendEnabled, compact),
      _gifButton(context, sendEnabled, compact),
      _BotSendButton(
        enabled: sendEnabled,
        onTap: _send,
        expand: compact,
        phone: phone,
      ),
    ];
    if (compact) {
      return Row(
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            Expanded(flex: i == buttons.length - 1 ? 2 : 1, child: buttons[i]),
            if (i != buttons.length - 1) const SizedBox(width: 10),
          ],
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          buttons[i],
          if (i != buttons.length - 1) const SizedBox(width: 5),
        ],
      ],
    );
  }

  Widget _emojiButton(BuildContext context, bool enabled, bool expand) {
    return CompositedTransformTarget(
      link: _emojiAnchor,
      child: OverlayPortal(
        controller: _emojiPortal,
        overlayChildBuilder: (context) => _popover(
          link: _emojiAnchor,
          onDismiss: _emojiPortal.hide,
          child: EmojiPicker(
            recents: _recents,
            onSelect: _onEmojiSelected,
          ),
        ),
        child: _BotIconBtn(
          svg: NymIcons.composerEmoji,
          tooltip: 'Emoji',
          expand: expand,
          enabled: enabled,
          onTap: _toggleEmojiPicker,
        ),
      ),
    );
  }

  Widget _gifButton(BuildContext context, bool enabled, bool expand) {
    return CompositedTransformTarget(
      link: _gifAnchor,
      child: OverlayPortal(
        controller: _gifPortal,
        overlayChildBuilder: (context) {
          final prefs = _prefs;
          if (prefs == null) return const SizedBox.shrink();
          return _popover(
            link: _gifAnchor,
            onDismiss: _gifPortal.hide,
            child: GifPicker(
              favoritesStore: FavoriteGifsStore(prefs),
              onSelect: _onGifSelected,
              onClose: _gifPortal.hide,
            ),
          );
        },
        child: _BotIconBtn(
          label: 'GIF',
          tooltip: 'GIF',
          expand: expand,
          enabled: enabled,
          onTap: _toggleGifPicker,
        ),
      ),
    );
  }

  /// Positions a picker above its anchor button (the PWA's `bottom: 100%`
  /// popups) with a barrier to dismiss on tap-out; phones center it above the
  /// input bar instead.
  Widget _popover({
    required LayerLink link,
    required VoidCallback onDismiss,
    required Widget child,
  }) {
    final media = MediaQuery.of(context);
    final isPhone = media.size.width <= NymDimens.mobileBreakpoint;
    final picker = Material(type: MaterialType.transparency, child: child);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
          ),
        ),
        if (isPhone)
          Positioned(
            left: 8,
            right: 8,
            bottom: 60 + media.viewInsets.bottom,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: picker,
              ),
            ),
          )
        else
          CompositedTransformFollower(
            link: link,
            targetAnchor: Alignment.topRight,
            followerAnchor: Alignment.bottomRight,
            offset: const Offset(0, -8),
            showWhenUnlinked: false,
            child: Align(
              alignment: Alignment.bottomRight,
              child: picker,
            ),
          ),
      ],
    );
  }

  /// The `#commandPalette` dropdown: `.command-item` rows (name w600 + desc);
  /// `.command-item.selected` highlights [_paletteIndex] (first row on open,
  /// then ↑/↓-navigable), bgTertiary surface.
  Widget _palette(NymColors c) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      // `.command-palette`: bg rgba(20,20,35,0.9), radius 16/16/0/0, padding 6,
      // max-height 200, shadow-lg.
      constraints: const BoxConstraints(maxHeight: 200),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        // `body.light-mode .command-palette { background: rgba(255,255,255,0.92);
        // box-shadow: 0 8px 32px rgba(0,0,0,0.12); border-color: rgba(0,0,0,0.08) }`
        // (styles-themes-responsive.css:1155-1158) vs dark rgba(20,20,35,0.9).
        color: c.isLight ? const Color(0xEBFFFFFF) : const Color(0xE6141423),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        border: Border.all(
            color: c.isLight ? const Color(0x14000000) : c.glassBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: c.isLight ? 0.12 : 0.5),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: _suggestions.length,
        itemBuilder: (_, i) {
          final cmd = _suggestions[i];
          final selected = i == _paletteIndex;
          return InkWell(
            onTap: () => _pick(cmd),
            child: Container(
              decoration: BoxDecoration(
                // `.command-item.selected`: background white@0.08 dark, flipped to
                // black@0.06 in light mode — `hoverOverlay` is mode-aware. Radius
                // xs (8).
                color: selected ? c.hoverOverlay : null,
                borderRadius: BorderRadius.circular(8),
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // `.command-name`: --primary, bold (not monospace).
                  Flexible(
                    child: Text(cmd.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: c.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 10),
                  // `.command-desc`: 12px; brightens to --text when selected.
                  Flexible(
                    child: Text(
                      cmd.desc,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          color: selected ? c.text : c.textDim, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// `.quote-preview`: bgTertiary panel with a 3px primary bar, the author
/// (primary 12/w600 with a muted `#suffix`) over the truncated quoted text
/// (dim 12, ellipsis) and a close ✕.
class _QuotePreviewChip extends StatelessWidget {
  const _QuotePreviewChip({
    required this.author,
    required this.text,
    required this.onClose,
  });

  final String author;
  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final hashIdx = author.indexOf('#');
    final base = hashIdx >= 0 ? author.substring(0, hashIdx) : author;
    final suffix = hashIdx >= 0 ? author.substring(hashIdx) : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        border: Border.all(color: c.glassBorder),
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(NymRadius.md)),
        // `--shadow-lg`: 0 8px 32px rgba(0,0,0,0.5).
        boxShadow: const [
          BoxShadow(color: Color(0x80000000), blurRadius: 32, offset: Offset(0, 8)),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // `.quote-preview-bar`: 3px wide, ≥28 tall, radius 2.
          Container(
            width: 3,
            constraints: const BoxConstraints(minHeight: 28),
            decoration: BoxDecoration(
              color: c.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                RichText(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    style: TextStyle(
                        color: c.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                    children: [
                      TextSpan(text: base),
                      if (suffix.isNotEmpty)
                        TextSpan(
                          text: suffix,
                          // `.nym-suffix`: opacity 0.7, 0.9em, weight 100.
                          style: TextStyle(
                            color: c.primary.withValues(alpha: 0.7),
                            fontWeight: FontWeight.w100,
                            fontSize: 12 * 0.9,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.textDim, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // `.quote-preview-close`: 16×16 ✕.
          InkWell(
            onTap: onClose,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: NymSvgIcon(NymIcons.close, size: 14, color: c.textDim),
            ),
          ),
        ],
      ),
    );
  }
}

/// `.icon-btn.input-btn` (styles-chat.css:1946-1965): 42px tall, 0 12px
/// padding, radius-sm, 18×18 glyph stroked text → primary on hover; disabled
/// dims to 0.35.
class _BotIconBtn extends StatefulWidget {
  const _BotIconBtn({
    this.svg,
    this.label,
    required this.tooltip,
    this.expand = false,
    this.enabled = true,
    this.onTap,
  }) : assert(svg != null || label != null, 'provide an svg or a label');

  final String? svg;
  final String? label;
  final String tooltip;
  final bool expand;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  State<_BotIconBtn> createState() => _BotIconBtnState();
}

class _BotIconBtnState extends State<_BotIconBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final enabled = widget.enabled;
    final hovered = enabled && _hover;
    final glyphColor = hovered ? c.primary : c.text;
    final child = widget.svg != null
        ? NymSvgIcon(widget.svg!, size: 18, color: glyphColor)
        : Text(
            widget.label!,
            style: TextStyle(
              color: glyphColor,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          );
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: enabled ? widget.onTap : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.35,
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: hovered ? c.hoverOverlay : c.glassBg,
                border: Border.all(color: c.glassBorder),
                borderRadius: NymRadius.rsm,
              ),
              child: widget.expand
                  ? Center(child: child)
                  : child,
            ),
          ),
        ),
      ),
    );
  }
}

/// `.send-btn` (styles-chat.css:1920-1944): primary@0.1 fill, primary@0.3 1px
/// border, radius-sm, 10px/22px padding at 42px height, 'SEND' 12px/600 with
/// 1.5px letter-spacing, uppercase; hover deepens the fill (0.18) + glow;
/// disabled dims to 0.35. Phones shrink to `padding:10px; font-size:11px`.
class _BotSendButton extends StatefulWidget {
  const _BotSendButton({
    required this.enabled,
    required this.onTap,
    this.expand = false,
    this.phone = false,
  });

  final bool enabled;
  final VoidCallback onTap;
  final bool expand;
  final bool phone;

  @override
  State<_BotSendButton> createState() => _BotSendButtonState();
}

class _BotSendButtonState extends State<_BotSendButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final enabled = widget.enabled;
    final hovered = enabled && _hover;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: enabled ? widget.onTap : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.35,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 42,
            padding: widget.phone
                ? const EdgeInsets.all(10)
                : const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.primaryA(hovered ? 0.18 : 0.10),
              border: Border.all(color: c.primaryA(0.30)),
              borderRadius: NymRadius.rsm,
              boxShadow: hovered
                  ? [BoxShadow(color: c.primaryA(0.10), blurRadius: 15)]
                  : null,
            ),
            child: Text(
              'SEND',
              style: TextStyle(
                color: c.primary,
                fontSize: widget.phone ? 11 : 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Git connect modal (provider + PAT + repo/branch) — premium surface
// =============================================================================

class _GitConnectModal extends StatefulWidget {
  const _GitConnectModal({
    required this.colors,
    required this.existing,
    required this.onConnect,
    required this.onDisconnect,
  });

  final NymColors colors;
  final GitConfig? existing;
  final ValueChanged<GitConfig> onConnect;
  final VoidCallback onDisconnect;

  @override
  State<_GitConnectModal> createState() => _GitConnectModalState();
}

class _GitConnectModalState extends State<_GitConnectModal> {
  late GitProvider _provider;
  late final TextEditingController _host;
  late final TextEditingController _token;
  late final TextEditingController _repo;
  late final TextEditingController _branch;
  late bool _allowWrites;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _provider = e?.provider ?? GitProvider.github;
    _host = TextEditingController(text: e?.host ?? _provider.defaultHost);
    _token = TextEditingController(text: e?.token ?? '');
    _repo = TextEditingController(text: e?.repo ?? '');
    _branch = TextEditingController(text: e?.branch ?? '');
    _allowWrites = e?.allowWrites ?? false;
  }

  @override
  void dispose() {
    _host.dispose();
    _token.dispose();
    _repo.dispose();
    _branch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Connect a git repo',
                style: TextStyle(
                    color: c.textBright,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              'Pro replies can read your code and, with writes on, commit, '
              'branch, and open PRs. Your access token is stored only on this '
              'device (Panic Mode wipes it) and sent per request — never stored '
              'server-side.',
              style: TextStyle(color: c.textDim, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            // Provider selector.
            Wrap(
              spacing: 8,
              children: [
                for (final p in GitProvider.values)
                  ChoiceChip(
                    label: Text(p.label),
                    selected: _provider == p,
                    onSelected: (_) => setState(() {
                      _provider = p;
                      _host.text = p.defaultHost;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            _field(_host, 'Host', 'github.com', c),
            const SizedBox(height: 10),
            _field(_token, 'Personal access token (PAT)', 'ghp_… / glpat-… ',
                c, obscure: true),
            const SizedBox(height: 10),
            _field(_repo, 'Repository', 'owner/repo', c),
            const SizedBox(height: 10),
            _field(_branch, 'Branch (optional)', 'main', c),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _allowWrites,
              thumbColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) return c.primary;
                return null;
              }),
              title: Text('Allow writes',
                  style: TextStyle(color: c.text, fontSize: 14)),
              subtitle: Text('commit, create branches, open pull/merge requests',
                  style: TextStyle(color: c.textDim, fontSize: 11)),
              onChanged: (v) => setState(() => _allowWrites = v),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (widget.existing != null)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        widget.onDisconnect();
                        Navigator.pop(context);
                      },
                      child: const Text('Disconnect'),
                    ),
                  ),
                if (widget.existing != null) const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: _canConnect ? _connect : null,
                    child: const Text('Connect'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool get _canConnect =>
      _token.text.trim().isNotEmpty && _repo.text.trim().isNotEmpty;

  void _connect() {
    widget.onConnect(GitConfig(
      provider: _provider,
      host: _host.text.trim().isEmpty ? _provider.defaultHost : _host.text.trim(),
      token: _token.text.trim(),
      repo: _repo.text.trim(),
      branch: _branch.text.trim().isEmpty ? null : _branch.text.trim(),
      allowWrites: _allowWrites,
    ));
    Navigator.pop(context);
  }

  Widget _field(TextEditingController ctrl, String label, String hint,
      NymColors c,
      {bool obscure = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: c.textDim, fontSize: 12)),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          obscureText: obscure,
          style: TextStyle(color: c.text, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: c.textDim),
            isDense: true,
            filled: true,
            fillColor: c.bgTertiary,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: c.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: c.border),
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Fallback theme colours (used only when NymColors isn't registered, e.g. in a
// bare widget test). The real app supplies NymColors via the theme extension.
// =============================================================================

const NymColors _fallbackColors = NymColors(
  primary: Color(0xFF7C5CFF),
  secondary: Color(0xFF4DA3FF),
  warning: Color(0xFFE0A800),
  danger: Color(0xFFE5484D),
  purple: Color(0xFF7C5CFF),
  blue: Color(0xFF4DA3FF),
  lightning: Color(0xFFF7931A),
  bg: Color(0xFF0E0E12),
  bgSecondary: Color(0xFF16161C),
  bgTertiary: Color(0xFF1E1E26),
  text: Color(0xFFE6E6EA),
  textDim: Color(0xFF9A9AA6),
  textBright: Color(0xFFFFFFFF),
  border: Color(0xFF2A2A33),
  glassBg: Color(0x22FFFFFF),
  glassBorder: Color(0x33FFFFFF),
  brightness: Brightness.dark,
);
