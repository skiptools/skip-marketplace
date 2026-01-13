// Copyright 2025 Skip
// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import SwiftUI
import OSLog
#if SKIP
import com.google.android.play.core.review.ReviewManagerFactory
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.queryProductDetails
import com.android.billingclient.api.QueryPurchasesParams
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
#else
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(MarketplaceKit)
import MarketplaceKit
#endif
#endif

/// An interface to the platform's app marketplace, such as the Apple App Store or the Google Play Store.
///
/// Mostly conforms to the [OpenIAP](https://www.openiap.dev) specification.
public struct Marketplace: Sendable {
    /// The current marketplace for the environment
    public static let current = Marketplace()

    #if SKIP
    public typealias PlatformPurchaseOptions = com.android.billingclient.api.BillingFlowParams.Builder
    #elseif canImport(StoreKit)
    public typealias PlatformPurchaseOptions = Set<Product.PurchaseOption>
    #endif

    let logger: Logger = Logger(subsystem: "skip.marketplace", category: "Marketplace") // adb logcat '*:S' 'skip.marketplace.Marketplace:V'

    public enum InstallationSource: Sendable, CustomStringConvertible {
        // MARK: Android app sources

        case googlePlayStore

        // MARK: iOS app sources

        case appleAppStore
        case testFlight
        case marketplace(bundleId: String)
        case web

        // MARK: Other app sources

        /// Can be an alternative app marketplace (like AltStore: "com.rileytestut.AltStore") or Android identifier (like F-Droid: "org.fdroid.fdroid")
        case other(_ name: String?)
        case unknown

        /// Returns true when this source is either the Google Play Store or Apple App Store
        public var isFirstPartyAppStore: Bool {
            switch self {
            case .appleAppStore, .googlePlayStore: return true
            default: return false
            }
        }

        public var description: String {
            switch self {
            case .googlePlayStore:
                return "googlePlayStore"
            case .appleAppStore:
                return "appleAppStore"
            case .testFlight:
                return "testFlight"
            case .marketplace(bundleId: let bundleId):
                return "marketplace(\(bundleId))"
            case .web:
                return "web"
            case .other(let name):
                return "other(\(name ?? ""))"
            case .unknown:
                return "unknown"
            }
        }
    }
    
    /// The installation source for the current app, which can be used to determine what payment options and features are available
    public var installationSource: InstallationSource {
        get async {
            #if SKIP
            let context = ProcessInfo.processInfo.androidContext
            var packageManager = context.packageManager
            var packageName = context.packageName

            var installerPackageName: String? = nil
            if android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R {
                installerPackageName = packageManager.getInstallSourceInfo(packageName).installingPackageName
            } else {
                // SKIP INSERT: @Suppress("DEPRECATION")
                installerPackageName = packageManager.getInstallerPackageName(packageName)
            }

            guard let installerPackageName, !installerPackageName.isEmpty else {
                return .unknown
            }

            switch installerPackageName {
            case "com.android.vending": return .googlePlayStore
            case "com.google.android.feedback": return .googlePlayStore
            default: return .other(installerPackageName)
            //case "org.fdroid.fdroid": return .other("F-Droid")
            //case "com.amazon.venezia": return .other("Amazon App Store")
            //case "com.sec.android.app.samsungapps": return .other("Samsung Galaxy Store")
            //case "com.huawei.appmarket": return .other("Huawei AppGallery")
            }
            #elseif canImport(MarketplaceKit)
            if #available(iOS 17.4, *) {
                let currentDistributor = try? await AppDistributor.current
                switch currentDistributor {
                case .none:
                    return .unknown
                case .appStore:
                    return .appleAppStore
                case .testFlight:
                    return .testFlight
                case .marketplace(let bundleId):
                    return .marketplace(bundleId: bundleId)
                case .web:
                    return .web
                case .other:
                    return .other(nil)
                @unknown default:
                    return .unknown
                }
            } else {
                return .unknown
            }
            #else
            return .unknown
            #endif
        }
    }


    #if SKIP
    private var activeBillingClient: BillingClient? = nil
    private var purchasesUpdatedListeners: [(PurchaseResultInfo) -> ()] = []

    private struct PurchaseResultInfo {
        let result: BillingResult
        let purchases: List<Purchase>?
    }

    private func connectBillingClient() async throws -> BillingClient {
        // return the cached client if it is ready
        if let activeBillingClient = self.activeBillingClient, activeBillingClient.isReady() {
            return activeBillingClient
        }

        // otherwise create a new billing client
        // https://developer.android.com/google/play/billing/integrate#connect_to_google_play

        func purchasesUpdated(billingResult: BillingResult, purchases: List<Purchase>?) {
            for purchasesUpdatedListener in purchasesUpdatedListeners {
                purchasesUpdatedListener(PurchaseResultInfo(billingResult, purchases))
            }
        }

        let billingClient = BillingClient.newBuilder(ProcessInfo.processInfo.androidContext)
            .setListener({ billingResult, purchases in
                purchasesUpdated(billingResult, purchases)
            })
            // TODO: configure other settings
            .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
            .enableAutoServiceReconnection()
            .build()

        try await withCheckedThrowingContinuation { continuation in
            func billingSetupFinished(billingResult: BillingResult) {
                logger.info("billing setup finished: \(billingResult)")
                if billingResult.responseCode == BillingClient.BillingResponseCode.OK {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: ErrorException(RuntimeException(errorMessage(for: billingResult))))
                }
            }

            func billingServiceDisconnected() {
                // the billing client disconnected, so drop the cached reference
                self.activeBillingClient = nil
            }

            // Skip has no support for anonymous subclass creation, so we need to patch it in
            /* SKIP INSERT:
            val billingClientListener = object : BillingClientStateListener {
                override fun onBillingSetupFinished(billingResult: BillingResult) { billingSetupFinished(billingResult) }
                override fun onBillingServiceDisconnected() { billingServiceDisconnected() }
            }
            */

            billingClient.startConnection(billingClientListener)
        }

        // cache the billing client so we don't always need to reconnect
        self.activeBillingClient = billingClient
        return billingClient
    }

    /// https://developer.android.com/reference/com/android/billingclient/api/BillingClient.BillingResponseCode
    private func errorMessage(for billingResult: BillingResult) -> String {
        switch billingResult.responseCode {
        case BillingClient.BillingResponseCode.ERROR: return "ERROR"
        case BillingClient.BillingResponseCode.BILLING_UNAVAILABLE: return "BILLING_UNAVAILABLE"
        case BillingClient.BillingResponseCode.DEVELOPER_ERROR: return "DEVELOPER_ERROR"
        case BillingClient.BillingResponseCode.FEATURE_NOT_SUPPORTED: return "FEATURE_NOT_SUPPORTED"
        case BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED: return "ITEM_ALREADY_OWNED"
        case BillingClient.BillingResponseCode.ITEM_NOT_OWNED: return "ITEM_NOT_OWNED"
        case BillingClient.BillingResponseCode.ITEM_UNAVAILABLE: return "ITEM_UNAVAILABLE"
        case BillingClient.BillingResponseCode.NETWORK_ERROR: return "NETWORK_ERROR"
        case BillingClient.BillingResponseCode.SERVICE_DISCONNECTED: return "SERVICE_DISCONNECTED"
        case BillingClient.BillingResponseCode.SERVICE_TIMEOUT: return "SERVICE_TIMEOUT"
        case BillingClient.BillingResponseCode.SERVICE_UNAVAILABLE: return "SERVICE_UNAVAILABLE"
        case BillingClient.BillingResponseCode.USER_CANCELED: return "USER_CANCELED"
        default: return "Unknown error"
        }
    }
    #endif

    public func fetchProducts(for identifiers: [String], subscription: Bool) async throws -> [ProductInfo] {
        #if SKIP
        let productList: [QueryProductDetailsParams.Product] = identifiers.map { identifier in
            QueryProductDetailsParams.Product.newBuilder()
                .setProductId(identifier)
                .setProductType(subscription ? BillingClient.ProductType.SUBS : BillingClient.ProductType.INAPP)
                .build()
        }

        let params = QueryProductDetailsParams.newBuilder()
        params.setProductList(productList.toList())

        let billingClient = try await connectBillingClient()
        let productDetailsResult = withContext(Dispatchers.IO) {
            billingClient.queryProductDetails(params.build())
        }

        guard let productDetailsList = productDetailsResult.productDetailsList else {
            return []
        }
        return Array(productDetailsList).map({ ProductInfo(product: $0) })
        #elseif canImport(StoreKit)
        return try await Product.products(for: identifiers).map({ ProductInfo(product: $0) })
        #else
        fatalError("Unsupported platform")
        #endif
    }

    /// Initiates a purchase for the given product with a confirmation sheet.
    ///
    /// On iOS, the `offer` parameter must be a win-back offer. Configure a promotional offer by passing it in via the `purchaseOptions` parameter,
    /// leaving the `offer` parameter nil. (iOS applies introductory offers automatically.)
    public func purchase(item: ProductInfo, offer: OfferInfo? = nil, purchaseOptions: PlatformPurchaseOptions? = nil) async throws -> PurchaseTransaction? {
        #if SKIP
        // https://developer.android.com/google/play/billing/integrate#launch
        let paramsBuilder = BillingFlowParams.ProductDetailsParams.newBuilder()
            .setProductDetails(item.product)
        if let offer, let offerToken = offer.offerToken {
            paramsBuilder.setOfferToken(offerToken)
        }
        let params = paramsBuilder.build()
        let billingFlowParams = (purchaseOptions ?? BillingFlowParams.newBuilder())
            .setProductDetailsParamsList(listOf(params))
            .build()

        guard let activity = UIApplication.shared.androidActivity else {
            fatalError("No current UIApplication.shared.androidActivity")
        }

        let billingClient = try await connectBillingClient()

        let purchaseResult: PurchaseResultInfo = try await withCheckedThrowingContinuation { continuation in
            // hook into the purchasesUpdated() callback above with a continuation that will be invoked when the purchase is completed
            purchasesUpdatedListeners.append({ purchaseResult in
                logger.info("purchases updated: result=\(purchaseResult.result) purchases=\(purchaseResult.purchases)")
                continuation.resume(returning: purchaseResult)
                purchasesUpdatedListeners.removeAll() // remove all listeners (we currently only support one at a time)
            })

            let result = billingClient.launchBillingFlow(activity, billingFlowParams)
            if result.responseCode != BillingClient.BillingResponseCode.OK {
                continuation.resume(throwing: ErrorException(RuntimeException(errorMessage(for: result))))
            }
        }

        if purchaseResult.result.responseCode != BillingClient.BillingResponseCode.OK {
            switch purchaseResult.result.responseCode {
            case BillingClient.BillingResponseCode.USER_CANCELED:
                logger.info("purchase of item \(item.id) pending")
                return nil // TODO: better signalling of user cancelled
            default:
                throw ErrorException(RuntimeException(errorMessage(for: purchaseResult.result)))
            }
        }

        logger.info("purchase of item \(item.id) successful")
        guard let purchase = purchaseResult.purchases?.first() else {
            throw ErrorException(RuntimeException("Successful purchase returned no purchases"))
        }

        return PurchaseTransaction(purchase)
        #elseif canImport(StoreKit)
        var opts: Set<Product.PurchaseOption> = purchaseOptions ?? []

        if let offer {
            guard let offer = offer as? SubscriptionOfferInfo else {
                fatalError("Unsupported offer type")
            }
            if offer.type == .promotional {
                fatalError("You can't pass a promotional offer to the purchase() method, because you have to sign them with your server-side app. Use the purchaseOptions parameter instead.")
            } else if #available(iOS 18.0, macOS 15.0, *), offer.type == .winBack {
                opts.insert(.winBackOffer(offer.offer))
            } else {
                fatalError("Unsupported offer type: \(offer.type)")
            }
        }
        let result: Product.PurchaseResult = try await item.product.purchase(options: opts)

        switch result {
        case .userCancelled:
            logger.info("purchase of item \(item.id) cancelled by user")
            return nil // TODO: better signalling of cancellation versus pending
        case .pending:
            logger.info("purchase of item \(item.id) pending")
            return nil
        case .success(let verificationResult):
            logger.info("purchase of item \(item.id) successful: \(verificationResult.debugDescription)")
            switch verificationResult {
            case .unverified(_, let error):
                throw error // fail when the transaction was not verified
            case .verified(let transaction):
                return PurchaseTransaction(transaction)
            }
        @unknown default:
            logger.info("purchase of item \(item.id) unknown result: \(String(describing: result))")
            return nil
        }
        #else
        fatalError("Unsupported platform")
        #endif
    }
    
    #if SKIP
    private func queryPurchasesAsync(_ productType: String) async throws -> List<Purchase> {
        let billingClient = try await connectBillingClient()
        let params = QueryPurchasesParams.newBuilder()
            .setProductType(productType)
            .build()
        
        return try await withCheckedThrowingContinuation { continuation in
            billingClient.queryPurchasesAsync(params) { billingResult, purchases in
                if billingResult.responseCode == BillingClient.BillingResponseCode.OK {
                    continuation.resume(returning: purchases)
                } else {
                    continuation.resume(throwing: ErrorException(RuntimeException(errorMessage(for: billingResult))))
                }
            }
        }
    }
    #endif
    
    public func fetchEntitlements() async throws -> [PurchaseTransaction] {
        var result: [PurchaseTransaction] = []
        #if SKIP
        async let inAppPurchases = try await queryPurchasesAsync(BillingClient.ProductType.INAPP)
        async let subsPurchases = try await queryPurchasesAsync(BillingClient.ProductType.SUBS)
        
        for purchase in try await inAppPurchases {
            if purchase.getPurchaseState() == Purchase.PurchaseState.PURCHASED {
                result.append(PurchaseTransaction(purchase))
            }
        }
        
        for purchase in try await subsPurchases {
            if purchase.getPurchaseState() == Purchase.PurchaseState.PURCHASED {
                result.append(PurchaseTransaction(purchase))
            }
        }
        
        return result
        #elseif canImport(StoreKit)
        for await verificationResult in Transaction.currentEntitlements {
            switch verificationResult {
            case .verified(let transaction):
                result.append(PurchaseTransaction(transaction))
            case .unverified(let unverifiedTransaction, let verificationError):
                print("Unverified transaction \(unverifiedTransaction), error: \(verificationError)")
            }
        }
        return result
        #else
        fatalError("Unsupported platform")
        #endif
    }
    
    /// A purchase transaction must be finished or else it will be in a pending state, or may be automatically refunded.
    ///
    /// See: https://developer.apple.com/documentation/storekit/transaction/finish()
    /// See: https://developer.android.com/reference/com/android/billingclient/api/BillingClient#acknowledgePurchase(com.android.billingclient.api.AcknowledgePurchaseParams,com.android.billingclient.api.AcknowledgePurchaseResponseListener)
    public func finish(purchaseTransaction: PurchaseTransaction) async throws {
        #if SKIP
        let billingClient = try await connectBillingClient()
        try await withCheckedThrowingContinuation { continuation in
            let params = AcknowledgePurchaseParams.newBuilder().setPurchaseToken(purchaseTransaction.purchaseTransaction.getPurchaseToken()).build();
            billingClient.acknowledgePurchase(params) { billingResult in
                if billingResult.responseCode == BillingClient.BillingResponseCode.OK {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: ErrorException(RuntimeException(errorMessage(for: billingResult))))
                }
            }
        }
        #elseif canImport(StoreKit)
        await purchaseTransaction.purchaseTransaction.finish()
        #else
        fatalError("Unsupported platform")
        #endif
    }

    // Design guides:
    // https://developer.android.com/guide/playcore/in-app-review#when-to-request
    // https://developer.apple.com/design/human-interface-guidelines/ratings-and-reviews#Best-practices
    @MainActor @discardableResult public func requestReview(period: ReviewRequestDelay = .default) -> Bool {
        if period.checkReviewDelay() == false {
            return false
        }

        #if SKIP
        // https://developer.android.com/guide/playcore/in-app-review/kotlin-java
        let context = ProcessInfo.processInfo.androidContext
        guard let activity = UIApplication.shared.androidActivity else {
            return false
        }
        // https://developer.android.com/reference/com/google/android/play/core/review/ReviewManager
        guard let manager = ReviewManagerFactory.create(context) else {
            return false
        }
        let request = manager.requestReviewFlow()
        request.addOnCompleteListener { task in
            guard task.isSuccessful else {
                // there was some problem, log or handle the error code.
                return
            }
            let flow = manager.launchReviewFlow(activity, task.result)
        }
        return true
        #elseif os(iOS)
        guard let activeScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            return false
        }

        if #available(iOS 16.0, *) {
            // https://developer.apple.com/documentation/storekit/appstore
            StoreKit.AppStore.requestReview(in: activeScene)
            return true
        } else {
            // https://developer.apple.com/documentation/storekit/skstorereviewcontroller (deprecated)
            SKStoreReviewController.requestReview(in: activeScene)
            return true
        }
        #else
        // unsupported platform
        return false
        #endif
    }

    /// The strategy for only requesting user reviews
    public struct ReviewRequestDelay {
        /// The closure to invoke to determine whether a review should be requested or not
        let shouldCheckReview: () -> Bool

        public init(shouldCheckReview: @escaping () -> Bool) {
            self.shouldCheckReview = shouldCheckReview
        }

        /// Determine whether the review request API should be invoked.
        public func checkReviewDelay() -> Bool {
            shouldCheckReview()
        }
    }
}

/// A wrapper around a market-specific purchase result, such as
/// [`StoreKit.Transaction`](https://developer.apple.com/documentation/storekit/transaction) on iOS
/// and
/// [`com.android.billingclient.api.Purchase`](https://developer.android.com/reference/com/android/billingclient/api/Purchase) on Android.
///
/// Note that the underlying `purchaseTransaction: PlatformPurchaseTransaction` property can facilitate accessing platform-specific details.
public struct PurchaseTransaction {
    #if SKIP
    public typealias PlatformPurchaseTransaction = com.android.billingclient.api.Purchase
    #elseif canImport(StoreKit)
    public typealias PlatformPurchaseTransaction = StoreKit.Transaction
    #endif
    
    // SKIP @nobridge
    public let purchaseTransaction: PlatformPurchaseTransaction
    init(_ purchaseTransaction: PlatformPurchaseTransaction) {
        self.purchaseTransaction = purchaseTransaction
    }
    
    public var id: String? {
        #if SKIP
        return purchaseTransaction.getOrderId()
        #elseif canImport(StoreKit)
        return String(purchaseTransaction.id)
        #else
        fatalError("Unsupported platform")
        #endif
    }
    
    public var products: [String] {
        #if SKIP
        return Array(purchaseTransaction.getProducts())
        #elseif canImport(StoreKit)
        return [purchaseTransaction.productID]
        #else
        fatalError("Unsupported platform")
        #endif
    }
}

extension Marketplace.ReviewRequestDelay {
    /// The default period of review requests as recommended by the guidelines for the individual store
    ///
    /// On the Google Play Store, this is discussed at https://developer.android.com/guide/playcore/in-app-review#quotas
    /// For the Apple App Store, this is discussed at https://developer.apple.com/documentation/storekit/requestreviewaction#overview
    nonisolated(unsafe) public static let `default` = Marketplace.ReviewRequestDelay.days(31)

    /// A strategy for checking reviews that delays calls by the specified number of days
    public static func days(_ days: Int) -> Marketplace.ReviewRequestDelay {
        return Marketplace.ReviewRequestDelay(shouldCheckReview: {
            let lastReviewRequestKey = "lastReviewRequest"
            let currentTime = Date.now.timeIntervalSince1970
            var lastReviewRequestTime = UserDefaults.standard.double(forKey: lastReviewRequestKey)
            if lastReviewRequestTime <= 0.0 {
                lastReviewRequestTime = currentTime
                // remember when we initially requested the review
                UserDefaults.standard.set(currentTime, forKey: lastReviewRequestKey)
                return false
            } else if (currentTime - lastReviewRequestTime) > Double(days) * 60.0 * 60.0 * 24.0 {
                // we can invoke the request; remember the last time that we asked for future reference
                UserDefaults.standard.set(currentTime, forKey: lastReviewRequestKey)
                return true
            } else {
                return false
            }
        })
    }
}

/// A wrapper around a market-specific product, such as
/// [`StoreKit.Product`](https://developer.apple.com/documentation/storekit/product) on iOS
/// and
/// [`com.android.billingclient.api.ProductDetails`](https://developer.android.com/reference/com/android/billingclient/api/ProductDetails) on Android.
///
/// Note that the underlying `product: PlatformProduct` property can facilitate accessing platform-specific details.
public struct ProductInfo {
    #if SKIP
    public typealias PlatformProduct = com.android.billingclient.api.ProductDetails
    #elseif canImport(StoreKit)
    public typealias PlatformProduct = StoreKit.Product
    #endif

    // SKIP @nobridge
    public let product: PlatformProduct

    init(product: PlatformProduct) {
        self.product = product
    }

    public var id: String {
        #if SKIP
        product.getProductId()
        #elseif canImport(StoreKit)
        product.id
        #endif
    }

    public var displayName: String {
        #if SKIP
        product.getTitle()
        #elseif canImport(StoreKit)
        product.displayName
        #endif
    }
    
    public var oneTimePurchaseOfferInfo: [OneTimePurchaseOfferInfo]? {
        #if SKIP
        if let offers = product.getOneTimePurchaseOfferDetailsList() {
            return Array(offers).map { OneTimePurchaseOfferInfo(offer: $0) }
        } else if let offer = product.getOneTimePurchaseOfferDetails() {
            return [OneTimePurchaseOfferInfo(offer: offer)]
        } else {
            return nil
        }
        #else
        guard !isSubscription else { return nil }
        return [OneTimePurchaseOfferInfo(price: product.price, displayPrice: product.displayPrice)]
        #endif
    }
    
    public var displayPrice: String? {
        #if SKIP
        if isSubscription, let sub = product.getSubscriptionOfferDetails()?.first() {
            return sub.getPricingPhases().getPricingPhaseList().first()?.getFormattedPrice()
        } else {
            return product.getOneTimePurchaseOfferDetails()?.getFormattedPrice()
        }
        #elseif canImport(StoreKit)
        return product.displayPrice // TODO: is this correct for subscriptions?
        #endif
    }

    public var isSubscription: Bool {
        #if SKIP
        switch product.getProductType() {
        case BillingClient.ProductType.SUBS: return true
        case BillingClient.ProductType.INAPP: return false
        default: return false
        }
        #elseif canImport(StoreKit)
        return product.subscription != nil ? true : false
        #endif
    }

    public var subscriptionOffers: [SubscriptionOfferInfo]? {
        #if SKIP
        guard let subs = product.getSubscriptionOfferDetails() else {
            return nil
        }
        return Array(subs).map({ SubscriptionOfferInfo(offer: $0) })
        #elseif canImport(StoreKit)
        var results: [SubscriptionOfferInfo] = []
        if let introductoryOffer = product.subscription?.introductoryOffer {
            results.append(SubscriptionOfferInfo(offer: introductoryOffer))
        }
        if let promotionalOffers = product.subscription?.promotionalOffers {
            results.append(contentsOf: promotionalOffers.map({ SubscriptionOfferInfo(offer: $0) }))
        }
        if #available(iOS 18.0, macOS 15.0, *) {
            if let winBackOffers = product.subscription?.winBackOffers {
                results.append(contentsOf: winBackOffers.map({ SubscriptionOfferInfo(offer: $0) }))
            }
        }
        return results
        #endif
    }
}

public protocol OfferInfo {
    var id: String? { get }
    #if SKIP
    var offerToken: String? { get }
    #endif
}

public struct OneTimePurchaseOfferInfo : OfferInfo {
    #if SKIP
    public typealias PlatformOneTimePurchaseOfferInfo = com.android.billingclient.api.ProductDetails.OneTimePurchaseOfferDetails
    
    let offer: PlatformOneTimePurchaseOfferInfo
    init(offer: PlatformOneTimePurchaseOfferInfo) {
        self.offer = offer
    }
    
    public var price: Decimal {
        return Decimal(offer.getPriceAmountMicros()) / Decimal(1_000_000)
    }


    public var displayPrice: String {
        return offer.getFormattedPrice()
    }
    #else
    public let price: Decimal
    public let displayPrice: String
    init(price: Decimal, displayPrice: String) {
        self.price = price
        self.displayPrice = displayPrice
    }
    #endif

    public var id: String? {
        #if SKIP
        return offer.getOfferId()
        #else
        return nil
        #endif
    }
    
    public var fullPrice: Decimal? {
        #if SKIP
        guard let fullPriceMicros = offer.getFullPriceMicros() else { return nil }
        return Decimal(fullPriceMicros) / 1_000_000 as Decimal
        #else
        return nil
        #endif
    }
    
    #if SKIP
    public var offerToken: String? {
        return offer.getOfferToken()
    }
    #endif

    public var discountAmount: Decimal? {
        #if SKIP
        guard let discountAmountMicros = offer.getDiscountDisplayInfo()?.getDiscountAmount()?.getDiscountAmountMicros() else { return nil }
        return Decimal(discountAmountMicros) / Decimal(1_000_000)
        #else
        return nil
        #endif
    }
    
    public var discountDisplayAmount: String? {
        #if SKIP
        return offer.getDiscountDisplayInfo()?.getDiscountAmount()?.getFormattedDiscountAmount()
        #else
        return nil
        #endif
    }

    public var discountPercentage: Int? {
        #if SKIP
        return offer.getDiscountDisplayInfo()?.getPercentageDiscount()
        #else
        return nil
        #endif
    }
}

/// A wrapper around a market-specific subscription, such as
/// [`StoreKit.Product.SubscriptionInfo`](https://developer.apple.com/documentation/storekit/product/subscriptioninfo) on iOS
/// and
/// [`com.android.billingclient.api.ProductDetails.SubscriptionOfferDetails`](https://developer.android.com/reference/com/android/billingclient/api/ProductDetails.SubscriptionOfferDetails) on Android.
///
/// Note that the underlying `product: PlatformProduct` property can facilitate accessing platform-specific details.
public struct SubscriptionOfferInfo : OfferInfo {
    #if SKIP
    public typealias PlatformSubscriptionOffer = com.android.billingclient.api.ProductDetails.SubscriptionOfferDetails
    #elseif canImport(StoreKit)
    public typealias PlatformSubscriptionOffer = StoreKit.Product.SubscriptionOffer
    #endif

    // SKIP @nobridge
    public let offer: PlatformSubscriptionOffer

    init(offer: PlatformSubscriptionOffer) {
        self.offer = offer
    }

    public var id: String? {
        #if SKIP
        return offer.getOfferId()
        #elseif canImport(StoreKit)
        return offer.id
        #endif
    }

    public var pricingPhases: [SubscriptionPricingPhase] {
        #if SKIP
        return Array(offer.getPricingPhases().getPricingPhaseList()).map { SubscriptionPricingPhase(phase: $0) }
        #elseif canImport(StoreKit)
        return [SubscriptionPricingPhase(phase: offer)]
        #endif
    }

    #if SKIP
    public var offerToken: String? {
        return offer.getOfferToken()
    }
    #elseif canImport(StoreKit)
    public var type: Product.SubscriptionOffer.OfferType {
        return offer.type
    }
    #endif
}

public struct SubscriptionPricingPhase {
    #if SKIP
    public typealias PlatformSubscriptionPricingPhase = com.android.billingclient.api.ProductDetails.PricingPhase
    #elseif canImport(StoreKit)
    public typealias PlatformSubscriptionPricingPhase = StoreKit.Product.SubscriptionOffer
    #endif

    // SKIP @nobridge
    public let phase: PlatformSubscriptionPricingPhase
    init(phase: PlatformSubscriptionPricingPhase) {
        self.phase = phase
    }

    public var price: Decimal {
        #if SKIP
        return Decimal(phase.getPriceAmountMicros()) / Decimal(1_000_000)
        #elseif canImport(StoreKit)
        return phase.price
        #endif
    }
    
    public var displayPrice: String {
        #if SKIP
        return phase.getFormattedPrice()
        #elseif canImport(StoreKit)
        return phase.displayPrice
        #endif
    }

    // TODO subscription period, duration
}

#endif
