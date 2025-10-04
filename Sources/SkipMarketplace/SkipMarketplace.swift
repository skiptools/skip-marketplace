// Copyright 2025 Skip
// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import SwiftUI
#if SKIP
import com.google.android.play.core.review.ReviewManagerFactory
#elseif canImport(StoreKit)
import StoreKit
#endif

/// An interface to the platform's app marketplace, such as the Apple App Store or the Google Play Store.
public struct Marketplace {
    /// The current marketplace for the environment
    nonisolated(unsafe) public static let current = Marketplace()

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
#endif
