import Foundation
import XCTest
@testable import HomeostatCore

/// HealthKit samples -> import -> local log -> Swift engine -> widget state, all on the phone.
final class LocalCalculationTests: XCTestCase {
    let zone = Zone(CHICAGO)!

    /// 20 nights of 7.5 h ending 06:30 local, then a 5.5 h night; HRV and resting HR each morning.
    func history(todayHRV: UUID = UUID()) -> (sleep: [RawSample], hrv: [RawSample], rhr: [RawSample]) {
        var sleep: [RawSample] = [], hrv: [RawSample] = [], rhr: [RawSample] = []
        let today = zone.day(of: NOW)
        for back in 0...20 {
            let day = zone.adding(days: -back, to: today)
            let bed = zone.instant(on: zone.adding(days: -1, to: day), hour: 23)
            let hours: Int64 = back == 0 ? 5 : 7
            let wake = bed.adding(seconds: hours * 3600 + 1800)
            sleep.append(sample(.sleep(.asleepCore), start: bed.wire, end: wake.wire))
            let reading = wake.adding(seconds: -1800)
            hrv.append(sample(.hrvSDNN(milliseconds: 50 + Double(back % 3)), start: reading.adding(seconds: -60).wire,
                              end: reading.wire, uuid: back == 0 ? todayHRV : UUID()))
            rhr.append(sample(.restingHR(beatsPerMinute: 60 + Double(back % 3)), start: reading.adding(seconds: -60).wire,
                              end: reading.wire))
        }
        return (sleep, hrv, rhr)
    }

    func page(_ samples: [RawSample]) -> AnchoredPage { .init(samples: samples, deleted: [], anchor: Data([1]), hasMore: false) }

    func testImportedSamplesBecomeTheWidgetStateOnDevice() async throws {
        let store = try LocalStore(path: nil)
        let source = FakeSource()
        let (sleep, hrv, rhr) = history()
        source.pages = [.sleep: [page(sleep)], .hrv: [page(hrv)], .rhr: [page(rhr)]]
        source.steps = { start, end in [HourlyBucket(start: start, end: end, steps: 100)] }
        let importer = ImportEngine(store: store, source: source, clock: { NOW }, deviceZone: { CHICAGO })
        let errors = await importer.catchUp(repairHistory: false)
        XCTAssertEqual(errors, [:])

        let state = try XCTUnwrap(try store.calculateLocally(now: NOW, zone: CHICAGO))
        XCTAssertEqual(state.day, "2026-09-22")
        XCTAssertEqual(state.effectiveAt, NOW)
        XCTAssertEqual(state.widgetState.presentation.headline, "Shorter sleep")
        XCTAssertEqual(state.widgetState.presentation.detail, "5h 30m")
        XCTAssertEqual(state.healthState["sleep"]?["state"], .string("below_baseline"))
        XCTAssertEqual(state.healthState["sleep"]?["confidence"], .double(1))
        XCTAssertEqual(state.healthState["calibration"]?["domains"]?["sleep"], .int(20))

        // Stored apart from any server state, and read back as the widget's source.
        try store.storeLocalState(state)
        let stored = try XCTUnwrap(try store.storedLocalState())  // JSON reads 1.0 back as 1
        XCTAssertEqual(stored.widgetState, state.widgetState)
        XCTAssertEqual(differences(state.healthState, stored.healthState, "health_state"), [])
        XCTAssertNil(try store.storedState())
    }

    func testARecordMissingFromARebuildIsNoLongerCounted() async throws {
        let store = try LocalStore(path: nil)
        let source = FakeSource()
        let todayHRV = UUID()
        let (sleep, hrv, rhr) = history(todayHRV: todayHRV)
        // The rebuild's fresh read no longer returns today's HRV (deleted while the anchor was lost).
        source.pages = [.sleep: [page(sleep)], .hrv: [page(hrv), page(hrv.filter { $0.uuid != todayHRV })], .rhr: [page(rhr)]]
        let importer = ImportEngine(store: store, source: source, clock: { NOW }, deviceZone: { CHICAGO })
        _ = await importer.catchUp(repairHistory: false)
        XCTAssertNotNil(try store.calculateLocally(now: NOW, zone: CHICAGO)?.healthState["drivers"])
        XCTAssertEqual(try hrvState(store), "typical")

        try store.beginAnchorRecovery(type: .hrv, lower: try await importer.lowerBound(), zone: CHICAGO, now: NOW)
        XCTAssertEqual(try hrvConfidence(store), 0)  // mid-rebuild: unknown, not complete
        _ = try await importer.drain(.hrv)
        XCTAssertEqual(try hrvState(store), "missing")
    }

    func hrvBlock(_ store: LocalStore) throws -> JSONValue? {
        guard case .array(let drivers)? = try store.calculateLocally(now: NOW, zone: CHICAGO)?.healthState["drivers"] else {
            return nil
        }
        return drivers.first { $0["domain"]?.string == "hrv" }
    }

    func hrvState(_ store: LocalStore) throws -> String? {
        let observations = try store.localObservations()
        let features = try calculateFeatures(observations, EngineContext(
            day: zone.day(of: NOW), timezone: CHICAGO, effectiveAt: NOW, knownAt: NOW, coverage: []))
        return features.hrv.state
    }

    func hrvConfidence(_ store: LocalStore) throws -> Double? {
        if case .double(let value)? = try hrvBlock(store)?["confidence"] { return value }
        return nil
    }
}

/// Plan/Plan.md §4 path 3 (M2): the widget's snapshot path must equal the app's calculation.
final class EngineInputsSnapshotTests: XCTestCase {
    func assertSameResult(_ store: LocalStore, now: Instant, zone: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let run = try XCTUnwrap(try store.localRun(now: now, zone: zone))
        let app = run.state
        let snapshot = try run.snapshot(scope: "scope-a")
        let widget = try LocalStore.calculate(snapshot: snapshot, now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(widget.healthState.encoded(), app.healthState.encoded(), file: file, line: line)
        XCTAssertEqual(try encoder.encode(widget.widgetState), try encoder.encode(app.widgetState), file: file, line: line)
        XCTAssertEqual(widget.revision, app.inputRevision, file: file, line: line)
        XCTAssertEqual(widget.effective, app.effectiveAt, file: file, line: line)
        XCTAssertEqual(widget.scope, "scope-a", file: file, line: line)
    }

    func testTheSnapshotGivesTheAppsResult() async throws {
        let base = LocalCalculationTests()
        let store = try LocalStore(path: nil)
        let source = FakeSource()
        let (sleep, hrv, rhr) = base.history()
        source.pages = [.sleep: [base.page(sleep)], .hrv: [base.page(hrv)], .rhr: [base.page(rhr)]]
        source.steps = { start, end in [HourlyBucket(start: start, end: end, steps: 100)] }
        _ = await ImportEngine(store: store, source: source, clock: { NOW }, deviceZone: { CHICAGO }).catchUp(repairHistory: false)
        try assertSameResult(store, now: NOW, zone: CHICAGO)
        try assertSameResult(store, now: NOW.adding(seconds: 3 * 3600), zone: CHICAGO)
    }

    func testAPhoneDatabaseGivesTheSameResultThroughTheSnapshot() throws {
        guard let source = ProcessInfo.processInfo.environment["HOMEOSTAT_DEVICE_DB"] else { throw XCTSkip("no device database given") }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID()).sqlite")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
        let store = try LocalStore(path: copy.path)
        try assertSameResult(store, now: Instant(Date()), zone: ProcessInfo.processInfo.environment["HOMEOSTAT_DEVICE_ZONE"] ?? "America/Chicago")
        let size = try XCTUnwrap(try store.localRun(now: Instant(Date()), zone: "America/Chicago")).snapshot(scope: "s").count
        print("SNAPSHOT bytes \(size)")
    }

    func testOtherVersionsAndMalformedSnapshotsAreRejected() {
        XCTAssertThrowsError(try LocalStore.calculate(snapshot: Data(#"{"version":"engine-inputs@9"}"#.utf8), now: NOW))
        XCTAssertThrowsError(try LocalStore.calculate(snapshot: Data(#"{"version":"engine-inputs@0.1"}"#.utf8), now: NOW))
        XCTAssertThrowsError(try LocalStore.calculate(snapshot: Data("not json".utf8), now: NOW))
    }
}
