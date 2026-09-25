import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public struct BackendConfig: Sendable {
    public var baseURL: URL
    public var apiKey: String

    public init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}

public struct SyncLimits: Sendable {
    public var maxEvents = 250
    public var maxBytes = 4 * 1024 * 1024
    public init() {}
}

public enum SyncOutcome: Equatable, Sendable {
    case idle
    /// Another trigger is already uploading; it continues as the single uploader.
    case busy
    case notDue(until: Instant)
    case sent(requestID: UUID, stateStatus: String)
    case retryScheduled(at: Instant, reason: String)
    case paused(reason: String)
    case quarantined(reason: String)
    case split
    case protocolError(reason: String)
}

public enum StateRefresh: Equatable, Sendable {
    case stored, olderIgnored, noStateYet, failed(reason: String)
}

/// The single uploader (Step 9-13 plan section 8). An actor, so concurrent
/// triggers can't assign or send the same request twice.
public actor SyncEngine {
    let store: LocalStore
    let config: BackendConfig
    let transport: HTTPTransport
    let clock: @Sendable () -> Instant
    let random: @Sendable () -> Double
    let deviceZone: @Sendable () -> String
    let limits: SyncLimits
    // Actors are reentrant: without this, a second trigger arriving while the
    // first awaits the network would find the same open request and send it again.
    var uploading = false

    public init(store: LocalStore, config: BackendConfig, transport: HTTPTransport,
                clock: @escaping @Sendable () -> Instant = { Instant(Date()) },
                random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
                deviceZone: @escaping @Sendable () -> String = { TimeZone.current.identifier },
                limits: SyncLimits = SyncLimits()) {
        self.store = store
        self.config = config
        self.transport = transport
        self.clock = clock
        self.random = random
        self.deviceZone = deviceZone
        self.limits = limits
    }

    /// Clears a credential pause after the user fixes the configuration.
    public func resume() throws {
        try store.setValue(nil, for: "paused")
    }

    /// Sends at most one request: the open one if any (exact bytes), else a new one.
    public func syncOnce() async -> SyncOutcome {
        if uploading { return .busy }
        uploading = true
        defer { uploading = false }
        do {
            if let reason = try store.value("paused") { return .paused(reason: reason) }
            let now = clock()
            let maxEvents = Int(try store.value("max_events") ?? "") ?? limits.maxEvents
            guard let request = try store.nextRequest(deviceZone: deviceZone(), maxEvents: maxEvents,
                                                       maxBytes: limits.maxBytes, now: now) else { return .idle }
            if request.nextAttemptAt > now { return .notDue(until: request.nextAttemptAt) }
            return try await send(request)
        } catch {
            return .protocolError(reason: "LOCAL_STORE_ERROR")
        }
    }

    /// Sends until there's nothing due, or a pause or failure (bounded).
    public func syncAll(maxRequests: Int = 50) async -> [SyncOutcome] {
        var outcomes: [SyncOutcome] = []
        for _ in 0..<maxRequests {
            if Task.isCancelled { break }
            let outcome = await syncOnce()
            outcomes.append(outcome)
            switch outcome {
            case .sent, .split: continue
            default: return outcomes
            }
        }
        return outcomes
    }

    func send(_ request: UploadRequest) async throws -> SyncOutcome {
        var http = URLRequest(url: config.baseURL.appendingPathComponent("v1/health/sync"))
        http.httpMethod = "POST"
        http.httpBody = request.body
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue(config.apiKey, forHTTPHeaderField: "X-Homeostat-Key")
        http.timeoutInterval = 60
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(http)
        } catch {
            // No response: the server may or may not have it. Resend the same bytes later.
            return try retry(request, reason: "NETWORK", retryAfter: nil)
        }
        switch response.statusCode {
        case 200:
            guard let decoded = try? JSONDecoder().decode(SyncResponse.self, from: data) else {
                return try retry(request, reason: "MALFORMED_RESPONSE", retryAfter: nil, protocolError: true)
            }
            if let problem = decoded.validate(against: request) {
                return try retry(request, reason: problem, retryAfter: nil, protocolError: true)
            }
            try store.apply(decoded, to: request)
            return .sent(requestID: request.requestID, stateStatus: decoded.state.status)
        case 401:
            try store.setValue("UNAUTHORIZED", for: "paused")
            return .paused(reason: "UNAUTHORIZED")
        case 409:
            try store.setRequestState(request, "paused", error: "REQUEST_ID_REUSED")
            return .paused(reason: "REQUEST_ID_REUSED")
        case 413:
            try store.split(request)
            return .split
        case 422:
            try store.setRequestState(request, "quarantined", error: "INVALID_REQUEST")
            return .quarantined(reason: "INVALID_REQUEST")
        case 429, 500...599:
            let after = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int64.init)
            return try retry(request, reason: "HTTP_\(response.statusCode)", retryAfter: after)
        default:
            return try retry(request, reason: "HTTP_\(response.statusCode)", retryAfter: nil, protocolError: true)
        }
    }

    /// Exponential backoff with jitter, 2 s to 5 min; a longer Retry-After wins.
    func retry(_ request: UploadRequest, reason: String, retryAfter: Int64?,
               protocolError: Bool = false) throws -> SyncOutcome {
        let attempts = request.attempts + 1
        let base = min(300.0, 2.0 * pow(2.0, Double(attempts - 1)))
        var delay = max(2.0, base * (0.5 + 0.5 * random()))
        if let retryAfter, Double(retryAfter) > delay { delay = Double(retryAfter) }
        let next = Instant(microseconds: clock().microseconds + Int64(delay * 1_000_000))
        try store.reschedule(request, attempts: attempts, next: next, error: reason)
        return protocolError ? .protocolError(reason: reason) : .retryScheduled(at: next, reason: reason)
    }

    /// Reads `GET /v1/state/current`. Stored only if not older than what we have.
    public func refreshState() async -> StateRefresh {
        var http = URLRequest(url: config.baseURL.appendingPathComponent("v1/state/current"))
        http.setValue(config.apiKey, forHTTPHeaderField: "X-Homeostat-Key")
        http.timeoutInterval = 30
        do {
            let (data, response) = try await transport.send(http)
            switch response.statusCode {
            case 200:
                guard let state = try? JSONDecoder().decode(ReturnedState.self, from: data) else {
                    return .failed(reason: "MALFORMED_STATE")
                }
                return try store.storeState(state) ? .stored : .olderIgnored
            case 404: return .noStateYet
            case 401:
                try store.setValue("UNAUTHORIZED", for: "paused")
                return .failed(reason: "UNAUTHORIZED")
            default: return .failed(reason: "HTTP_\(response.statusCode)")
            }
        } catch {
            return .failed(reason: "NETWORK")
        }
    }
}
