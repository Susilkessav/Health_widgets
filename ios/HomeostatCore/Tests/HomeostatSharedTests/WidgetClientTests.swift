import Foundation
import XCTest
@testable import HomeostatShared

final class WidgetClientTests: XCTestCase {
    var directory: URL!
    var store: SharedWidgetStore!
    let now = Instant.parse("2026-09-30T12:00:00Z")!
    let account = UUID()
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SharedWidgetStore(directory: directory)
        try store.activate(config())
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    func config(scope: String = "one") -> WidgetBackendConfiguration {
        .init(scope: scope, baseURL: URL(string: "https://example.com")!, accountID: account,
              credentialID: "test", syncEnabled: true)
    }
    func payload(run: Int = 2, account: UUID? = nil) throws -> Data {
        let widget = WidgetState(effectiveAt: now, presentation: .init(icon: "🙂", headline: "Typical day"),
            primaryTrait: .init(id: "typical", explainable: true), freshness: .init(lastUpdatedAt: now))
        let state = try JSONSerialization.jsonObject(with: JSONEncoder().encode(widget))
        return try JSONSerialization.data(withJSONObject: ["schema": 1, "account_id": (account ?? self.account).uuidString,
            "calculation_status": "ready", "accepted_revision": 3,
            "published": ["day": "2026-09-30", "timezone": "UTC", "input_revision": 3, "run_id": run, "widget_state": state]])
    }
    func testFetchPublishesWithoutChangingHealthFreshnessAndSuppressesAnotherFetch() async throws {
        let body = try payload()
        await WidgetClient.refresh(store: store, now: now, credential: { _ in "token" }) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let manifest = try store.manifest()
        XCTAssertEqual(manifest.cache?.runID, 2)
        XCTAssertEqual(manifest.cache?.widgetState.freshness.lastUpdatedAt, now)
        XCTAssertEqual(manifest.fetch.lastCheckedAt, now)
        await WidgetClient.refresh(store: store, now: now.adding(seconds: 5), credential: { _ in "token" }) { _ in
            XCTFail("recent successful check should suppress GET"); throw URLError(.unknown)
        }
    }
    func testLateAccountResponseAndOlderRunCannotOverwriteCache() async throws {
        let body = try payload()
        let store = self.store!
        let replacement = config(scope: "two")
        await WidgetClient.refresh(store: store, now: now, credential: { _ in "token" }) { request in
            try store.activate(replacement)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertNil(try store.manifest().cache)
        try store.activate(config())
        let newer = try JSONDecoder().decode(WidgetPublication.self, from: payload(run: 10)).published!
        await WidgetClient.refresh(store: store, now: now, credential: { _ in "token" }) { request in
            _ = try store.write(WidgetCache(scope: "one", day: newer.day, inputRevision: 3, runID: 10,
                widgetState: newer.widgetState), now: self.now)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(try store.manifest().cache?.runID, 10)
    }
    func testUnauthorizedHaltsUntilReconfiguredAndRetryAfterWins() async throws {
        await WidgetClient.refresh(store: store, now: now, credential: { _ in "token" }) { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertTrue(try store.manifest().fetch.unauthorized)
        await WidgetClient.refresh(store: store, now: now.adding(seconds: 86400), credential: { _ in "token" }) { _ in
            XCTFail("401 must stop polling"); throw URLError(.unknown)
        }
        try store.activate(config())
        await WidgetClient.refresh(store: store, now: now, credential: { _ in "token" }) { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": "9000"])!)
        }
        XCTAssertEqual(try store.manifest().fetch.nextAttemptAt, now.adding(seconds: 9000))
    }
    func testUnavailableCredentialAndDisabledSyncNeverIssueRequests() async throws {
        await WidgetClient.refresh(store: store, now: now, credential: { _ in nil }) { _ in
            XCTFail("no credential"); throw URLError(.unknown)
        }
        XCTAssertFalse(try store.manifest().fetch.unauthorized)
        var disabled = config(); disabled.syncEnabled = false
        try store.activate(disabled)
        await WidgetClient.refresh(store: store, now: now, credential: { _ in "token" }) { _ in
            XCTFail("sync disabled"); throw URLError(.unknown)
        }
    }
    func testWrongAccountOrMalformedResponsePreservesCachedState() async throws {
        let body = try payload(account: UUID())
        await WidgetClient.refresh(store: store, now: now, credential: { _ in "token" }) { request in
            (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertNil(try store.manifest().cache)
        XCTAssertEqual(try store.manifest().fetch.lastError, "fetch_failed")
    }
}

extension WidgetClientTests {
    func testLeaseSuppressesParallelFetchAndExpiredLeaseCannotPublishLate() async throws {
        let old = try payload(run: 2)
        let new = try payload(run: 5)
        let store = self.store!
        let now = self.now
        await WidgetClient.refresh(store: store, now: now, credential: { _ in "token" }) { request in
            await WidgetClient.refresh(store: store, now: now, credential: { _ in "token" }) { _ in
                XCTFail("live lease must suppress duplicate GET"); throw URLError(.unknown)
            }
            await WidgetClient.refresh(store: store, now: now.adding(seconds: 21), credential: { _ in "token" }) { inner in
                (new, HTTPURLResponse(url: inner.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (old, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(try store.manifest().cache?.runID, 5)
    }

    func testConfigurationCanRepairCorruptCacheAndToggleKeepsDatedState() async throws {
        try Data("damaged".utf8).write(to: store.fileURL)
        try store.activate(config())
        let body = try payload()
        await WidgetClient.refresh(store: store, now: now, credential: { _ in "token" }) { request in
            (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        var disabled = config(); disabled.syncEnabled = false
        try store.activate(disabled)
        XCTAssertEqual(try store.manifest().cache?.runID, 2)
        XCTAssertFalse(try store.manifest().configuration!.syncEnabled)
    }
}
