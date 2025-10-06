// Copyright 2025 Skip
// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import SwiftUI
#if SKIP
import com.google.android.play.core.review.ReviewManagerFactory
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClient.BillingResponseCode
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.queryProductDetails
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
#elseif canImport(StoreKit)
import StoreKit
#endif

/// An interface to the platform's app marketplace, such as the Apple App Store or the Google Play Store.
public struct Marketplace {
    /// The current marketplace for the environment
    nonisolated(unsafe) public static let current = Marketplace()

    #if SKIP
    private var activeBillingClient: BillingClient? = nil

    private func connectBillingClient() async throws -> BillingClient {
        // return the cached client if it is ready
        if let activeBillingClient = self.activeBillingClient, activeBillingClient.isReady() {
            return activeBillingClient
        }

        // otherwise create a new billing client
        // https://developer.android.com/google/play/billing/integrate#connect_to_google_play

        func purchasesUpdated(billingResult: BillingResult, purchases: List<Purchase>?) {
            if billingResult.responseCode == BillingResponseCode.OK && purchases != nil {
                // TODO: call back into a continuation that is set when purchase() is invoked
            }
        }

        // Skip has no support for anonymous subclass creation, so we need to patch it in
        /* SKIP INSERT:
        val purchasesUpdatedListener = object : PurchasesUpdatedListener {
            override fun onPurchasesUpdated(billingResult: BillingResult, purchases: List<Purchase>?) {
                purchasesUpdated(billingResult, purchases)
             }
         }
        */

        let billingClient = BillingClient.newBuilder(ProcessInfo.processInfo.androidContext)
            .setListener(purchasesUpdatedListener)
            // TODO: configure other settings
            //.enablePendingPurchases()
            .enableAutoServiceReconnection()
            .build()


        try await withCheckedThrowingContinuation { continuation in
            func billingSetupFinished(billingResult: BillingResult) {
                //logger.log("billing setup finished: \(billingResult)")
                if billingResult.responseCode == BillingResponseCode.OK {
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
        case BillingResponseCode.ERROR: return "ERROR"
        case BillingResponseCode.BILLING_UNAVAILABLE: return "BILLING_UNAVAILABLE"
        case BillingResponseCode.DEVELOPER_ERROR: return "DEVELOPER_ERROR"
        case BillingResponseCode.FEATURE_NOT_SUPPORTED: return "FEATURE_NOT_SUPPORTED"
        case BillingResponseCode.ITEM_ALREADY_OWNED: return "ITEM_ALREADY_OWNED"
        case BillingResponseCode.ITEM_NOT_OWNED: return "ITEM_NOT_OWNED"
        case BillingResponseCode.ITEM_UNAVAILABLE: return "ITEM_UNAVAILABLE"
        case BillingResponseCode.NETWORK_ERROR: return "NETWORK_ERROR"
        case BillingResponseCode.SERVICE_DISCONNECTED: return "SERVICE_DISCONNECTED"
        case BillingResponseCode.SERVICE_TIMEOUT: return "SERVICE_TIMEOUT"
        case BillingResponseCode.SERVICE_UNAVAILABLE: return "SERVICE_UNAVAILABLE"
        case BillingResponseCode.USER_CANCELED: return "USER_CANCELED"
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
        try await Product.products(for: identifiers).map({ ProductInfo(product: $0) })
        #else
        fatalError("Unsupported platform")
        #endif
    }

    /// Initiates a purchase for the given product with a confirmation sheet.
    public func purchase(item: ProductInfo, quantity: Int? = nil) async throws {
        #if SKIP
        // https://developer.android.com/google/play/billing/integrate#launch
        let params = BillingFlowParams.ProductDetailsParams.newBuilder()
            .setProductDetails(item.product)
            //.setOfferToken(selectedOfferToken) // TODO: offers
            .build()
        let billingFlowParams = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(listOf(params))
            .build()

        guard let activity = UIApplication.shared.androidActivity else {
            fatalError("No current UIApplication.shared.androidActivity")
        }

        // TODO: hook into the purchasesUpdated() callback above with a continuation that will be invoked when the purchase is completed

        let result = try connectBillingClient().launchBillingFlow(activity, billingFlowParams)
        if result.responseCode != BillingResponseCode.OK {
            throw ErrorException(RuntimeException(errorMessage(for: result)))
        }

        // TODO: run continuation to get async result

        #elseif canImport(StoreKit)
        var opts: Set<Product.PurchaseOption> = []
        if let quantity {
            opts.insert(.quantity(quantity))
        }

        //opts.insert(.promotionalOffer(offerID: nil, signature: nil)) // TODO: offers

        let result: Product.PurchaseResult = try await item.product.purchase(options: opts)

        switch result {
        case .userCancelled: break
        case .pending: break
        case .success(let verificationResult): break
        @unknown default: break
        }
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
    #else
    public typealias PlatformProduct = Product
    #endif

    // SKIP @nobridge
    public let product: PlatformProduct

    init(product: PlatformProduct) {
        self.product = product
    }

    public var id: String {
        #if SKIP
        product.getProductId()
        #else
        product.id
        #endif
    }

    public var displayName: String {
        #if SKIP
        product.getTitle()
        #else
        product.displayName
        #endif
    }

//    public var displayPrice: String {
//        #if SKIP
//        #else
//        product.displayPrice
//        #endif
//    }
}

#endif
