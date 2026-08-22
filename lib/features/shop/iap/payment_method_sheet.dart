import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../../core/theme/nym_colors.dart';
import '../../../core/theme/nym_metrics.dart';
import '../../i18n/i18n.dart';
import '../shop_models.dart';
import 'iap_service.dart';
import 'iap_tiers.dart';

/// Which way the buyer chose to pay.
enum PaymentMethod { lightning, store }

/// The buy/gift payment chooser.
///
/// Both routes buy the same item; they differ only in who processes the money.
/// The store row shows the store's OWN localized price (the 30% commission is
/// already baked into the console price of the tier), and the Lightning row
/// shows the sats price and hands off to the web app.
///
/// The Lightning row is hidden entirely where [IapService.lightningAllowed] is
/// false — see the note there on store steering rules.
Future<PaymentMethod?> showPaymentMethodSheet(
  BuildContext context, {
  required ShopItem item,
  required bool isGift,
}) async {
  final iap = IapService.instance;
  final product = await iap.productForSats(item.price);
  if (!context.mounted) return null;

  // Neither option available is a dead end worth naming rather than showing an
  // empty sheet.
  if (product == null && !iap.lightningAllowed) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('Purchases are unavailable right now.'))),
    );
    return null;
  }

  // Only one way to pay — skip the sheet rather than make the buyer confirm a
  // choice they don't have.
  if (product == null) return PaymentMethod.lightning;
  if (!iap.lightningAllowed) return PaymentMethod.store;

  return showModalBottomSheet<PaymentMethod>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => _PaymentMethodSheet(
      item: item,
      isGift: isGift,
      product: product,
    ),
  );
}

class _PaymentMethodSheet extends StatelessWidget {
  const _PaymentMethodSheet({
    required this.item,
    required this.isGift,
    required this.product,
  });

  final ShopItem item;
  final bool isGift;
  final ProductDetails product;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: c.bgSecondary,
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rmd,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isGift ? tr('Gift {name}', {'name': item.name}) : tr('Buy {name}', {'name': item.name}),
              style: TextStyle(
                  color: c.text, fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              tr('Choose how to pay.'),
              style: TextStyle(color: c.textDim, fontSize: 12),
            ),
            const SizedBox(height: 14),
            _MethodRow(
              icon: Icons.bolt,
              iconColor: const Color(0xFFF7931A),
              title: tr('Bitcoin Lightning'),
              price: tr('{price} sats', {'price': item.price}),
              // Named plainly: the hop off-app is the surprising part, so it is
              // stated up front rather than discovered after the tap.
              note: tr('Opens the web app to pay an invoice'),
              onTap: () => Navigator.of(context).pop(PaymentMethod.lightning),
            ),
            const SizedBox(height: 8),
            _MethodRow(
              icon: Icons.shopping_bag_outlined,
              iconColor: c.primary,
              title: tr('In-app purchase'),
              // The store's localized price, already inclusive of the store's
              // commission — never a figure computed here.
              price: product.price,
              note: tr('Billed by the app store'),
              onTap: () => Navigator.of(context).pop(PaymentMethod.store),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr('Cancel'),
                    style: TextStyle(color: c.textDim, fontSize: 13)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MethodRow extends StatelessWidget {
  const _MethodRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.price,
    required this.note,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String price;
  final String note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: NymRadius.rsm,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: c.insetFill,
            border: Border.all(color: c.insetBorder),
            borderRadius: NymRadius.rsm,
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: c.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(note,
                        style: TextStyle(color: c.textDim, fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(price,
                  style: TextStyle(
                      color: c.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Human-readable label for the tier an item falls in — used by the docs page
/// and by tests to check the ladder is wired the way the console is configured.
String tierLabelForItem(ShopItem item) => tierForSats(item.price).id;
