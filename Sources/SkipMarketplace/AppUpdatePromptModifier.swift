// Copyright 2025 Skip
// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import SwiftUI
import OSLog
#if SKIP
import com.google.android.play.core.appupdate.AppUpdateManager
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateInfo
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.install.model.UpdateAvailability
import android.app.Activity
#else
import StoreKit
#endif
#if canImport(AppKit)
import AppKit
#endif

let logger: Logger = Logger(subsystem: "skip.marketplace", category: "AppUpdatePromptModifier")

// MARK: - View extension

public extension View {
    /// Presents an app update prompt when a newer version is available.
    ///
    /// - Parameters:
    ///   - forcePrompt: When true, the prompt is shown every time an update is available. When false, the prompt is throttled to at most once per 24 hours.
    func appUpdatePrompt(forcePrompt: Bool = false) -> some View {
        modifier(AppUpdatePromptModifier(forcePrompt: forcePrompt))
    }
}

// MARK: - Modifier

private struct AppUpdatePromptModifier: ViewModifier {
    let forcePrompt: Bool

    #if !SKIP
    @State private var showUpdateAlert = false
    @State private var updateVersion: String? = nil
    @State private var showAppStoreOverlay = false
    @State private var appStoreConnectId: Int? = nil
    #endif

    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("lastAppUpdatePromptDate") private var lastPromptDate: TimeInterval = 0
    private static let throttleInterval: TimeInterval = 86400.0 // 24 hours

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase, initial: true) { old, new in
                if new == .active {
                    Task(priority: .background) { await checkForUpdate() }
                }
            }
            #if !SKIP
            .alert("Update Available", isPresented: $showUpdateAlert) {
                Button("Update") {
                    lastPromptDate = Date().timeIntervalSince1970
                    #if os(iOS)
                    showAppStoreOverlay = true
                    #elseif canImport(AppKit)
                    NSWorkspace.shared.open(URL(string: "https://apps.apple.com/app/id\(appStoreConnectId!)")!)
                    #else
                    fatalError("Unsupported platform")
                    #endif
                }
                Button("Later", role: .cancel) { }
            } message: {
                if let version = updateVersion {
                    Text("Version \(version) is available. Please update to get the latest features and improvements.")
                } else {
                    Text("A new version is available. Please update to get the latest features and improvements.")
                }
            }
            #if os(iOS)
            .appStoreOverlay(isPresented: $showAppStoreOverlay) {
                guard let appStoreConnectId else {
                    fatalError("trackId is not available for App Store overlay")
                }
                let config = SKOverlay.AppConfiguration(appIdentifier: String(appStoreConnectId), position: .bottom)
                config.userDismissible = true
                return config
            }
            #endif
            #endif
    }

    private func checkForUpdate() async {
        #if SKIP
        let appUpdateManager = AppUpdateManagerFactory.create(ProcessInfo.processInfo.androidContext)
        let task = appUpdateManager.appUpdateInfo
        let appUpdateInfo: AppUpdateInfo? = await withCheckedContinuation { cont in
            task.addOnSuccessListener { info in cont.resume(returning: info) }
            task.addOnFailureListener { error in
                logger.error("Failed to check for app update: \(error)")
                cont.resume(returning: nil)
            }
        }
        guard let appUpdateInfo else { return }
        guard appUpdateInfo.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE else {
            logger.info("App update is not available, update availability: \(appUpdateInfo.updateAvailability())")
            return
        }
        let options = AppUpdateOptions.newBuilder(AppUpdateType.IMMEDIATE).build()
        guard appUpdateInfo.isUpdateTypeAllowed(options) else {
            let failedPreconditions = appUpdateInfo.getFailedUpdatePreconditions(options)
            logger.info("Immediate app update is not allowed, failed preconditions: \(failedPreconditions)")
            return
        }
        if !forcePrompt && !shouldPromptAfterThrottle() { return }
        logger.info("Immediate app update is allowed, launching update flow for version \(appUpdateInfo.availableVersionCode())")
        Task { @MainActor in
            lastPromptDate = Date().timeIntervalSince1970
            await startUpdateFlowAndroid(appUpdateInfo: appUpdateInfo)
        }
        #else
        guard let bundleId = Bundle.main.bundleIdentifier else { return }

        func isVersion(_ a: String, greaterThan b: String) -> Bool {
            let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
            let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
            let count = max(aParts.count, bParts.count)
            for i in 0..<count {
                let av = i < aParts.count ? aParts[i] : 0
                let bv = i < bParts.count ? bParts[i] : 0
                if av > bv { return true }
                if av < bv { return false }
            }
            return false
        }

        let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundleId)")!
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let storeVersion = first["version"] as? String else { return }
            guard let trackIdValue = first["trackId"],
                  let appStoreConnectId = (trackIdValue as? Int) ?? (trackIdValue as? String).flatMap({ Int($0) }) else {
                logger.error("trackId not found or invalid in iTunes lookup response")
                return
            }
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            guard isVersion(storeVersion, greaterThan: currentVersion) else {
                logger.info("Store version \(storeVersion) is not greater than current version \(currentVersion)")
                return
            }
            logger.info("Store version \(storeVersion) is greater than current version \(currentVersion)")
            if let minimumOsVersion = first["minimumOsVersion"] as? String {
                let osVersion = ProcessInfo.processInfo.operatingSystemVersion
                let osVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
                if isVersion(minimumOsVersion, greaterThan: osVersionString) {
                    logger.info("User OS \(osVersionString) is below minimum \(minimumOsVersion) required for store version \(storeVersion)")
                    return
                }
            }
            if !forcePrompt && !shouldPromptAfterThrottle() { return }
            Task { @MainActor in
                updateVersion = storeVersion
                self.appStoreConnectId = appStoreConnectId
                showUpdateAlert = true
            }
        } catch {
            logger.error("Failed to check for app update: \(error)")
        }
        #endif
    }

    private func shouldPromptAfterThrottle() -> Bool {
        let now = Date().timeIntervalSince1970
        if lastPromptDate <= 0 { return true }
        if (now - lastPromptDate) < Self.throttleInterval {
            logger.info("App update prompt is throttled, last prompt date: \(lastPromptDate), now: \(now)")
            return false
        }
        lastPromptDate = now
        return true
    }

    #if SKIP
    @MainActor
    private func startUpdateFlowAndroid(appUpdateInfo: AppUpdateInfo) async {
        guard let activity = UIApplication.shared.androidActivity else {
            logger.info("No Android activity, opening Play Store")
            await openPlayStore()
            return
        }
        
        do {
            let appUpdateManager = AppUpdateManagerFactory.create(ProcessInfo.processInfo.androidContext)
            let options = AppUpdateOptions.newBuilder(AppUpdateType.IMMEDIATE).build()
            let task = try appUpdateManager.startUpdateFlow(appUpdateInfo, activity, options)
            let resultCode: Int? = await withCheckedContinuation { cont in
                task.addOnSuccessListener { code in
                    cont.resume(returning: code)
                }
                task.addOnFailureListener { error in
                    logger.error("Failed to start app update flow: \(error)")
                    cont.resume(returning: nil)
                }
            }
            guard let resultCode else {
                logger.error("Failed to start app update flow, opening Play Store")
                await openPlayStore()
                return
            }
            if resultCode == android.app.Activity.RESULT_OK {
                logger.info("App update flow completed successfully")
            } else if resultCode == android.app.Activity.RESULT_CANCELED {
                logger.info("App update flow was canceled by user")
            } else {
                logger.info("App update flow completed with result code: \(resultCode)")
            }
        } catch {
            logger.error("Failed to start app update flow for Android: \(error)")
            await openPlayStore()
            return
        }
    }

    @MainActor
    private func openPlayStore() async {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        guard let url = URL(string: "https://play.google.com/store/apps/details?id=\(bundleId)") else { return }
        await UIApplication.shared.open(url)
    }
    #endif
}

#endif
