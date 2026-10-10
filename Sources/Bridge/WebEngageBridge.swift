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
    /// callback — nothing on WebEngage's side ever clears it again. Immediate
    /// free, for WebEngage-side dismissals and silent drops; the outcome path
    /// uses `notifyDismissed` instead.
    func releaseGate(experimentId: String)

    /// Gate free, 1 s after the call (see `gateReleaseDelay`).
    /// Called from the hold observer and drops with no presentation.
    func notifyDismissed(experimentId: String)

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
/// initialization time** in your `AppDelegate`: pass `DigiaWebEngagePlugin.notificationDelegate`
/// to `WebEngage.sharedInstance().application(_:didFinishLaunchingWithOptions:notificationDelegate:)`.
internal final class WebEngageSdkBridge: NSObject, WebEngageBridgeProtocol, @unchecked Sendable {

    // Singleton used for AppDelegate registration (see DigiaWebEngagePlugin.notificationDelegate).
    nonisolated(unsafe) internal static let shared = WebEngageSdkBridge()

    // `var` so that DigiaWebEngagePlugin.init(config:) can apply a custom config after the
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

    // Screen hold (WE-14). Main thread only.
    private var pendingScreens: [String] = []
    private var screenHoldActive = false
    private var awaitingRenderSettle = false
    private var settleGeneration = 0
    private var lastPreparedId: String?

    // Seams for tests. Defaults run on the main queue and call WebEngage.
    internal var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        nonisolated(unsafe) let work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
    }
    internal var forwardScreen: (String) -> Void = { name in
        WebEngage.sharedInstance().analytics.navigatingToScreen(withName: name)
    }
    internal lazy var renderingNotificationId: () -> String? = { [unowned self] in
        self.readRenderingNotificationId()
    }

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
        // DigiaWebEngagePlugin.notificationDelegate. Nothing to do here at runtime.
        // Pre-attach payloads are not buffered. They drop at once as not_ready
        // with the gate freed, per de_workspace#42.
    }

    func registerInlineListener(
        onInlineCampaign: @escaping (String, String, [String: Any], [String: Any]) -> Void
    ) {
        // App In-line is unsupported: no inline listener is ever registered.
    }

    /// Reads a private WebEngage value only if the target implements the selector.
    ///
    /// A miss logs at warning level and skips — private symbols move between
    /// versions, and an unguarded send crashes the host app.
    private func logMissing(_ sel: Selector) {
        let selector = NSStringFromSelector(sel)
        log.w(
            "Missing WebEngage private API — skipped (selector=\(selector))",
            reason: CEPPluginReason.bridgeUnavailable,
            extras: ["selector": selector]
        )
    }

    /// Internal for tests: linked binaries have every selector, so only a
    /// direct call against a bare object exercises the miss path.
    internal func valuePrivate(_ target: AnyObject, _ sel: Selector) -> AnyObject? {
        guard target.responds(to: sel) else {
            logMissing(sel)
            return nil
        }
        typealias ObjectIMP = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(target.method(for: sel), to: ObjectIMP.self)(target, sel)?
            .takeUnretainedValue()
    }

    /// Reads a private WebEngage `BOOL` with the same guard as [valuePrivate].
    internal func boolPrivate(_ target: AnyObject, _ sel: Selector) -> Bool {
        guard target.responds(to: sel) else {
            logMissing(sel)
            return false
        }
        typealias BoolIMP = @convention(c) (AnyObject, Selector) -> ObjCBool
        return unsafeBitCast(target.method(for: sel), to: BoolIMP.self)(target, sel).boolValue
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
            logMissing(sel)
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

        // Use trackSDKEventWithName:andValue: which bypasses reserved-name
        // guards and routes through the full SDK event pipeline.
        let experimentId = systemData["experiment_id"] as? String ?? "-"
        guard let analyticsCls = NSClassFromString("WEGAnalyticsImpl"),
              let analytics = valuePrivate(analyticsCls as AnyObject, NSSelectorFromString("sharedInstance")),
              callPrivate(
                  analytics,
                  NSSelectorFromString("trackSDKEventWithName:andValue:"),
                  eventName as NSString,
                  andValue as NSDictionary
              )
        else {
            log.e("System event failed — continuing (event=\(eventName), experimentId=\(experimentId))")
            return
        }
    }

    /// WebEngage iOS drops an in-flight in-app render on a screen change, so a
    /// campaign triggered just before navigation is lost. Each screen change waits
    /// for that render to reach `notificationPrepared`, capped at 1 s, in order.
    func navigateScreen(_ name: String) {
        schedule(0) { [self] in
            pendingScreens.append(name)
            if !screenHoldActive { holdNextScreen() }
        }
    }

    private static let renderStartWindow: TimeInterval = 0.1
    private static let renderSettleTimeout: TimeInterval = 1.0

    /// Close-echo window: the `notification_close` re-evaluation arrives within
    /// milliseconds, so the gate stays shut for a generous 1 s.
    private static let gateReleaseDelay: TimeInterval = 1.0

    private func holdNextScreen() {
        guard !pendingScreens.isEmpty else {
            screenHoldActive = false
            return
        }
        screenHoldActive = true
        // WebEngage starts a render a few ms after the trigger event.
        schedule(Self.renderStartWindow) { [self] in
            guard let current = renderingNotificationId(), current != lastPreparedId else {
                forwardNextScreen()
                return
            }
            settleGeneration += 1
            let generation = settleGeneration
            awaitingRenderSettle = true
            schedule(Self.renderSettleTimeout) { [self] in
                guard awaitingRenderSettle, generation == settleGeneration else { return }
                log.d("Screen hold timed out (notificationId=\(current))")
                forwardNextScreen()
            }
        }
    }

    private func forwardNextScreen() {
        awaitingRenderSettle = false
        forwardScreen(pendingScreens.removeFirst())
        holdNextScreen()
    }

    private func renderSettled(_ notificationId: String?) {
        schedule(0) { [self] in
            lastPreparedId = notificationId
            if awaitingRenderSettle { forwardNextScreen() }
        }
    }

    /// The id of a render `WEGRenderer` has started, or nil when idle or when a
    /// private symbol is missing.
    private func readRenderingNotificationId() -> String? {
        guard let rendererCls = NSClassFromString("WEGRenderer"),
              let renderer = valuePrivate(rendererCls as AnyObject, NSSelectorFromString("sharedInstance")),
              boolPrivate(renderer, NSSelectorFromString("rendering")) else { return nil }
        return valuePrivate(renderer, NSSelectorFromString("currentNotificationId")) as? String
    }

    func releaseGate(experimentId: String) {
        guard !experimentId.isEmpty else { return }
        activeExperimentIds.remove(experimentId)
    }

    func notifyDismissed(experimentId: String) {
        guard !experimentId.isEmpty else { return }
        schedule(Self.gateReleaseDelay) { [self] in
            self.releaseGate(experimentId: experimentId)
        }
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
        // App In-line is unsupported — no-op.
        onInlineCampaignCallback = nil
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

        // Every render that reaches this callback frees a held screen change.
        renderSettled(str(raw["notificationEncId"] ?? raw["experimentId"] ?? raw["experiment_id"]))

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
            // Takes neither gate nor cache: nothing downstream settles it.
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
        // Duplicates never reach the plugin; stay silent.
        if !experimentId.isEmpty {
            if activeExperimentIds.contains(experimentId) {
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
                "Dropping in-app — no host attached (reason=not_ready, "
                    + "experimentId=\(experimentId.isEmpty ? "-" : experimentId))",
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
    }

    @objc func notificationDismissed(_ inAppNotificationData: [String: Any]!) {
        let id = str(inAppNotificationData?["notificationEncId"]
                     ?? inAppNotificationData?["experimentId"]
                     ?? inAppNotificationData?["experiment_id"]) ?? ""
        if !id.isEmpty {
            // Release the gate so the campaign can show again if re-triggered.
            releaseGate(experimentId: id)
            onInvalidateCallback?(id)
        }
    }

    @objc func notification(_ inAppNotificationData: [String: Any]!, clickedWithAction actionId: String!) {
    }
}



// MARK: - String helper

private func str(_ value: Any?) -> String? {
    guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    return s
}

