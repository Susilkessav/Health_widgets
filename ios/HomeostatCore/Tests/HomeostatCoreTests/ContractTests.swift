import Foundation
import XCTest
@testable import HomeostatCore

/// Cross-language contract tests (Step 9-13 plan sections 3 and 6).
final class ContractTests: XCTestCase {
    func testInstantFormattingMatchesPython() {
        XCTAssertEqual(instant("2026-09-22T18:00:00Z").pythonISO, "2026-09-22T18:00:00+00:00")
        XCTAssertEqual(instant("2026-09-22T18:00:00.1Z").pythonISO, "2026-09-22T18:00:00.100000+00:00")
        XCTAssertEqual(instant("2026-09-22T13:00:05.123456-05:00").wire, "2026-09-22T18:00:05.123456Z")
        XCTAssertEqual(Instant(Date(timeIntervalSince1970: 1.0000004)).microseconds, 1_000_000)  // rounds to µs
        XCTAssertNil(Instant.parse("2026-09-22 18:00:00"))
    }

    func testSnapshotIDsMatchPythonExactly() throws {
        struct Case: Decodable {
            var timezone: String, day: LocalDay, as_of: Instant, queried_at: Instant, steps: Int64
            var source_record_id: String
        }
        let cases = try JSONDecoder().decode([Case].self, from: fixture("snapshot_ids.json"))
        XCTAssertEqual(cases.count, 5)
        for c in cases {
            XCTAssertEqual(snapshotRecordID(timezone: c.timezone, day: c.day, asOf: c.as_of, queriedAt: c.queried_at,
                                            steps: c.steps), c.source_record_id)
        }
    }

    func testZoneDayBoundariesMatchTheBackend() {
        let santiago = Zone("America/Santiago")!
        // DST skips midnight on 2026-09-06: the day starts at 01:00 local (04:00 UTC).
        XCTAssertEqual(santiago.start(of: LocalDay(year: 2026, month: 9, day: 6)).wire, "2026-09-06T04:00:00Z")
        let chicago = Zone(CHICAGO)!
        XCTAssertEqual(chicago.day(of: NOW).description, "2026-09-22")
        XCTAssertEqual(chicago.start(of: LocalDay(year: 2026, month: 11, day: 2)).wire, "2026-11-02T06:00:00Z")
    }

    /// Swift -> Python: these encoded events are validated by
    /// backend/tests/api/test_wire_fixtures.py through the real contracts.
    func testGoldenEncodedEvents() throws {
        let metadata = SampleMetadata(
            healthKitType: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", sourceName: "Apple Watch",
            sourceBundleID: "com.apple.health.2F1C", sourceRevision: "11.0", deviceProductType: "Watch7,1",
            timezone: CHICAGO, timezoneSource: .sampleMetadata, sampleStart: instant("2026-09-22T11:58:59.25Z"),
            sampleEnd: instant("2026-09-22T11:59:59.75Z"),
            providerMetadata: ["HKMetadataKeyHeartRateMotionContext": "1", "HKAlgorithmVersion": "2"])
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
        let events: [CanonicalEvent] = [
            .point(.init(eventID: id(1), sourceRecordID: "5d1a4c2e-0000-4000-8000-000000000001", metric: .hrvSDNN,
                         observedAt: metadata.sampleEnd, value: 54.2, metadata: metadata)),
            .point(.init(eventID: id(2), sourceRecordID: "5d1a4c2e-0000-4000-8000-000000000002", metric: .restingHR,
                         observedAt: instant("2026-09-22T12:30:00Z"), value: 58,
                         metadata: SampleMetadata(healthKitType: "HKQuantityTypeIdentifierRestingHeartRate",
                                                  sourceName: "Apple Watch", sourceBundleID: "com.apple.health.2F1C",
                                                  sourceRevision: nil, deviceProductType: nil, timezone: CHICAGO,
                                                  timezoneSource: .deviceAtIngestion,
                                                  sampleStart: instant("2026-09-22T05:00:00Z"),
                                                  sampleEnd: instant("2026-09-22T12:30:00Z"), providerMetadata: [:]))),
            .interval(.init(eventID: id(3), sourceRecordID: "5d1a4c2e-0000-4000-8000-000000000003", stage: .asleepCore,
                            start: instant("2026-09-22T04:10:00Z"), end: instant("2026-09-22T07:10:00Z"),
                            metadata: SampleMetadata(healthKitType: "HKCategoryTypeIdentifierSleepAnalysis",
                                                     sourceName: "Apple Watch", sourceBundleID: "com.apple.health.2F1C",
                                                     sourceRevision: "11.0", deviceProductType: "Watch7,1",
                                                     timezone: CHICAGO, timezoneSource: .sampleMetadata,
                                                     sampleStart: instant("2026-09-22T04:10:00Z"),
                                                     sampleEnd: instant("2026-09-22T07:10:00Z"), providerMetadata: [:]))),
            .workout(.init(eventID: id(4), sourceRecordID: "5d1a4c2e-0000-4000-8000-000000000004",
                           workoutType: "traditional_strength_training", start: instant("2026-09-22T16:00:00Z"),
                           end: instant("2026-09-22T17:00:00Z"), durationMinutes: 52.5,
                           metadata: SampleMetadata(healthKitType: "HKWorkoutTypeIdentifier", sourceName: "Apple Watch",
                                                    sourceBundleID: "com.apple.health.2F1C", sourceRevision: "11.0",
                                                    deviceProductType: "Watch7,1", timezone: CHICAGO,
                                                    timezoneSource: .sampleMetadata,
                                                    sampleStart: instant("2026-09-22T16:00:00Z"),
                                                    sampleEnd: instant("2026-09-22T17:00:00Z"), providerMetadata: [:]))),
            .snapshot(.init(eventID: id(5), day: LocalDay(year: 2026, month: 9, day: 22), timezone: CHICAGO,
                            asOf: instant("2026-09-22T18:00:00Z"), queriedAt: instant("2026-09-22T18:00:05.123456Z"),
                            steps: 4821)),
            .delete(.init(eventID: id(6), sourceRecordID: "5d1a4c2e-0000-4000-8000-000000000001",
                          deletedAt: instant("2026-09-22T19:00:00.5Z"))),
        ]
        let text = events.map { String(decoding: $0.json.encoded(), as: UTF8.self) }.joined(separator: "\n") + "\n"
        let path = fixtures.appendingPathComponent("swift_events.jsonl")
        if ProcessInfo.processInfo.environment["UPDATE_WIRE_FIXTURES"] == "1" {
            try text.write(to: path, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), text,
                       "swift_events.jsonl is stale: rerun with UPDATE_WIRE_FIXTURES=1, then the Python test")
    }

    /// Python -> Swift: every real server response decodes.
    func testRealServerResponsesDecode() throws {
        struct Exchange: Decodable { var status: Int; var response: JSONValue }
        let wire = try JSONDecoder().decode([String: Exchange].self, from: fixture("server_wire.json"))
        func data(_ name: String) -> Data { wire[name]!.response.encoded() }

        let published = try JSONDecoder().decode(SyncResponse.self, from: data("sync_published"))
        XCTAssertEqual(published.state.status, "published")
        XCTAssertNotNil(published.state.widgetState?.presentation.headline)
        XCTAssertNotNil(published.state.runID)
        XCTAssertTrue(published.results.allSatisfy { $0.status == "accepted" })

        let replayed = try JSONDecoder().decode(SyncResponse.self, from: data("sync_replayed"))
        XCTAssertEqual(replayed.results, published.results)

        let mixed = try JSONDecoder().decode(SyncResponse.self, from: data("sync_mixed"))
        XCTAssertEqual(mixed.results.map(\.status), ["accepted", "accepted", "conflict", "rejected"])
        XCTAssertEqual(mixed.results.map(\.code), [nil, nil, "CONFLICTING_PROVIDER_RECORD", "INVALID_UNIT"])

        XCTAssertEqual(try JSONDecoder().decode(SyncResponse.self, from: data("sync_pending")).state.status, "pending")
        XCTAssertEqual(try JSONDecoder().decode(SyncResponse.self, from: data("sync_unchanged")).state.status, "unchanged")

        let state = try JSONDecoder().decode(ReturnedState.self, from: data("state_current"))
        XCTAssertEqual(state.day, "2026-09-22")
        XCTAssertGreaterThan(state.runID, 0)

        for (name, code) in [("error_401", "UNAUTHORIZED"), ("error_409", "REQUEST_ID_REUSED"),
                             ("error_413", "TOO_MANY_EVENTS"), ("error_422", "INVALID_REQUEST"),
                             ("state_before_any", "NO_STATE_YET")] {
            XCTAssertEqual(try JSONDecoder().decode(ErrorBody.self, from: data(name)).code, code, name)
        }
    }
}

/// JSONValue.parse (the fast event-log path) must equal the Codable decoder.
final class JSONValueParseTests: XCTestCase {
    func testMatchesTheDecoderOnEdgeCasesAndTheWholeSyntheticCorpus() throws {
        for text in ["1", "1.0", "1.5", "1e2", "-0", "-0.0", "9223372036854775807", "9223372036854775808", "1.0e0",
                     "true", "false", "null", "0.1", "-3.25e-5", #""aé\n""#, #"{"a":[1,2.5,{"b":null}],"c":"’"}"#] {
            let data = Data(text.utf8)
            XCTAssertEqual(try JSONValue.parse(data), try JSONDecoder().decode(JSONValue.self, from: data), text)
        }
        let data = fixtures.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("data/synthetic")
        var checked = 0
        for case let url as URL in FileManager.default.enumerator(at: data, includingPropertiesForKeys: nil)!
            where url.lastPathComponent == "events.jsonl" {
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                let bytes = Data(line.utf8)
                XCTAssertEqual(try JSONValue.parse(bytes), try JSONDecoder().decode(JSONValue.self, from: bytes))
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 1000)
    }
}
