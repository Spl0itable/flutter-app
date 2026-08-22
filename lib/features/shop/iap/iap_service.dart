import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../../services/api/api_config.dart';
import 'iap_tiers.dart';

/// Store billing for the flair shop.
///
/// Wraps `in_app_purchase` with the bits the shop needs: a one-shot product
/// query (so the sheet can show the store's own localized price), a buy call
/// that resolves when that specific purchase settles, and the availability
/// gates that decide whether the in-app option is offered at all.
///
/// Deliberately NOT a Riverpod provider: the purchase stream is a
/// process-global singleton in the plugin, and binding its lifetime to a
/// widget's would drop purchases that complete while the shop is closed.

/// Which platforms may offer the "pay with Bitcoin Lightning on the web" row.
///
/// Apple restricts steering users to outside payment for the same digital
/// goods, so the iOS hand-off is gated behind [confirmExternalPurchase], which
/// shows Apple's prescribed disclosure before the buyer leaves.
///
/// ON by default. That requires the External Purchase Link entitlement for the
/// storefronts you ship to — build with
/// `--dart-define=NYM_IOS_EXTERNAL_PAY=false` to ship an IAP-only iOS build
/// while that is pending. Play's alternative-billing and external-offer terms
/// are more permissive, so Android shows both regardless.
const bool kIosExternalPayEnabled =
    bool.fromEnvironment('NYM_IOS_EXTERNAL_PAY', defaultValue: true);

/// Where the Lightning row sends a buyer: the served PWA, whose
/// `/shop?item=<itemId>` route opens the shop straight on that item's invoice
/// (app.js `parseUrlChannel`).
///
/// Derived from [ApiConfig.apiHost] rather than written out again — the web app
/// and the API are the same host, and a second copy is a second thing to get
/// wrong.
///
/// A PATH, not a `#shop` fragment, and that is load-bearing on Android. The
/// manifest claims these hosts as verified App Links, so a link this app opens
/// on its own host resolves straight back INTO this app — the external purchase
/// would bounce instead of reaching a browser. The App Links filter is scoped to
/// `android:path="/"` (every deep link the app understands is fragment-based, so
/// its path is always "/"), which leaves `/shop` unclaimed and free to open in
/// the browser where an external purchase belongs.
///
/// The item rides in the QUERY rather than as `/shop/<itemId>`: a second path
/// segment would re-base index.html's relative script and style URLs onto
/// `/shop/`, and the web app would never boot.
String get kShopWebBase => 'https://${ApiConfig.apiHost}';

String shopWebUrlFor(String itemId) => itemId.isEmpty
    ? '$kShopWebBase/shop'
    : '$kShopWebBase/shop?item=${Uri.encodeQueryComponent(itemId)}';

/// The outcome of a store purchase attempt.
enum IapResult { purchased, canceled, pending, error }

class IapPurchase {
  const IapPurchase({
    required this.result,
    this.productId,
    this.token,
    this.message,
  });

  final IapResult result;
  final String? productId;

  /// The value the backend validates: Play's `purchaseToken` on Android, the
  /// StoreKit transaction id on iOS.
  final String? token;

  final String? message;
}

class IapService {
  IapService._();
  static final IapService instance = IapService._();

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;

  /// Completers keyed by product id, resolved by the purchase stream.
  final Map<String, Completer<IapPurchase>> _pending = {};

  Map<String, ProductDetails>? _products;
  bool _started = false;

  /// True on the two platforms that have a store at all. Desktop and web fall
  /// straight through to Lightning.
  bool get platformSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isIOS || Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// Whether the Lightning row may be shown next to the in-app option.
  bool get lightningAllowed {
    if (!platformSupported) return true;
    try {
      return Platform.isIOS ? kIosExternalPayEnabled : true;
    } catch (_) {
      return true;
    }
  }

  /// `'ios'` / `'android'` — what the backend keys receipt validation off.
  String? get platformTag {
    if (!platformSupported) return null;
    try {
      return Platform.isIOS ? 'ios' : 'android';
    } catch (_) {
      return null;
    }
  }

  /// Begin listening for purchase updates. Safe to call repeatedly. Must run
  /// before any buy so a purchase that completes out of band (a store-side
  /// retry, or one interrupted by a kill) is still delivered.
  Future<void> start() async {
    if (_started || !platformSupported) return;
    _started = true;
    _sub = _iap.purchaseStream.listen(
      _onPurchases,
      onError: (Object e) => _failAll('$e'),
    );
    // Replays purchases that were completed while the app was gone; the stream
    // handler settles or acknowledges each one.
    try {
      await _iap.restorePurchases();
    } catch (_) {
      // A store that refuses a restore is not a reason to block the shop.
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _started = false;
  }

  /// The store's own [ProductDetails] for every tier, or an empty map when
  /// billing is unavailable or no products are configured yet. Cached after the
  /// first successful query.
  Future<Map<String, ProductDetails>> products() async {
    if (_products != null) return _products!;
    if (!platformSupported) return const {};
    try {
      if (!await _iap.isAvailable()) return const {};
      final response = await _iap.queryProductDetails(kIapProductIds);
      final map = {
        for (final p in response.productDetails) p.id: p,
      };
      // Only cache a real answer — an empty result usually means the products
      // aren't configured in the console yet, and we want to re-ask later.
      if (map.isNotEmpty) _products = map;
      return map;
    } catch (_) {
      return const {};
    }
  }

  /// Whether this install has working store billing.
  ///
  /// This is the signal that decides whether the app is running in a
  /// store-distributed context at all. A Zapstore / direct-APK install on a
  /// de-Googled device (GrapheneOS and friends) has no Play billing, so this is
  /// false and the shop keeps its native Lightning invoice — there is no store
  /// policy to satisfy where there is no store. Where billing IS available the
  /// in-app purchase is offered and Lightning becomes an external hop to the
  /// web app.
  Future<bool> billingAvailable() async => (await products()).isNotEmpty;

  /// The store product for an item priced at [sats], or null when it isn't
  /// available (billing off, or the tier not configured in the console).
  Future<ProductDetails?> productForSats(int sats) async {
    final all = await products();
    return all[tierForSats(sats).productId];
  }

  /// Buy [product] and resolve once that purchase settles.
  ///
  /// [applicationUserName] is passed to the store as the obfuscated account id,
  /// which lets Google surface the buyer in the Play Console and helps their
  /// fraud checks. It is NOT what the backend trusts — the receipt is.
  Future<IapPurchase> buy(
    ProductDetails product, {
    String? applicationUserName,
  }) async {
    if (!platformSupported) {
      return const IapPurchase(
          result: IapResult.error, message: 'Store billing is unavailable.');
    }
    await start();
    // A second buy of the same product while one is in flight would have two
    // completers racing for one stream event.
    final inFlight = _pending[product.id];
    if (inFlight != null) return inFlight.future;

    final completer = Completer<IapPurchase>();
    _pending[product.id] = completer;
    try {
      final param = PurchaseParam(
        productDetails: product,
        applicationUserName: applicationUserName,
      );
      // Flair is non-consumable in spirit but each purchase grants a distinct
      // item, so it is bought as a consumable and consumed on Android once the
      // backend has granted. `autoConsume` is the plugin's default.
      final started = await _iap.buyConsumable(purchaseParam: param);
      if (!started) {
        _pending.remove(product.id);
        return const IapPurchase(
            result: IapResult.error, message: 'The store declined to start this purchase.');
      }
    } catch (e) {
      _pending.remove(product.id);
      return IapPurchase(result: IapResult.error, message: '$e');
    }
    return completer.future;
  }

  /// Tell the store the purchase is settled. Call ONLY after the backend has
  /// granted the item: on Android this acknowledges (an unacknowledged purchase
  /// is auto-refunded after three days) and consumes, on iOS it finishes the
  /// transaction so it stops being replayed.
  Future<void> complete(PurchaseDetails purchase) async {
    if (!purchase.pendingCompletePurchase) return;
    try {
      await _iap.completePurchase(purchase);
    } catch (_) {
      // The store retries on its own; a failure here is not fatal to the grant.
    }
  }

  /// Purchases that arrived without anyone waiting for them — an interrupted
  /// buy, or a store-side retry. The shop drains these on open so the item is
  /// granted rather than silently refunded.
  final List<PurchaseDetails> orphaned = [];

  void _onPurchases(List<PurchaseDetails> purchases) {
    for (final p in purchases) {
      switch (p.status) {
        case PurchaseStatus.pending:
          // Nothing to settle yet; the store will emit again.
          break;
        case PurchaseStatus.canceled:
          _resolve(p.productID, const IapPurchase(result: IapResult.canceled));
          break;
        case PurchaseStatus.error:
          _resolve(
            p.productID,
            IapPurchase(
              result: IapResult.error,
              message: p.error?.message ?? 'The purchase failed.',
            ),
          );
          break;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          final token = tokenFor(p);
          final settled = _resolve(
            p.productID,
            IapPurchase(
              result: IapResult.purchased,
              productId: p.productID,
              token: token,
            ),
          );
          // Hold the raw details so the caller can complete() after granting,
          // and stash anything nobody was waiting for.
          _details[p.productID] = p;
          if (!settled) orphaned.add(p);
          break;
      }
    }
  }

  final Map<String, PurchaseDetails> _details = {};

  /// The last raw [PurchaseDetails] seen for [productId] — needed to complete
  /// the purchase after the backend grants.
  PurchaseDetails? detailsFor(String productId) => _details[productId];

  /// What the backend validates. Android: the Play purchase token. iOS: the
  /// StoreKit transaction id, which the App Store Server API looks up directly.
  String? tokenFor(PurchaseDetails p) {
    try {
      if (Platform.isAndroid) {
        return p.verificationData.serverVerificationData;
      }
      // On iOS `purchaseID` is the transaction identifier.
      return p.purchaseID ?? p.verificationData.serverVerificationData;
    } catch (_) {
      return p.purchaseID;
    }
  }

  bool _resolve(String productId, IapPurchase result) {
    final completer = _pending.remove(productId);
    if (completer == null || completer.isCompleted) return false;
    completer.complete(result);
    return true;
  }

  void _failAll(String message) {
    for (final entry in _pending.entries.toList()) {
      if (!entry.value.isCompleted) {
        entry.value.complete(IapPurchase(result: IapResult.error, message: message));
      }
    }
    _pending.clear();
  }
}
