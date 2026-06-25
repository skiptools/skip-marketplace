// Copyright 2025–2026 Skip
// SPDX-License-Identifier: MPL-2.0

import XCTest
import OSLog
import Foundation
@testable import SkipMarketplace

let logger: Logger = Logger(subsystem: "SkipMarketplace", category: "Tests")

@available(macOS 13, *)
final class SkipMarketplaceTests: XCTestCase {

    func testSkipMarketplace() throws {
        logger.log("running testSkipMarketplace")
        XCTAssertEqual(1 + 2, 3, "basic test")
    }

    func testDecodeType() throws {
        let resourceURL: URL = try XCTUnwrap(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        XCTAssertEqual("SkipMarketplace", testData.testModuleName)
    }

    func testInstallationSourceDescription() throws {
        let source = Marketplace.InstallationSource.unknown
        XCTAssertEqual(source.description, "unknown")
        XCTAssertFalse(source.isFirstPartyAppStore)

        let playStore = Marketplace.InstallationSource.googlePlayStore
        XCTAssertTrue(playStore.isFirstPartyAppStore)
        XCTAssertEqual(playStore.description, "googlePlayStore")

        let appStore = Marketplace.InstallationSource.appleAppStore
        XCTAssertTrue(appStore.isFirstPartyAppStore)
        XCTAssertEqual(appStore.description, "appleAppStore")

        let testFlight = Marketplace.InstallationSource.testFlight
        XCTAssertFalse(testFlight.isFirstPartyAppStore)
        XCTAssertEqual(testFlight.description, "testFlight")

        let other = Marketplace.InstallationSource.other("com.example")
        XCTAssertFalse(other.isFirstPartyAppStore)
    }

    func testMarketplaceSingleton() throws {
        let marketplace = Marketplace.current
        XCTAssertNotNil(marketplace)
    }

    func testPurchaseResultCases() throws {
        // The cases that carry no platform-specific transaction can be constructed directly and must
        // remain distinct (the whole point of A1 is that cancel and pending are no longer both `nil`).
        func describe(_ result: PurchaseResult) -> String {
            switch result {
            case .success: return "success"
            case .pending: return "pending"
            case .userCancelled: return "userCancelled"
            case .unverified: return "unverified"
            }
        }

        XCTAssertEqual(describe(.userCancelled), "userCancelled")
        XCTAssertEqual(describe(.pending), "pending")
        XCTAssertNotEqual(describe(.userCancelled), describe(.pending))
    }

    func testReviewRequestDelay() throws {
        // Test custom delay
        var called = false
        let customDelay = Marketplace.ReviewRequestDelay(shouldCheckReview: {
            called = true
            return false
        })
        let result = customDelay.checkReviewDelay()
        XCTAssertTrue(called)
        XCTAssertFalse(result)
    }
}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
