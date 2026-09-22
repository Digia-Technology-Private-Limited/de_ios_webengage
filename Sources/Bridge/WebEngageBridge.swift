@preconcurrency import Foundation
@preconcurrency import WebEngage
import DigiaEngage

// MARK: - Bridge Protocol

/// Abstracts all WebEngage SDK calls so they can be mocked in unit tests.
/// Mirrors `WebEngageBridge.kt` interface on Android.
/// NOT @MainActor — uses regular @escaping closures; the plugin dispatches onto the main actor.
internal protocol WebEngageBridgeProtocol: AnyObject {
    func registerInAppListener(
        onPayload: @escaping ([String: Any]) -> Void,
        onInvalidate: @escaping (String) -> Void
    )
    func registerInlineListener(
        onInlineCampaign: @escaping (
            _ campaignId: String,
            _ targetViewId: String,
            _ customData: [String: Any],
            _ metadata: [String: Any]
        ) -> Void
    )
    func trackSystemEvent(eventName: String, systemData: [String: Any], eventData: [String: Any])
    func navigateScreen(_ name: String)

    /// Frees the per-experiment gate that blocks WebEngage from preparing the
    /// same campaign twice.
    ///
    /// The gate is set when a campaign is suppressed for Digia to render, and —
    /// because a suppressed notification never reaches WebEngage's own dismiss
    /// callback — nothing on WebEngage's side ever clears it again. The plugin
    /// releases it when the presentation's `outcome` settles, on **both** arms.
    func releaseGate(experimentId: String)

    func unregisterInAppListener()
    func unregisterInlineListener()
    func isAvailable() -> Bool
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
    private let log = DigiaLogger("WE")

    /// How long an in-app payload may sit buffered waiting for
    /// `Digia.register()` before its gate is released and the payload dropped.
    ///
    /// Buffering at all is what lets an app-launch campaign survive the gap
    /// between WebEngage preparing it and Digia being registered — this delegate
    /// is installed in `AppDelegate`, strictly earlier than any plugin can
    /// attach. Bounding it is what stops that same gap from silencing the
    /// campaign for the whole session when registration never happens: the gate
    /// is set the moment the campaign is suppressed, and an unreleased gate
    /// means WebEngage never offers that campaign again.
    ///
    /// Spec §10.5 G-d: this timer, and only this timer, stays in the plugin.
    static let attachGrace: TimeInterval = 10

    /// Bound on the pre-attach buffer. Unbounded buffering is the bug, not the
    /// feature — a session that never registers Digia would otherwise accumulate
    /// every campaign WebEngage prepared.
    private static let maxBufferedPayloads = 5

    /// Payloads WebEngage prepared before any plugin attached.
    private var buffered: [(experimentId: String, payload: [String: Any])] = []

    private var onPayloadCallback:      (([String: Any]) -> Void)?
    private var onInvalidateCallback:   ((String) -> Void)?
    private var onInlineCampaignCallback: ((String, String, [String: Any], [String: Any]) -> Void)?

    private override init() {
        self.config = WebEngagePluginConfig()
        self.dataCache = InAppDataCache()
        super.init()
    }

    /// Internal init for tests allowing a custom config.
    internal init(config: WebEngagePluginConfig, dataCache: InAppDataCache = InAppDataCache()) {
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
        log.d("In-app listener registered")

        guard !buffered.isEmpty else { return }
        let pending = buffered
        buffered = []
        log.d("Flushing \(pending.count) in-app payload(s) buffered before attach")
        pending.forEach { onPayload($0.payload) }
    }

    func registerInlineListener(
        onInlineCampaign: @escaping (String, String, [String: Any], [String: Any]) -> Void
    ) {
        // WEPersonalization not available — inline campaigns are unsupported.
        log.d("Inline listener skipped — WEPersonalization not linked")
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

        log.d("Track system event (name=\(eventName))")

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
                log.d("Marked in sessionCloses (key=\(closeKey))")
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
                log.d("System event fired (name=\(eventName))")
            } else {
                log.w("System event failed — analytics not available (name=\(eventName))")
            }
        }
    }

    func navigateScreen(_ name: String) {
        WebEngage.sharedInstance().analytics.navigatingToScreen(withName: name)
    }

    func releaseGate(experimentId: String) {
        guard !experimentId.isEmpty else { return }
        activeExperimentIds.remove(experimentId)
        log.d("Gate released (experimentId=\(experimentId))")
    }

    // MARK: - Pre-attach buffer

    /// Holds a payload that arrived before any plugin attached, under a bounded
    /// grace period. Always ends with the campaign either delivered or its gate
    /// released — never silently held.
    private func bufferUntilAttach(experimentId: String, payload: [String: Any]) {
        if buffered.count >= Self.maxBufferedPayloads {
            let evicted = buffered.removeFirst()
            log.w("Pre-attach buffer full — dropping (experimentId=\(evicted.experimentId)) and releasing gate")
            releaseGate(experimentId: evicted.experimentId)
        }
        buffered.append((experimentId: experimentId, payload: payload))
        log.d("No plugin attached yet — buffering (experimentId=\(experimentId))")

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.attachGrace) { [weak self] in
            self?.expireBuffered(experimentId: experimentId)
        }
    }

    private func expireBuffered(experimentId: String) {
        guard let index = buffered.firstIndex(where: { $0.experimentId == experimentId }) else { return }
        buffered.remove(at: index)
        log.w(
            "No Digia plugin registered within \(Self.attachGrace)s of experimentId=\(experimentId) — "
                + "releasing the WebEngage gate. Call Digia.register(DigiaWebEngagePlugin()) during startup."
        )
        releaseGate(experimentId: experimentId)
    }

    func unregisterInAppListener() {
        log.d("In-app listener unregistered")
        WebEngage.sharedInstance().setValue(nil, forKey: "notificationDelegate")
        onPayloadCallback    = nil
        onInvalidateCallback = nil
        activeExperimentIds.removeAll()
        buffered.removeAll()
    }

    func unregisterInlineListener() {
        // WEPersonalization not available — no-op.
        onInlineCampaignCallback = nil
        log.d("Inline listener unregister skipped — WEPersonalization not linked")
    }

    func isAvailable() -> Bool { true }
}

// MARK: - WEGInAppNotificationProtocol

extension WebEngageSdkBridge: WEGInAppNotificationProtocol {

    @objc func notificationPrepared(
        _ inAppNotificationData: [String: Any]!,
        shouldStop stopRendering: UnsafeMutablePointer<ObjCBool>!
    ) -> [AnyHashable: Any]! {
        guard let raw = inAppNotificationData else {
            log.w("Notification prepared with nil data — skipping")
            return inAppNotificationData
        }

        // ── Step 1: Is this campaign ours? (mirrors Flutter isDigiaCampaign) ────
        if !WebEngagePayloadMapper.isDigiaCampaign(raw) {
            log.d("Non-Digia campaign — allowing normal WebEngage rendering")
            return inAppNotificationData
        }

        // ── Step 2: Digia campaign → suppress WebEngage's own renderer ──────────
        stopRendering?.pointee = true

        // ── Step 3: Ensure experimentId is forwarded under the canonical key ────
        let experimentId = str(raw["notificationEncId"]
                               ?? raw["experimentId"] ?? raw["experiment_id"]) ?? ""
        var payload = raw
        if !experimentId.isEmpty, payload["experimentId"] == nil {
            payload["experimentId"] = experimentId
        }

        log.d("Digia campaign suppressed for rendering (experimentId=\(experimentId))")

        // ── Step 4: Claimed, but not mappable → let go of everything ────────────
        // `isDigiaCampaign` is deliberately wider than the mapper: a
        // `<template id="digia-config">` block claims the campaign even when the
        // marketer left no campaign key inside it. WebEngage's own renderer is
        // already suppressed by the time we know, and that is the safe half —
        // what must not also happen is this bridge taking the per-experiment gate
        // and the cache entry. Nothing will ever settle a presentation that was
        // never delivered, so the gate would stay set and silence that experiment
        // for the rest of the session. Abstaining from both is the whole of the
        // release path: unlike Android, iOS hands back no in-app queue handle.
        guard WebEngagePayloadMapper.resolveConfig(raw) != nil else {
            log.w(
                "Suppressed and dropped — digia-config block with no campaign key (experimentId=\(experimentId)). "
                    + "Holding neither the gate nor the cache. Add a "
                    + "<meta name=\"campaign-key\" content=\"…\"> to the block."
            )
            return inAppNotificationData
        }

        // ── Step 5: Cache for event dispatch ────────────────────────────────────
        if !experimentId.isEmpty {
            var cacheEntry = payload
            cacheEntry["experimentId"] = experimentId
            let layoutId    = str(raw["layoutId"] ?? raw["layout_id"]) ?? ""
            let variationId = str(raw["variationId"] ?? raw["variation_id"]) ?? ""
            if !layoutId.isEmpty    { cacheEntry["layoutId"]    = layoutId }
            if !variationId.isEmpty { cacheEntry["variationId"] = variationId }
            dataCache.put(experimentId: experimentId, data: cacheEntry)
        }

        // ── Step 6: Gate check — block duplicate fires for the same campaign ───
        if !experimentId.isEmpty {
            if activeExperimentIds.contains(experimentId) {
                log.d("Duplicate delivery blocked (experimentId=\(experimentId))")
                return inAppNotificationData
            }
            activeExperimentIds.insert(experimentId)
        }

        // ── Step 7: Forward to plugin, or buffer under the grace period ────────
        if let onPayloadCallback {
            onPayloadCallback(payload)
        } else {
            bufferUntilAttach(experimentId: experimentId, payload: payload)
        }
        return inAppNotificationData
    }

    @objc func notificationShown(_ inAppNotificationData: [String: Any]!) {
        let id = inAppNotificationData?["experimentId"] as? String ?? ""
        log.d("WebEngage in-app shown (experimentId=\(id))")
    }

    @objc func notificationDismissed(_ inAppNotificationData: [String: Any]!) {
        let id = str(inAppNotificationData?["notificationEncId"]
                     ?? inAppNotificationData?["experimentId"]
                     ?? inAppNotificationData?["experiment_id"]) ?? ""
        log.d("WebEngage in-app dismissed (experimentId=\(id))")
        if !id.isEmpty {
            // Release the gate so the campaign can show again if re-triggered.
            releaseGate(experimentId: id)
            onInvalidateCallback?(id)
        }
    }

    @objc func notification(_ inAppNotificationData: [String: Any]!, clickedWithAction actionId: String!) {
        let id = inAppNotificationData?["experimentId"] as? String ?? ""
        log.d("WebEngage in-app clicked (experimentId=\(id), actionId=\(actionId ?? ""))")
    }
}



// MARK: - String helper

private func str(_ value: Any?) -> String? {
    guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    return s
}

