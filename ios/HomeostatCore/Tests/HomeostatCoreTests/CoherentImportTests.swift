import Foundation
import GRDB
import XCTest
@testable import HomeostatCore

private actor AdvancingSource: HealthDataSource {
    let clock: TestClock
    var stepCalls = 0
    var concurrentSteps = 0
    var maxConcurrentSteps = 0
    let entered: XCTestExpectation?
    init(clock: TestClock, entered: XCTestExpectation? = nil) { self.clock = clock; self.entered = entered }
    func anchoredPage(_ type: SampleType, since lowerBound: Instant, anchor: Data?, limit: Int) async throws -> AnchoredPage {
        clock.advance(seconds: 60)
        return .init(samples: [], deleted: [], anchor: Data([1]), hasMore: false)
    }
    func hourlySteps(from start: Instant, to end: Instant, zone: String) async throws -> [HourlyBucket] {
        stepCalls += 1; concurrentSteps += 1; maxConcurrentSteps = max(maxConcurrentSteps, concurrentSteps)
        defer { concurrentSteps -= 1 }
        if stepCalls == 1, let entered {
            entered.fulfill()
            try await Task.sleep(nanoseconds: 100_000_000)
        } else { try await Task.sleep(nanoseconds: 1_000_000) }
        clock.advance(seconds: 60)
        return []
    }
    func counts() -> (Int, Int) { (stepCalls, maxConcurrentSteps) }
}

final class CoherentImportTests: XCTestCase {
    func testAllDomainsUseCycleStartDespiteQueriesFinishingLater() async throws {
        let store = try LocalStore(path: nil)
        let clock = TestClock()
        let source = AdvancingSource(clock: clock)
        let importer = ImportEngine(store: store, source: source, clock: { clock.now }, deviceZone: { CHICAGO })
        let errors = await importer.catchUp(repairHistory: false)
        XCTAssertTrue(errors.isEmpty)
        let ends = try await store.db.read { try String.fetchAll($0, sql: "SELECT end_at FROM coverage_outbox") }
        XCTAssertEqual(ends.count, 5)
        XCTAssertEqual(Set(ends), [NOW.wire])
        XCTAssertGreaterThan(clock.now, NOW)
    }
    func testConcurrentStepRefreshesShareOneQuery() async throws {
        let store = try LocalStore(path: nil)
        let clock = TestClock()
        let source = AdvancingSource(clock: clock)
        let importer = ImportEngine(store: store, source: source, clock: { clock.now }, deviceZone: { CHICAGO })
        async let first = importer.refreshSteps(full: false)
        async let second = importer.refreshSteps(full: false)
        let results = try await [first, second]
        XCTAssertEqual(results[0], results[1])
        let counts = await source.counts()
        XCTAssertEqual(counts.0, 2) // yesterday and today, once each
        XCTAssertEqual(counts.1, 1)
    }
    func testPageBudgetCheckpointsAnchorWithoutClaimingCompleteCoverage() async throws {
        let store = try LocalStore(path: nil)
        let source = FakeSource()
        source.pages[.hrv] = [
            .init(samples: [], deleted: [], anchor: Data([1]), hasMore: true),
            .init(samples: [], deleted: [], anchor: Data([2]), hasMore: false)]
        let importer = ImportEngine(store: store, source: source, clock: { NOW }, deviceZone: { CHICAGO })
        do { _ = try await importer.drain(.hrv, maxPages: 1); XCTFail("must defer") } catch {}
        XCTAssertEqual(try store.counts().coveragePending, 0)
        XCTAssertNotNil(try store.value("import_deferred"))
        _ = try await importer.drain(.hrv, maxPages: 1)
        XCTAssertEqual(source.anchorsSeen[.hrv], [nil, Data([1])])
        XCTAssertEqual(try store.counts().coveragePending, 1)
    }
    func testHistoryRepairResumesAcrossEngineRecreation() async throws {
        let store = try LocalStore(path: nil)
        let source = FakeSource()
        let first = ImportEngine(store: store, source: source, clock: { NOW }, deviceZone: { CHICAGO })
        _ = await first.catchUp()
        let checkpoint = try store.value("steps_history_cursor_\(CHICAGO)")
        XCTAssertNotNil(checkpoint)
        for _ in 0..<6 {
            let resumed = ImportEngine(store: store, source: source, clock: { NOW }, deviceZone: { CHICAGO })
            _ = await resumed.catchUp()
        }
        XCTAssertNil(try store.value("steps_history_cursor_\(CHICAGO)"))
        XCTAssertEqual(try store.value("steps_full_refresh_day"), "\(CHICAGO)|2026-09-22")
    }
}

extension CoherentImportTests {
    func testConcurrentObserverCyclesRunOneExtraPassForLaterChanges() async throws {
        let store = try LocalStore(path: nil)
        let clock = TestClock()
        let entered = expectation(description: "first cycle has already read all sample types")
        let source = AdvancingSource(clock: clock, entered: entered)
        let importer = ImportEngine(store: store, source: source, clock: { clock.now }, deviceZone: { CHICAGO })
        let first = Task { await importer.catchUp(repairHistory: false) }
        await fulfillment(of: [entered], timeout: 2)
        let second = await importer.catchUp(repairHistory: false)
        let results = await [first.value, second]
        XCTAssertTrue(results.allSatisfy(\.isEmpty))
        let counts = await source.counts()
        XCTAssertEqual(counts.0, 4) // two days per pass, with one coalesced rerun
        XCTAssertEqual(counts.1, 1)
    }
}

extension CoherentImportTests {
    func testCancellingOneCallerLeavesAnotherCallersSharedCycleRunning() async throws {
        let store = try LocalStore(path: nil)
        let clock = TestClock()
        let entered = expectation(description: "the shared cycle is reading steps")
        let source = AdvancingSource(clock: clock, entered: entered)
        let importer = ImportEngine(store: store, source: source, clock: { clock.now }, deviceZone: { CHICAGO })
        let background = Task { await importer.catchUp(repairHistory: false) }
        await fulfillment(of: [entered], timeout: 2)
        let foreground = Task { await importer.catchUp(repairHistory: false) }
        try await Task.sleep(nanoseconds: 20_000_000)  // the foreground caller has joined
        background.cancel()  // e.g. a background refresh expiring
        let result = await foreground.value
        XCTAssertEqual(result, [:])
    }

    func testCancellingTheOnlyCallerStillStopsTheCycle() async throws {
        let store = try LocalStore(path: nil)
        let clock = TestClock()
        let entered = expectation(description: "the cycle is reading steps")
        let source = AdvancingSource(clock: clock, entered: entered)
        let importer = ImportEngine(store: store, source: source, clock: { clock.now }, deviceZone: { CHICAGO })
        let only = Task { await importer.catchUp(repairHistory: false) }
        await fulfillment(of: [entered], timeout: 2)
        only.cancel()
        let result = await only.value
        XCTAssertFalse(result.isEmpty)
    }

    func testStepHistoryRepairStaysWithinTheLookbackWindow() async throws {
        let store = try LocalStore(path: nil)
        let zone = Zone(CHICAGO)!
        let today = zone.day(of: NOW)
        // Installed over a year ago: the import lower bound never moves.
        try store.setValue(zone.start(of: zone.adding(days: -400, to: today)).wire, for: "import_lower_bound")
        let source = FakeSource()
        let starts = LockedList()
        source.steps = { start, _ in starts.append(start); return [] }
        let importer = ImportEngine(store: store, source: source, clock: { NOW }, deviceZone: { CHICAGO })
        for _ in 0..<10 where try store.value("steps_full_refresh_day") == nil {
            _ = await importer.catchUp()
        }
        XCTAssertEqual(try store.value("steps_full_refresh_day"), "\(CHICAGO)|\(today)")
        XCTAssertEqual(starts.values.min(), zone.start(of: zone.adding(days: -36, to: today)))
        _ = try await importer.refreshSteps(full: true)
        XCTAssertEqual(starts.values.min(), zone.start(of: zone.adding(days: -36, to: today)))
    }
}

final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Instant] = []
    func append(_ item: Instant) { lock.withLock { items.append(item) } }
    var values: [Instant] { lock.withLock { items } }
}
