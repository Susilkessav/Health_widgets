import Foundation
import GRDB
import XCTest
@testable import HomeostatCore

final class ImportEngineTests: XCTestCase {
    var store: LocalStore!
    var clock: TestClock!
    var source: FakeSource!

    override func setUpWithError() throws {
        store = try LocalStore(path: nil)
        clock = TestClock()
        source = FakeSource()
    }

    func engine(zone: String = CHICAGO) -> ImportEngine {
        let clock = self.clock!
        return ImportEngine(store: store, source: source, clock: { clock.now }, deviceZone: { zone })
    }

    func page(_ values: [Double], anchor: UInt8, more: Bool, deleted: [UUID] = []) -> AnchoredPage {
        AnchoredPage(samples: values.map {
            sample(.hrvSDNN(milliseconds: $0), start: "2026-09-22T11:59:00Z", end: "2026-09-22T12:00:00Z")
        }, deleted: deleted, anchor: Data([anchor]), hasMore: more)
    }

    func pending() throws -> Int { try store.counts().pending }

    func test_pagesCommitWithTheirAnchorsAndCoverageFollowsSuccess() async throws {
        source.pages[.hrv] = [page([50, 51], anchor: 1, more: true), page([52], anchor: 2, more: false)]
        let outcome = try await engine().drain(.hrv)
        guard case .drained(let totals) = outcome else { return XCTFail() }
        XCTAssertEqual(totals.pages, 2)
        XCTAssertEqual(totals.newEvents, 3)
        XCTAssertTrue(totals.coverageQueued)
        XCTAssertEqual(source.anchorsSeen[.hrv], [nil, Data([1])])  // page 2 was asked from page 1's anchor
        XCTAssertEqual(try pending(), 3)
    }

    func test_aFailureMidDrainKeepsCommittedPagesAndTheLastAnchorAndDeclaresNoCoverage() async throws {
        source.pages[.hrv] = [page([50], anchor: 1, more: true), page([51], anchor: 2, more: false)]
        source.failAfterPages[.hrv] = 1
        let sut = engine()
        do {
            _ = try await sut.drain(.hrv)
            XCTFail("expected the second page to fail")
        } catch {}
        let version = try await sut.predicateVersion()
        XCTAssertEqual(try store.anchor(type: "hrv", predicateVersion: version), Data([1]))
        XCTAssertEqual(try pending(), 1)
        XCTAssertEqual(try store.counts().coveragePending, 0)
        source.failAfterPages[.hrv] = nil  // relaunch: resumes from anchor 1
        _ = try await sut.drain(.hrv)
        XCTAssertEqual(source.anchorsSeen[.hrv]?.last, Data([1]))
        XCTAssertEqual(try pending(), 2)
    }

    func test_triggersDuringADrainCoalesceIntoOneMorePass() async throws {
        source.pages[.hrv] = [page([50], anchor: 1, more: false)]
        let entered = expectation(description: "first source query is suspended")
        let gate = FirstPageGate(entered: entered)
        source.beforeAnchoredPage = { await gate.pauseOnce() }
        let sut = engine()
        let first = Task { try await sut.drain(.hrv) }
        await fulfillment(of: [entered], timeout: 5)
        let second = try await sut.drain(.hrv)
        await gate.release()
        _ = try await first.value
        XCTAssertEqual(second, .coalesced)
        XCTAssertEqual(try pending(), 1)
        XCTAssertEqual(source.anchorsSeen[.hrv]?.count, 2)
    }

    func test_aCorruptAnchorStartsANewGenerationWithoutLosingPendingUploads() async throws {
        let uuid = UUID()
        let one = sample(.hrvSDNN(milliseconds: 50), start: "2026-09-22T11:59:00Z", end: "2026-09-22T12:00:00Z", uuid: uuid)
        source.pages[.hrv] = [AnchoredPage(samples: [one], deleted: [], anchor: Data([1]), hasMore: false),
                              AnchoredPage(samples: [one], deleted: [], anchor: Data([7]), hasMore: false)]
        let sut = engine()
        _ = try await sut.drain(.hrv)
        source.corruptAnchorOnce = [.hrv]
        _ = try await sut.drain(.hrv)
        XCTAssertEqual(source.anchorsSeen[.hrv], [nil, Data([1]), nil])  // re-read from no anchor
        XCTAssertEqual(try pending(), 1)                                   // the re-read sample was a duplicate
        XCTAssertNotNil(try store.value("last_anchor_recovery"))
    }

    func test_theLowerBoundIsFixedOnceAndNeverSlides() async throws {
        let sut = engine()
        let first = try await sut.lowerBound()
        XCTAssertEqual(first.wire, "2026-08-17T05:00:00Z")  // 35 + 1 local days before 2026-09-22 in Chicago
        clock.advance(seconds: 10 * 86400)
        let later = try await sut.lowerBound()
        XCTAssertEqual(later, first)
    }

    // MARK: - Steps

    func hourly(_ start: Instant, _ end: Instant, steps: Int64 = 100) -> [HourlyBucket] {
        var buckets: [HourlyBucket] = []
        var cursor = start
        while cursor < end {
            let next = min(end, cursor.adding(seconds: 3600))
            buckets.append(HourlyBucket(start: cursor, end: next, steps: steps))
            cursor = next
        }
        return buckets
    }

    func test_aCompletedDayHasAnHourlyLadderEndingAtItsClosingBoundary() {
        let zone = Zone(CHICAGO)!
        let day = LocalDay(year: 2026, month: 11, day: 1)  // 25 hours: fall back
        let start = zone.start(of: day), end = zone.start(of: zone.adding(days: 1, to: day))
        let snapshots = stepSnapshots(day: day, zone: zone, buckets: hourly(start, end), through: end, queriedAt: NOW)
        XCTAssertEqual(snapshots.count, 25)
        XCTAssertEqual(snapshots.last?.asOf, end)
        XCTAssertEqual(snapshots.last?.steps, 2500)
        // The repeated 01:00 hour gives two distinct instants.
        XCTAssertEqual(Set(snapshots.map(\.asOf)).count, 25)
    }

    func test_aSkippedMidnightStartsTheDayAtItsFirstValidInstant() {
        let zone = Zone("America/Santiago")!
        let day = LocalDay(year: 2026, month: 9, day: 5)
        let end = zone.start(of: zone.adding(days: 1, to: day))
        XCTAssertEqual(end.wire, "2026-09-06T04:00:00Z")
        let snapshots = stepSnapshots(day: day, zone: zone, buckets: hourly(zone.start(of: day), end), through: end,
                                      queriedAt: NOW)
        XCTAssertEqual(snapshots.last?.asOf, end)
    }

    func test_todayEndsWithASnapshotAtTheQueryTime() {
        let zone = Zone(CHICAGO)!
        let day = zone.day(of: NOW)
        let now = NOW.adding(seconds: 1800)  // 13:30
        let snapshots = stepSnapshots(day: day, zone: zone, buckets: hourly(zone.start(of: day), now), through: now,
                                      queriedAt: now)
        XCTAssertEqual(snapshots.last?.asOf, now)
        XCTAssertEqual(snapshots.count, 14)  // 13 whole hours plus now
    }

    func test_unchangedTotalsAreNotReEnqueuedButCorrectionsAre() async throws {
        let sut = engine()
        var steps: Int64 = 100
        source.steps = { [unowned self] start, end in self.hourly(start, end, steps: steps) }
        let first = try await sut.refreshSteps(full: false)
        XCTAssertGreaterThan(first, 0)
        clock.advance(seconds: 60)
        let unchanged = try await sut.refreshSteps(full: false)
        XCTAssertEqual(unchanged, 1)  // only the snapshot at the new "now"
        steps = 90  // a downward correction
        clock.advance(seconds: 60)
        let corrected = try await sut.refreshSteps(full: false)
        // Every stored bucket changed (37: yesterday's 24 hours and today's 13),
        // plus one snapshot at the new "now".
        XCTAssertEqual(first, 37)
        XCTAssertEqual(corrected, 38)
    }

    func test_aFailedStatisticsQueryEmitsNoZerosAndNoCoverage() async throws {
        source.steps = { _, _ in throw FakeSource.Failure() }
        do {
            try await engine().refreshSteps(full: true)
            XCTFail()
        } catch {}
        XCTAssertEqual(try pending(), 0)
        XCTAssertEqual(try store.counts().coveragePending, 0)
    }

    // MARK: - End to end, offline first

    func test_offlineBootstrapThenReconnectAcknowledgesEverythingOnce() async throws {
        source.pages[.hrv] = [page([50, 51], anchor: 1, more: false, deleted: [UUID()])]
        source.pages[.sleep] = [AnchoredPage(samples: [
            sample(.sleep(.asleepCore), start: "2026-09-22T04:00:00Z", end: "2026-09-22T11:00:00Z")],
            deleted: [], anchor: Data([1]), hasMore: false)]
        source.steps = { [unowned self] start, end in self.hourly(start, end) }
        let errors = await engine().catchUp()
        XCTAssertEqual(errors, [:])
        let queued = try store.counts().pending

        var online = false
        let server = acceptingServer()
        let transport = FakeTransport { request in
            guard online else { throw URLError(.notConnectedToInternet) }
            return try await server(request)
        }
        let clock = self.clock!
        let offline = SyncEngine(store: store, config: BackendConfig(baseURL: URL(string: "http://localhost")!, deviceToken: "k"),
                                 transport: transport, clock: { clock.now }, random: { 1 }, deviceZone: { CHICAGO })
        guard case .retryScheduled = await offline.syncOnce() else { return XCTFail() }

        // "Relaunch": a fresh engine over the same store, now online, after the backoff.
        online = true
        clock.advance(seconds: 3)
        let relaunched = SyncEngine(store: store, config: BackendConfig(baseURL: URL(string: "http://localhost")!,
                                                                        deviceToken: "k"),
                                    transport: transport, clock: { clock.now }, random: { 1 }, deviceZone: { CHICAGO })
        var outcomes = await relaunched.syncAll()
        while outcomes.last.map({ if case .notDue = $0 { return true } else { return false } }) == true {
            clock.advance(seconds: 300)
            outcomes = await relaunched.syncAll()
        }
        let counts = try store.counts()
        XCTAssertEqual(counts.acknowledged, queued)
        XCTAssertEqual(counts.pending + counts.assigned, 0)
        XCTAssertEqual(counts.coveragePending, 0)  // coverage followed the acknowledgements
        // Each event was sent in exactly one distinct request (the first attempt was lost offline).
        let sent = try transport.bodies.flatMap { body -> [String] in
            guard case .array(let events)? = try JSONDecoder().decode(JSONValue.self, from: body)["events"] else { return [] }
            return events.compactMap { $0["event_id"]?.string }
        }
        XCTAssertEqual(Set(sent).count, queued)
    }

    // MARK: - Lost-anchor reconciliation (Step 9-13 plan section 3B)

    func lastCoverageStatus(_ domain: String) throws -> String? {
        try store.db.read {
            try String.fetchOne($0, sql: "SELECT status FROM coverage_outbox WHERE domain = ? ORDER BY id DESC LIMIT 1",
                                arguments: [domain])
        }
    }

    func scansInBodies(_ transport: FakeTransport) throws -> [JSONValue] {
        try transport.bodies.flatMap { body -> [JSONValue] in
            guard case .array(let scans)? = try JSONDecoder().decode(JSONValue.self, from: body)["visibility"] else { return [] }
            return scans
        }
    }

    func syncEverything(_ transport: FakeTransport) async {
        let clock = self.clock!
        let engine = SyncEngine(store: store, config: BackendConfig(baseURL: URL(string: "http://localhost")!, deviceToken: "k"),
                                transport: transport, clock: { clock.now }, random: { 1 }, deviceZone: { CHICAGO })
        _ = await engine.syncAll()
    }

    func test_aCompletedDrainSendsItsScanListingEveryVisibleRecordOnce() async throws {
        let a = UUID(), b = UUID()
        let one = sample(.hrvSDNN(milliseconds: 50), start: "2026-09-22T11:59:00Z", end: "2026-09-22T12:00:00Z", uuid: a)
        let two = sample(.hrvSDNN(milliseconds: 0), start: "2026-09-22T11:59:00Z", end: "2026-09-22T12:00:00Z", uuid: b)
        source.pages[.hrv] = [AnchoredPage(samples: [one, two], deleted: [], anchor: Data([1]), hasMore: false)]
        _ = try await engine().drain(.hrv)
        XCTAssertEqual(try store.counts().scansPending, 1)
        let transport = FakeTransport(acceptingServer())
        await syncEverything(transport)
        let scans = try scansInBodies(transport)
        XCTAssertEqual(scans.count, 1)
        // The quarantined sample (0 ms) is still visible, so it is listed too.
        XCTAssertEqual(scans[0]["members"], .array([a, b].map { .string($0.uuidString.lowercased()) }
            .sorted { $0.string! < $1.string! }))
        XCTAssertEqual(scans[0]["healthkit_type"]?.string, "HKQuantityTypeIdentifierHeartRateVariabilitySDNN")
        XCTAssertEqual(scans[0]["scope_start_at"]?.string, "2026-08-17T05:00:00Z")
        XCTAssertEqual(try store.counts().scansPending, 0)
        // A later drain of the same generation doesn't scan again.
        _ = try await engine().drain(.hrv)
        XCTAssertEqual(try store.counts().scansPending, 0)
    }

    func test_recoveryCompletesOnlyWhenTheNewGenerationsScanIsAcknowledged() async throws {
        let kept = sample(.hrvSDNN(milliseconds: 50), start: "2026-09-22T11:59:00Z", end: "2026-09-22T12:00:00Z")
        let gone = sample(.hrvSDNN(milliseconds: 60), start: "2026-09-22T10:59:00Z", end: "2026-09-22T11:00:00Z")
        source.pages[.hrv] = [AnchoredPage(samples: [kept, gone], deleted: [], anchor: Data([1]), hasMore: false),
                              AnchoredPage(samples: [kept], deleted: [], anchor: Data([2]), hasMore: false)]
        let sut = engine()
        _ = try await sut.drain(.hrv)
        source.corruptAnchorOnce = [.hrv]
        _ = try await sut.drain(.hrv)  // new generation: "gone" is no longer returned
        XCTAssertEqual(try store.value("recovery_hrv"), "incomplete")
        let transport = FakeTransport(acceptingServer())
        await syncEverything(transport)
        // Only the new generation's scan is sent; the old one was superseded before sending.
        let scans = try scansInBodies(transport)
        XCTAssertEqual(scans.map { $0["members"] }, [.array([.string(kept.uuid.uuidString.lowercased())])])
        XCTAssertNil(try store.value("recovery_hrv"))
        XCTAssertEqual(try store.value("last_anchor_recovery"), "Reconciled")
        // Coverage becomes complete again on the next drain.
        _ = try await sut.drain(.hrv)
        XCTAssertEqual(try lastCoverageStatus("hrv"), "complete")
    }

    func test_aScanFromAnOlderGenerationNeverClearsRecovery() async throws {
        source.pages[.hrv] = [page([50], anchor: 1, more: false)]
        let sut = engine()
        _ = try await sut.drain(.hrv)
        let transport = FakeTransport(acceptingServer())
        let clock = self.clock!
        let sync = SyncEngine(store: store, config: BackendConfig(baseURL: URL(string: "http://localhost")!, deviceToken: "k"),
                              transport: transport, clock: { clock.now }, random: { 1 }, deviceZone: { CHICAGO })
        let request = try store.nextRequest(deviceZone: CHICAGO, maxEvents: 250, maxBytes: 1 << 22, now: clock.now)
        try store.apply(accepted(try XCTUnwrap(request)), to: try XCTUnwrap(request))
        let scanRequest = try store.nextRequest(deviceZone: CHICAGO, maxEvents: 250, maxBytes: 1 << 22, now: clock.now)
        XCTAssertNotNil(scanRequest)  // the generation-1 scan is now assigned
        try store.beginAnchorRecovery(type: .hrv, lower: try await sut.lowerBound(), zone: CHICAGO, now: clock.now)
        _ = await sync.syncAll()  // the open request (old scan) is still sent and acknowledged
        XCTAssertEqual(try store.value("recovery_hrv"), "incomplete")
    }

    func test_legacyScanReturnedToQueueAfterSplitCannotFinalizeRecovery() throws {
        try store.setValue("incomplete", for: "recovery_hrv")
        try store.setValue(CHICAGO, for: "sent_zone")
        try store.enqueueScan(type: .hrv, generation: "legacy", scopeStart: NOW.adding(seconds: -86400), now: NOW)
        try store.enqueueCoverage(.init(domain: .hrv, timezone: CHICAGO, start: NOW.adding(seconds: -86400),
                                       end: NOW, status: "unavailable"), now: NOW)
        let request = try XCTUnwrap(store.nextRequest(deviceZone: CHICAGO, maxEvents: 250, maxBytes: 1 << 22, now: NOW))
        // v3 rows have no end time. The old frozen request is still retryable,
        // but a 413 forces its contents to be reconsidered in a new envelope.
        try store.db.write { try $0.execute(sql: "UPDATE visibility_outbox SET scope_end_at = NULL") }
        try store.split(request)
        let retry = try XCTUnwrap(store.nextRequest(deviceZone: CHICAGO, maxEvents: 250, maxBytes: 1 << 22, now: NOW))
        try store.apply(accepted(retry), to: retry)
        XCTAssertNil(try store.nextRequest(deviceZone: CHICAGO, maxEvents: 250, maxBytes: 1 << 22, now: NOW))
        XCTAssertEqual(try store.value("recovery_hrv"), "incomplete")
        XCTAssertEqual(try store.counts().scansPending, 0)
    }

    /// Swift -> Python: a real request with a scan, validated by the backend's SyncRequest.
    func test_writesTheSwiftRequestFixture() async throws {
        let ids = IDs()
        try store.setValue("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", for: "installation_id")
        let one = sample(.hrvSDNN(milliseconds: 50), start: "2026-09-22T11:59:00Z", end: "2026-09-22T12:00:00Z",
                         uuid: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        try store.commitPage(type: "hrv", domain: .hrv, predicateVersion: "g", samples: [one], deleted: [],
                             newAnchor: Data([1]), normalizer: Normalizer(deviceZone: CHICAGO), now: NOW, makeID: ids.make)
        try store.enqueueScan(type: .hrv, generation: "g", scopeStart: instant("2026-08-17T05:00:00Z"), now: NOW,
                              makeID: ids.make)
        let request = try store.nextRequest(deviceZone: CHICAGO, maxEvents: 250, maxBytes: 1 << 22, now: NOW,
                                            makeID: ids.make)!
        // Finalization is a second request, after its member upload is ACKed.
        try store.apply(accepted(request), to: request)
        let scanRequest = try XCTUnwrap(try store.nextRequest(deviceZone: CHICAGO, maxEvents: 250, maxBytes: 1 << 22,
                                                              now: NOW, makeID: ids.make))
        let text = String(decoding: scanRequest.body, as: UTF8.self) + "\n"
        let eventText = String(decoding: request.body, as: UTF8.self) + "\n"
        let eventPath = fixtures.appendingPathComponent("swift_member_request.json")
        if ProcessInfo.processInfo.environment["UPDATE_WIRE_FIXTURES"] == "1" {
            try eventText.write(to: eventPath, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try String(contentsOf: eventPath, encoding: .utf8), eventText)
        let path = fixtures.appendingPathComponent("swift_request.json")
        if ProcessInfo.processInfo.environment["UPDATE_WIRE_FIXTURES"] == "1" {
            try text.write(to: path, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), text,
                       "swift_request.json is stale: rerun with UPDATE_WIRE_FIXTURES=1, then the Python test")
    }
}

extension ImportEngineTests {
    func testScanWaitsUntilQueuedMissingSampleAndKeptSampleAreAcknowledged() async throws {
        let kept = sample(.hrvSDNN(milliseconds: 50), start: "2026-09-22T11:59:00Z", end: "2026-09-22T12:00:00Z")
        let gone = sample(.hrvSDNN(milliseconds: 60), start: "2026-09-22T10:59:00Z", end: "2026-09-22T11:00:00Z")
        source.pages[.hrv] = [.init(samples: [kept, gone], deleted: [], anchor: Data([1]), hasMore: false),
                              .init(samples: [kept], deleted: [], anchor: Data([2]), hasMore: false)]
        let sut = engine()
        _ = try await sut.drain(.hrv)
        source.corruptAnchorOnce = [.hrv]
        _ = try await sut.drain(.hrv)
        var sent: [UploadRequest] = []
        for _ in 0..<8 {
            guard let request = try store.nextRequest(deviceZone: CHICAGO, maxEvents: 1, maxBytes: 1 << 22, now: NOW) else { break }
            let body = try JSONDecoder().decode(JSONValue.self, from: request.body)
            if case .array(let scans)? = body["visibility"], !scans.isEmpty {
                XCTAssertTrue(request.eventIDs.isEmpty)
                XCTAssertEqual(try store.counts().acknowledged, 2)
                XCTAssertEqual(scans[0]["members"], .array([.string(kept.uuid.uuidString.lowercased())]))
                XCTAssertNotNil(scans[0]["scope_end_at"])
            }
            sent.append(request)
            try store.apply(accepted(request), to: request)
        }
        XCTAssertGreaterThan(sent.count, 2)
        XCTAssertNil(try store.value("recovery_hrv"))
        XCTAssertEqual(try lastCoverageStatus("hrv"), "complete") // no second drain required
    }
}

/// Hold the first source query so coalescing is tested with genuine overlap,
/// independently of how the task scheduler orders two fast async calls.
private actor FirstPageGate {
    let entered: XCTestExpectation
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(entered: XCTestExpectation) { self.entered = entered }

    func pauseOnce() async {
        guard !started else { return }
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
