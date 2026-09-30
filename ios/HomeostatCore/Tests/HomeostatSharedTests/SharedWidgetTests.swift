import Foundation
import XCTest
@testable import HomeostatShared

/// Shares the Core tests' fixtures directory (written by the Python tests).
let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../HomeostatCoreTests/Fixtures").standardized

func instant(_ text: String) -> Instant { Instant.parse(text)! }

let NOW = instant("2026-09-22T18:00:00Z")  // 13:00 in Chicago
let CHICAGO = Zone("America/Chicago")!

func widget(_ headline: String = "Shorter sleep", updated: Instant = NOW, version: String = "widget-state@0.1.0")
    -> WidgetState {
    WidgetState(version: version, effectiveAt: updated,
                presentation: .init(icon: "😴", headline: headline, detail: "5h 58m"),
                primaryTrait: .init(id: "sleep", explainable: true), freshness: .init(lastUpdatedAt: updated))
}

func cache(_ revision: Int64, run: Int64 = 1, scope: String = "a", day: LocalDay = CHICAGO.day(of: NOW),
           widget state: WidgetState = widget()) -> WidgetCache {
    WidgetCache(scope: scope, day: day, inputRevision: revision, runID: run, widgetState: state)
}

final class SharedWidgetStoreTests: XCTestCase {
    var store: SharedWidgetStore!

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SharedWidgetStore(directory: directory)
    }

    func testAWrittenStateReadsBackIdentically() throws {
        XCTAssertEqual(store.read(), .none)
        XCTAssertEqual(try store.write(cache(1), now: NOW), .written(meaningful: true))
        XCTAssertEqual(store.read(), .state(cache(1)))
        XCTAssertEqual(try store.write(cache(1), now: NOW), .unchanged)
    }

    func testOrderingIsByRevisionThenRunWithinOneScope() throws {
        _ = try store.write(cache(5, run: 9), now: NOW)
        XCTAssertEqual(try store.write(cache(4, run: 99), now: NOW), .ignoredOlder)
        XCTAssertEqual(try store.write(cache(5, run: 8), now: NOW), .ignoredOlder)
        XCTAssertEqual(try store.write(cache(5, run: 10, widget: widget("Longer sleep")), now: NOW),
                       .written(meaningful: true))
        // Another account's state replaces it whatever its order.
        XCTAssertEqual(try store.write(cache(1, scope: "b"), now: NOW), .written(meaningful: true))
        XCTAssertEqual(store.read(), .state(cache(1, scope: "b")))
    }

    func testOnlyVisibleChangesAreMeaningful() throws {
        _ = try store.write(cache(1), now: NOW)
        let later = NOW.adding(seconds: 600)
        XCTAssertEqual(try store.write(cache(2, widget: widget(updated: later)), now: later),
                       .written(meaningful: true))  // refresh the already-published stale deadline
        let muchLater = later.adding(seconds: WidgetPolicy.staleAfterSeconds + 60)
        XCTAssertEqual(try store.write(cache(3, widget: widget(updated: muchLater)), now: muchLater),
                       .written(meaningful: true))  // the stored one had gone stale
        XCTAssertEqual(try store.write(cache(4, day: LocalDay(year: 2026, month: 9, day: 23),
                                             widget: widget(updated: muchLater)), now: muchLater),
                       .written(meaningful: true))  // a new day
    }

    func testInvalidInputKeepsThePreviousFile() throws {
        _ = try store.write(cache(1), now: NOW)
        XCTAssertEqual(try store.write(cache(2, widget: widget(" ")), now: NOW), .invalid)
        XCTAssertEqual(try store.write(cache(2, widget: widget(version: "widget-state@1.0.0")), now: NOW), .invalid)
        XCTAssertEqual(store.read(), .state(cache(1)))
    }

    func testUnknownFormatsAndDamageAreReportedNotCrashed() throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var future = try JSONEncoder().encode(cache(1, widget: widget(version: "widget-state@9.0.0")))
        try future.write(to: store.fileURL)
        XCTAssertEqual(store.read(), .unreadable(.version))
        future = Data(#"{"schema": 2, "something": "new"}"#.utf8)
        try future.write(to: store.fileURL)
        XCTAssertEqual(store.read(), .unreadable(.version))
        try Data("{not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.read(), .unreadable(.unavailable))
        try store.clear()
        XCTAssertEqual(store.read(), .none)
        try store.clear()  // clearing twice is fine
    }

    /// Python -> Swift: every distinct payload the backend can produce decodes and caches.
    func testEveryBackendWidgetStateDecodesAndCaches() throws {
        let text = try String(contentsOf: fixtures.appendingPathComponent("widget_states.jsonl"), encoding: .utf8)
        let states = try text.split(separator: "\n").map { try JSONDecoder().decode(WidgetState.self, from: Data($0.utf8)) }
        XCTAssertEqual(Set(states.map(\.primaryTrait.id)),
                       ["sleep", "recovery", "movement", "workout", "calibration", "typical", "no_data"])
        for (index, state) in states.enumerated() {
            guard case .written = try store.write(cache(Int64(index + 1), widget: state), now: NOW) else {
                return XCTFail("fixture line \(index + 1) was not written")
            }
            XCTAssertEqual(store.read(), .state(cache(Int64(index + 1), widget: state)))
        }
    }
}

final class WidgetPolicyTests: XCTestCase {
    func display(_ c: WidgetCache?, at now: Instant, zone: Zone = CHICAGO) -> WidgetPolicy.Display {
        WidgetPolicy.display(c.map(SharedWidgetStore.ReadResult.state) ?? .none, now: now, zone: zone)
    }

    func testFreshUntilNinetyMinutesThenStale() {
        let c = cache(1)
        XCTAssertEqual(display(c, at: NOW.adding(seconds: 90 * 60)), .fresh(c))
        XCTAssertEqual(display(c, at: NOW.adding(seconds: 90 * 60 + 1)), .stale(c))
    }

    func testAClockBehindTheServerCountsAsFresh() {
        let c = cache(1)
        XCTAssertEqual(display(c, at: NOW.adding(seconds: -3600)), .fresh(c))
    }

    func testAnEarlierDayIsNeverShownAsToday() {
        let c = cache(1)
        let midnight = instant("2026-09-23T05:00:00Z")
        XCTAssertEqual(display(c, at: midnight.adding(seconds: -1)), .stale(c))
        XCTAssertEqual(display(c, at: midnight), .earlierDay(c))
        // After flying west the device's day can still be the state's day.
        XCTAssertEqual(display(c, at: midnight, zone: Zone("America/Los_Angeles")!), .stale(c))
    }

    func testEmptyAndUnreadable() {
        XCTAssertEqual(display(nil, at: NOW), .empty)
        XCTAssertEqual(WidgetPolicy.display(.unreadable(.version), now: NOW, zone: CHICAGO), .unreadable(.version))
        XCTAssertEqual(WidgetPolicy.timelineDates(.none, now: NOW, zone: CHICAGO), [NOW])
    }

    func testLocalDaysParse() {
        XCTAssertEqual(LocalDay("2026-09-22"), LocalDay(year: 2026, month: 9, day: 22))
        XCTAssertNil(LocalDay("22/09/2026"))
    }

    func testTimelineChangesAtStaleAndMidnight() {
        let dates = WidgetPolicy.timelineDates(.state(cache(1)), now: NOW, zone: CHICAGO)
        XCTAssertEqual(dates, [NOW, NOW.adding(seconds: 90 * 60 + 1), instant("2026-09-23T05:00:00Z")])
        // Already stale: the stale instant is in the past and dropped.
        let later = NOW.adding(seconds: 4 * 3600)
        XCTAssertEqual(WidgetPolicy.timelineDates(.state(cache(1)), now: later, zone: CHICAGO),
                       [later, instant("2026-09-23T05:00:00Z")])
    }

    func testMidnightFollowsDSTAndSkippedMidnights() {
        // Fall back: 1 Nov 2026 has 25 hours in Chicago.
        let fallBack = instant("2026-11-01T12:00:00Z")
        XCTAssertEqual(WidgetPolicy.nextMidnight(after: fallBack, zone: CHICAGO), instant("2026-11-02T06:00:00Z"))
        // Santiago skips midnight on 6 Sep 2026: the day starts at 01:00.
        let santiago = Zone("America/Santiago")!
        XCTAssertEqual(WidgetPolicy.nextMidnight(after: instant("2026-09-05T12:00:00Z"), zone: santiago),
                       instant("2026-09-06T04:00:00Z"))
        XCTAssertEqual(WidgetPolicy.reloadAfter(now: fallBack, zone: CHICAGO), fallBack.adding(seconds: 1800))
    }
}
