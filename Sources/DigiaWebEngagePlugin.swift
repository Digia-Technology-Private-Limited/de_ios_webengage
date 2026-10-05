import Foundation
import DigiaEngage
@preconcurrency import WebEngage

/// Top-level plugin that wires WebEngage in-app callbacks into Digia's
/// CEP rendering engine on iOS.  Drop-in equivalent of `WebEngagePlugin.kt` on Android.
///
/// **Usage (AppDelegate):**
/// ```swift
/// import DigiaEngageWebEngage
///
/// WebEngage.sharedInstance().application(
///     application,
///     didFinishLaunchingWithOptions: launchOptions,
///     notificationDelegate: DigiaWebEngagePlugin.notificationDelegate
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
/// ever clears that mark — so the plugin must, and it does so 1 s after the
/// presentation's `holdReleased` settles: `notification_close` makes WebEngage
/// re-prepare the campaign it just closed within milliseconds.
///
/// The gate stays a *de-duplication* gate, not a queue hold: the delay stops
/// WebEngage preparing the same campaign on top of itself. An inline outcome
/// fires only when its slot hides, and that may be never — binding to `outcome`
/// would silence that experiment for the rest of the session. Modals are
/// unaffected: the two settle together there.
@MainActor
public final class DigiaWebEngagePlugin: DigiaCEPPlugin {

    // MARK: - State

    public let id: String = "webengage"

    private let bridge: WebEngageBridgeProtocol
    private let mapper: WebEngagePayloadMapper
    private let config: WebEngagePluginConfig
    private let cache:  InAppDataCache
    private lazy var dispatcher = WebEngageEventDispatcher(bridge: bridge, cache: cache)
    private let log = DigiaLogger("WE")

    private var host: DigiaCEPHost?
    private var callbacksRegistered: Bool = false

    /// Presentations this plugin still owns, keyed by WebEngage experiment id.
    ///
    /// Also the idempotency guard on the terminal path: `finish` removes the
    /// entry first, so the outcome task, a WebEngage-side dismissal and `detach`
    /// can all race and only the first one does any work.
    private var live: [String: CampaignPresentation] = [:]

    /// In-apps held while Core is not ready, one copy per experiment id.
    /// WebEngage's queue waits until each one settles.
    private lazy var pending = PendingPayloadBuffer(onDrop: { [weak self] in self?.onPendingDropped($0, $1) })

    /// Core init failed: stop holding until Core is ready again.
    private var hostFailed = false

    // MARK: - AppDelegate hook

    /// The in-app notification delegate that must be passed to WebEngage at SDK
    /// initialisation time in your `AppDelegate`:
    /// ```swift
    /// WebEngage.sharedInstance().application(
    ///     application,
    ///     didFinishLaunchingWithOptions: launchOptions,
    ///     notificationDelegate: DigiaWebEngagePlugin.notificationDelegate
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
        self.host = host
        log.i("Plugin attached — listening for in-app campaigns")
        bridge.registerInAppListener(
            onPayload:    { [weak self] data in onMainActor { self?.dispatchMappedPayload(data) } },
            onInvalidate: { [weak self] id   in onMainActor { self?.dispatchInvalidation(campaignID: id) } }
        )
        bridge.registerInlineListener { [weak self] cid, tvid, custom, meta in
            onMainActor {
                self?.dispatchInlinePayload(campaignId: cid, targetViewId: tvid,
                                            customData: custom, metadata: meta)
            }
        }
        callbacksRegistered = true
        if host.isReady { onHostReady() }
    }

    public func onHostReady() {
        hostFailed = false
        let held = pending.takeAll()
        guard !held.isEmpty else { return }
        log.i("Digia ready — flushing \(held.count) held payloads")
        held.forEach(deliver)
    }

    public func onHostInitFailed() {
        onHostFailed()
    }

    public func onScreenChanged(_ screenName: String) {
        dispatcher.forwardScreen(screenName)
    }

    public func detach() {
        bridge.unregisterInAppListener()
        bridge.unregisterInlineListener()
        hostFailed = false
        pending.dropAll(DropReason.pluginDetached)

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
        log.i("Plugin detached")
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

    private func dispatchMappedPayload(_ rawPayload: [String: Any]) {
        guard let payload = mapper.map(rawPayload) ?? mapper.mapBadValue(rawPayload) else { return }
        deliver(payload)
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
        guard let presentation = live[campaignID] else { return }
        log.d("WebEngage dismissed the campaign itself — cancelling (experimentId=\(campaignID))", campaign: presentation.trigger.campaignKey)
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
    /// analytic rides `outcome` via `finish`, and the gate rides `holdReleased`
    /// via `notifyDismissed` — see the type doc.
    private func deliver(_ trigger: CEPTriggerPayload) {
        let experimentId = Self.experimentId(of: trigger)
        guard let host else {
            log.w(
                "Dropping in-app — no host attached (reason=not_ready, "
                    + "experimentId=\(experimentId.isEmpty ? "-" : experimentId))",
                campaign: trigger.campaignKey,
                stage: .trigger,
                reason: DropReason.notReady
            )
            settleUndelivered(experimentId)
            return
        }
        if !hostFailed && !host.isReady {
            log.i("Held until Digia is ready (experimentId=\(experimentId))", campaign: trigger.campaignKey)
            pending.add(trigger)
            return
        }
        log.i("Received — in-app (experimentId=\(experimentId))", campaign: trigger.campaignKey)

        let presentation = host.deliver(trigger)
        // A held in-app keeps WebEngage's hold until it is shown or dropped.
        if holdIfNotReady(presentation) { return }
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

        // Gate rides holdReleased; attach before the sync-drop check so settled
        // holds still free. weak self: a parked task must not retain the plugin.
        Task { @MainActor [weak self] in
            _ = await presentation.holdReleased.value
            self?.bridge.notifyDismissed(experimentId: experimentId)
        }

        // A synchronous drop settled before any task could be scheduled. Finish
        // inline rather than across a suspension point; the hold observer above
        // still schedules the gate.
        if let outcome = presentation.outcome.settledValue {
            finish(experimentId: experimentId, trigger: trigger, displayed: didDisplay(outcome))
            return
        }

        Task { @MainActor [weak self] in
            let outcome = await presentation.outcome.value
            self?.finish(experimentId: experimentId, trigger: trigger, displayed: didDisplay(outcome))
        }
    }

    /// Holds a not-ready in-app again and returns true; stops holding on
    /// initialization_failed.
    private func holdIfNotReady(_ presentation: CampaignPresentation) -> Bool {
        guard case .dropped(let reason, _)? = presentation.outcome.settledValue else { return false }
        switch reason {
        case .notReady where !hostFailed, .notInitialized where !hostFailed:
            log.i("Digia not ready — held again", campaign: presentation.trigger.campaignKey, reason: reason)
            pending.add(presentation.trigger)
            return true
        case .initializationFailed:
            onHostFailed()
        default:
            break
        }
        return false
    }

    private func onHostFailed() {
        guard !hostFailed else { return }
        hostFailed = true
        pending.dropAll(DropReason.initializationFailed)
    }

    private func onPendingDropped(_ trigger: CEPTriggerPayload, _ reason: DiagnosticReason) {
        let experimentId = Self.experimentId(of: trigger)
        log.w("Dropped while held (experimentId=\(experimentId))", campaign: trigger.campaignKey, stage: .trigger, reason: reason)
        settleUndelivered(experimentId)
    }

    /// Settles an undelivered in-app with WebEngage: frees its cache entry and its gate.
    private func settleUndelivered(_ experimentId: String) {
        guard !experimentId.isEmpty else { return }
        cache.remove(experimentId: experimentId)
        bridge.notifyDismissed(experimentId: experimentId)
    }

    private static func experimentId(of trigger: CEPTriggerPayload) -> String {
        trigger.cepMetadata["experimentId"] ?? trigger.cepCampaignId
    }

    /// The single terminal funnel. Idempotent through `live`, so the outcome
    /// task, a WebEngage-side dismissal and `detach()` may all call it.
    /// Markings and cache eviction only — the gate rides `holdReleased`.
    private func finish(experimentId: String, trigger: CEPTriggerPayload, displayed: Bool) {
        guard live.removeValue(forKey: experimentId) != nil else { return }
        dispatcher.experienceEnded(trigger, displayed: displayed)
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
