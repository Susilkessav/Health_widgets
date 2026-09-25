import Foundation
@testable import HomeostatCore

/// The Fixtures directory in the source tree (shared with the Python tests).
let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }

func instant(_ text: String) -> Instant { Instant.parse(text)! }

let NOW = instant("2026-09-22T18:00:00Z")  // 13:00 in Chicago
let CHICAGO = "America/Chicago"

/// A controllable clock shared across actors.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Instant
    init(_ start: Instant = NOW) { current = start }
    var now: Instant {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
    func advance(seconds: Int64) { now = now.adding(seconds: seconds) }
}

/// Deterministic UUIDs for tests.
final class IDs: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 1
    func make() -> UUID {
        lock.withLock {
            defer { next += 1 }
            return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", next))!
        }
    }
}

func sample(_ kind: RawSample.Kind, start: String, end: String, uuid: UUID = UUID(), zone: String? = CHICAGO,
            metadata: [String: String] = [:]) -> RawSample {
    RawSample(uuid: uuid, kind: kind, start: instant(start), end: instant(end), sourceName: "Apple Watch",
              sourceBundleID: "com.apple.health.ABC", sourceRevision: "11.0", productType: "Watch7,1",
              sampleTimeZone: zone, metadata: metadata)
}

/// Records every request and answers from a handler.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data, [String: String])
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    var requests: [URLRequest] { lock.withLock { _requests } }
    var bodies: [Data] { requests.compactMap(\.httpBody) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let (status, data, headers) = try await handler(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

/// A server that accepts every event, like the real one for new records.
func acceptingServer(stateStatus: String = "published") -> FakeTransport.Handler {
    { request in
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
        guard case .array(let events)? = body["events"] else { return (422, Data(), [:]) }
        let results: [JSONValue] = events.enumerated().map { index, event in
            .object(["index": .int(Int64(index)), "client_event_id": event["event_id"]!,
                     "status": .string("accepted"), "retryable": .bool(false)])
        }
        let response = JSONValue.object([
            "request_id": body["request_id"]!, "revision": .int(1), "results": .array(results),
            "affected_days": .array([]), "days_beyond_recalc_window": .int(0),
            "state": .object(["status": .string(stateStatus), "widget_state": .null,
                              "input_revision": .null, "run_id": .null]),
        ])
        return (200, response.encoded(), [:])
    }
}

/// A HealthKit stand-in with scripted pages and hourly steps.
final class FakeSource: HealthDataSource, @unchecked Sendable {
    private let lock = NSLock()
    var pages: [SampleType: [AnchoredPage]] = [:]
    var failAfterPages: [SampleType: Int] = [:]
    var corruptAnchorOnce: Set<SampleType> = []
    var steps: (Instant, Instant) throws -> [HourlyBucket] = { _, _ in [] }
    private(set) var anchorsSeen: [SampleType: [Data?]] = [:]
    private var served: [SampleType: Int] = [:]

    struct Failure: Error {}

    func anchoredPage(_ type: SampleType, since lowerBound: Instant, anchor: Data?, limit: Int) async throws -> AnchoredPage {
        try lock.withLock {
            anchorsSeen[type, default: []].append(anchor)
            if corruptAnchorOnce.contains(type), anchor != nil {
                corruptAnchorOnce.remove(type)
                throw HealthSourceError.corruptAnchor
            }
            let index = served[type, default: 0]
            if let limit = failAfterPages[type], index >= limit { throw Failure() }
            let scripted = pages[type] ?? []
            guard index < scripted.count else {
                return AnchoredPage(samples: [], deleted: [], anchor: anchor ?? Data([0]), hasMore: false)
            }
            served[type] = index + 1
            return scripted[index]
        }
    }

    func hourlySteps(from start: Instant, to end: Instant, zone: String) async throws -> [HourlyBucket] {
        try steps(start, end)
    }
}
