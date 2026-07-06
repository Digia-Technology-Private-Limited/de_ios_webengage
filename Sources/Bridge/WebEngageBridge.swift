@preconcurrency import Foundation
@preconcurrency import WebEngage

// MARK: - Bridge Protocol

/// Abstracts all WebEngage SDK calls so they can be mocked in unit tests.
/// Mirrors `WebEngageBridge.kt` interface on Android.
/// NOT @MainActor — uses regular @escaping closures; the plugin dispatches onto the main actor.
internal protocol WebEngageBridgeProtocol: AnyObject {
    func registerInAppListener(
        onPayload: @escaping ([String: Any]) -> Void,
        onInvalidate: @escaping (String) -> Void
    )
    func trackSystemEvent(eventName: String, systemData: [String: Any], eventData: [String: Any])
    func navigateScreen(_ name: String)
    func unregisterInAppListener()
    func isAvailable() -> Bool
    func releaseCampaignGate(_ experimentId: String)
}

// MARK: - SDK Bridge

/// Concrete bridge that delegates to the WebEngage iOS SDK.
/// Mirrors `WebEngageSdkBridge` on Android.
///
/// WebEngage iOS accepts one `WEGInAppNotificationProtocol` delegate at a time.
/// This bridge must be registered as `notificationDelegate` **at WebEngage SDK
/// initialization time** in your `AppDelegate`. Use `WebEngagePlugin.makeWebEngageConfig()`
/// to get a `WebEngageConfig` with the bridge pre-wired, then pass it to:
/// `WebEngage.sharedInstance().application(_:didFinishLaunchingWithOptions:webengageConfig:)`
internal final class WebEngageSdkBridge: NSObject, WebEngageBridgeProtocol, @unchecked Sendable {

    // Singleton used for AppDelegate registration (see WebEngagePlugin.makeWebEngageConfig()).
    nonisolated(unsafe) internal static let shared = WebEngageSdkBridge()

    // `var` so that WebEngagePlugin.init(config:) can apply a custom config after the
    // singleton is created with default settings.
    internal var config: WebEngagePluginConfig
    private let dataCache: InAppDataCache
    // Gate: mirrors Flutter's _activeExperimentIds — blocks duplicate onInAppPrepared
    // calls for the same campaign (race conditions between WE re-evaluation cycles).
    private var activeExperimentIds: Set<String> = []
    // Pending deferred gate releases, keyed by experimentId, so they can be cancelled on
    // unregister (or superseded by a re-add) instead of firing later against stale state.
    private var pendingGateReleases: [String: DispatchWorkItem] = [:]

    private var onPayloadCallback:      (([String: Any]) -> Void)?
    private var onInvalidateCallback:   ((String) -> Void)?
    private var pendingInAppPayloads: [[String: Any]] = []

    private static let gateReleaseDelay: TimeInterval = 0.5

    init(config: WebEngagePluginConfig = WebEngagePluginConfig(),
         dataCache: InAppDataCache = InAppDataCache()) {
        self.config = config
        self.dataCache = dataCache
        super.init()
    }

    // MARK: - WebEngageBridgeProtocol

    func registerInAppListener(
        onPayload: @escaping ([String: Any]) -> Void,
        onInvalidate: @escaping (String) -> Void
    ) {
        onPayloadCallback    = onPayload
        onInvalidateCallback = onInvalidate
        // NOTE: The delegate binding happens at WebEngage init time in AppDelegate via
        // WebEngagePlugin.makeWebEngageConfig(). Nothing to do here at runtime.
        logDebug("register_inapp_listener")

        if !pendingInAppPayloads.isEmpty {
            let queued = pendingInAppPayloads
            pendingInAppPayloads.removeAll()
            logDebug("flushing \(queued.count) buffered inapp payload(s)")
            queued.forEach(onPayload)
        }
    }

    func trackSystemEvent(eventName: String, systemData: [String: Any], eventData: [String: Any]) {
        // Build the andValue dict the same way WebEngage fires notification_view
        // internally: put campaign data under "system_data_overrides" so the
        // WEGEvent factory merges it into system_data (not event_data).
        var andValue: [String: Any] = [:]
        if !systemData.isEmpty {
            andValue["system_data_overrides"] = systemData
        }
        if !eventData.isEmpty {
            andValue["event_data_overrides"] = eventData
        }

        logDebug("trackSystemEvent name=\(eventName) andValue=\(andValue)")

        // Use trackSDKEventWithName:andValue: which bypasses reserved-name
        // guards and routes through the full SDK event pipeline.
        // Mark sessionCloses BEFORE firing the event so re-evaluation
        // triggered by the event already sees the mark.
        if eventName == "notification_close",
           let expId = systemData["experiment_id"] as? String, !expId.isEmpty {
            if let rendererCls = NSClassFromString("WEGRenderer"),
               let renderer = (rendererCls as AnyObject).perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue(),
               let closes = renderer.perform(NSSelectorFromString("sessionCloses"))?.takeUnretainedValue() as? NSMutableDictionary {
                let closeKey = expId + "_close"
                closes[closeKey] = 1
                logDebug("Marked \(closeKey) in sessionCloses")
            }
        }

        let analyticsCls: AnyClass? = NSClassFromString("WEGAnalyticsImpl")
        if let analyticsCls = analyticsCls {
            let sharedSel = NSSelectorFromString("sharedInstance")
            let trackSel = NSSelectorFromString("trackSDKEventWithName:andValue:")

            if let analytics = (analyticsCls as AnyObject).perform(sharedSel)?.takeUnretainedValue() {
                if let result = analytics.perform(trackSel, with: eventName, with: andValue) {
                    _ = result.takeUnretainedValue()
                }
                logDebug("trackSystemEvent fired: \(eventName)")
            } else {
                logDebug("trackSystemEvent analytics not available")
            }
        }
    }

    func navigateScreen(_ name: String) {
        WebEngage.sharedInstance().analytics.navigatingToScreen(withName: name)
        logDebug("navigate_screen name=\(name)")
    }

    func unregisterInAppListener() {
        logDebug("unregister_inapp_listener")
        WebEngage.sharedInstance().setValue(nil, forKey: "notificationDelegate")
        onPayloadCallback    = nil
        onInvalidateCallback = nil
        activeExperimentIds.removeAll()
        pendingGateReleases.values.forEach { $0.cancel() }
        pendingGateReleases.removeAll()
        pendingInAppPayloads.removeAll()
    }

    func releaseCampaignGate(_ experimentId: String) {
        // Deferred (not immediate) release: WebEngage's own `notification_close` event
        // triggers an internal async re-evaluation that can re-invoke
        // notificationPrepared for this same experimentId within milliseconds. Releasing
        // the gate immediately would let that echo re-dispatch the campaign a second time.
        // The delay absorbs the echo — mirrors Android's `releaseCampaignGate` behavior.
        pendingGateReleases.removeValue(forKey: experimentId)?.cancel()
        let release = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingGateReleases.removeValue(forKey: experimentId)
            self.activeExperimentIds.remove(experimentId)
            self.logDebug("campaign_gate_released exp=\(experimentId)")
        }
        pendingGateReleases[experimentId] = release
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.gateReleaseDelay, execute: release)
    }

    func isAvailable() -> Bool { true }

    // MARK: - Logging

    private func logDebug(_ message: String) {
        if config.diagnosticsEnabled { NSLog("[Digia WebEngage] \(message)") }
    }

    private func logWarning(_ message: String) {
        if config.diagnosticsEnabled { NSLog("[Digia WebEngage] WARNING: \(message)") }
    }
}

// MARK: - WEGInAppNotificationProtocol

extension WebEngageSdkBridge: WEGInAppNotificationProtocol {

    @objc func notificationPrepared(
        _ inAppNotificationData: [String: Any]!,
        shouldStop stopRendering: UnsafeMutablePointer<ObjCBool>!
    ) -> [AnyHashable: Any]! {
        logDebug("notificationPrepared called keys=\(inAppNotificationData?.keys.sorted() ?? [])")

        guard let raw = inAppNotificationData else {
            logWarning("in-app prepared with nil data; skipping")
            return inAppNotificationData
        }

        // ── Step 1: Identify campaign type + extract contract (mirrors Android's
        //    WebEngageBridge.kt: normalize first, then check for contract presence) ──
        let normalized = normalizeWithDigiaContract(raw)
        guard normalized["digiaContractSource"] != nil else {
            logDebug("inapp_prepared non-Digia campaign, allowing normal rendering")
            return inAppNotificationData
        }

        // ── Step 2: Digia campaign → suppress WebEngage's own renderer ──────────
        stopRendering?.pointee = true

        // ── Step 3: Ensure experimentId is forwarded under the canonical key ────
        let experimentId = str(normalized["notificationEncId"]
                               ?? normalized["experimentId"] ?? normalized["experiment_id"]) ?? ""
        var payload = normalized
        if !experimentId.isEmpty, payload["experimentId"] == nil {
            payload["experimentId"] = experimentId
        }

        logDebug("inapp_prepared exp=\(experimentId) isDigia=true suppress=true")

        // ── Step 4: Cache for event dispatch ────────────────────────────────────
        if !experimentId.isEmpty {
            var cacheEntry = payload
            cacheEntry["experimentId"] = experimentId
            let layoutId    = str(raw["layoutId"] ?? raw["layout_id"]) ?? ""
            let variationId = str(raw["variationId"] ?? raw["variation_id"]) ?? ""
            if !layoutId.isEmpty    { cacheEntry["layoutId"]    = layoutId }
            if !variationId.isEmpty { cacheEntry["variationId"] = variationId }
            dataCache.put(experimentId: experimentId, data: cacheEntry)
        }

        // ── Step 5: Gate check — block duplicate fires for the same campaign ───
        if !experimentId.isEmpty {
            if activeExperimentIds.contains(experimentId) {
                logDebug("inapp_prepared duplicate blocked exp=\(experimentId)")
                return inAppNotificationData
            }
            activeExperimentIds.insert(experimentId)
        }

        // ── Step 6: Forward to plugin ───────────────────────────────────────────
        if let onPayloadCallback {
            onPayloadCallback(payload)
        } else {
            // Listener not attached yet (setup() races this launch-time callback) — buffer
            // instead of silently dropping. See `pendingInAppPayloads` doc comment above.
            pendingInAppPayloads.append(payload)
            logDebug("inapp_prepared buffered exp=\(experimentId) (listener not yet registered)")
        }
        return inAppNotificationData
    }

    @objc func notificationShown(_ inAppNotificationData: [String: Any]!) {
        let id = inAppNotificationData?["experimentId"] as? String ?? ""
        logDebug("inapp_shown exp=\(id)")
    }

    @objc func notificationDismissed(_ inAppNotificationData: [String: Any]!) {
        let id = str(inAppNotificationData?["notificationEncId"]
                     ?? inAppNotificationData?["experimentId"]
                     ?? inAppNotificationData?["experiment_id"]) ?? ""
        logDebug("inapp_dismissed exp=\(id)")
        if !id.isEmpty {
            // Release the gate so the campaign can show again if re-triggered.
            activeExperimentIds.remove(id)
            onInvalidateCallback?(id)
        }
    }

    @objc func notification(_ inAppNotificationData: [String: Any]!, clickedWithAction actionId: String!) {
        let id = inAppNotificationData?["experimentId"] as? String ?? ""
        logDebug("inapp_clicked exp=\(id) actionId=\(actionId ?? "")")
    }

}

// MARK: - String helper

private func str(_ value: Any?) -> String? {
    guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    return s
}

