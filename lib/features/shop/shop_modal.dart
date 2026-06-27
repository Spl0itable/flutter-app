import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/identity/modal_chrome.dart';
import '../../services/api/api_client.dart';
import '../../state/nostr_controller.dart';
import 'shop_catalog.dart';
import 'shop_controller.dart';
import 'shop_models.dart';
import 'shop_widgets.dart';

/// Reads the live [ShopIdentity] from the nostr controller (pubkey + signable
/// privkey), or null when there is no live signer.
ShopIdentity? _shopIdentity(WidgetRef ref) {
  final id = ref.read(nostrControllerProvider).identity;
  if (id == null) return null;
  return ShopIdentity(pubkey: id.pubkey, privkey: id.privkey);
}

/// The flair shop (`#shopModal`, docs/specs/04 §3). Tabs: Message Styles /
/// Nickname Flair / Special Items / Limited & Bundles / My Items. Each item is
/// a card with a cosmetic preview, price, and a Buy / Activate action. Buy opens
/// a Lightning-invoice QR flow (backend stubbed). A recovery-code field restores
/// purchases.
class ShopModal extends ConsumerStatefulWidget {
  const ShopModal({super.key});

  static Future<void> open(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => const ShopModal(),
    );
  }

  @override
  ConsumerState<ShopModal> createState() => _ShopModalState();
}

class _ShopModalState extends ConsumerState<ShopModal> {
  ShopTab _tab = ShopTab.styles;
  final _recoveryController = TextEditingController();

  @override
  void dispose() {
    _recoveryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: c.bgSecondary,
                borderRadius: NymRadius.rxl,
                border: Border.all(color: c.glassBorder),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 40,
                    offset: const Offset(0, 20),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.9,
                ),
                child: Stack(
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _header(c),
                        _tabs(c),
                        Flexible(child: _body(c)),
                      ],
                    ),
                    // `.shop-close`: 32×32 glass ✕ chip, absolute top-right
                    // (14,14), z-index 10 — the shared modal-close chrome.
                    ModalChrome.closeChip(c, () => Navigator.of(context).pop()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(NymColors c) {
    // `.shop-header` is a space-between flex Row: the title/subtitle block on
    // the left and the `.shop-recovery` restore field on the right. The close
    // ✕ is the separate absolute `.shop-close` chip (added in build), so the
    // header reserves right padding (40) to clear it.
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 24, 40, 24),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'FLAIR',
                  style: TextStyle(
                    color: c.primary,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Get addon packs to change the styling of your messages '
                  'and nickname that others will see across all channels '
                  '(only in the Nymchat app).',
                  style: TextStyle(color: c.textDim, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          _recoveryRow(c),
        ],
      ),
    );
  }

  Widget _recoveryRow(NymColors c) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 180,
          child: TextField(
            controller: _recoveryController,
            style: TextStyle(color: c.text, fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Recovery code',
              hintStyle: TextStyle(color: c.textDim, fontSize: 13),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: NymRadius.rxs,
                borderSide: BorderSide(color: c.glassBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: NymRadius.rxs,
                borderSide: BorderSide(color: c.glassBorder),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: _restore,
          style: TextButton.styleFrom(
            backgroundColor: c.primaryA(0.10),
            shape: RoundedRectangleBorder(
              borderRadius: NymRadius.rxs,
              side: BorderSide(color: c.primaryA(0.30)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          ),
          child: Text('Restore', style: TextStyle(color: c.primary)),
        ),
      ],
    );
  }

  Future<void> _restore() async {
    final code = _recoveryController.text.trim();
    if (!ShopController.isValidRecoveryCode(code)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid recovery code.')),
      );
      return;
    }
    final identity = _shopIdentity(ref);
    final ctrl = ref.read(shopControllerProvider.notifier);
    String message;
    if (identity == null) {
      message = 'Sign in to restore purchases.';
    } else {
      try {
        // Real `shop-redeem` round-trip (shop.js restorePurchases).
        final itemId = await ctrl.redeem(code, identity: identity);
        message = itemId != null
            ? 'Purchase restored!'
            : 'Unknown recovery code.';
      } catch (_) {
        // Backend host unreachable in this environment — tolerate gracefully.
        // TODO(verify): live `/api/storage` redeem.
        message = 'Could not reach the server. Try again later.';
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _tabs(NymColors c) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.1),
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final t in ShopTab.values) _tabButton(c, t),
          ],
        ),
      ),
    );
  }

  void _selectTab(ShopTab t) {
    setState(() => _tab = t);
    // Entering the limited tab kicks off the public supply fetch (F5).
    if (t == ShopTab.limited) {
      final ids = ShopCatalog.limited
          .where((i) => i.maxSupply != null)
          .map((i) => i.id)
          .toList();
      if (ids.isNotEmpty) {
        ref.read(shopControllerProvider.notifier).fetchSupply(ids);
      }
    }
  }

  Widget _tabButton(NymColors c, ShopTab t) {
    final active = _tab == t;
    return GestureDetector(
      onTap: () => _selectTab(t),
      child: Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: active ? c.primaryA(0.06) : Colors.transparent,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(NymRadius.xs),
            topRight: Radius.circular(NymRadius.xs),
          ),
          border: Border(
            bottom: BorderSide(
              color: active ? c.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          t.label,
          style: TextStyle(
            color: active ? c.primary : c.textDim,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// Fixed card width (mirrors the PWA `.shop-items` flex columns); cards size to
  /// their content height so taller inventory/bundle cards don't overflow.
  static const double _cardWidth = 214;

  Widget _body(NymColors c) {
    final state = ref.watch(shopControllerProvider);
    if (_tab == ShopTab.inventory) {
      return _inventoryBody(c, state);
    }
    if (_tab == ShopTab.limited) {
      return _limitedBody(c, state);
    }
    final items = _itemsForTab(_tab, state);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: _cardWrap(c, state, items),
    );
  }

  /// A wrapping row of item cards (PWA `.shop-items` flex-wrap).
  Widget _cardWrap(NymColors c, ShopState state, List<ShopItem> items) {
    // PWA `.shop-items { grid-template-columns: repeat(auto-fill,
    // minmax(200px,1fr)); gap: 20px }` (styles-features.css:116-121): as many
    // >=200px columns as fit the width, each stretching to share the row equally
    // — a fluid grid, not fixed 214px cards with a ragged right edge.
    const gap = 20.0;
    const minCard = 200.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final fit = ((w + gap) / (minCard + gap)).floor();
        final cols = fit < 1 ? 1 : fit;
        final cardW = (w - (cols - 1) * gap) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final item in items)
              SizedBox(width: cardW, child: _card(c, state, item)),
          ],
        );
      },
    );
  }

  Widget _card(
    NymColors c,
    ShopState state,
    ShopItem item, {
    bool inventory = false,
    ShopAvailability? availability,
  }) {
    return _ShopItemCard(
      item: item,
      owned: state.owns(item.id),
      active: _isActive(item, state.active),
      inventory: inventory,
      ownedItem: inventory ? state.owned[item.id] : null,
      availability: availability,
      // Stamp a sample Genesis edition (#69) only on the unowned preview; the
      // inventory shows the owner's real edition via ShopEditionNumber instead.
      sampleEdition:
          (!inventory && item.id == 'flair-genesis') ? 69 : null,
      onBuy: () => _buy(item),
      onActivate: () => _activate(item),
      onGift: () => _gift(item),
      onTransfer: () => _transfer(item),
    );
  }

  /// The Limited & Bundles tab (F5/F6): limited drops with supply badges +
  /// soldout/soon/ended gating, then bundles with content chips + savings. The
  /// supply fetch is kicked off when the tab is selected (`_selectTab`).
  Widget _limitedBody(NymColors c, ShopState state) {
    final ctrl = ref.read(shopControllerProvider.notifier);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Each section title renders only when its list is non-empty
          // (shop.js:920/927 — `if (limited.length)` / `if (bundles.length)`).
          if (ShopCatalog.limited.isNotEmpty) ...[
            _categoryTitle(c, 'Limited Editions'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final item in ShopCatalog.limited)
                  SizedBox(
                    width: _cardWidth,
                    child: _card(
                      c,
                      state,
                      item,
                      availability: ctrl.availability(item),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 24),
          ],
          if (ShopCatalog.bundles.isNotEmpty) ...[
            _categoryTitle(c, 'Bundles'),
            const SizedBox(height: 12),
            _cardWrap(c, state, ShopCatalog.bundles),
          ],
        ],
      ),
    );
  }

  /// The My Items (inventory) tab (F9): a live self-message preview, the
  /// active-items summary blocks, then every purchased item with its edition #,
  /// acquired date, recovery code and Transfer action.
  Widget _inventoryBody(NymColors c, ShopState state) {
    final owned = state.owned.keys
        .map(ShopCatalog.byId)
        .whereType<ShopItem>()
        .toList();
    if (owned.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Text(
          'No items purchased yet',
          textAlign: TextAlign.center,
          style: TextStyle(color: c.textDim),
        ),
      );
    }
    final active = state.active;
    final activeStyle = active.style != null
        ? ShopCatalog.byId(active.style!)
        : null;
    final activeFlairs = active.flair
        .map(ShopCatalog.byId)
        .whereType<ShopItem>()
        .toList();
    final activeCosmetics = active.cosmetics
        .map(ShopCatalog.byId)
        .whereType<ShopItem>()
        .toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _categoryTitle(c, 'My Items'),
          const SizedBox(height: 12),
          _ActiveItemsPreview(active: active),
          if (activeStyle != null)
            _ActiveSummaryBlock(
              title: 'Active Message Style',
              // `Active Message Style` chip is name-only (shop.js:984).
              chips: [_ActiveChip(name: activeStyle.name)],
            ),
          if (activeFlairs.isNotEmpty)
            _ActiveSummaryBlock(
              title: 'Active Nickname Flair',
              // `${f.name} ${f.icon}` — name then trailing icon (shop.js:993).
              chips: [
                for (final f in activeFlairs)
                  _ActiveChip(name: f.name, icon: f.icon, iconLeading: false),
              ],
            ),
          if (activeCosmetics.isNotEmpty)
            _ActiveSummaryBlock(
              title: 'Active Special Items',
              // `${it.icon} ${it.name}` — leading icon then name (shop.js:1003).
              chips: [
                for (final x in activeCosmetics)
                  _ActiveChip(name: x.name, icon: x.icon, iconLeading: true),
              ],
            ),
          const SizedBox(height: 8),
          _categoryTitle(c, 'All Purchased Items'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final item in owned)
                SizedBox(
                  width: _cardWidth,
                  child: _card(c, state, item, inventory: true),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// The `.shop-category-title`: primary, 18px 700, bottom hairline.
  Widget _categoryTitle(NymColors c, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: c.primary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  List<ShopItem> _itemsForTab(ShopTab tab, ShopState state) {
    switch (tab) {
      case ShopTab.styles:
        return ShopCatalog.styles;
      case ShopTab.flair:
        return ShopCatalog.flair;
      case ShopTab.special:
        return ShopCatalog.special;
      case ShopTab.limited:
        return [...ShopCatalog.limited, ...ShopCatalog.bundles];
      case ShopTab.inventory:
        return state.owned.keys
            .map(ShopCatalog.byId)
            .whereType<ShopItem>()
            .toList();
    }
  }

  bool _isActive(ShopItem item, ActiveItems active) {
    switch (item.type) {
      case 'message-style':
        return active.style == item.id;
      case 'nickname-flair':
        return active.flair.contains(item.id);
      case 'cosmetic':
        return active.cosmetics.contains(item.id);
      case 'supporter':
        return active.supporter;
      default:
        return false;
    }
  }

  Future<void> _activate(ShopItem item) async {
    final ctrl = ref.read(shopControllerProvider.notifier);
    switch (item.type) {
      case 'message-style':
        await ctrl.toggleStyle(item.id);
      case 'nickname-flair':
        await ctrl.toggleFlair(item.id);
      case 'cosmetic':
        await ctrl.toggleCosmetic(item.id);
      case 'supporter':
        await ctrl.toggleSupporter();
    }
    // Push the new active set to D1 so other clients render it via shop-status
    // (shop.js `publishActiveShopItems`). Best-effort; no-ops without a signer.
    final identity = _shopIdentity(ref);
    if (identity != null) await ctrl.publishActiveItems(identity);
  }

  Future<void> _buy(ShopItem item) async {
    final identity = _shopIdentity(ref);
    final granted = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => _InvoiceDialog(item: item, identity: identity),
    );
    if (granted == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${item.name} unlocked!')),
      );
    }
  }

  /// Gift [item] to another user (shop.js `promptGiftShopItem` →
  /// `executeGiftShopItem`): prompt for a recipient hex pubkey, then settle the
  /// gift via the normal buy→claim with `recipientPubkey` set.
  Future<void> _gift(ShopItem item) async {
    final identity = _shopIdentity(ref);
    final recipient = await _promptRecipientPubkey(
      title: 'Gift Item',
      item: item,
      description:
          "Enter the recipient's hex pubkey (64 characters). You pay for the "
          'item and it lands directly in their inventory.',
      selfPubkey: identity?.pubkey,
      selfMessage: 'Use Buy to purchase an item for yourself.',
      // Gift modal: "Continue" CTA + price row (shop.js:1620, 1630).
      ctaLabel: 'Continue',
      showPrice: true,
    );
    if (recipient == null || !mounted) return;
    await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => _InvoiceDialog(
        item: item,
        identity: identity,
        recipientPubkey: recipient,
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gift sent: ${item.name}')),
      );
    }
  }

  /// Transfer an owned [item] to another user (shop.js `promptTransferShopItem`
  /// → `executeTransferShopItem`): prompt for a recipient hex pubkey, then
  /// `shop-transfer` — revoking it locally and assigning it to the recipient.
  Future<void> _transfer(ShopItem item) async {
    final identity = _shopIdentity(ref);
    if (identity == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in to transfer items.')),
      );
      return;
    }
    final recipient = await _promptRecipientPubkey(
      title: 'Transfer Item',
      item: item,
      description:
          "Enter the recipient's hex pubkey (64 characters). The item will be "
          'revoked from your inventory and assigned to theirs.',
      selfPubkey: identity.pubkey,
      selfMessage: 'You already own this item.',
      // Transfer modal: "Confirm" CTA + no price (shop.js:1698-1702, 1711).
      ctaLabel: 'Confirm',
      showPrice: false,
    );
    if (recipient == null || !mounted) return;
    try {
      await ref
          .read(shopControllerProvider.notifier)
          .transfer(item.id, recipient, identity: identity);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${item.name} transferred.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Transfer failed: $e')),
        );
      }
    }
  }

  /// Shared recipient-pubkey prompt for gift/transfer. Validates the 64-hex
  /// format and rejects the self pubkey, mirroring the PWA's gift/transfer
  /// modals. Returns the lowercased pubkey, or null on cancel.
  Future<String?> _promptRecipientPubkey({
    required String title,
    required ShopItem item,
    required String description,
    String? selfPubkey,
    required String selfMessage,
    required String ctaLabel,
    required bool showPrice,
  }) {
    return showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => _RecipientPubkeyDialog(
        title: title,
        item: item,
        description: description,
        selfPubkey: selfPubkey,
        selfMessage: selfMessage,
        ctaLabel: ctaLabel,
        showPrice: showPrice,
      ),
    );
  }
}

class _ShopItemCard extends StatelessWidget {
  const _ShopItemCard({
    required this.item,
    required this.owned,
    required this.active,
    required this.inventory,
    required this.onBuy,
    required this.onActivate,
    required this.onGift,
    required this.onTransfer,
    this.ownedItem,
    this.availability,
    this.sampleEdition,
  });

  final ShopItem item;
  final bool owned;
  final bool active;

  /// True when rendered inside the inventory ("My Items") tab — owned items
  /// there expose a Transfer action (shop.js inventory render).
  final bool inventory;
  final VoidCallback onBuy;
  final VoidCallback onActivate;
  final VoidCallback onGift;
  final VoidCallback onTransfer;

  /// The owned record (inventory tab) — surfaces edition #, acquired date and
  /// recovery code (F9).
  final OwnedItem? ownedItem;

  /// Limited-tab availability — supply badge + soldout/soon/ended gating (F5).
  final ShopAvailability? availability;

  /// Sample edition stamped on a flair preview (e.g. Genesis #69 in the
  /// limited tab); only affects the preview, not real ownership.
  final int? sampleEdition;

  /// Gates the inventory TRANSFER action: a bundle has no single recovery code
  /// to transfer, so only single owned items expose Transfer. (GIFT on the shop
  /// tabs is handled in [_actions], where bundles ARE giftable per the PWA.)
  bool get _giftable => item.type != 'bundle';

  bool get _isBundle => item.type == 'bundle';

  /// True when a limited item is not currently buyable (soon/ended/soldout) —
  /// the Buy button is replaced with the status label (F5).
  bool get _blockedByAvailability =>
      availability != null && !availability!.isAvailable;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final legendary = item.isLegendary;
    final card = Container(
      // `.shop-item { padding: 18px }` (styles-features.css:123-132).
      padding: const EdgeInsets.all(18),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        // `.shop-item-legendary { background: linear-gradient(160deg,
        // rgba(255,196,64,.06), rgba(255,120,200,.04)) }` — a faint gold→pink
        // wash (styles-features.css:1306-1310). Non-legendary cards keep the
        // flat owned/base fill.
        color: legendary
            ? null
            : (owned
                ? c.secondaryA(0.04)
                : Colors.white.withValues(alpha: 0.03)),
        gradient: legendary
            ? const LinearGradient(
                begin: Alignment(-0.342, -0.940), // CSS 160deg
                end: Alignment(0.342, 0.940),
                colors: [Color(0x0FFFC440), Color(0x0AFF78C8)],
              )
            : null,
        border: Border.all(
          color: legendary
              ? const Color(0x80FFC440)
              : (owned ? c.secondaryA(0.20) : c.glassBorder),
        ),
        borderRadius: NymRadius.rmd,
        boxShadow: legendary
            ? const [BoxShadow(color: Color(0x2EFFB428), blurRadius: 18)]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // `.shop-item-icon` uses currentColor (= var(--text)) for legendary and
          // non-legendary alike — there is no `.shop-item-legendary .shop-item-icon`
          // override in the PWA (styles-features.css:161-165). Always tint c.text.
          ShopSvgIcon(
            svg: item.icon,
            size: 32,
            color: c.text,
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  item.name,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: c.text,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              // Inventory: gold edition number after the name (F9).
              if (ownedItem?.edition != null) ...[
                const SizedBox(width: 6),
                ShopEditionNumber(
                  edition: ownedItem!.edition!,
                  editionMax: ownedItem!.editionMax,
                ),
              ],
            ],
          ),
          // Per-card description — the PWA renders `.shop-item-description` on
          // EVERY card type (styles/flair/special/limited/bundle/inventory;
          // shop.js:737,757,800,877,908,1022), not just the inventory tab.
          const SizedBox(height: 4),
          Text(
            item.description,
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
          // Inventory: acquired date (F9).
          if (inventory && ownedItem != null) ...[
            const SizedBox(height: 6),
            Text(
              'Acquired: ${_formatDate(ownedItem!.timestamp)}',
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textDim, fontSize: 10),
            ),
          ],
          const SizedBox(height: 8),
          // Limited-tab supply badge (F5).
          if (availability != null && availability!.label.isNotEmpty) ...[
            Center(child: ShopSupplyBadge(availability: availability!)),
            const SizedBox(height: 8),
          ],
          // Preview region: bundle chips (F6) or the standard item preview (F4).
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            alignment: Alignment.center,
            // `.shop-item-preview { min-height: 50px }` (styles-features.css:181-193).
            constraints: const BoxConstraints(minHeight: 50),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              border: Border.all(color: c.glassBorder),
              borderRadius: NymRadius.rsm,
            ),
            child: _isBundle
                ? ShopBundlePreview(item: item)
                : (sampleEdition != null && item.type == 'nickname-flair'
                    ? _flairSamplePreview(c)
                    // The inventory supporter card shows a single supporter-badge
                    // preview row (shop.js:1048), not the full special preview.
                    : (inventory && item.type == 'supporter'
                        ? const SupporterBadge()
                        : ShopItemPreview(item: item))),
          ),
          const SizedBox(height: 10),
          if (_blockedByAvailability)
            // Limited soon/ended/soldout: the PWA replaces the whole footer with
            // just the availability label — NO price row, no buttons
            // (shop.js:870, the `else` footer branch).
            Text(
              availability!.label,
              style: TextStyle(color: c.textDim, fontSize: 12),
            )
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // `.shop-price-amount`: ⚡ {price} sats — lightning, 16px bold
                // (styles-features.css:204-208).
                Row(
                  children: [
                    // `.shop-price-amount` prefixes a literal "⚡" emoji in the PWA
                    // (`<span class="shop-price-amount">⚡ ${price} sats</span>`).
                    const Text('⚡',
                        style: TextStyle(
                            fontSize: 16, color: Color(0xFFF7931A))),
                    const SizedBox(width: 2),
                    Text(
                      '${item.price} sats',
                      style: const TextStyle(
                        color: Color(0xFFF7931A),
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _actions(c),
                  ),
                ),
              ],
            ),
          // Inventory: recovery code + transfer (F9).
          if (inventory && owned) ...[
            if (ownedItem?.code != null && ownedItem!.code!.isNotEmpty)
              RecoveryCodeRow(code: ownedItem!.code!),
            if (_giftable) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: _PillButton(
                    label: 'TRANSFER TO PUBKEY', onTap: onTransfer),
              ),
            ],
          ],
        ],
      ),
    );
    if (!legendary && !owned) return card;
    // Overlays: the legendary 45deg corner ribbon (F14, clipped to the card's
    // rounded corner — PWA `.shop-item { overflow:hidden }` — while the card
    // keeps its outer gold glow a whole-stack clip would crop), and/or the
    // `✓ OWNED` corner pill on purchased cards (`.shop-item.purchased::after`).
    return Stack(
      children: [
        card,
        if (legendary)
          Positioned.fill(
            child: ClipRRect(
              borderRadius: NymRadius.rmd,
              child: const Stack(children: [ShopLegendaryRibbon()]),
            ),
          ),
        if (owned) const Positioned(top: 8, left: 8, child: _OwnedBadge()),
      ],
    );
  }

  Widget _actions(NymColors c) {
    // Bundles are never individually owned/activatable — always BUY + GIFT
    // (_renderBundleCard → _shopItemActionsHtml, shop.js:911).
    if (_isBundle) {
      return _buyGiftRow();
    }
    // Inventory tab is the only place ACTIVATE lives (shop.js renderInventory);
    // on the shop tabs an owned item shows GIFT (regular) or nothing (limited),
    // never ACTIVATE.
    if (inventory) {
      return _ActivateButton(active: active, onTap: onActivate, item: item);
    }
    if (owned) {
      // `_shopItemOwnedHtml(item, allowGift)`: regular owned → price + GIFT
      // (allowGift true); limited owned → price only (allowGift false,
      // shop.js:869).
      return availability != null
          ? const SizedBox.shrink()
          : _PillButton(label: 'GIFT', onTap: onGift);
    }
    // Not owned: BUY + GIFT (`_shopItemActionsHtml` always shows both).
    return _buyGiftRow();
  }

  Widget _buyGiftRow() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PillButton(label: 'GIFT', onTap: onGift),
          const SizedBox(width: 6),
          _BuyButton(onTap: onBuy),
        ],
      );

  /// The flair preview with a stamped sample edition (Genesis #69), used in the
  /// limited tab (`_renderLimitedCard`).
  Widget _flairSamplePreview(NymColors c) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Your_Nick', style: TextStyle(fontWeight: FontWeight.w600)),
        FlairBadge(flairId: item.id, edition: sampleEdition),
      ],
    );
  }

  /// `M/D/YYYY` from a ms-epoch timestamp (matches the inventory acquired date).
  static String _formatDate(int msEpoch) {
    final d = DateTime.fromMillisecondsSinceEpoch(msEpoch);
    return '${d.month}/${d.day}/${d.year}';
  }
}

/// The `✓ OWNED` corner pill on a purchased card (`.shop-item.purchased::after`,
/// styles-features.css:147-159): secondary text, 10px 500, `secondary@.1` bg,
/// `secondary@.25` border, radius 20, padding `3px 8px`.
class _OwnedBadge extends StatelessWidget {
  const _OwnedBadge();

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.secondaryA(0.10),
        border: Border.all(color: c.secondaryA(0.25)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '✓ OWNED',
        style: TextStyle(
          color: c.secondary,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// A small outlined pill action (Gift / Transfer), styled like the Bitcoin-orange
/// Buy button but in the muted secondary accent.
class _PillButton extends StatelessWidget {
  const _PillButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: c.secondaryA(0.4)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: c.secondary,
            fontWeight: FontWeight.w500,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

/// The live "Preview" self-message at the top of the inventory tab
/// (`_renderActiveItemsPreview`): your nym with the active style + flair +
/// supporter + cosmetics, over "This is how your messages look." Built locally
/// from [ShopCatalog] visuals + the shop's badge widgets.
class _ActiveItemsPreview extends ConsumerWidget {
  const _ActiveItemsPreview({required this.active});

  final ActiveItems active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final supporter = active.supporter;
    final cosmetics =
        active.cosmetics.where((x) => x != 'cosmetic-redacted').toList();
    final redacted = active.cosmetics.contains('cosmetic-redacted');
    final hasActive = active.style != null ||
        supporter ||
        cosmetics.isNotEmpty ||
        active.flair.isNotEmpty;
    if (!hasActive) return const SizedBox.shrink();

    final id = ref.watch(nostrControllerProvider).identity;
    final nym = id != null ? stripPubkeySuffix(id.nym) : 'You';
    final suffix = id != null ? getPubkeySuffix(id.pubkey) : '';
    final flairId = active.flair.isNotEmpty ? active.flair.last : null;
    final isGenesis = flairId == 'flair-genesis';
    final edition = flairId != null ? active.editions[flairId] : null;

    // Author line: <nym#suffix> + flair + supporter badge. Genesis bolds the
    // nym (suffix stays w400); redacted dims the author.
    final authorColor = redacted ? c.textDim : c.secondary;
    final author = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                text: '<$nym',
                style: TextStyle(
                  color: authorColor,
                  fontWeight: isGenesis ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
              TextSpan(
                text: '#$suffix>',
                style: TextStyle(color: authorColor, fontWeight: FontWeight.w400),
              ),
            ]),
          ),
        ),
        if (flairId != null)
          // `.flair-badge` = 20px (the PWA renders the preview nym's flair at the
          // standard size, styles-features.css:316-320).
          FlairBadge(flairId: flairId, edition: edition),
        if (supporter) const SupporterBadge(),
      ],
    );

    // Content bubble: active style's text treatment + cosmetic aura.
    Widget content;
    if (redacted) {
      content = const ShopCosmeticBubblePreview(
        cosmeticId: 'cosmetic-redacted',
      );
    } else if (active.style != null &&
        ShopCatalog.styleVisuals.containsKey(active.style)) {
      content = ShopStyleBubblePreview(
        styleId: active.style!,
        text: 'This is how your messages look.',
      );
    } else if (supporter) {
      content = const _SupporterContentLine();
    } else {
      content = Text(
        'This is how your messages look.',
        style: TextStyle(color: c.text, fontSize: 12),
      );
    }
    // Wrap in the first active aura cosmetic's bubble decoration, if any.
    if (cosmetics.isNotEmpty &&
        ShopCatalog.cosmeticVisuals.containsKey(cosmetics.first)) {
      final v = ShopCatalog.cosmeticVisuals[cosmetics.first]!;
      content = Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: v.borderLeft != null
              ? Border(left: BorderSide(color: v.borderLeft!, width: 3))
              : null,
          boxShadow: v.boxShadows,
        ),
        child: content,
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.secondaryA(0.04),
        border: Border.all(color: c.secondaryA(0.20)),
        borderRadius: NymRadius.rsm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Preview',
              style: TextStyle(color: c.secondary, fontSize: 14)),
          const SizedBox(height: 10),
          author,
          const SizedBox(height: 6),
          Align(alignment: Alignment.centerLeft, child: content),
        ],
      ),
    );
  }
}

/// The supporter content line ("This is how your messages look." in gold).
class _SupporterContentLine extends StatelessWidget {
  const _SupporterContentLine();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x14FFD700),
        border:
            const Border(left: BorderSide(color: Color(0xFFFFD700), width: 3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        'This is how your messages look.',
        style: TextStyle(
          color: Color(0xFFFFD700),
          fontSize: 12,
          shadows: [Shadow(color: Color(0x40FFD700), blurRadius: 8)],
        ),
      ),
    );
  }
}

/// One `.shop-active-item` chip: a name and (for flair / special items) the
/// item's inline SVG icon, ordered to match the PWA (`iconLeading` = special
/// items `${icon} ${name}`; trailing = flair `${name} ${icon}`).
class _ActiveChip {
  const _ActiveChip({required this.name, this.icon, this.iconLeading = true});

  final String name;
  final String? icon;
  final bool iconLeading;
}

/// An active-items summary block (`.shop-active-items`): a secondary-tinted
/// panel with a title + a row of pill chips (F9).
class _ActiveSummaryBlock extends StatelessWidget {
  const _ActiveSummaryBlock({required this.title, required this.chips});

  final String title;
  final List<_ActiveChip> chips;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.secondaryA(0.04),
        border: Border.all(color: c.secondaryA(0.20)),
        borderRadius: NymRadius.rsm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: c.secondary, fontSize: 14)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              for (final chip in chips)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: c.secondaryA(0.10),
                    border: Border.all(color: c.secondary),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (chip.icon != null && chip.iconLeading) ...[
                        ShopSvgIcon(svg: chip.icon!, size: 14, color: c.text),
                        const SizedBox(width: 5),
                      ],
                      Text(chip.name,
                          style: TextStyle(color: c.text, fontSize: 12)),
                      if (chip.icon != null && !chip.iconLeading) ...[
                        const SizedBox(width: 5),
                        ShopSvgIcon(svg: chip.icon!, size: 14, color: c.text),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The recipient-pubkey prompt shared by gift/transfer (shop.js gift/transfer
/// modals): a 64-hex pubkey field with inline validation.
class _RecipientPubkeyDialog extends StatefulWidget {
  const _RecipientPubkeyDialog({
    required this.title,
    required this.item,
    required this.description,
    required this.selfPubkey,
    required this.selfMessage,
    required this.ctaLabel,
    required this.showPrice,
  });

  final String title;
  final ShopItem item;
  final String description;
  final String? selfPubkey;
  final String selfMessage;

  /// CTA verb — "Continue" for the gift modal (shop.js:1630), "Confirm" for the
  /// transfer modal (shop.js:1711).
  final String ctaLabel;

  /// The gift modal shows the price row (shop.js:1620); the transfer modal shows
  /// only icon+name with no price (shop.js:1698-1702).
  final bool showPrice;

  @override
  State<_RecipientPubkeyDialog> createState() => _RecipientPubkeyDialogState();
}

class _RecipientPubkeyDialogState extends State<_RecipientPubkeyDialog> {
  final _controller = TextEditingController();
  static final _hexRe = RegExp(r'^[0-9a-f]{64}$');
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final pk = _controller.text.trim().toLowerCase();
    if (!_hexRe.hasMatch(pk)) {
      setState(() => _error = 'Invalid pubkey. Must be 64 hex characters.');
      return;
    }
    if (widget.selfPubkey != null && pk == widget.selfPubkey) {
      setState(() => _error = widget.selfMessage);
      return;
    }
    Navigator.of(context).pop(pk);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            margin: const EdgeInsets.all(20),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: c.bgSecondary,
              borderRadius: NymRadius.rxl,
              border: Border.all(color: c.glassBorder),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.title,
                  style: TextStyle(
                    color: c.text,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    ShopSvgIcon(svg: widget.item.icon, size: 24, color: c.text),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.item.name,
                        style: TextStyle(
                          color: c.text,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (widget.showPrice)
                      Text(
                        '${widget.item.price} sats',
                        style: const TextStyle(
                          color: Color(0xFFF7931A),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  widget.description,
                  style: TextStyle(color: c.textDim, fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  style: TextStyle(color: c.text, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Recipient hex pubkey (64 chars)',
                    hintStyle: TextStyle(color: c.textDim),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: c.glassBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: c.secondaryA(0.5)),
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 12),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: _submit,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: c.secondaryA(0.18),
                            border: Border.all(color: c.secondaryA(0.4)),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(widget.ctaLabel,
                              style: TextStyle(color: c.secondary)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: c.glassBorder),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text('Cancel',
                            style: TextStyle(color: c.textDim)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BuyButton extends StatelessWidget {
  const _BuyButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0x26F7931A), Color(0x14F7931A)],
          ),
          border: Border.all(color: const Color(0x59F7931A)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          'BUY',
          style: TextStyle(
            color: Color(0xFFF7931A),
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _ActivateButton extends StatelessWidget {
  const _ActivateButton({
    required this.active,
    required this.onTap,
    required this.item,
  });
  final bool active;
  final VoidCallback onTap;
  final ShopItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Bundles aren't toggleable; show an owned chip instead.
    if (item.type == 'bundle') {
      return Text('Owned',
          style: TextStyle(color: c.secondary, fontSize: 12));
    }
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: active ? c.secondaryA(0.18) : Colors.transparent,
          border: Border.all(color: c.secondaryA(0.4)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          // PWA toggles the verb ACTIVATE/DEACTIVATE (shop.js:1032-1051), not an
          // "Active" state chip.
          active ? 'DEACTIVATE' : 'ACTIVATE',
          style: TextStyle(color: c.secondary, fontSize: 12),
        ),
      ),
    );
  }
}

/// The Lightning-invoice dialog shown when buying. Fetches a real
/// `shop-buy-invoice` bolt11 (shop.js `generateShopPaymentInvoice`), shows its
/// QR + copy + open-wallet, then polls `shop-check` (2s × 180) and on payment
/// runs `shop-claim` to grant the item, mirroring `handleShopPaymentSuccess`.
///
/// TODO(verify): the live `/api/storage` host is unreachable in this
/// environment, so the network call may fail — the dialog surfaces the error
/// and offers a manual "I've paid" fallback that grants locally.
class _InvoiceDialog extends ConsumerStatefulWidget {
  const _InvoiceDialog({
    required this.item,
    required this.identity,
    this.recipientPubkey,
  });

  final ShopItem item;
  final ShopIdentity? identity;

  /// When set, this is a gift purchase — the item lands in [recipientPubkey]'s
  /// inventory instead of the buyer's (shop.js `purchaseItem(id, recipient)`).
  final String? recipientPubkey;

  @override
  ConsumerState<_InvoiceDialog> createState() => _InvoiceDialogState();
}

enum _BuyPhase { generating, invoice, claiming, paid, error }

class _InvoiceDialogState extends ConsumerState<_InvoiceDialog> {
  final _api = ApiClient();
  _BuyPhase _phase = _BuyPhase.generating;
  String _status = '';
  ShopInvoice? _invoice;
  Timer? _pollTimer;

  // Purchase-success details revealed in the `paid` phase (F10).
  bool _isGift = false;
  String? _successCode;
  int? _successEdition;
  int? _successEditionMax;

  /// Per-component recovery codes for a bundle purchase: (name, code).
  List<({String name, String code})> _bundleCodes = const [];

  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _api.dispose();
    super.dispose();
  }

  ShopController get _ctrl => ref.read(shopControllerProvider.notifier);

  Future<void> _generate() async {
    final identity = widget.identity;
    if (identity == null) {
      setState(() {
        _phase = _BuyPhase.error;
        _status = 'Sign in to buy flair.';
      });
      return;
    }
    try {
      final inv = await _ctrl.buy(
        widget.item.id,
        identity: identity,
        recipientPubkey: widget.recipientPubkey,
      );
      if (!mounted) return;
      setState(() {
        _invoice = inv;
        _phase = _BuyPhase.invoice;
      });
      _startPolling(inv, identity);
    } catch (e) {
      if (!mounted) return;
      // Backend unreachable in this environment — fall back to the manual
      // confirmation path. TODO(verify): live `/api/storage` shop-buy-invoice.
      setState(() {
        _phase = _BuyPhase.error;
        _status = 'Could not reach the server.';
      });
    }
  }

  void _startPolling(ShopInvoice inv, ShopIdentity identity) {
    if (inv.invoiceId.isEmpty) return;
    var checks = 0;
    // shop.js checkShopPaymentViaServer: every 2s, up to 180 (~6 min).
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      checks++;
      final paid = await _ctrl.checkPaid(inv.invoiceId, identity: identity);
      if (!mounted) return;
      if (paid) {
        t.cancel();
        await _claim(inv, identity);
      } else if (checks >= 180) {
        t.cancel();
        setState(() {
          _phase = _BuyPhase.error;
          _status = 'Payment timeout - please check your wallet';
        });
      }
    });
  }

  Future<void> _claim(ShopInvoice inv, ShopIdentity identity) async {
    setState(() => _phase = _BuyPhase.claiming);
    try {
      final data = await _ctrl.claim(inv.invoiceId, identity: identity);
      if (!mounted) return;
      _captureSuccess(data);
      // A limited purchase changes remaining supply; force a refresh next view.
      if (widget.item.maxSupply != null) _ctrl.invalidateSupply();
      setState(() => _phase = _BuyPhase.paid);
      // shop.js: don't auto-close while a recovery code is on screen — the user
      // must tap Close to dismiss so they can save it. With no code (e.g. a
      // gift), auto-close after 2s.
      if (!_hasRecoveryReveal) {
        Future<void>.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.of(context).pop(true);
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _BuyPhase.error;
        _status = 'Claim failed - your payment is safe, try restoring later.';
      });
    }
  }

  /// Extracts the recovery code / edition / bundle codes from a `shop-claim`
  /// response (shop.js `_renderShopSuccess`).
  void _captureSuccess(Map<String, dynamic> data) {
    _isGift = data['gift'] == true;
    final edition = data['edition'];
    if (edition is Map) {
      _successEdition = (edition['n'] as num?)?.toInt();
      _successEditionMax = (edition['max'] as num?)?.toInt();
    }
    final bundle = data['bundle'];
    if (!_isGift && bundle is List) {
      _bundleCodes = [
        for (final b in bundle)
          if (b is Map && b['code'] != null)
            (
              name: ShopCatalog.byId(b['itemId']?.toString() ?? '')?.name ??
                  (b['itemId']?.toString() ?? ''),
              code: b['code'].toString(),
            ),
      ];
    }
    // Single-item recovery code (not shown for gifts).
    if (!_isGift && _bundleCodes.isEmpty) {
      _successCode = data['code']?.toString();
    }
  }

  /// True when the success view shows a recovery code (single or bundle) that
  /// must be saved before dismissing.
  bool get _hasRecoveryReveal =>
      !_isGift &&
      ((_successCode != null && _successCode!.isNotEmpty) ||
          _bundleCodes.isNotEmpty);

  Future<void> _copy() async {
    final pr = _invoice?.pr;
    if (pr != null) await Clipboard.setData(ClipboardData(text: pr));
  }

  Future<void> _openWallet() async {
    final pr = _invoice?.pr;
    if (pr == null) return;
    final uri = Uri.parse(
        pr.toLowerCase().startsWith('lightning:') ? pr : 'lightning:$pr');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: pr));
    }
  }

  /// Offline fallback for the unreachable-backend case: grant locally, then show
  /// the same success reveal (recovery code + edition) as the online path so the
  /// user can still save their code. Gifts land in the recipient's inventory, so
  /// a gift grants nothing here and just closes.
  Future<void> _manualConfirm() async {
    if (widget.recipientPubkey != null) {
      _isGift = true;
      if (mounted) Navigator.of(context).pop(true);
      return;
    }
    await _ctrl.claimAfterPayment(widget.item.id);
    if (widget.item.maxSupply != null) _ctrl.invalidateSupply();
    // Surface the locally-granted code + edition from the persisted record.
    final granted = ref.read(shopControllerProvider).owned[widget.item.id];
    _successCode = granted?.code;
    _successEdition = granted?.edition;
    _successEditionMax = granted?.editionMax;
    if (!mounted) return;
    setState(() => _phase = _BuyPhase.paid);
    if (!_hasRecoveryReveal) {
      Future<void>.delayed(const Duration(seconds: 2), () {
        if (mounted) Navigator.of(context).pop(true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Material(
            color: c.bgSecondary,
            borderRadius: NymRadius.rxl,
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.85,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Purchasing ${widget.item.name}',
                      style: TextStyle(
                        color: c.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text('${widget.item.price} sats',
                        style: TextStyle(color: c.textDim, fontSize: 13)),
                    const SizedBox(height: 16),
                    ..._phaseBody(c),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _phaseBody(NymColors c) {
    switch (_phase) {
      case _BuyPhase.generating:
        return [
          const SizedBox(height: 8),
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text('Generating invoice...',
              style: TextStyle(color: c.textDim, fontSize: 12)),
          const SizedBox(height: 8),
          _cancelButton(c),
        ];
      case _BuyPhase.claiming:
        return [
          const SizedBox(height: 8),
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text('Payment received — unlocking...',
              style: TextStyle(color: c.textDim, fontSize: 12)),
        ];
      case _BuyPhase.paid:
        return [
          const SizedBox(height: 8),
          const Text('✅', style: TextStyle(fontSize: 32)),
          const SizedBox(height: 8),
          Text(
            _isGift ? 'Gift sent!' : 'Purchase successful!',
            style: TextStyle(color: c.text, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(widget.item.name,
              style: TextStyle(color: c.textBright, fontSize: 16)),
          // Edition number (F10): "Edition #n of max".
          if (_successEdition != null) ...[
            const SizedBox(height: 10),
            Text(
              'Edition #$_successEdition of ${_successEditionMax ?? '?'}',
              style: TextStyle(color: c.text, fontSize: 16),
            ),
          ],
          // Recovery code reveal (F10): single or per-bundle-component.
          if (_bundleCodes.isNotEmpty)
            _recoveryWarningBlock(
              c,
              title: '⚠️ SAVE YOUR RECOVERY CODES',
              children: [
                for (final b in _bundleCodes)
                  RecoveryCodeRow(code: b.code, label: b.name),
              ],
            )
          else if (_successCode != null && _successCode!.isNotEmpty)
            _recoveryWarningBlock(
              c,
              title: '⚠️ SAVE YOUR RECOVERY CODE',
              children: [
                Text(
                  'Use this code to restore this item on another pubkey:',
                  style: TextStyle(color: c.textDim, fontSize: 12),
                ),
                RecoveryCodeRow(code: _successCode!, label: ''),
              ],
            ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.primary),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Close'),
            ),
          ),
        ];
      case _BuyPhase.error:
        return [
          const SizedBox(height: 12),
          Text(_status,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.text, fontSize: 13)),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text('Close', style: TextStyle(color: c.textDim)),
                ),
              ),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: c.primary),
                  // TODO(verify): manual grant fallback while the live backend
                  // is unreachable here.
                  onPressed: _manualConfirm,
                  child: const Text("I've paid"),
                ),
              ),
            ],
          ),
        ];
      case _BuyPhase.invoice:
        final pr = _invoice!.pr;
        return [
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.white,
            child: QrImageView(
                data: pr, size: 200, backgroundColor: Colors.white),
          ),
          const SizedBox(height: 12),
          Text('Scan with a Lightning wallet to pay.',
              style: TextStyle(color: c.textDim, fontSize: 12)),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _copy,
                  child: Text('Copy', style: TextStyle(color: c.primary)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: _openWallet,
                  child:
                      Text('Open Wallet', style: TextStyle(color: c.primary)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _cancelButton(c),
        ];
    }
  }

  Widget _cancelButton(NymColors c) => TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: Text('Cancel', style: TextStyle(color: c.textDim)),
      );

  /// The prominent "SAVE YOUR RECOVERY CODE(S)" panel (`.nm-shop-12/.nm-shop-13`,
  /// `no-inline.css:119-122`): a warning-bordered tertiary box (F10).
  Widget _recoveryWarningBlock(
    NymColors c, {
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(15),
      width: double.infinity,
      decoration: BoxDecoration(
        color: c.bgTertiary,
        border: Border.all(color: c.warning),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: c.warning,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}
