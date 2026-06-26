import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/nym_utils.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/chat/message_row.dart'
    show formatRelativeTime, formatFullTimestamp;
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/context_menu/interaction_hooks.dart';
import '../../widgets/context_menu/profile_badges.dart' show VerifiedBadge;
import '../messages/format/message_content.dart';
import 'bot_credits_modal.dart';
import 'nymbot_models.dart';
import 'nymbot_providers.dart';

/// The private 1:1 Nymbot chat screen.
///
/// 1:1 port of the PWA's paid Nymbot PM surface (README "Nymbot" section + spec
/// §11). Features:
///   * message list with the bot,
///   * a collapsed "💭 Reasoning" section above replies that have reasoning,
///   * the Standard / Pro model switch,
///   * `?balance` / `?buy` (invoice QR placeholder),
///   * `?model <name>` picker (the 7 Pro frontier models),
///   * the `?git` connect flow (provider + PAT + repo/branch; PAT on-device,
///     wiped by panic).
///
/// Payment/invoice settlement is stubbed (see TODO(verify) markers); the full UI
/// is built.
class BotChatScreen extends ConsumerStatefulWidget {
  const BotChatScreen({super.key});

  @override
  ConsumerState<BotChatScreen> createState() => _BotChatScreenState();
}

class _BotChatScreenState extends ConsumerState<BotChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// The free, local `?help` guide (PWA `_displayBotPmHelp`). Listed so users
  /// can discover every PM command without being billed.
  static const String _botHelpText =
      'Nymbot commands (free):\n'
      '?help — this guide\n'
      '?balance — your standard & Pro credit balances\n'
      '?buy — purchase credits over Lightning (Standard/Pro)\n'
      '?gift @nym#xxxx — gift credits to another user\n'
      '?transfer @nym#xxxx confirm — move ALL credits to another pubkey\n'
      '?model [name|off] — pick a Pro frontier model (or standard routing)\n'
      '?git — connect a repo so Pro replies can read/commit code\n'
      '?clear — wipe this chat and start fresh\n\n'
      'Just type normally to chat. Start a message with ! for a one-off answer '
      'that ignores history. Quote-reply a message to ask a follow-up about it.';

  @override
  void initState() {
    super.initState();
    // Lazy: fetch balance once when the screen opens (no-op if unbound).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(botChatControllerProvider.notifier).refreshBalance();
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  NymColors _colors(BuildContext context) =>
      Theme.of(context).extension<NymColors>() ?? _fallbackColors;

  @override
  Widget build(BuildContext context) {
    final c = _colors(context);
    final state = ref.watch(botChatControllerProvider);

    // Observe the gift-credits mailbox the context menu writes to
    // (`giftCreditsRequestProvider`, interaction_hooks.dart). When a "Gift
    // Nymbot Credits" request arrives, open the gift-credit modal prefilled with
    // the recipient, then consume the request (PWA `showBotCreditsModal`).
    ref.listen<GiftCreditsRequest?>(giftCreditsRequestProvider, (prev, next) {
      if (next == null) return;
      // Consume immediately so a rebuild can't re-open the modal.
      ref.read(giftCreditsRequestProvider.notifier).consume();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _openGiftModal(next.pubkey, next.nym);
      });
    });

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.bgSecondary,
        foregroundColor: c.textBright,
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: c.purple.withValues(alpha: 0.2),
              child: Text('🤖', style: const TextStyle(fontSize: 16)),
            ),
            const SizedBox(width: 10),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Canonical header name = base nym + dim `#suffix`
                // (PWA `displayNym`, pms.js:2607; suffix dims the base color to
                // 0.7 / 0.9em / weight 100 — message_row.dart:307-316).
                Text.rich(
                  TextSpan(children: [
                    const TextSpan(text: 'Nymbot'),
                    TextSpan(
                      text:
                          '#${getPubkeySuffix(NostrController.nymbotPubkey)}',
                      style: TextStyle(
                        color: c.textBright.withValues(alpha: 0.7),
                        fontSize: 16 * 0.9,
                        fontWeight: FontWeight.w100,
                      ),
                    ),
                  ]),
                  style: TextStyle(
                      color: c.textBright,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2),
                ),
                Text(
                  state.isPro
                      ? 'Pro · ${state.proModel!.label}'
                      : 'Standard · auto-routed',
                  style: TextStyle(color: c.textDim, fontSize: 11),
                ),
              ],
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
                color: state.git != null ? c.primary : c.text),
            onPressed: () => _showGitConnect(context),
          ),
        ],
      ),
      body: Column(
        children: [
          _TierSwitch(
            isPro: state.isPro,
            proLabel: state.proModel?.label,
            colors: c,
            onTapStandard: () =>
                ref.read(botChatControllerProvider.notifier).setModelDirect(null),
            onTapPro: () => _showModelPicker(context),
          ),
          Expanded(child: _buildMessageList(c, state)),
          _Composer(
            controller: _input,
            colors: c,
            sending: state.sending,
            onSubmit: _handleSubmit,
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList(NymColors c, BotChatState state) {
    if (state.messages.isEmpty) {
      // Rich welcome bubble from Nymbot (PWA `_botWelcomeHtml`), styled like an
      // actual bot message with avatar + verified ✓ badge.
      return ListView(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        children: [_BotWelcomeBubble(colors: c)],
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      itemCount: state.messages.length,
      itemBuilder: (_, i) {
        // Same-author adjacency → group the bubble (suppress avatar/name,
        // square the tail, tighten the gap), like the canonical message row.
        final grouped = i > 0 &&
            state.messages[i - 1].fromUser == state.messages[i].fromUser &&
            !state.messages[i - 1].pending;
        return _MessageBubble(
          message: state.messages[i],
          colors: c,
          grouped: grouped,
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Submit / command interception (mirrors the PWA: `?` commands typed inside
  // the bot PM are handled as control commands).
  // ---------------------------------------------------------------------------

  void _handleSubmit() {
    var text = _input.text.trim();
    if (text.isEmpty) return;
    final ctrl = ref.read(botChatControllerProvider.notifier);

    if (text.startsWith('?')) {
      final lower = text.toLowerCase();
      if (lower == '?balance') {
        _input.clear();
        _showBalance(context);
        return;
      }
      if (lower == '?buy') {
        _input.clear();
        _showBuy(context);
        return;
      }
      if (lower == '?help' || lower == '?commands') {
        // `?help` is a free local guide — never billed (PWA `_displayBotPmHelp`,
        // pms.js). When the chat is empty the rich welcome bubble already shows
        // the guide, so just scroll to it; otherwise append a help bubble.
        _input.clear();
        if (ref.read(botChatControllerProvider).messages.isEmpty) {
          _scrollToTop();
        } else {
          ctrl.addBotInfo(_botHelpText);
          _scrollToBottom();
        }
        return;
      }
      if (lower == '?clear') {
        _input.clear();
        ctrl.clearHistory();
        return;
      }
      if (lower.startsWith('?model')) {
        final arg = text.substring(6).trim();
        _input.clear();
        if (arg.isEmpty) {
          _showModelPicker(context);
        } else {
          ctrl.setModel(arg);
        }
        return;
      }
      if (lower.startsWith('?gift')) {
        // `?gift @nym#xxxx` — resolve the nym, then open the gift-credit modal
        // prefilled with the recipient (PWA `_handleBotPM` ?gift branch,
        // pms.js:2426-2441 → showBotCreditsModal({pubkey, nym})).
        _input.clear();
        _handleGiftCommand(text);
        return;
      }
      if (lower.startsWith('?transfer')) {
        // `?transfer @nym [confirm]` — confirm flow that moves ALL credits to
        // another pubkey (PWA `_handleBotTransferCommand`, pms.js:1919).
        _input.clear();
        _handleTransferCommand(text);
        return;
      }
      if (lower.startsWith('?git')) {
        _input.clear();
        // `?git writes on/off` toggles writes when already connected.
        final state = ref.read(botChatControllerProvider);
        if (lower.contains('writes') && state.git != null) {
          final on = lower.contains('on');
          ctrl.connectGit(state.git!.copyWith(allowWrites: on));
        } else {
          _showGitConnect(context);
        }
        return;
      }
    }

    // A leading `!` marks a one-off "fresh" message that ignores history
    // (PWA: `send(..., fresh:true)`).
    var fresh = false;
    if (text.startsWith('!')) {
      fresh = true;
      text = text.substring(1).trim();
      if (text.isEmpty) return;
    }

    _input.clear();
    ctrl.send(text, fresh: fresh);
    _scrollToBottom();
  }

  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(0,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Gift / transfer (PWA `_handleBotPM` ?gift + `_handleBotTransferCommand`)
  // ---------------------------------------------------------------------------

  /// Opens the gift-credit modal prefilled with [pubkey]/[nym] (PWA
  /// `showBotCreditsModal({pubkey, nym})`). Pro tier is preselected when a Pro
  /// model is currently pinned, matching the buy path.
  void _openGiftModal(String pubkey, String nym) {
    final state = ref.read(botChatControllerProvider);
    BotCreditsModal.show(
      context,
      colors: _colors(context),
      giftRecipientPubkey: pubkey,
      giftRecipientNym: nym,
      initialTier: state.isPro ? CreditTier.pro : CreditTier.standard,
    );
  }

  /// Resolves a `?gift`/`?transfer` argument to a pubkey, mirroring the PWA's
  /// `resolvePubkeyFromNym` priority: a 64-char hex pubkey is used directly;
  /// otherwise the users map is matched by `base#suffix` then by base nym
  /// (case-insensitive). Returns null when nothing matches.
  String? _resolvePubkeyFromNym(String arg) {
    final raw = arg.trim().replaceFirst(RegExp(r'^@'), '');
    if (raw.isEmpty) return null;
    if (RegExp(r'^[0-9a-f]{64}$', caseSensitive: false).hasMatch(raw)) {
      return raw.toLowerCase();
    }
    final users = ref.read(usersProvider);
    final needle = raw.toLowerCase();
    // Exact base#suffix match first.
    for (final entry in users.entries) {
      final full =
          '${stripPubkeySuffix(entry.value.nym)}#${getPubkeySuffix(entry.key)}';
      if (full.toLowerCase() == needle) return entry.key;
    }
    // Then a bare base-nym match (first hit).
    for (final entry in users.entries) {
      if (stripPubkeySuffix(entry.value.nym).toLowerCase() == needle) {
        return entry.key;
      }
    }
    return null;
  }

  /// `?gift @nym#xxxx` — resolves the recipient and opens the gift modal, or
  /// surfaces the PWA's usage / not-found guidance (pms.js:2426-2441).
  void _handleGiftCommand(String text) {
    final ctrl = ref.read(botChatControllerProvider.notifier);
    final arg = text.replaceFirst(RegExp(r'^\?gift\b', caseSensitive: false), '').trim();
    if (arg.isEmpty) {
      ctrl.addBotInfo(
          'Usage: ?gift @nym#xxxx — gift Nymbot credits to another user.');
      return;
    }
    final pubkey = _resolvePubkeyFromNym(arg);
    if (pubkey == null) {
      ctrl.addBotInfo(
          'Could not find user "${arg.replaceFirst(RegExp(r'^@'), '')}". '
          'Try ?gift with their full nym (e.g. ?gift @cyber_wolf#a3f2).');
      return;
    }
    final user = ref.read(usersProvider)[pubkey];
    final nym = stripPubkeySuffix(user?.nym ?? pubkey.substring(0, 8));
    _openGiftModal(pubkey, nym);
  }

  /// `?transfer @nym [confirm]` — confirm-gated transfer of ALL credits to
  /// another pubkey (PWA `_handleBotTransferCommand`, pms.js:1919).
  Future<void> _handleTransferCommand(String text) async {
    final ctrl = ref.read(botChatControllerProvider.notifier);
    final raw =
        text.replaceFirst(RegExp(r'^\?transfer\b', caseSensitive: false), '').trim();
    final parts = raw.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final confirming =
        parts.isNotEmpty && parts.last.toLowerCase() == 'confirm';
    final targetArg = (confirming ? parts.sublist(0, parts.length - 1) : parts)
        .join(' ')
        .trim()
        .replaceFirst(RegExp(r'^@'), '');
    if (targetArg.isEmpty) {
      ctrl.addBotInfo(
          'Usage: ?transfer @nym#xxxx or ?transfer <hex pubkey> — moves your '
          'entire Nymbot credit balance to another pubkey. Append "confirm" to '
          'execute (e.g. ?transfer @friend#a1b2 confirm).');
      return;
    }
    final targetPubkey = _resolvePubkeyFromNym(targetArg);
    if (targetPubkey == null) {
      ctrl.addBotInfo(
          'Could not resolve "$targetArg". Try ?transfer with a full nym '
          '(e.g. ?transfer @friend#a1b2 confirm) or a 64-char hex pubkey.');
      return;
    }
    final selfPubkey = ref.read(nostrControllerProvider).identity?.pubkey;
    if (targetPubkey == selfPubkey) {
      ctrl.addBotInfo("You can't transfer credits to your own pubkey.");
      return;
    }
    final user = ref.read(usersProvider)[targetPubkey];
    final targetNym = stripPubkeySuffix(user?.nym ?? targetPubkey.substring(0, 8));
    final suffix = getPubkeySuffix(targetPubkey);

    if (!confirming) {
      final b = ref.read(botChatControllerProvider).balance;
      if (b.balance <= 0 && b.proBalance <= 0) {
        ctrl.addBotInfo('You have no Nymbot credits to transfer.');
        return;
      }
      final segs = <String>[];
      if (b.balance > 0) {
        segs.add('${b.balance} credit${b.balance == 1 ? '' : 's'}');
      }
      if (b.proBalance > 0) {
        segs.add('${b.proBalance} Pro credit${b.proBalance == 1 ? '' : 's'}');
      }
      ctrl.addBotInfo(
          'Transfer ALL ${segs.join(' and ')} to @$targetNym? This empties your '
          'balance. To confirm, type: ?transfer @$targetNym#$suffix confirm');
      return;
    }

    // Confirmed: run the transfer.
    final res = await ctrl.transferCredits(targetPubkey);
    if (res == null) {
      ctrl.addBotInfo('Transfer failed. Please try again.');
      return;
    }
    if (res['error'] != null) {
      ctrl.addBotInfo('Transfer failed: ${res['error']}');
      return;
    }
    final moved = <String>[];
    final transferred = (res['transferred'] as num?)?.toInt() ?? 0;
    final proTransferred = (res['proTransferred'] as num?)?.toInt() ?? 0;
    if (transferred > 0) {
      moved.add('$transferred credit${transferred == 1 ? '' : 's'}');
    }
    if (proTransferred > 0) {
      moved.add('$proTransferred Pro credit${proTransferred == 1 ? '' : 's'}');
    }
    ctrl.addBotInfo(
        'Transferred ${moved.isEmpty ? '0 credits' : moved.join(' and ')} to '
        '@$targetNym. Your balance is now 0.');
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Modals
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
// Tier switch (Standard / Pro)
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
// Message bubble + collapsed reasoning
// =============================================================================

/// A single Nymbot-chat row.
///
/// The PWA routes bot replies and the user's own messages through the SAME
/// `displayMessage()` / `.message` pipeline as every other message (pms.js:1337,
/// 1362), so they share the canonical bubble. This widget mirrors
/// `message_row.dart`'s bubble exactly — fill (others = white@0.14, self =
/// primary@0.25), 16px radius with a 4px tail, the 32px avatar + name header on
/// bot rows, the in-bubble bottom-right relative timestamp, borderless bubbles,
/// and the full [MessageContent] formatter — so the premium bot chat flows with
/// the rest of the app instead of using a divergent bubble.
class _MessageBubble extends ConsumerWidget {
  const _MessageBubble({
    required this.message,
    required this.colors,
    this.grouped = false,
  });

  final BotChatMessage message;
  final NymColors colors;

  /// True when the previous row shares this row's author — suppresses the
  /// avatar/name header and squares the tail (canonical `widget.grouped`).
  final bool grouped;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = colors;
    final fromUser = message.fromUser;
    final settings = ref.watch(settingsProvider);
    final fontSize = settings.textSize.toDouble();

    // Canonical `.message-content` fill (message_row.dart:761-767): self =
    // primary@0.25 (dark) / 0.20 (light); others (bot) = white@0.14 (dark) /
    // black@0.10 (light). The error state takes the danger wash.
    final bubbleColor = message.error
        ? c.danger.withValues(alpha: 0.14)
        : fromUser
            ? c.primaryA(c.isLight ? 0.20 : 0.25)
            : (c.isLight
                ? const Color(0x1A000000) // black @ 0.10
                : Colors.white.withValues(alpha: 0.14));

    final bubble = ConstrainedBox(
      // `.message-content { min-width:180px; max-width:85% }`.
      constraints: BoxConstraints(
        minWidth: 180,
        maxWidth: MediaQuery.of(context).size.width * 0.85,
      ),
      child: Container(
        // Canonical `.message-content { padding: 8px 12px 6px }`
        // (styles-features.css:3608).
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: _bubbleRadius(fromUser),
          // Canonical bubbles are borderless; only the error state keeps a ring.
          border: message.error ? Border.all(color: c.danger) : null,
        ),
        child: message.pending
            ? _TypingDots(color: c.textDim)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The collapsed reasoning is PREPENDED inside `.message-content`
                  // (PWA `messages.js:796-797` prepends `.bot-think` into the
                  // bubble), so it renders on the bubble background above the
                  // reply text — not floating above the bubble.
                  if (message.hasReasoning)
                    _ReasoningSection(
                        reasoning: message.reasoning!, colors: c),
                  // Full canonical inline formatting (markdown / links / emoji /
                  // mentions / fenced code) — not a raw Text — so bot replies
                  // render identically to channel/PM messages.
                  MessageContent(
                    content: message.text,
                    baseColor: message.error ? c.danger : c.text,
                    fontSize: fontSize,
                  ),
                  // `.bubble-time-inner`: relative time pinned bottom-right,
                  // 4px below the body, inside the bubble. Tapping it reveals the
                  // full date+time (canonical `showTimestampPopup`,
                  // message_row.dart:932-940).
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Tooltip(
                      message: formatFullTimestamp(message.timestamp,
                          settings.timeFormat, settings.dateFormat),
                      triggerMode: TooltipTriggerMode.tap,
                      child: Text(
                        formatRelativeTime(message.timestamp),
                        style: TextStyle(
                            color: c.textDim, fontSize: 10, height: 1),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );

    // The user's own rows: right-aligned, no avatar/name (canonical `group-self`
    // is row-reversed with no avatar).
    if (fromUser) {
      return Padding(
        padding: EdgeInsets.fromLTRB(14, grouped ? 2 : 6, 14, 0),
        child: Align(alignment: Alignment.centerRight, child: bubble),
      );
    }

    // Bot rows: a 32px avatar gutter (6px from the edge) + a "Nymbot ✓" name
    // line above the bubble (suppressed on grouped continuations).
    final botPicture =
        ref.watch(usersProvider)[NostrController.nymbotPubkey]?.profile?.picture;
    return Padding(
      padding: EdgeInsets.fromLTRB(6, grouped ? 2 : 6, 14, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: grouped
                ? const SizedBox.shrink()
                : NymAvatar(
                    seed: NostrController.nymbotPubkey,
                    size: 32,
                    imageUrl: botPicture,
                  ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!grouped)
                  Padding(
                    // `.message-author { margin-bottom: 2px }`
                    // (styles-features.css:3582).
                    padding: const EdgeInsets.only(left: 2, bottom: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Canonical name = base nym + dim `#suffix` span with
                        // letter-spacing 0.2 (message_row.dart:307-316,358).
                        Flexible(
                          child: Text.rich(
                            TextSpan(children: [
                              const TextSpan(text: 'Nymbot'),
                              TextSpan(
                                text:
                                    '#${getPubkeySuffix(NostrController.nymbotPubkey)}',
                                style: TextStyle(
                                  color: c.secondaryA(0.7),
                                  fontSize: 11 * 0.9,
                                  fontWeight: FontWeight.w100,
                                ),
                              ),
                            ]),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: c.secondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.2),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const VerifiedBadge(size: 14),
                      ],
                    ),
                  ),
                Align(alignment: Alignment.centerLeft, child: bubble),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 16px radius with a 4px tail (top-left for bot, top-right for self); a
  /// grouped continuation is fully rounded. Mirrors `message_row._bubbleRadius`.
  BorderRadius _bubbleRadius(bool self) {
    const r = Radius.circular(16);
    const tail = Radius.circular(4);
    if (grouped) return const BorderRadius.all(r);
    if (self) {
      return const BorderRadius.only(
          topLeft: r, topRight: tail, bottomLeft: r, bottomRight: r);
    }
    return const BorderRadius.only(
        topLeft: tail, topRight: r, bottomLeft: r, bottomRight: r);
  }
}

// =============================================================================
// Rich welcome bubble (empty-state) — PWA `_botWelcomeHtml`
// =============================================================================

/// The premium-bot intro, rendered as a non-`fromUser` bubble with the bot
/// avatar (🤖), name, and verified ✓ badge. Copy ported verbatim from the PWA
/// `_botWelcomeHtml` (pms.js:1707-1728); `**bold**` and `` `code` `` markers are
/// rendered inline (code spans as monospace pills).
class _BotWelcomeBubble extends StatelessWidget {
  const _BotWelcomeBubble({required this.colors});
  final NymColors colors;

  /// One line of the welcome copy. A leading `• ` marks a bullet row.
  static const List<String> _lines = [
    "Hey, I'm **Nymbot** 👋 — your private, end-to-end encrypted 1:1 AI assistant.",
    '',
    "I'm smarter than the free public-channel bot. I read each message, figure out the type of task (coding, reasoning/math, creative writing, translation, or general chat) and route it to the best AI model for the job — so my answers are sharper.",
    '',
    "**Here's how to get the most out of me:**",
    '• `?help` — full guide to premium vs Pro, the git repo integration, and every command (free).',
    '• Just type normally — I use our whole conversation as context.',
    '• Start a message with `!` to get a one-off answer that ignores all earlier chat history (e.g. `!what is 2+2`).',
    "• Quote-reply any message to ask a follow-up about it — I'll see what you're replying to.",
    '• `?clear` — wipe this chat and start fresh.',
    '• `?balance` — check your credit balance (also shown in the header).',
    '• `?buy` — purchase more credits. `?gift @nym#xxxx` — gift credits to someone.',
    '• `?model` — go **Pro**: pick a specific frontier model (Claude Fable 5, Claude Opus/Sonnet/Haiku, GPT-5.1, Codex) for every reply, paid with separate Pro credits.',
    '• `?git` — connect a git repo (GitHub, GitLab, Gitea/Codeberg) so Pro replies read your actual code and can even commit, branch, and open PRs — like a chat-based coding agent.',
    '• `?transfer @nym#xxxx confirm` — move ALL your credits to another pubkey (great for switching nyms).',
    '',
    '**Pricing:** general chat, creative writing, and translation replies cost **1 credit**. Coding and reasoning/math replies cost **2 credits** (they use larger models). Pro replies start at **1–2 Pro credits** and scale with reply length (each model\'s range is in `?model`). Credits are tied to your nym — save your nsec so you don\'t lose them.',
    '',
    'So, what can I help you with?',
  ];

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.9,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Author row: avatar + "Nymbot" + verified ✓ badge.
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: c.purple.withValues(alpha: 0.2),
                    child: const Text('🤖', style: TextStyle(fontSize: 16)),
                  ),
                  const SizedBox(width: 6),
                  // Canonical name = base nym + dim `#suffix`, letter-spacing 0.2
                  // (message_row.dart:307-316,358).
                  Flexible(
                    child: Text.rich(
                      TextSpan(children: [
                        const TextSpan(text: 'Nymbot'),
                        TextSpan(
                          text:
                              '#${getPubkeySuffix(NostrController.nymbotPubkey)}',
                          style: TextStyle(
                            color: c.secondaryA(0.7),
                            fontSize: 11 * 0.9,
                            fontWeight: FontWeight.w100,
                          ),
                        ),
                      ]),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: c.secondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const VerifiedBadge(size: 14),
                ],
              ),
            ),
            Container(
              // Canonical `.message-content { padding: 8px 12px 6px }`.
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              decoration: BoxDecoration(
                // Canonical bot-bubble fill (others = white@0.14 dark /
                // black@0.10 light), borderless — matches the reply bubbles.
                color: c.isLight
                    ? const Color(0x1A000000)
                    : Colors.white.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in _lines) _line(c, line),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _line(NymColors c, String raw) {
    if (raw.isEmpty) return const SizedBox(height: 8);
    final bullet = raw.startsWith('• ');
    final text = bullet ? raw.substring(2) : raw;
    final body = Text.rich(
      _inlineSpans(c, text),
      style: TextStyle(color: c.text, fontSize: 13.5, height: 1.45),
    );
    if (!bullet) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: body,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('•  ', style: TextStyle(color: c.textDim, fontSize: 13.5)),
          Expanded(child: body),
        ],
      ),
    );
  }

  /// Renders `**bold**` and `` `code` `` runs inline. Code runs become a
  /// monospace pill (bgTertiary fill, secondary-tinted text).
  TextSpan _inlineSpans(NymColors c, String text) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      if (m.group(1) != null) {
        spans.add(TextSpan(
          text: m.group(1),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ));
      } else {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: c.bgTertiary,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: c.border),
            ),
            child: Text(
              m.group(2)!,
              style: TextStyle(
                color: c.secondary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ));
      }
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }
    return TextSpan(children: spans);
  }
}

/// The collapsed "💭 Reasoning" section. Tap to expand/collapse.
class _ReasoningSection extends StatefulWidget {
  const _ReasoningSection({required this.reasoning, required this.colors});

  final String reasoning;
  final NymColors colors;

  @override
  State<_ReasoningSection> createState() => _ReasoningSectionState();
}

class _ReasoningSectionState extends State<_ReasoningSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    // PWA `.bot-think`: secondary @8% fill, 1px glass border + a 3px primary
    // @45% left accent bar, --radius-xs (8).
    final side = BorderSide(color: c.glassBorder);
    return Container(
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Rotating ▸ marker (rotates 90° when open).
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 250),
                    turns: _expanded ? 0.25 : 0,
                    child: Text('▸',
                        style: TextStyle(color: c.textDim, fontSize: 12)),
                  ),
                  const SizedBox(width: 6),
                  const Text('💭', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 4),
                  // `.bot-think summary` has no font-weight (normal/w400).
                  Text('Reasoning',
                      style: TextStyle(
                          color: c.textDim,
                          fontSize: 12,
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
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Text(
                  widget.reasoning,
                  style: TextStyle(
                      color: c.textDim,
                      fontSize: 12,
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

class _TypingDots extends StatelessWidget {
  const _TypingDots({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: color),
        ),
        const SizedBox(width: 8),
        // PWA shared typing indicator labels in-flight replies "is typing…".
        Text('Nymbot is typing…',
            style: TextStyle(color: color, fontSize: 13)),
      ],
    );
  }
}

// =============================================================================
// Composer
// =============================================================================

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.colors,
    required this.sending,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final NymColors colors;
  final bool sending;
  final VoidCallback onSubmit;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  /// The currently-filtered `?…` suggestions (empty → palette hidden).
  List<BotPMCommand> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    final text = widget.controller.text;
    final next = text.startsWith('?')
        ? filterBotPMCommands(text)
        : const <BotPMCommand>[];
    if (!_sameCommands(next, _suggestions)) {
      setState(() => _suggestions = next);
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
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    // Re-filter so a multi-step command (e.g. `?git `) immediately surfaces its
    // subcommands; a leaf command just hides the palette.
    _onTextChanged();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_suggestions.isNotEmpty) _palette(c),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: c.bgSecondary,
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    minLines: 1,
                    maxLines: 5,
                    style: TextStyle(color: c.text, fontSize: 14),
                    onSubmitted: (_) => widget.onSubmit(),
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      hintText: 'Message Nymbot…  (try ?help)',
                      hintStyle: TextStyle(color: c.textDim),
                      filled: true,
                      fillColor: c.bgTertiary,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide(color: c.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide(color: c.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide(color: c.primary),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: widget.sending ? null : widget.onSubmit,
                  icon: const Icon(Icons.send, size: 18),
                  style: IconButton.styleFrom(backgroundColor: c.primary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The `#commandPalette` dropdown: `.command-item` rows (name w600 + desc),
  /// the first row highlighted (`.command-item.selected`), bgTertiary surface.
  Widget _palette(NymColors c) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
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
          final selected = i == 0;
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

// (Buy modal is now the shared `BotCreditsModal` in bot_credits_modal.dart,
// used for both `?buy` and `?gift`.)

// =============================================================================
// Git connect modal (provider + PAT + repo/branch)
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
