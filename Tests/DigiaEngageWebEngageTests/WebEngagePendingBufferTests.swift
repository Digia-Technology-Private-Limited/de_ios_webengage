@testable import DigiaEngage
@testable import DigiaEngageWebEngage
import Foundation
import Testing

/// The plugin pending buffer (de_workspace#71).
@MainActor
@Suite("DigiaWebEngagePlugin — pending buffer", .serialized)
struct WebEngagePendingBufferTests {
    private let bridge = FakeWebEngageBridge()
    private let host: FakeCEPHost
    private let plugin: DigiaWebEngagePlugin

    init() {
        let config = WebEngagePluginConfig(diagnosticsEnabled: false)
        host = FakeCEPHost()
        host.isReady = false
        plugin = DigiaWebEngagePlugin(
            bridge: bridge,
            mapper: WebEngagePayloadMapper(config: config),
            config: config,
            cache: InAppDataCache()
        )
        plugin.attach(host: host)
    }

    private var keys: [String] { host.delivered.map(\.campaignKey) }

    @Test("held while Core is not READY with the gate kept, flushed newest first on ready")
    func flushNewestFirst() {
        bridge.emitPrepared(inAppPayload(experimentId: "e1", campaignKey: "k1"))
        bridge.emitPrepared(inAppPayload(experimentId: "e2", campaignKey: "k2"))
        #expect(host.delivered.isEmpty)
        #expect(bridge.releasedGates.isEmpty)

        host.isReady = true
        plugin.onHostReady()
        #expect(keys == ["k2", "k1"])
    }

    @Test("a not_ready outcome puts the in-app back without releasing the gate")
    func notReadyRebuffers() {
        host.isReady = true
        host.syncDrop = .notReady
        bridge.emitPrepared(inAppPayload())
        #expect(host.delivered.count == 1)
        #expect(bridge.releasedGates.isEmpty)

        host.syncDrop = nil
        plugin.onHostReady()
        #expect(host.delivered.count == 2)
    }

    @Test("FAILED releases held gates and later in-apps go straight to Core")
    func failedStopsBuffering() {
        bridge.emitPrepared(inAppPayload(experimentId: "e1"))
        plugin.onHostInitFailed()
        #expect(bridge.releasedGates == ["e1"])

        host.syncDrop = .initializationFailed
        bridge.emitPrepared(inAppPayload(experimentId: "e2"))
        #expect(host.delivered.count == 1)
    }

    @Test("detach releases held gates")
    func detachReleases() {
        bridge.emitPrepared(inAppPayload(experimentId: "e1"))
        plugin.detach()
        #expect(bridge.releasedGates == ["e1"])
        #expect(host.delivered.isEmpty)
    }
}
