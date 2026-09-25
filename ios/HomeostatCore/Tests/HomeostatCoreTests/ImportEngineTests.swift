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
        let sut = engine()
        async let first = sut.drain(.hrv)
        async let second = sut.drain(.hrv)
        let results = try await [first, second]
        XCTAssertTrue(results.contains(.coalesced))
        XCTAssertEqual(try pending(), 1)
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
        let offline = SyncEngine(store: store, config: BackendConfig(baseURL: URL(string: "http://localhost")!, apiKey: "k"),
                                 transport: transport, clock: { clock.now }, random: { 1 }, deviceZone: { CHICAGO })
        guard case .retryScheduled = await offline.syncOnce() else { return XCTFail() }

        // "Relaunch": a fresh engine over the same store, now online, after the backoff.
        online = true
        clock.advance(seconds: 3)
        let relaunched = SyncEngine(store: store, config: BackendConfig(baseURL: URL(string: "http://localhost")!,
                                                                        apiKey: "k"),
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
}
