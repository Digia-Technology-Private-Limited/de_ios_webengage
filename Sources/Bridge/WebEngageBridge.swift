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
        // Pre-attach payloads are not buffered. They drop at once as not_ready
        // with the gate freed, per de_workspace#42.
        log.d("In-app listener registered")
    }

    func registerInlineListener(
        onInlineCampaign: @escaping (String, String, [String: Any], [String: Any]) -> Void
    ) {
        // WEPersonalization not available — inline campaigns are unsupported.
        log.d("Inline listener skipped — WEPersonalization not linked")
    }

    /// Reads a private WebEngage value only if the target implements the selector.
    ///
    /// A miss logs at warning level and skips — private symbols move between
    /// versions, and an unguarded send crashes the host app.
    /// Internal for tests: linked binaries have every selector, so only a
    /// direct call against a bare object exercises the miss path.
    internal func valuePrivate(_ target: AnyObject, _ sel: Selector) -> AnyObject? {
        guard target.responds(to: sel) else {
            log.w("Missing WebEngage private API — skipped (selector=\(NSStringFromSelector(sel)))")
            return nil
        }
        typealias ObjectIMP = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(target.method(for: sel), to: ObjectIMP.self)(target, sel)?
            .takeUnretainedValue()
    }

    /// Fires a private WebEngage method only if the target implements the selector.
    ///
    /// Same miss-and-skip guard as [valuePrivate], via a typed IMP (`perform`
    /// on a `void` method reads back an undefined result). Returns whether the
    /// call went out, so callers never log a success they did not get.
    /// Internal for tests, like [valuePrivate].
    @discardableResult
    internal func callPrivate(_ target: AnyObject, _ sel: Selector, _ arg1: AnyObject, _ arg2: AnyObject) -> Bool {
        guard target.responds(to: sel) else {
            log.w("Missing WebEngage private API — skipped (selector=\(NSStringFromSelector(sel)))")
            return false
        }
        typealias VoidIMP = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
        unsafeBitCast(target.method(for: sel), to: VoidIMP.self)(target, sel, arg1, arg2)
        return true
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
               let renderer = valuePrivate(rendererCls as AnyObject, NSSelectorFromString("sharedInstance")),
               let closes = valuePrivate(renderer, NSSelectorFromString("sessionCloses")) as? NSMutableDictionary {
                let closeKey = expId + "_close"
                closes[closeKey] = 1
                log.d("Marked in sessionCloses (key=\(closeKey))")
            } else {
                log.w("Session close not marked — WEGRenderer unavailable (experimentId=\(expId))")
            }
        }

        if let analyticsCls = NSClassFromString("WEGAnalyticsImpl"),
           let analytics = valuePrivate(analyticsCls as AnyObject, NSSelectorFromString("sharedInstance")) {
            let fired = callPrivate(
                analytics,
                NSSelectorFromString("trackSDKEventWithName:andValue:"),
                eventName as NSString,
                andValue as NSDictionary
            )
            if fired {
                log.d("System event fired (name=\(eventName))")
            }
        } else {
            log.w("System event failed — analytics not available (name=\(eventName))")
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

    func unregisterInAppListener() {
        log.d("In-app listener unregistered")
        // The WebEngage delegate stays installed for the life of the process:
        // clearing it ends Digia interception on every re-registration, and
        // WebEngage then draws Digia campaigns with its own template.
        onPayloadCallback    = nil
        onInvalidateCallback = nil
        activeExperimentIds.removeAll()
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
        guard WebEngagePayloadMapper.resolveConfig(raw) != nil
            || WebEngagePayloadMapper.badTopLevelCampaignKey(in: raw) != nil else {
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

        // ── Step 7: Forward to plugin, or drop at once ─────────────────────────
        // Suppression already applied above, so WebEngage renders nothing.
        // With no plugin attached there is no presentation to settle, so free
        // the gate and the cache here. Never report notification_close.
        if let onPayloadCallback {
            onPayloadCallback(payload)
        } else {
            let campaignKey = WebEngagePayloadMapper.resolveConfig(payload)?.campaignKey
            log.w(
                "No Digia plugin registered when experimentId=\(experimentId) prepared — "
                    + "dropping as not_ready and releasing gate. "
                    + "Call Digia.register(DigiaWebEngagePlugin()) during startup.",
                campaign: campaignKey,
                stage: .trigger,
                reason: DropReason.notReady
            )
            if !experimentId.isEmpty {
                dataCache.remove(experimentId: experimentId)
                releaseGate(experimentId: experimentId)
            }
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

