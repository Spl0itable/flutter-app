import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import 'nymbot_models.dart';
import 'nymbot_providers.dart';

/// The Nymbot **buy / gift credits** modal — a 1:1 port of the PWA's
/// `showBotCreditsModal` (zaps.js:530-660) presented as a bottom sheet.
///
/// Two modes share one surface, mirroring the PWA:
///   * **Buy** (`giftRecipient == null`): "Buy Nymbot private message credits".
///   * **Gift** (`giftRecipient != null`): "Gift Nymbot credits to @nym" — the
///     created invoice carries `recipientPubkey`, so the worker credits THEM.
///
/// Layout matches the PWA: a Standard/Pro tier toggle (both segments use the
/// lightning accent), a grid of sats presets (per-tier, with the bulk-bonus
/// credit count shown on each), a custom-amount field, a live credit estimate,
/// and — once an amount is picked — the Lightning invoice (QR placeholder +
/// copyable bolt11).
class BotCreditsModal extends ConsumerStatefulWidget {
  const BotCreditsModal({
    super.key,
    required this.colors,
    this.giftRecipientPubkey,
    this.giftRecipientNym,
    this.initialTier = CreditTier.standard,
  });

  final NymColors colors;

  /// Recipient pubkey when gifting (PWA `giftRecipient.pubkey`). Null = self-buy.
  final String? giftRecipientPubkey;

  /// Recipient base nym when gifting (PWA `giftRecipient.nym`).
  final String? giftRecipientNym;

  /// Opening tier (PWA passes `'pro'` when a Pro model is pinned).
  final CreditTier initialTier;

  bool get isGift =>
      giftRecipientPubkey != null && giftRecipientPubkey!.isNotEmpty;

  /// Presents the modal as a scroll-controlled bottom sheet.
  static Future<void> show(
    BuildContext context, {
    required NymColors colors,
    String? giftRecipientPubkey,
    String? giftRecipientNym,
    CreditTier initialTier = CreditTier.standard,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.bgSecondary,
      builder: (_) => BotCreditsModal(
        colors: colors,
        giftRecipientPubkey: giftRecipientPubkey,
        giftRecipientNym: giftRecipientNym,
        initialTier: initialTier,
      ),
    );
  }

  @override
  ConsumerState<BotCreditsModal> createState() => _BotCreditsModalState();
}

class _BotCreditsModalState extends ConsumerState<BotCreditsModal> {
  late CreditTier _tier;
  final _custom = TextEditingController();

  /// The selected preset (null when the custom field drives the amount).
  int? _selectedPreset;
  BotInvoice? _invoice;
  bool _loading = false;
  String? _error;

  /// Preset purchase tiers (PWA `_botCreditTiers` / `_botProCreditPresets`,
  /// zaps.js:349-352).
  static const List<int> _standardPresets = [100, 500, 1000, 2500, 5000, 10000];
  static const List<int> _proPresets = [2000, 5000, 10000, 20000, 50000, 100000];

  @override
  void initState() {
    super.initState();
    _tier = widget.initialTier;
    _custom.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  List<int> get _presets =>
      _tier == CreditTier.pro ? _proPresets : _standardPresets;

  /// Credits for [sats] at the current tier, with the bulk bonus
  /// (PWA `_botCreditsForSats` / `_botProCreditsForSats`, zaps.js:324-342).
  int _creditsForSats(int sats) {
    final s = sats < 0 ? 0 : sats;
    double mult = 1;
    if (_tier == CreditTier.pro) {
      if (s >= 50000) {
        mult = 1.20;
      } else if (s >= 10000) {
        mult = 1.15;
      } else if (s >= 5000) {
        mult = 1.10;
      }
      return ((s / 100) * mult).floor();
    }
    if (s >= 5000) {
      mult = 1.20;
    } else if (s >= 1000) {
      mult = 1.15;
    } else if (s >= 500) {
      mult = 1.10;
    }
    return ((s / 10) * mult).floor();
  }

  /// The effective amount in sats (custom field wins when non-empty).
  int? get _amountSats {
    final raw = _custom.text.trim();
    if (raw.isNotEmpty) {
      final v = int.tryParse(raw);
      return (v != null && v > 0) ? v : null;
    }
    return _selectedPreset;
  }

  String _satLabel(int sats) =>
      sats >= 1000 ? '${(sats / 1000).toStringAsFixed(sats % 1000 == 0 ? 0 : 1)}K' : '$sats';

  String get _creditWord => _tier == CreditTier.pro ? 'Pro' : 'credits';

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 18,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // PWA `zapRecipientInfo`: gift vs buy heading.
            Text(
              widget.isGift
                  ? 'Gift Nymbot credits to @${widget.giftRecipientNym ?? 'user'}'
                  : 'Buy Nymbot private message credits',
              style: TextStyle(
                  color: c.textBright,
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 14),
            if (_invoice == null) ...[
              _tierToggle(c),
              const SizedBox(height: 12),
              _amountGrid(c),
              const SizedBox(height: 12),
              _customRow(c),
              const SizedBox(height: 10),
              _estimate(c),
              _pricingNote(c),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: c.danger, fontSize: 12)),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed:
                      (_loading || _amountSats == null) ? null : _generate,
                  style: FilledButton.styleFrom(backgroundColor: c.lightning),
                  icon: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.bolt),
                  label: Text(_loading
                      ? 'Generating invoice…'
                      : (widget.isGift ? 'Generate gift invoice' : 'Pay with Lightning')),
                ),
              ),
            ] else
              _InvoiceView(invoice: _invoice!, colors: c, onBack: () {
                setState(() => _invoice = null);
              }),
          ],
        ),
      ),
    );
  }

  /// `.bot-credit-tier-toggle`: two equal pills; the active one uses the
  /// lightning accent for BOTH Standard and Pro (zaps.js:432-440).
  Widget _tierToggle(NymColors c) {
    Widget seg(String label, CreditTier tier) {
      final active = _tier == tier;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() {
            _tier = tier;
            _invoice = null;
            // Reset the selection — preset sets differ per tier.
            _selectedPreset = null;
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: active
                  ? c.lightning.withValues(alpha: 0.12)
                  : Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: active ? c.lightning.withValues(alpha: 0.5) : c.border,
              ),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
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

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          seg('Standard', CreditTier.standard),
          seg('Pro', CreditTier.pro),
        ],
      ),
    );
  }

  /// The sats-preset grid (`.zap-amounts` in credit mode): each cell shows the
  /// sat label + the bulk-bonus credit count. Selected = lightning glow.
  Widget _amountGrid(NymColors c) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.5,
      children: [
        for (final sats in _presets)
          _amountBtn(c, sats),
      ],
    );
  }

  Widget _amountBtn(NymColors c, int sats) {
    final selected = _custom.text.trim().isEmpty && _selectedPreset == sats;
    final credits = _creditsForSats(sats);
    return GestureDetector(
      onTap: () => setState(() {
        _selectedPreset = sats;
        _custom.clear();
      }),
      child: Container(
        decoration: BoxDecoration(
          color: selected
              ? c.lightning.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? c.lightning.withValues(alpha: 0.5) : c.border,
          ),
          boxShadow: selected
              ? [BoxShadow(color: c.lightning.withValues(alpha: 0.15), blurRadius: 15)]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('${_satLabel(sats)} sats',
                style: TextStyle(
                    color: c.lightning,
                    fontSize: 15,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('$credits $_creditWord',
                style: TextStyle(color: c.textDim, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  /// Custom-amount field (`zapCustomAmount`).
  Widget _customRow(NymColors c) {
    return TextField(
      controller: _custom,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: TextStyle(color: c.text, fontSize: 14),
      decoration: InputDecoration(
        hintText: 'Custom amount (sats)',
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
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: c.lightning),
        ),
      ),
    );
  }

  /// Live credit estimate (`botCreditEstimate`).
  Widget _estimate(NymColors c) {
    final sats = _amountSats;
    if (sats == null) {
      return Text('Select or enter an amount',
          style: TextStyle(color: c.textDim, fontSize: 12));
    }
    final credits = _creditsForSats(sats);
    return Text(
      '≈ $credits ${_tier == CreditTier.pro ? "Pro" : "standard"} '
      'credit${credits == 1 ? '' : 's'}',
      style: TextStyle(color: c.text, fontSize: 13, fontWeight: FontWeight.w600),
    );
  }

  /// Pricing note (`.bot-credit-pricing-note`, zaps.js:466-480).
  Widget _pricingNote(NymColors c) {
    final lines = _tier == CreditTier.pro
        ? const [
            'Pro replies start at 1–2 Pro credits and scale with reply length '
                '(each model\'s range is in ?model).',
            'Bulk bonus: +10% at 5K sats, +15% at 10K, +20% at 50K.',
          ]
        : const [
            '1 credit per general chat, creative writing, or translation reply.',
            '2 credits per coding or reasoning/math reply (larger models).',
            'Bulk bonus: +10% at 500 sats, +15% at 1K, +20% at 5K.',
          ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(l,
                  style: TextStyle(color: c.textDim, fontSize: 11, height: 1.35)),
            ),
        ],
      ),
    );
  }

  Future<void> _generate() async {
    final sats = _amountSats;
    if (sats == null) {
      setState(() => _error = 'Please select or enter an amount');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    // Build the purchase comment exactly like the PWA (zaps.js:596-603) so the
    // worker memo reads e.g. "Nymbot credits gift for @nym — 100 messages".
    final isPro = _tier == CreditTier.pro;
    final credits = _creditsForSats(sats);
    final creditWord = isPro
        ? '$credits Pro credit${credits == 1 ? '' : 's'}'
        : '$credits message${credits == 1 ? '' : 's'}';
    final giftNym = widget.giftRecipientNym;
    final comment = giftNym != null
        ? 'Nymbot ${isPro ? 'Pro ' : ''}credits gift for @$giftNym — $creditWord'
        : 'Nymbot ${isPro ? 'Pro ' : ''}credits — $creditWord';

    BotInvoice? inv;
    try {
      inv = await ref.read(botChatControllerProvider.notifier).buy(
            sats,
            _tier,
            recipientPubkey: widget.giftRecipientPubkey,
            comment: comment,
          );
    } catch (_) {
      inv = null;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _invoice = inv ??
          BotInvoice(
            // Placeholder when the identity isn't bound (no live backend) so the
            // flow stays reviewable, mirroring the buy modal's stub.
            pr: 'lnbc${sats}n1p...stub-invoice-bind-identity-to-buy',
            invoiceId: 'stub',
            tier: _tier,
            amountSats: sats,
          );
    });
  }
}

/// The invoice screen (QR placeholder + copyable bolt11 + waiting state),
/// mirroring `displayZapInvoice` for the credit purchase.
class _InvoiceView extends StatelessWidget {
  const _InvoiceView({
    required this.invoice,
    required this.colors,
    required this.onBack,
  });

  final BotInvoice invoice;
  final NymColors colors;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Column(
      children: [
        Container(
          width: 200,
          height: 200,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
          ),
          alignment: Alignment.center,
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.qr_code_2, size: 96, color: Colors.black87),
              SizedBox(height: 4),
              Text('Lightning invoice',
                  style: TextStyle(color: Colors.black54, fontSize: 11)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SelectableText(
          invoice.pr,
          maxLines: 2,
          style: TextStyle(
              color: c.textDim, fontSize: 11, fontFamily: 'monospace'),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: invoice.pr)),
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: c.lightning),
                onPressed: () {},
                icon: const Icon(Icons.account_balance_wallet, size: 16),
                label: const Text('Open wallet'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('Waiting for payment…',
            style: TextStyle(color: c.textDim, fontSize: 11)),
        const SizedBox(height: 4),
        TextButton(
          onPressed: onBack,
          child: Text('Change amount', style: TextStyle(color: c.textDim)),
        ),
      ],
    );
  }
}
