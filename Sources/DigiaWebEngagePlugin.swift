import Foundation
import DigiaEngage
@preconcurrency import WebEngage

/// Top-level plugin that wires WebEngage in-app and personalization callbacks into Digia's
/// CEP rendering engine on iOS.  Drop-in equivalent of `WebEngagePlugin.kt` on Android.
///
/// **Usage (AppDelegate):**
/// ```swift
/// import DigiaEngageWebEngage
///
/// WebEngage.sharedInstance().application(
///     application,
///     didFinishLaunchingWithOptions: launchOptions,
///     notificationDelegate: WebEngagePlugin.notificationDelegate
/// )
/// ```
/// **Usage (app entry-point):**
/// ```swift
/// Digia.register(DigiaWebEngagePlugin())
/// ```
///
/// ## What this plugin holds, and when it lets go
///
/// WebEngage has no single visual slot the way CleverTap does. What it has is a
/// **per-experiment gate**: when a campaign is suppressed so Digia can render it
/// (`WebEngageSdkBridge.notificationPrepared`), that experiment is marked active
/// and WebEngage will not prepare it again. Because a suppressed notification
/// never reaches WebEngage's own dismiss callback, nothing on WebEngage's side
/// ever clears that mark — so the plugin must, and it does so when the
/// presentation's `outcome` settles, on **both** arms.
///
/// The gate is bound to `outcome` rather than to `holdReleased` (spec §7.2
/// sketches the latter) because it is a *de-duplication* gate, not a queue hold:
/// releasing it while the experience is still on screen would let WebEngage
/// prepare the same campaign on top of itself. Nothing here binds to
/// `holdReleased` — for a modal experience the two settle together anyway.
@MainActor
public final class DigiaWebEngagePlugin: DigiaCEPPlugin {

    // MARK: - State

    public let id: String = "webengage"

    private let bridge: WebEngageBridgeProtocol
    private let mapper: WebEngagePayloadMapper
    private let config: WebEngagePluginConfig
    private let cache:  InAppDataCache
    private lazy var dispatcher = WebEngageEventDispatcher(bridge: bridge, cache: cache)

    private var host: DigiaCEPHost?
    private var callbacksRegistered: Bool = false

    /// Presentations this plugin still owns, keyed by WebEngage experiment id.
    ///
    /// Also the idempotency guard on the terminal path: `finish` removes the
    /// entry first, so the outcome task, a WebEngage-side dismissal and `detach`
    /// can all race and only the first one does any work.
    private var live: [String: CampaignPresentation] = [:]

    // MARK: - AppDelegate hook

    /// The in-app notification delegate that must be passed to WebEngage at SDK
    /// initialisation time in your `AppDelegate`:
    /// ```swift
    /// WebEngage.sharedInstance().application(
    ///     application,
    ///     didFinishLaunchingWithOptions: launchOptions,
    ///     notificationDelegate: WebEngagePlugin.notificationDelegate
    /// )
    /// ```
    /// WebEngage keeps only a **weak** reference to this object; the shared
    /// bridge singleton at class scope ensures its lifetime.
    nonisolated public static let notificationDelegate: any WEGInAppNotificationProtocol = WebEngageSdkBridge.shared

    // MARK: - Init

    /// Designated public initialiser.
    public convenience init(config: WebEngagePluginConfig = WebEngagePluginConfig()) {
        let cache  = InAppDataCache()
        // Reuse the same singleton that AppDelegate registered with WebEngage SDK.
        let bridge = WebEngageSdkBridge.shared
        bridge.config = config
        let mapper = WebEngagePayloadMapper(config: config)
        self.init(bridge: bridge, mapper: mapper, config: config, cache: cache)
    }

    /// Internal / test initialiser with injectable bridge and mapper.
    internal init(
        bridge: WebEngageBridgeProtocol,
        mapper: WebEngagePayloadMapper,
        config: WebEngagePluginConfig,
        cache:  InAppDataCache
    ) {
        self.bridge  = bridge
        self.mapper  = mapper
        self.config  = config
        self.cache   = cache
    }

    // MARK: - DigiaCEPPlugin

    public func attach(host: DigiaCEPHost) {
        logDebug("attach start diagnostics=\(config.diagnosticsEnabled)")
        self.host = host
        bridge.registerInAppListener(
            onPayload:    { [weak self] data in onMainActor { self?.dispatchMappedPayloads(data) } },
            onInvalidate: { [weak self] id   in onMainActor { self?.dispatchInvalidation(campaignID: id) } }
        )
        bridge.registerInlineListener { [weak self] cid, tvid, custom, meta in
            onMainActor {
                self?.dispatchInlinePayload(campaignId: cid, targetViewId: tvid,
                                            customData: custom, metadata: meta)
            }
        }
        callbacksRegistered = true
        logDebug("attach complete hostAttached=\(self.host != nil)")
    }

    public func onScreenChanged(_ screenName: String) {
        logDebug("screen_changed name=\(screenName)")
        dispatcher.forwardScreen(screenName)
    }

    public func detach() {
        logDebug("detach start")
        bridge.unregisterInAppListener()
        bridge.unregisterInlineListener()

        // Core settles a plugin's presentations before detaching it, but the
        // tasks awaiting those outcomes have not necessarily run yet — and a
        // gate left set silences that campaign for the rest of the session.
        // This is the last moment the plugin can free WebEngage's side.
        for (experimentId, presentation) in live {   // a snapshot: `finish` mutates `live`
            // Read the outcome rather than assuming `false`: `cancel()` settles on the main
            // actor, inline, so by now the true terminal result is here. If core had already
            // settled this presentation as `dismissed` and only its awaiting task had yet to
            // run, hardcoding `false` silently dropped the final CEP marking for a campaign
            // the user really did see.
            presentation.cancel()
            finish(
                experimentId: experimentId,
                trigger: presentation.trigger,
                displayed: presentation.outcome.settledValue.map(didDisplay) ?? false
            )
        }
        live.removeAll()

        cache.clear()
        callbacksRegistered = false
        host = nil
        logDebug("detach complete")
    }

    /// Not part of ``DigiaCEPPlugin`` — a plugin-level diagnostic a host app
    /// can call directly.
    public func healthCheck() -> DiagnosticReport {
        let attached = host != nil
        let isAvailable = bridge.isAvailable()
        let isHealthy   = attached && isAvailable
        return DiagnosticReport(
            isHealthy: isHealthy,
            issue: isHealthy ? nil : "webengage plugin not fully wired",
            resolution: isHealthy ? nil : "Call Digia.register(DigiaWebEngagePlugin()) after WebEngage initialises",
            metadata: [
                "id":                   id,
                "attached":             String(attached),
                "bridgeAvailable":      String(isAvailable),
                "callbacksRegistered":  String(callbacksRegistered),
                "livePresentations":    String(live.count),
                "diagnosticsEnabled":   String(config.diagnosticsEnabled),
            ]
        )
    }

    // MARK: - Private dispatch

    private func dispatchMappedPayloads(_ rawPayload: [String: Any]) {
        let payloads = mapper.map(rawPayload)
        guard !payloads.isEmpty else {
            logWarning("inapp_payload_dropped reason=mapper_returned_empty"); return
        }
        payloads.forEach(deliver)
    }

    private func dispatchInlinePayload(
        campaignId:  String,
        targetViewId: String,
        customData:  [String: Any],
        metadata:    [String: Any]
    ) {
        guard let payload = mapper.mapInline(
            campaignId: campaignId,
            targetViewId: targetViewId,
            customData: customData,
            metadata: metadata
        ) else { return }
        deliver(payload)
    }

    /// WebEngage told us the campaign is gone — it was pulled, or the user
    /// dismissed WebEngage's own surface. Owner-initiated termination, so the
    /// presentation is cancelled; core settles it and the normal terminal path
    /// does the rest.
    private func dispatchInvalidation(campaignID: String) {
        guard let presentation = live[campaignID] else {
            logDebug("invalidation for an experiment we do not hold campaignID=\(campaignID)"); return
        }
        logDebug("dispatch_invalidation campaignID=\(campaignID)")
        presentation.cancel()
        // See `detach()`: the settled outcome is already here, and it is the honest answer.
        finish(
            experimentId: campaignID,
            trigger: presentation.trigger,
            displayed: presentation.outcome.settledValue.map(didDisplay) ?? false
        )
    }

    // MARK: - Delivery

    /// Hands a trigger to Digia and binds WebEngage's side to the handle.
    ///
    /// Three bindings, and no fourth: view/click ride `onSignal`, the close
    /// analytic and the gate ride `outcome`, and nothing rides `holdReleased` —
    /// see the type doc.
    private func deliver(_ trigger: CEPTriggerPayload) {
        guard let host else {
            logWarning("payload_dropped payloadId=\(trigger.cepCampaignId) reason=host_unavailable")
            return
        }
        let experimentId = trigger.cepMetadata["experimentId"] ?? trigger.cepCampaignId
        logDebug("deliver payloadId=\(trigger.cepCampaignId) exp=\(experimentId)")

        let presentation = host.deliver(trigger)
        live[experimentId] = presentation

        _ = presentation.onSignal { [weak self] signal in
            guard let self else { return }
            switch signal {
            case .displayed:
                self.dispatcher.notificationViewed(trigger)
            case .clicked(let elementId):
                self.dispatcher.notificationClicked(trigger, elementId: elementId)
            }
        }

        // A synchronous drop settled before any task could be scheduled. Free
        // the gate inline rather than across a suspension point.
        if let outcome = presentation.outcome.settledValue {
            finish(experimentId: experimentId, trigger: trigger, displayed: didDisplay(outcome))
            return
        }

        // `weak self`: PresentationPromise deliberately ignores cancellation, so
        // a task awaiting an outcome core never settles parks forever — it must
        // not keep the plugin alive.
        Task { @MainActor [weak self] in
            let outcome = await presentation.outcome.value
            self?.finish(experimentId: experimentId, trigger: trigger, displayed: didDisplay(outcome))
        }
    }

    /// The single terminal funnel. Idempotent through `live`, so the outcome
    /// task, a WebEngage-side dismissal and `detach()` may all call it.
    private func finish(experimentId: String, trigger: CEPTriggerPayload, displayed: Bool) {
        guard live.removeValue(forKey: experimentId) != nil else { return }
        dispatcher.experienceEnded(trigger, displayed: displayed)
        bridge.releaseGate(experimentId: experimentId)
        logDebug("finished exp=\(experimentId) displayed=\(displayed)")
    }

    // MARK: - Logging

    private func logDebug(_ message: String) {
        if config.diagnosticsEnabled { NSLog("[DigiaWEPlugin] \(message)") }
    }

    private func logWarning(_ message: String) {
        NSLog("[DigiaWEPlugin] WARNING: \(message)")
    }
}

/// Runs `work` on the main actor, inline when the caller is already there.
///
/// WebEngage delivers its in-app callbacks on the main thread. An unconditional
/// `Task { @MainActor in … }` would defer every delivery by a turn, which lets
/// `detach()` run between WebEngage suppressing a campaign and the plugin seeing
/// it — the payload is then dropped with its gate still set, and that campaign is
/// silenced for the rest of the session. Mirrors the CleverTap plugin's helper of
/// the same name.
private func onMainActor(_ work: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(work)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}

/// `dismissed` is the only arm that means the experience reached the screen.
private func didDisplay(_ outcome: PresentationOutcome) -> Bool {
    if case .dismissed = outcome { return true }
    return false
}
