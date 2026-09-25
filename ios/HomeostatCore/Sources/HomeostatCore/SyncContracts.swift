import Foundation

/// `POST /v1/health/sync` response (backend Step 6-8 plan section 5.1).
public struct SyncResponse: Codable, Hashable, Sendable {
    public var requestID: UUID
    public var revision: Int64?
    public var results: [EventResult]
    public var affectedDays: [String]
    public var daysBeyondRecalcWindow: Int
    public var state: StateBlock

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id", revision, results, affectedDays = "affected_days"
        case daysBeyondRecalcWindow = "days_beyond_recalc_window", state
    }

    /// Checks the response belongs to `request`: same request ID, one result per
    /// event in order, and matching event IDs. Nothing is acknowledged otherwise.
    public func validate(against request: UploadRequest) -> String? {
        if requestID != request.requestID { return "RESPONSE_REQUEST_ID_MISMATCH" }
        if results.count != request.eventIDs.count { return "RESPONSE_RESULT_COUNT_MISMATCH" }
        for (position, result) in results.enumerated() {
            if result.index != position { return "RESPONSE_INDEX_MISMATCH" }
            if result.clientEventID != request.eventIDs[position] { return "RESPONSE_EVENT_ID_MISMATCH" }
            if !["accepted", "duplicate", "conflict", "rejected"].contains(result.status) {
                return "RESPONSE_UNKNOWN_STATUS"
            }
        }
        return nil
    }
}

public struct EventResult: Codable, Hashable, Sendable {
    public var index: Int
    public var clientEventID: UUID?
    public var status: String
    public var code: String?
    public var retryable: Bool

    enum CodingKeys: String, CodingKey {
        case index, clientEventID = "client_event_id", status, code, retryable
    }
}

/// Whether the upload's state is ready. `pending` is not an upload failure.
public struct StateBlock: Codable, Hashable, Sendable {
    public var status: String  // "published", "pending" or "unchanged"
    public var widgetState: WidgetState?
    public var inputRevision: Int64?
    public var runID: Int64?

    enum CodingKeys: String, CodingKey {
        case status, widgetState = "widget_state", inputRevision = "input_revision", runID = "run_id"
    }
}

/// The widget payload (backend `widget_state.py`).
public struct WidgetState: Codable, Hashable, Sendable {
    public var version: String
    public var effectiveAt: Instant
    public var presentation: Presentation
    public var primaryTrait: PrimaryTrait
    public var freshness: Freshness

    public struct Presentation: Codable, Hashable, Sendable {
        public var icon: String
        public var headline: String
        public var detail: String?
        public var secondary: String?
    }

    public struct PrimaryTrait: Codable, Hashable, Sendable {
        public var id: String
        public var explainable: Bool
    }

    public struct Freshness: Codable, Hashable, Sendable {
        public var lastUpdatedAt: Instant
        enum CodingKeys: String, CodingKey { case lastUpdatedAt = "last_updated_at" }
    }

    enum CodingKeys: String, CodingKey {
        case version, effectiveAt = "effective_at", presentation, primaryTrait = "primary_trait", freshness
    }
}

/// `GET /v1/state/current`.
public struct ReturnedState: Codable, Hashable, Sendable {
    public var day: String
    public var effectiveAt: Instant
    public var inputRevision: Int64
    public var runID: Int64
    public var isToday: Bool
    public var healthState: JSONValue
    public var widgetState: WidgetState

    enum CodingKeys: String, CodingKey {
        case day, effectiveAt = "effective_at", inputRevision = "input_revision", runID = "run_id"
        case isToday = "is_today", healthState = "health_state", widgetState = "widget_state"
    }
}

/// Error bodies carry a code only (the server never echoes values).
public struct ErrorBody: Codable, Hashable, Sendable {
    public var code: String
}
