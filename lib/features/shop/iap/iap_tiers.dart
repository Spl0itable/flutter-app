/// The store-product tier ladder shared with the backend.
///
/// The shop is priced in sats and settled over Lightning. Apple and Google both
/// require digital goods consumed in-app to also be purchasable through their
/// own billing, so the native clients offer an in-app purchase alongside the
/// Lightning invoice.
///
/// A store product's price is fixed in App Store Connect / Play Console — an app
/// cannot add a margin at runtime — so the 30% store commission is baked into
/// the console price of each tier rather than computed anywhere in code. Items
/// map to a small ladder of shared tier products by their sats price.
///
/// This table MUST stay byte-identical to `TIER_LADDER` in
/// `functions/api/_iap.js` (nym-staging). The server re-derives the tier from
/// its own catalog at claim time and refuses a receipt for a cheaper product
/// than the item costs, so a drift here shows up as failed claims rather than
/// as underpayment — but it is still a drift. `iap_tiers_test.dart` pins the
/// table; update both sides together.
library;

class IapTier {
  const IapTier({
    required this.id,
    required this.maxSats,
    required this.productId,
    required this.usdHint,
  });

  final String id;

  /// Inclusive upper bound in sats. An item takes the first tier it fits in.
  final int maxSats;

  /// The App Store / Play product id to purchase.
  final String productId;

  /// The console price this ladder was derived at, for documentation only.
  /// Nothing reads it for display — the store is always the authority on what a
  /// buyer actually pays, and the sheet shows the store's localized price.
  final String usdHint;
}

/// Ordered by [IapTier.maxSats] ascending. The last entry is the catch-all.
const List<IapTier> kIapTiers = [
  IapTier(id: 't1', maxSats: 1000, productId: 'nymchat.flair.t1', usdHint: '0.99'),
  IapTier(id: 't2', maxSats: 2000, productId: 'nymchat.flair.t2', usdHint: '2.99'),
  IapTier(id: 't3', maxSats: 3500, productId: 'nymchat.flair.t3', usdHint: '4.99'),
  IapTier(id: 't4', maxSats: 5000, productId: 'nymchat.flair.t4', usdHint: '6.99'),
  IapTier(id: 't5', maxSats: 10000, productId: 'nymchat.flair.t5', usdHint: '12.99'),
  IapTier(id: 't6', maxSats: 25000, productId: 'nymchat.flair.t6', usdHint: '29.99'),
  IapTier(id: 't7', maxSats: 50000, productId: 'nymchat.flair.t7', usdHint: '59.99'),
  IapTier(id: 't8', maxSats: 100000, productId: 'nymchat.flair.t8', usdHint: '119.99'),
  IapTier(id: 't9', maxSats: 150000, productId: 'nymchat.flair.t9', usdHint: '179.99'),
  // Catch-all: anything above the ladder settles at the top product.
  IapTier(id: 't10', maxSats: 1 << 62, productId: 'nymchat.flair.t10', usdHint: '249.99'),
];

/// The tier an item priced at [sats] belongs to.
IapTier tierForSats(int sats) {
  for (final tier in kIapTiers) {
    if (sats <= tier.maxSats) return tier;
  }
  return kIapTiers.last;
}

/// Every product id the app may ever purchase — the set handed to
/// `queryProductDetails` on startup.
Set<String> get kIapProductIds =>
    {for (final tier in kIapTiers) tier.productId};
