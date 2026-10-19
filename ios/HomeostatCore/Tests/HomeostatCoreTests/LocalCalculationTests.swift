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
    func importedStore() async throws -> LocalStore {
        let base = LocalCalculationTests()
        let store = try LocalStore(path: nil)
        let source = FakeSource()
        let (sleep, hrv, rhr) = base.history()
        source.pages = [.sleep: [base.page(sleep)], .hrv: [base.page(hrv)], .rhr: [base.page(rhr)]]
        source.steps = { start, end in [HourlyBucket(start: start, end: end, steps: 100)] }
        _ = await ImportEngine(store: store, source: source, clock: { NOW }, deviceZone: { CHICAGO }).catchUp(repairHistory: false)
        return store
    }

    func assertSameResult(_ store: LocalStore, now: Instant, zone: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let run = try XCTUnwrap(try store.localRun(now: now, zone: zone))
        let app = run.state
        let widget = try EngineSnapshot.calculate(try run.snapshot(scope: "scope-a"), now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(widget.healthState.encoded(), app.healthState.encoded(), file: file, line: line)
        XCTAssertEqual(try encoder.encode(widget.widgetState), try encoder.encode(app.widgetState), file: file, line: line)
        XCTAssertEqual(widget.effective, app.effectiveAt, file: file, line: line)
        XCTAssertEqual(widget.header, .init(scope: "scope-a", zone: zone, day: Zone(zone)!.day(of: app.effectiveAt),
                                            inputRevision: app.inputRevision, runID: app.runID,
                                            effective: app.effectiveAt, knownAt: now), file: file, line: line)
    }

    func testTheSnapshotGivesTheAppsResult() async throws {
        let store = try await importedStore()
        try assertSameResult(store, now: NOW, zone: CHICAGO)
        try assertSameResult(store, now: NOW.adding(seconds: 3 * 3600), zone: CHICAGO)
    }

    func drivers(_ state: JSONValue) -> [String: JSONValue] {
        guard case .array(let list)? = state["drivers"] else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0["id"]!.string!, $0) })
    }

    /// Plan.md §4 path 3 / D-A: the widget's step read moves movement only.
    func testAStepReadUpdatesMovementAndHoldsTheOtherDomains() async throws {
        let store = try await importedStore()
        let run = try XCTUnwrap(try store.localRun(now: NOW, zone: CHICAGO))
        let later = NOW.adding(seconds: 3600)
        let widget = try EngineSnapshot.calculate(try run.snapshot(scope: "s"), now: later,
                                                  steps: .init(steps: 9999, at: later))
        let app = run.state.healthState
        XCTAssertEqual(widget.effective, later)
        XCTAssertEqual(drivers(widget.healthState)["steps_so_far"]?["value"], .double(9999))
        XCTAssertEqual(drivers(widget.healthState)["steps_so_far"]?["observed_at"], .string(later.wire))
        for id in ["sleep_duration", "hrv_sdnn", "resting_hr"] {
            XCTAssertEqual(drivers(widget.healthState)[id], drivers(app)[id], id)
        }
        for domain in ["sleep", "recovery", "workout", "calibration"] {
            XCTAssertEqual(widget.healthState[domain], app[domain], domain)  // coverage held at their cutoff
        }
    }

    func testAReadThatIsNotNewerOrOnAnotherDayIsRejected() async throws {
        let store = try await importedStore()
        let snapshot = try XCTUnwrap(try store.localRun(now: NOW, zone: CHICAGO)).snapshot(scope: "s")
        for at in [NOW, NOW.adding(seconds: -60), NOW.adding(seconds: 12 * 3600)] {  // app's own import; earlier; tomorrow
            XCTAssertThrowsError(try EngineSnapshot.calculate(snapshot, now: at, steps: .init(steps: 1, at: at))) {
                XCTAssertEqual($0 as? EngineSnapshot.Failure, .notNewer)
            }
        }
    }

    func testASnapshotFromOtherSettingsIsRejected() async throws {
        let store = try await importedStore()
        let snapshot = try XCTUnwrap(try store.localRun(now: NOW, zone: CHICAGO)).snapshot(scope: "s")
        let other = Data(String(decoding: snapshot, as: UTF8.self)
            .replacingOccurrences(of: EngineSettings.configSHA256, with: String(repeating: "0", count: 64)).utf8)
        XCTAssertThrowsError(try EngineSnapshot.calculate(other, now: NOW)) {
            XCTAssertEqual($0 as? EngineSnapshot.Failure, .otherSettings)
        }
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

    func testASnapshotOverTheCapIsNotWritten() {
        let big = Data(#"{"x":""#.utf8) + Data(repeating: UInt8(ascii: "a"), count: EngineSnapshot.maxBytes) + Data(#""}"#.utf8)
        let inputs = LocalInputs(lower: NOW, through: [:], observations: [], rows: [(body: big, createdAt: NOW.wire)],
                                 coverage: [], revision: 1)
        let header = EngineSnapshot.Header(scope: "s", zone: CHICAGO, day: Zone(CHICAGO)!.day(of: NOW), inputRevision: 1,
                                           runID: 1, effective: NOW, knownAt: NOW)
        XCTAssertThrowsError(try EngineSnapshot.encode(inputs, header: header)) {
            XCTAssertEqual($0 as? EngineSnapshot.Failure, .tooLarge)
        }
    }

    func testOversizedSnapshotsAreRejectedBeforeParsing() throws {
        let oversized = Data(repeating: UInt8(ascii: "x"), count: EngineSnapshot.maxBytes + 1)
        XCTAssertThrowsError(try EngineSnapshot.calculate(oversized, now: NOW)) {
            XCTAssertEqual($0 as? EngineSnapshot.Failure, .tooLarge)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-cap-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        try oversized.write(to: url)
        XCTAssertThrowsError(try EngineSnapshot.read(from: url)) {
            XCTAssertEqual($0 as? EngineSnapshot.Failure, .tooLarge)
        }
        let atLimit = Data(oversized.prefix(EngineSnapshot.maxBytes))
        try atLimit.write(to: url)
        XCTAssertEqual(try EngineSnapshot.read(from: url), atLimit)
    }

    /// P1: the engine's own HealthState becomes the facts and the daily summary.
    func testTheEnginesStateBecomesTheDailySummary() async throws {
        let store = try await importedStore()
        let state = try XCTUnwrap(try store.localRun(now: NOW, zone: CHICAGO)).state
        let facts = try XCTUnwrap(DisplayFacts(healthState: state.healthState))
        XCTAssertEqual(facts.sleep.state, "below_baseline")
        XCTAssertEqual(facts.learningDays["sleep"], 20)
        XCTAssertEqual(facts.requiredDays, 14)
        let cache = WidgetCache(scope: "s", day: Zone(CHICAGO)!.day(of: NOW), inputRevision: state.inputRevision,
                                runID: state.runID, widgetState: state.widgetState, facts: facts)
        let summary = DailySummary.make(.fresh(cache))
        XCTAssertEqual(summary.kind, .change)
        XCTAssertEqual(summary.headline, "Shorter sleep")
        XCTAssertEqual(summary.comparison, "5h 30m · usually 7h 30m")
        XCTAssertEqual(summary.domains.map(\.id), ["sleep", "recovery", "movement"])
        XCTAssertEqual(summary.domains.last?.readiness, .learning(usable: 0, required: 14))
    }

    func testOtherVersionsAndMalformedSnapshotsAreRejected() {
        XCTAssertThrowsError(try EngineSnapshot.calculate(Data(#"{"version":"engine-inputs@9"}"#.utf8), now: NOW))
        XCTAssertThrowsError(try EngineSnapshot.calculate(Data(#"{"version":"engine-inputs@0.1"}"#.utf8), now: NOW))
        XCTAssertThrowsError(try EngineSnapshot.calculate(Data("not json".utf8), now: NOW))
    }
}
