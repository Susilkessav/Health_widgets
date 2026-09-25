import Foundation
import GRDB
import XCTest
@testable import HomeostatCore

final class NormalizerTests: XCTestCase {
    let normalizer = Normalizer(deviceZone: "America/Los_Angeles")

    func event(_ raw: RawSample) -> CanonicalEvent? {
        if case .event(let event) = normalizer.normalize(raw, eventID: UUID()) { return event }
        return nil
    }

    func reason(_ raw: RawSample) -> String? {
        if case .quarantined(let item) = normalizer.normalize(raw, eventID: UUID()) { return item.reason }
        return nil
    }

    func testPointsKeepOriginalTimesAndUseTheSampleEnd() throws {
        let raw = sample(.hrvSDNN(milliseconds: 54.2), start: "2026-09-22T05:00:00Z", end: "2026-09-22T12:00:00Z")
        guard case .point(let point) = event(raw) else { return XCTFail() }
        XCTAssertEqual(point.observedAt, raw.end)
        XCTAssertEqual(point.metadata.sampleStart, raw.start)  // a long interval is kept, not shortened
        XCTAssertEqual(point.sourceRecordID, raw.uuid.uuidString.lowercased())
    }

    func testTheSampleZoneWinsAndTheDeviceZoneIsTheRecordedFallback() {
        guard case .point(let own) = event(sample(.restingHR(beatsPerMinute: 58), start: "2026-09-22T12:00:00Z",
                                                  end: "2026-09-22T12:00:00Z")) else { return XCTFail() }
        XCTAssertEqual(own.metadata.timezoneSource, .sampleMetadata)
        guard case .point(let fallback) = event(sample(.restingHR(beatsPerMinute: 58), start: "2026-09-22T12:00:00Z",
                                                       end: "2026-09-22T12:00:00Z", zone: "Not/AZone")) else { return XCTFail() }
        XCTAssertEqual(fallback.metadata.timezone, "America/Los_Angeles")
        XCTAssertEqual(fallback.metadata.timezoneSource, .deviceAtIngestion)
    }

    func testSamplesTheServerWouldRejectAreQuarantinedWithAReason() {
        XCTAssertEqual(reason(sample(.sleep(.asleepCore), start: "2026-09-22T05:00:00Z", end: "2026-09-22T05:00:00Z")),
                       "ZERO_LENGTH_INTERVAL")
        XCTAssertEqual(reason(sample(.sleep(nil), start: "2026-09-22T05:00:00Z", end: "2026-09-22T06:00:00Z")),
                       "UNKNOWN_SLEEP_VALUE")
        XCTAssertEqual(reason(sample(.workout(activityType: "running", durationMinutes: 90),
                                     start: "2026-09-22T05:00:00Z", end: "2026-09-22T06:00:00Z")),
                       "DURATION_EXCEEDS_INTERVAL")
        XCTAssertEqual(reason(sample(.hrvSDNN(milliseconds: 0), start: "2026-09-22T05:00:00Z",
                                     end: "2026-09-22T05:00:00Z")), "NON_POSITIVE_VALUE")
        var noSource = sample(.hrvSDNN(milliseconds: 50), start: "2026-09-22T05:00:00Z", end: "2026-09-22T05:00:00Z")
        noSource.sourceBundleID = " "
        XCTAssertEqual(reason(noSource), "MISSING_SOURCE")
    }
}

final class StoreTests: XCTestCase {
    var store: LocalStore!
    let ids = IDs()
    let normalizer = Normalizer(deviceZone: CHICAGO)

    override func setUpWithError() throws { store = try LocalStore(path: nil) }

    func hrv(_ value: Double, uuid: UUID = UUID()) -> RawSample {
        sample(.hrvSDNN(milliseconds: value), start: "2026-09-22T11:59:00Z", end: "2026-09-22T12:00:00Z", uuid: uuid)
    }

    @discardableResult
    func commit(_ samples: [RawSample], deleted: [UUID] = [], anchor: UInt8 = 1, type: String = "hrv",
                domain: Domain = .hrv, fail: Bool = false) throws -> LocalStore.PageResult {
        try store.commitPage(type: type, domain: domain, predicateVersion: "v", samples: samples, deleted: deleted,
                             newAnchor: Data([anchor]), normalizer: normalizer, now: NOW, makeID: ids.make,
                             beforeCommit: fail ? { throw FakeSource.Failure() } : nil)
    }

    func testAPageAndItsAnchorCommitTogetherOrNotAtAll() throws {
        XCTAssertThrowsError(try commit([hrv(50)], anchor: 9, fail: true))
        XCTAssertNil(try store.anchor(type: "hrv", predicateVersion: "v"))
        XCTAssertEqual(try store.counts().pending, 0)
        try commit([hrv(50)], anchor: 9)
        XCTAssertEqual(try store.anchor(type: "hrv", predicateVersion: "v"), Data([9]))
        XCTAssertEqual(try store.counts().pending, 1)
    }

    func testRequeriedIdenticalSamplesAreNotEnqueuedTwice() throws {
        let uuid = UUID()
        XCTAssertEqual(try commit([hrv(50, uuid: uuid)]).newEvents, 1)
        XCTAssertEqual(try commit([hrv(50, uuid: uuid)]).skippedDuplicates, 1)
        XCTAssertEqual(try commit([hrv(51, uuid: uuid)]).newEvents, 1)  // changed content is new
        XCTAssertEqual(try store.counts().pending, 2)
    }

    func testADeletionIsEnqueuedOnceWithItsFirstObservedTime() throws {
        let uuid = UUID()
        XCTAssertEqual(try commit([], deleted: [uuid]).deletions, 1)
        XCTAssertEqual(try commit([], deleted: [uuid]).deletions, 0)
        let body = try store.db.read { try Data.fetchOne($0, sql: "SELECT body FROM event_outbox")! }
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        XCTAssertEqual(json["deleted_at"]?.string, NOW.wire)
        XCTAssertEqual(json["source_record_id"]?.string, uuid.uuidString.lowercased())
    }

    func testCoverageWaitsForItsEventsThenIsSent() throws {
        try commit([hrv(50)])
        try store.enqueueCoverage(.init(domain: .hrv, timezone: CHICAGO, start: NOW.adding(seconds: -86400), end: NOW),
                                  now: NOW)
        let first = try XCTUnwrap(try store.nextRequest(deviceZone: CHICAGO, maxEvents: 250, maxBytes: 1 << 22, now: NOW,
                                                        makeID: ids.make))
        XCTAssertEqual(try coverage(in: first), 0)  // the event isn't acknowledged yet
        try store.apply(accepted(first), to: first)
        let second = try XCTUnwrap(try store.nextRequest(deviceZone: CHICAGO, maxEvents: 250, maxBytes: 1 << 22, now: NOW,
                                                         makeID: ids.make))
        XCTAssertEqual(second.eventIDs, [])
        XCTAssertEqual(try coverage(in: second), 1)
    }

    func testADeadLetteredEventWithholdsItsDomainsCoverage() throws {
        try commit([hrv(50)])
        try store.enqueueCoverage(.init(domain: .hrv, timezone: CHICAGO, start: NOW.adding(seconds: -86400), end: NOW),
                                  now: NOW)
        let request = try XCTUnwrap(try store.nextRequest(deviceZone: CHICAGO, maxEvents: 250, maxBytes: 1 << 22,
                                                          now: NOW, makeID: ids.make))
        var response = accepted(request)
        response.results[0].status = "rejected"
        response.results[0].code = "INVALID_UNIT"
        try store.apply(response, to: request)
        try store.setValue(CHICAGO, for: "sent_zone")
        XCTAssertNil(try store.nextRequest(deviceZone: CHICAGO, maxEvents: 250, maxBytes: 1 << 22, now: NOW))
        XCTAssertEqual(try store.counts().coverageWithheld, 1)
        XCTAssertEqual(try store.counts().deadLetter, 1)
    }

    func testAQuarantinedSampleSuppressesCompleteCoverage() throws {
        let bad = sample(.sleep(nil), start: "2026-09-22T05:00:00Z", end: "2026-09-22T06:00:00Z")
        XCTAssertEqual(try commit([bad], type: "sleep", domain: .sleep).quarantined, 1)
        XCTAssertFalse(try store.enqueueCoverage(.init(domain: .sleep, timezone: CHICAGO,
                                                       start: NOW.adding(seconds: -86400), end: NOW), now: NOW))
        XCTAssertTrue(try store.enqueueCoverage(.init(domain: .hrv, timezone: CHICAGO,
                                                      start: NOW.adding(seconds: -86400), end: NOW), now: NOW))
    }

    func testRequestsRespectEventAndByteLimits() throws {
        try commit((0..<5).map { hrv(Double(50 + $0)) })
        let request = try XCTUnwrap(try store.nextRequest(deviceZone: CHICAGO, maxEvents: 2, maxBytes: 1 << 22,
                                                          now: NOW, makeID: ids.make))
        XCTAssertEqual(request.eventIDs.count, 2)
        try store.apply(accepted(request), to: request)
        let small = try XCTUnwrap(try store.nextRequest(deviceZone: CHICAGO, maxEvents: 250, maxBytes: request.body.count - 1, now: NOW,
                                                        makeID: ids.make))
        XCTAssertEqual(small.eventIDs.count, 1)  // the complete envelope fits one event, not two
        XCTAssertLessThan(small.body.count, request.body.count)
    }

    func testAnOlderStateIsNeverStoredOverANewerOne() throws {
        let wire = try JSONDecoder().decode([String: [String: JSONValue]].self, from: fixture("server_wire.json"))
        var state = try JSONDecoder().decode(ReturnedState.self, from: wire["state_current"]!["response"]!.encoded())
        XCTAssertTrue(try store.storeState(state))
        state.runID -= 1
        XCTAssertFalse(try store.storeState(state))
        state.inputRevision += 1
        XCTAssertTrue(try store.storeState(state))
    }

    func coverage(in request: UploadRequest) throws -> Int {
        guard case .array(let items)? = try JSONDecoder().decode(JSONValue.self, from: request.body)["coverage"] else {
            return -1
        }
        return items.count
    }
}

func accepted(_ request: UploadRequest) -> SyncResponse {
    SyncResponse(requestID: request.requestID, revision: 1,
                 results: request.eventIDs.enumerated().map {
                     EventResult(index: $0.offset, clientEventID: $0.element, status: "accepted", code: nil, retryable: false)
                 },
                 affectedDays: [], daysBeyondRecalcWindow: 0,
                 state: StateBlock(status: "pending", widgetState: nil, inputRevision: nil, runID: nil))
}
