import Foundation
import GRDB
import XCTest
@testable import HomeostatCore

final class SyncEngineTests: XCTestCase {
    var store: LocalStore!
    var clock: TestClock!
    let config = BackendConfig(baseURL: URL(string: "http://localhost:8000")!, deviceToken: "test-key")

    override func setUpWithError() throws {
        store = try LocalStore(path: nil)
        clock = TestClock()
    }

    func engine(_ transport: FakeTransport, maxEvents: Int = 250) -> SyncEngine {
        var limits = SyncLimits()
        limits.maxEvents = maxEvents
        let clock = self.clock!
        return SyncEngine(store: store, config: config, transport: transport, clock: { clock.now },
                          random: { 1.0 }, deviceZone: { CHICAGO }, limits: limits)
    }

    func enqueue(_ count: Int) throws {
        let samples = (0..<count).map {
            sample(.hrvSDNN(milliseconds: Double(50 + $0)), start: "2026-09-22T11:59:00Z", end: "2026-09-22T12:00:00Z")
        }
        _ = try store.commitPage(type: "hrv", domain: .hrv, predicateVersion: "v", samples: samples, deleted: [],
                                 newAnchor: Data([1]), normalizer: Normalizer(deviceZone: CHICAGO), now: NOW)
    }

    func clientIDs() throws -> [String] {
        try store.db.read { try String.fetchAll($0, sql: "SELECT client_event_id FROM event_outbox ORDER BY id") }
    }

    func requestIDRows() throws -> [String] {
        try store.db.read { try String.fetchAll($0, sql: "SELECT request_id FROM upload_requests") }
    }

    func states() throws -> [String] {
        try store.db.read { try String.fetchAll($0, sql: "SELECT state FROM event_outbox ORDER BY id") }
    }

    func testAcceptedEventsAreAcknowledgedAndTheRequestIsDone() async throws {
        try enqueue(3)
        let transport = FakeTransport(acceptingServer())
        let outcome = await engine(transport).syncOnce()
        guard case .sent(_, "published") = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try states(), ["acknowledged", "acknowledged", "acknowledged"])
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let second = await engine(transport).syncOnce()
        XCTAssertEqual(second, .idle)
    }

    func testALostResponseResendsTheExactSameBytes() async throws {
        try enqueue(2)
        var fail = true
        let server = acceptingServer()
        let transport = FakeTransport { request in
            if fail { fail = false; throw URLError(.networkConnectionLost) }
            return try await server(request)
        }
        let sync = engine(transport)
        guard case .retryScheduled(let at, "NETWORK") = await sync.syncOnce() else { return XCTFail() }
        XCTAssertEqual(at, NOW.adding(seconds: 2))
        let early = await sync.syncOnce()
        XCTAssertEqual(early, .notDue(until: at))  // the schedule is persisted
        clock.now = at
        guard case .sent = await sync.syncOnce() else { return XCTFail() }
        XCTAssertEqual(transport.bodies.count, 2)
        XCTAssertEqual(transport.bodies[0], transport.bodies[1])
    }

    func testRejectionsDeadLetterAndConflictsAreKeptForDiagnosis() async throws {
        try enqueue(3)
        let transport = FakeTransport { request in
            var response = try JSONDecoder().decode(SyncResponse.self, from: try await acceptingServer()(request).1)
            response.results[1].status = "conflict"
            response.results[1].code = "CONFLICTING_PROVIDER_RECORD"
            response.results[2].status = "rejected"
            response.results[2].code = "INVALID_UNIT"
            return (200, try JSONEncoder().encode(response), [:])
        }
        guard case .sent = await engine(transport).syncOnce() else { return XCTFail() }
        XCTAssertEqual(try states(), ["acknowledged", "conflict", "dead_letter"])
    }

    func testMalformedOrMismatchedResponsesAcknowledgeNothing() async throws {
        let mutations: [(inout SyncResponse) -> Void] = [
            { $0.results.removeLast() },                              // missing result
            { $0.results[0].index = 1 },                              // wrong index
            { $0.results[0].clientEventID = UUID() },                 // wrong event
            { $0.requestID = UUID() },                                // another request's response
        ]
        for mutate in mutations {
            try setUpWithError()
            try enqueue(2)
            let transport = FakeTransport { request in
                var response = try JSONDecoder().decode(SyncResponse.self, from: try await acceptingServer()(request).1)
                mutate(&response)
                return (200, try JSONEncoder().encode(response), [:])
            }
            guard case .protocolError = await engine(transport).syncOnce() else { return XCTFail() }
            XCTAssertEqual(try states(), ["assigned", "assigned"])
        }
        try setUpWithError()
        try enqueue(1)
        guard case .protocolError("MALFORMED_RESPONSE") = await engine(FakeTransport { _ in (200, Data("{".utf8), [:]) })
            .syncOnce() else { return XCTFail() }
    }

    func testUnauthorizedPausesAllUploadsUntilResumed() async throws {
        try enqueue(1)
        let sync = engine(FakeTransport { _ in (401, Data(#"{"code":"UNAUTHORIZED"}"#.utf8), [:]) })
        let first = await sync.syncOnce()
        let again = await sync.syncOnce()
        XCTAssertEqual(first, .paused(reason: "UNAUTHORIZED"))
        XCTAssertEqual(again, .paused(reason: "UNAUTHORIZED"))
        try await sync.resume()
        XCTAssertEqual(try store.value("paused"), nil)
    }

    func testReusedRequestIDAndInvalidEnvelopeStopAutomaticRetries() async throws {
        try enqueue(1)
        let reused = await engine(FakeTransport { _ in (409, Data(), [:]) }).syncOnce()
        XCTAssertEqual(reused, .paused(reason: "REQUEST_ID_REUSED"))
        XCTAssertEqual(try store.openRequests().map(\.state), ["paused"])
        try setUpWithError()
        try enqueue(1)
        let invalid = await engine(FakeTransport { _ in (422, Data(), [:]) }).syncOnce()
        XCTAssertEqual(invalid, .quarantined(reason: "INVALID_REQUEST"))
        XCTAssertEqual(try store.openRequests().map(\.state), ["quarantined"])
    }

    func testTooLargeSplitsIntoNewRequestsKeepingEventIDs() async throws {
        try enqueue(4)
        let original = try clientIDs()
        var sizes: [Int] = []
        let server = acceptingServer()
        let transport = FakeTransport { request in
            let events = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)["events"]
            guard case .array(let items)? = events else { return (500, Data(), [:]) }
            sizes.append(items.count)
            return items.count > 2 ? (413, Data(), [:]) : try await server(request)
        }
        let outcomes = await engine(transport).syncAll()
        XCTAssertEqual(outcomes.first, .split)
        XCTAssertEqual(sizes, [4, 2, 2])
        XCTAssertEqual(try states(), Array(repeating: "acknowledged", count: 4))
        let sent = try clientIDs()
        XCTAssertEqual(sent, original)
    }

    func testRetryAfterLongerThanBackoffIsHonored() async throws {
        try enqueue(1)
        guard case .retryScheduled(let at, "HTTP_429") = await engine(
            FakeTransport { _ in (429, Data(), ["Retry-After": "120"]) }).syncOnce() else { return XCTFail() }
        XCTAssertEqual(at, NOW.adding(seconds: 120))
        try setUpWithError()
        try enqueue(1)
        let unavailable = engine(FakeTransport { _ in (503, Data(), [:]) })
        var delays: [Int64] = []
        for _ in 0..<10 {
            guard case .retryScheduled(let next, _) = await unavailable.syncOnce() else { return XCTFail() }
            delays.append((next.microseconds - clock.now.microseconds) / 1_000_000)
            clock.now = next
        }
        XCTAssertEqual(delays, [2, 4, 8, 16, 32, 64, 128, 256, 300, 300])  // capped at 5 minutes
    }

    func testTwoConcurrentTriggersSendOneRequest() async throws {
        try enqueue(5)
        let transport = FakeTransport(acceptingServer())
        let sync = engine(transport)
        async let first = sync.syncOnce()
        async let second = sync.syncOnce()
        let outcomes = await [first, second]
        XCTAssertTrue(outcomes.contains(.busy))
        let requestIDs = try requestIDRows()
        XCTAssertEqual(requestIDs.count, 1)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testATimezoneChangeAloneIsSentOnce() async throws {
        let transport = FakeTransport(acceptingServer(stateStatus: "unchanged"))
        let sync = engine(transport)
        guard case .sent = await sync.syncOnce() else { return XCTFail() }  // first sync: the zone is new
        let idle = await sync.syncOnce()
        XCTAssertEqual(idle, .idle)
        let body = try JSONDecoder().decode(JSONValue.self, from: transport.bodies[0])
        XCTAssertEqual(body["device_timezone"]?.string, CHICAGO)
    }

    func testStateIsStoredOnlyWhenNotOlder() async throws {
        let wire = try JSONDecoder().decode([String: [String: JSONValue]].self, from: fixture("server_wire.json"))
        let current = wire["state_current"]!["response"]!.encoded()
        let sync = engine(FakeTransport { _ in (200, current, [:]) })
        let stored = await sync.refreshState()
        XCTAssertEqual(stored, .stored)
        XCTAssertEqual(try store.storedState()?.day, "2026-09-22")
        let none = await engine(FakeTransport { _ in (404, Data(#"{"code":"NO_STATE_YET"}"#.utf8), [:]) }).refreshState()
        XCTAssertEqual(none, .noStateYet)
    }

    func testAnOldDeadLetterNoLongerPinsRecovery() async throws {
        let lower = instant("2026-08-17T05:00:00Z")
        let rejected = sample(.hrvSDNN(milliseconds: 40), start: "2026-09-01T10:00:00Z", end: "2026-09-01T10:01:00Z")
        _ = try store.commitPage(type: "hrv", domain: .hrv, predicateVersion: "g1", samples: [rejected], deleted: [],
                                 newAnchor: Data([1]), normalizer: Normalizer(deviceZone: CHICAGO), now: NOW)
        try sql("UPDATE event_outbox SET state = 'dead_letter'")
        try store.beginAnchorRecovery(type: .hrv, lower: lower, zone: CHICAGO, now: NOW)
        try store.enqueueScan(type: .hrv, generation: "g2", scopeStart: lower, now: NOW)

        let transport = FakeTransport(acceptingServer())
        _ = await engine(transport).syncAll()

        XCTAssertNil(try store.value("recovery_hrv"))
        let sent = try transport.bodies.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
        XCTAssertTrue(sent.contains { $0["visibility"] != nil })
        // The coverage the scan unlocks is sent, starting after the rejected sample.
        let complete = sent.flatMap { body -> [JSONValue] in
            guard case .array(let items)? = body["coverage"] else { return [] }
            return items.filter { $0["status"]?.string == "complete" }
        }
        XCTAssertEqual(complete.map { $0["start_at"]?.string }, [rejected.end.wire])
        XCTAssertEqual(try count("SELECT COUNT(*) FROM coverage_outbox WHERE state = 'withheld'"), 0)
    }

    func testAScanReplacedWhileInFlightIsNotSentBesideItsReplacement() async throws {
        let lower = instant("2026-08-17T05:00:00Z")
        try store.enqueueScan(type: .hrv, generation: "g1", scopeStart: lower, now: NOW)
        // A second item, so the 413 split requeues the scan instead of withholding it.
        try store.enqueueCoverage(.init(domain: .sleep, timezone: CHICAGO, start: lower, end: NOW), now: NOW)
        var first = true
        let accept = acceptingServer()
        let transport = FakeTransport { request in
            if first {
                first = false
                // While the g1 scan is in flight, the anchor is lost and g2 completes.
                try self.store.beginAnchorRecovery(type: .hrv, lower: lower, zone: CHICAGO, now: NOW)
                try self.store.enqueueScan(type: .hrv, generation: "g2", scopeStart: lower, now: NOW)
                return (413, Data(), [:])
            }
            return try await accept(request)
        }
        _ = await engine(transport).syncAll()

        let scans = try transport.bodies.dropFirst().map { body -> Int in
            guard case .array(let items)? = try JSONDecoder().decode(JSONValue.self, from: body)["visibility"] else { return 0 }
            return items.count
        }
        XCTAssertEqual(scans.reduce(0, +), 1)  // only g2, never both in one request (the server rejects that)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM visibility_outbox WHERE generation = 'g1' AND state = 'superseded'"), 1)
        XCTAssertNil(try store.value("recovery_hrv"))
    }

    func sql(_ statement: String) throws { try store.db.write { try $0.execute(sql: statement) } }
    func count(_ query: String) throws -> Int? { try store.db.read { try Int.fetchOne($0, sql: query) } }
}
