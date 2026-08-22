# In-app purchases for the flair shop

The shop is priced in sats and settled over Lightning. Apple and Google both
require that digital goods consumed inside an app also be purchasable through
their own billing, so the store builds offer an in-app purchase alongside the
Lightning invoice.

Nothing here changes what an item costs in sats, and nothing changes for
installs that have no store billing.

## How a purchase flows

```
BUY / GIFT
    │
    ├─ payment sheet (skipped when only one rail is available)
    │
    ├─ Bitcoin Lightning
    │     ├─ store install   → opens https://web.nymchat.app/shop?item=<itemId>
    │     └─ no store billing→ native invoice dialog, exactly as before
    │
    └─ In-app purchase
          ├─ shop-iap-order  → server picks the tier product + reserves supply
          ├─ store purchase  → in_app_purchase
          ├─ shop-iap-claim  → server validates the receipt, then grants
          └─ completePurchase→ acknowledge + consume (only after the grant)
```

The IAP path reuses the Lightning machinery end to end. An order allocates an
`orderId` that plays exactly the role a bolt11 `invoiceId` plays — supply
reservation, single-use claim gate, edition allocation — so the ledger and the
client's claim handling need no IAP-specific branches.

## Which rails each install sees

The deciding signal is whether store billing actually works on the device, not a
build flag:

| Install | In-app purchase | Lightning |
|---|---|---|
| Play Store (Play services present) | yes | yes, opens the web app |
| App Store | yes | hidden by default — see below |
| Zapstore / direct APK, de-Googled (GrapheneOS etc.) | no billing available | yes, **native invoice dialog** |
| Desktop / web | n/a | native invoice dialog |

An install with no Play billing gets exactly today's behaviour: the sheet is
skipped and the native Lightning invoice opens. There is no store policy to
satisfy where there is no store, and the in-app invoice is the better
experience — so it is kept rather than replaced with a web hop.

### iOS and the Lightning row

The Lightning row is shown on iOS, and tapping it opens the web app in Safari —
genuinely leaving the app, since Universal Links are disabled here (no
`associated-domains` entitlement, no AASA served).

Before the hand-off the buyer sees the disclosure Apple's external-link rules
require, with their prescribed wording, and can back out
(`external_purchase_disclosure.dart`). The wording is Apple's and must not be
paraphrased.

**This requires the External Purchase Link entitlement** for the storefronts you
ship to. While that is pending, ship an IAP-only iOS build with:

```
flutter build ipa --dart-define=NYM_IOS_EXTERNAL_PAY=false
```

**One limitation to know before review.** Apple's entitlement expects the
*system* disclosure sheet, shown by StoreKit's
`ExternalPurchaseLink.open(url:)`. That is a native API `in_app_purchase` does
not expose, so reaching it needs a platform channel and a Swift shim, which is
not in this change. What ships is the in-app disclosure modal in the shape the
external-link rules describe — the same pattern reader apps use under the
External Link Account Entitlement. If App Review asks specifically for the
StoreKit sheet, that shim is the follow-up.

Play's alternative-billing and external-offer terms are more permissive, so
Android shows both rails with no disclosure step.

## Console setup

### 1. Create the tier products

Ten **consumable** products in each store. The ids are fixed by the ladder in
`lib/features/shop/iap/iap_tiers.dart` and `functions/api/_iap.js`; both copies
must agree, and `test/iap_tiers_test.dart` pins them.

| Tier | Applies to items priced ≤ | Product id | Suggested price |
|---|---|---|---|
| t1  | 1,000 sats   | `nymchat.flair.t1`  | $0.99 |
| t2  | 2,000 sats   | `nymchat.flair.t2`  | $2.99 |
| t3  | 3,500 sats   | `nymchat.flair.t3`  | $4.99 |
| t4  | 5,000 sats   | `nymchat.flair.t4`  | $6.99 |
| t5  | 10,000 sats  | `nymchat.flair.t5`  | $12.99 |
| t6  | 25,000 sats  | `nymchat.flair.t6`  | $29.99 |
| t7  | 50,000 sats  | `nymchat.flair.t7`  | $59.99 |
| t8  | 100,000 sats | `nymchat.flair.t8`  | $119.99 |
| t9  | 150,000 sats | `nymchat.flair.t9`  | $179.99 |
| t10 | anything above | `nymchat.flair.t10` | $249.99 |

**The suggested prices are a starting point, not a computed value.** A store
product's price is fixed in the console — an app cannot add a margin at runtime
— so the 30% store commission has to be baked into the price you set. Derive
each row as:

```
tier price ≈ (tier ceiling in sats × BTC/USD) × 1.30, rounded up to a store tier
```

The table above was derived that way and then rounded to the usual charm-price
points. Recompute it at your current BTC rate before you create the products,
and revisit it if the rate moves a long way — the ladder buckets by **sats**,
which is fixed, while the console price is in fiat, which is not.

The app never displays a computed price. The sheet shows the store's own
localized `ProductDetails.price`, so whatever you set in the console is what the
buyer sees and pays.

### 2. Backend secrets (nym-staging worker)

```
# Google Play
wrangler secret put GOOGLE_PLAY_CLIENT_EMAIL     # service account email
wrangler secret put GOOGLE_PLAY_PRIVATE_KEY      # the service account's PEM private key
wrangler secret put ANDROID_PACKAGE_NAME         # com.nym.bar

# App Store
wrangler secret put APPLE_ISSUER_ID              # App Store Connect API issuer id
wrangler secret put APPLE_KEY_ID                 # the .p8 key id
wrangler secret put APPLE_PRIVATE_KEY            # the .p8 contents
wrangler secret put APPLE_BUNDLE_ID              # com.nym.bar
```

The Play service account needs the **View financial data / Manage orders**
permission on the app. The App Store Connect key needs the **In-App Purchase**
role.

Until these are set, `shop-iap-claim` returns "…billing is not configured." and
the shop falls back to Lightning. Nothing else breaks.

### 3. Android manifest

`com.android.vending.BILLING` is contributed by the `in_app_purchase_android`
plugin's own manifest, so no manual entry is needed. A build for a device with
no Play services still installs and runs — the plugin's calls simply report
billing unavailable, which is exactly the signal the shop keys off.

## Security model

The client is never trusted with what was paid or what it costs:

- **The server picks the product.** `shop-iap-order` derives the tier from its
  own catalog price and returns the product id; the app buys what it is told to,
  and a client that asks for a different one is refused at claim time.
- **Receipts are validated server-side.** Google via the Play Developer API
  (`purchases/products/…/tokens/…`, checking `purchaseState` and
  `consumptionState`), Apple via the App Store Server API
  (`/inApps/v1/transactions/…`, checking bundle id, product id and revocation).
- **Underpayment is blocked.** The claim compares the ladder *position* of the
  purchased product against the position the item requires, so a t1 receipt
  cannot settle a t6 item. Comparing positions rather than equality means a
  buyer who paid for a dearer tier is not refused.
- **One receipt settles one order.** The ledger binds the store transaction id
  to the first order that claims it (`shop-iap-bind`); presenting the same
  receipt against a second order is rejected, while retrying the *same* order
  stays idempotent.
- **Nothing is granted on the store's word alone.** The item is unlocked only
  after the backend grants it, and only then is `completePurchase` called.

## Failure handling

A purchase where money moved but the grant did not land is the case that matters
most. The order is written to the pending list *before* the store is invoked,
and the store replays any purchase that was never completed, so:

- the claim is retried on 402/503 with a backoff;
- if it still fails, the purchase is deliberately left **uncompleted** and the
  buyer is told it will retry;
- opening the shop drains any pending IAP order against the store's replayed
  purchase and grants it.

On Android an unacknowledged purchase is auto-refunded by Google after three
days, so the worst case is the buyer's money coming back rather than a silent
loss.

## Testing

- `flutter test test/iap_tiers_test.dart` — ladder shape, bucketing, and parity
  with the server table.
- Google Play: add testers to a **License testing** list; purchases are free and
  refund automatically.
- App Store: use a **Sandbox Apple ID**. The backend tries the production
  App Store Server API host first and falls back to sandbox, so TestFlight and
  review builds validate without a configuration switch.
