import Foundation
import GRDB
import XCTest
@testable import HomeostatCore

final class RepairRegressionTests: XCTestCase {
    @discardableResult
    func commit(_ raw: RawSample, store: LocalStore, zone: String = CHICAGO) throws -> LocalStore.PageResult {
        try store.commitPage(type: raw.domain.rawValue, domain: raw.domain, predicateVersion: "v", samples: [raw],
                             deleted: [], newAnchor: Data([1]), normalizer: Normalizer(deviceZone: zone), now: NOW)
    }

    func testReimportAfterTravelPreservesFirstFallbackZoneButDetectsChangedValues() throws {
        let store = try LocalStore(path: nil)
        var raw = sample(.hrvSDNN(milliseconds: 50), start: NOW.wire, end: NOW.wire, zone: "invalid")
        XCTAssertEqual(try commit(raw, store: store).newEvents, 1)
        XCTAssertEqual(try commit(raw, store: store, zone: "Asia/Tokyo").skippedDuplicates, 1)
        raw.kind = .hrvSDNN(milliseconds: 51)
        XCTAssertEqual(try commit(raw, store: store, zone: "Asia/Tokyo").newEvents, 1)
    }

    func testQuarantineRetainsUnknownValuesAndScopesCoverageUntilResolved() throws {
        let store = try LocalStore(path: nil)
        var raw = sample(.sleep(nil), start: "2026-09-22T05:00:00Z", end: "2026-09-22T06:00:00Z")
        raw.rawCategoryValue = 12345
        try commit(raw, store: store)
        let saved = try store.db.read { try Data.fetchOne($0, sql: "SELECT raw_sample FROM quarantine")! }
        XCTAssertEqual(try JSONDecoder().decode(RawSample.self, from: saved), raw)
        XCTAssertEqual(try store.reprocessQuarantine(normalizer: Normalizer(deviceZone: CHICAGO), now: NOW), 0)
        let affected = LocalStore.CoverageDeclaration(domain: .sleep, timezone: CHICAGO,
                                                      start: NOW.adding(seconds: -86400), end: NOW)
        XCTAssertFalse(try store.enqueueCoverage(affected, now: NOW))
        XCTAssertTrue(try store.enqueueCoverage(.init(domain: .sleep, timezone: CHICAGO,
                                                       start: NOW, end: NOW.adding(seconds: 86400)), now: NOW))
        // A corrected provider read repairs the retained item atomically.
        raw.kind = .sleep(.asleepCore)
        try commit(raw, store: store)
        XCTAssertEqual(try store.counts().quarantined, 0)
        XCTAssertTrue(try store.enqueueCoverage(affected, now: NOW))
    }

    func testNonFiniteQuarantineDataCanBeStoredWithoutAdvancingPastLostData() throws {
        let store = try LocalStore(path: nil)
        try commit(sample(.hrvSDNN(milliseconds: .nan), start: NOW.wire, end: NOW.wire), store: store)
        XCTAssertEqual(try store.counts().quarantined, 1)
        XCTAssertEqual(try store.reprocessQuarantine(normalizer: Normalizer(deviceZone: CHICAGO), now: NOW), 0)
        XCTAssertNotNil(try store.anchor(type: "hrv", predicateVersion: "v"))
    }

    func testFullRefreshCheckpointRollsBackWithSnapshotsAndCoverage() throws {
        let store = try LocalStore(path: nil)
        let snapshot = CanonicalEvent.Snapshot(eventID: UUID(), day: Zone(CHICAGO)!.day(of: NOW), timezone: CHICAGO,
                                               asOf: NOW, queriedAt: NOW, steps: 100)
        let coverage = LocalStore.CoverageDeclaration(domain: .movement, timezone: CHICAGO,
                                                      start: NOW.adding(seconds: -86400), end: NOW)
        XCTAssertThrowsError(try store.commitSnapshots([snapshot], coverage: coverage, now: NOW,
                                                        fullRefreshDay: "2026-09-22", beforeCommit: { throw FakeSource.Failure() }))
        XCTAssertNil(try store.value("steps_full_refresh_day"))
        XCTAssertEqual(try store.counts().pending, 0)
        XCTAssertEqual(try store.counts().coveragePending, 0)
        _ = try store.commitSnapshots([snapshot], coverage: coverage, now: NOW, fullRefreshDay: "2026-09-22")
        XCTAssertEqual(try store.value("steps_full_refresh_day"), "2026-09-22")
        XCTAssertEqual(try store.counts().pending, 1)
    }

    func testRecoveryInvalidatesCoverageEvenIfFreshQueryFailsAndSurvivesRestart() async throws {
        let store = try LocalStore(path: nil)
        let source = FakeSource()
        let engine = ImportEngine(store: store, source: source, clock: { NOW }, deviceZone: { CHICAGO })
        _ = try await engine.drain(.hrv)
        let rhrVersion = try await engine.predicateVersion(.rhr)
        source.corruptAnchorOnce = [.hrv]
        source.failAfterPages[.hrv] = 0
        // FakeSource reports corruption before its injected query failure.
        do { _ = try await engine.drain(.hrv) } catch {}
        XCTAssertEqual(try store.value("recovery_hrv"), "incomplete")
        let unchanged = try await engine.predicateVersion(.rhr)
        XCTAssertEqual(unchanged, rhrVersion)
        source.failAfterPages[.hrv] = nil
        let restarted = ImportEngine(store: store, source: source, clock: { NOW }, deviceZone: { CHICAGO })
        _ = try await restarted.drain(.hrv)
        let statuses = try await store.db.read {
            try String.fetchAll($0, sql: "SELECT status FROM coverage_outbox WHERE domain = 'hrv' AND state = 'pending'")
        }
        XCTAssertFalse(statuses.isEmpty)
        XCTAssertEqual(Set(statuses), ["unavailable"])
    }

    func testCoverageBacklogFitsFullRequestBudgetAndEventuallyDrains() throws {
        let store = try LocalStore(path: nil)
        for index in 0..<20 {
            try store.enqueueCoverage(.init(domain: .hrv, timezone: CHICAGO,
                                             start: NOW.adding(seconds: -86400), end: NOW.adding(seconds: Int64(index))), now: NOW)
        }
        var count = 0
        while let request = try store.nextRequest(deviceZone: CHICAGO, maxEvents: 250, maxBytes: 600, now: NOW) {
            XCTAssertLessThanOrEqual(request.body.count, 600)
            try store.apply(accepted(request), to: request)
            count += 1
            if count > 30 { return XCTFail("queue did not drain") }
        }
        XCTAssertGreaterThan(count, 1)
        XCTAssertEqual(try store.counts().coveragePending, 0)
    }

    func test413SplitsCoverageWithoutDiscardingTheSingleHealthyEvent() async throws {
        let store = try LocalStore(path: nil)
        try commit(sample(.hrvSDNN(milliseconds: 50), start: NOW.wire, end: NOW.wire), store: store)
        for _ in 0..<4 {
            try store.enqueueCoverage(.init(domain: .sleep, timezone: CHICAGO,
                                             start: NOW.adding(seconds: -86400), end: NOW), now: NOW)
        }
        let server = acceptingServer()
        let transport = FakeTransport { request in
            let json = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
            guard case .array(let coverage)? = json["coverage"], case .array(let events)? = json["events"] else {
                throw FakeSource.Failure()
            }
            return coverage.count + events.count > 1 ? (413, Data(), [:]) : try await server(request)
        }
        let sync = SyncEngine(store: store, config: BackendConfig(baseURL: URL(string: "http://localhost")!, apiKey: "k"),
                              transport: transport, clock: { NOW }, deviceZone: { CHICAGO })
        let outcomes = await sync.syncAll()
        XCTAssertEqual(outcomes.last, .idle)
        XCTAssertEqual(try store.counts().acknowledged, 1)
        XCTAssertEqual(try store.counts().deadLetter, 0)
        XCTAssertEqual(try store.counts().coveragePending, 0)
    }

    @MainActor
    func testScheduledRetryUploadsAfterFailureWithoutAnotherExternalTrigger() async throws {
        let store = try LocalStore(path: nil)
        try commit(sample(.hrvSDNN(milliseconds: 50), start: NOW.wire, end: NOW.wire), store: store)
        let attempts = IDs()
        let server = acceptingServer()
        let transport = FakeTransport { request in
            if attempts.make().uuidString.hasSuffix("000000000001") { return (503, Data(), [:]) }
            return try await server(request)
        }
        let sync = SyncEngine(store: store, config: BackendConfig(baseURL: URL(string: "http://localhost")!, apiKey: "k"),
                              transport: transport, deviceZone: { CHICAGO })
        guard case .retryScheduled(let at, _) = await sync.syncOnce() else { return XCTFail() }
        let done = expectation(description: "automatic retry")
        let scheduler = UploadRetryScheduler()
        scheduler.schedule(at: at.date) {
            let outcome = await sync.syncOnce()
            if case .sent = outcome {} else { XCTFail("\(outcome)") }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(try store.counts().acknowledged, 1)
        XCTAssertEqual(transport.bodies.first, transport.bodies.last)
    }

    @MainActor
    func testCancelledForegroundRetryDoesNotSend() async {
        let scheduler = UploadRetryScheduler()
        let cancelled = expectation(description: "no upload after background or disable")
        cancelled.isInverted = true
        scheduler.schedule(at: Date().addingTimeInterval(0.02)) { cancelled.fulfill() }
        scheduler.cancel()
        await fulfillment(of: [cancelled], timeout: 0.06)
    }
}

extension RepairRegressionTests {
    func testUpgradePreservesQueueAndFallbackZoneAndInvalidatesLegacyRecovery() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let raw = sample(.hrvSDNN(milliseconds: 50), start: NOW.wire, end: NOW.wire, zone: "invalid")
        guard case .event(let event) = Normalizer(deviceZone: CHICAGO).normalize(raw, eventID: UUID()) else {
            return XCTFail()
        }
        do {
            let old = try DatabaseQueue(path: path)
            try LocalStore.migrator.migrate(old, upTo: "v1")
            try old.write { db in
                _ = try LocalStore.enqueueIfNew(event, domain: .hrv, now: NOW, in: db)
                try LocalStore.set("2026-09-22", "steps_full_refresh_day", in: db)
                try LocalStore.set("hrv at old query", "last_anchor_recovery", in: db)
                try LocalStore.set(NOW.adding(seconds: -86400).wire, "import_lower_bound", in: db)
                try LocalStore.set("2", "query_generation", in: db)
            }
        }
        let upgraded = try LocalStore(path: path)
        XCTAssertEqual(try upgraded.counts().pending, 1)
        XCTAssertNil(try upgraded.value("steps_full_refresh_day"))
        XCTAssertEqual(try commit(raw, store: upgraded, zone: "Asia/Tokyo").skippedDuplicates, 1)
        XCTAssertEqual(try upgraded.value("recovery_hrv"), "incomplete")
        XCTAssertEqual(try upgraded.counts().coveragePending, 4)
        let again = try LocalStore(path: path)
        XCTAssertEqual(try again.counts().coveragePending, 4) // migration is not repeated
    }
}
