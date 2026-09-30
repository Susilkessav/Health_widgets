import Foundation
import GRDB

/// A persisted upload request. Its `body` is sent byte for byte on every retry.
public struct UploadRequest: Hashable, Sendable {
    public var requestID: UUID
    public var body: Data
    public var eventIDs: [UUID]
    public var attempts: Int
    public var nextAttemptAt: Instant
}

public enum OutboxError: Error { case byteLimitBelowEnvelope }

extension LocalStore {
    /// The open request to (re)send, or a new one built from the outbox.
    /// Coverage is included only after every event it vouches for (same domain,
    /// queued earlier) has been acknowledged; a dead-lettered one withholds it.
    public func nextRequest(deviceZone: String, maxEvents: Int, maxBytes: Int, now: Instant,
                            makeID: () -> UUID = UUID.init) throws -> UploadRequest? {
        try db.write { db in
            if let open = try Row.fetchOne(db, sql: """
                SELECT * FROM upload_requests WHERE state = 'pending' ORDER BY created_at, request_id LIMIT 1
                """) {
                return LocalStore.request(from: open)
            }
            let requestID = makeID()
            let installation = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'installation_id'")!
            var coverage: [(Int64, JSONValue)] = []
            var events: [(Int64, UUID, JSONValue)] = []
            var scans: [(Int64, JSONValue)] = []
            func encoded() -> Data {
                var body: [String: JSONValue] = [
                    "request_id": .string(requestID.uuidString.lowercased()),
                    "installation_id": .string(installation),
                    "device_timezone": .string(deviceZone),
                    "coverage": .array(coverage.map(\.1)),
                    "events": .array(events.map(\.2)),
                ]
                if !scans.isEmpty { body["visibility"] = .array(scans.map(\.1)) }
                return JSONValue.object(body).encoded()
            }
            guard encoded().count <= maxBytes else { throw OutboxError.byteLimitBelowEnvelope }
            let itemLimit = max(1, Int(try String.fetchOne(db,
                sql: "SELECT value FROM sync_state WHERE key = 'max_items'") ?? "") ?? maxEvents)
            // Events first, so eligible coverage cannot starve the remaining import.
            for row in try Row.fetchAll(db, sql: """
                SELECT id, client_event_id, body FROM event_outbox WHERE state = 'pending' ORDER BY id LIMIT ?
                """, arguments: [min(maxEvents, itemLimit)]) {
                let body: Data = row["body"]
                let json = try JSONDecoder().decode(JSONValue.self, from: body)
                events.append((row["id"], UUID(uuidString: row["client_event_id"])!, json))
                if encoded().count > maxBytes {
                    events.removeLast()
                    if !events.isEmpty { break }
                    try db.execute(sql: "UPDATE event_outbox SET state = 'dead_letter', code = 'TOO_LARGE' WHERE id = ?",
                                   arguments: [row["id"] as Int64])
                }
            }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM coverage_outbox WHERE state = 'pending' ORDER BY id") {
                if events.count + coverage.count >= itemLimit { break }
                let id: Int64 = row["id"], domain: String = row["domain"], dependsOn: Int64 = row["depends_on_outbox_id"]
                let states = try String.fetchSet(db, sql: """
                    SELECT DISTINCT state FROM event_outbox WHERE domain = ? AND id <= ?
                    """, arguments: [domain, dependsOn])
                let unavailable = (row["status"] as String) == "unavailable"
                if unavailable || states.isDisjoint(with: ["pending", "assigned"]) {
                    var start: String = row["start_at"]
                    // "complete" can't vouch for a record the server rejected, so it
                    // starts after the latest dead letter instead of never being sent.
                    if !unavailable && states.contains("dead_letter") {
                        guard let after = try LocalStore.latestDeadLetterEnd(domain: domain, upTo: dependsOn, in: db),
                              let end = Instant.parse(row["end_at"]), after < end else {
                            try db.execute(sql: "UPDATE coverage_outbox SET state = 'withheld' WHERE id = ?", arguments: [id])
                            continue
                        }
                        if let from = Instant.parse(start), from < after { start = after.wire }
                    }
                    coverage.append((id, .object([
                        "domain": .string(domain), "timezone": .string(row["timezone"]),
                        "status": .string(row["status"]),
                        "start_at": .string(start), "end_at": .string(row["end_at"]),
                    ])))
                    if encoded().count > maxBytes {
                        coverage.removeLast()
                        if !events.isEmpty || !coverage.isEmpty { break }
                        try db.execute(sql: "UPDATE coverage_outbox SET state = 'withheld' WHERE id = ?", arguments: [id])
                    }
                }
            }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM visibility_outbox WHERE state = 'pending' ORDER BY id") {
                if !events.isEmpty { break }
                if events.count + coverage.count + scans.count >= itemLimit { break }
                let id: Int64 = row["id"], type: String = row["type"]
                // A legacy assigned request may return here after a 413 split, and so
                // may a scan whose generation was replaced while it was in flight.
                // Only the current generation's scan is accurate, and the server
                // takes one scan per type per request.
                guard let scopeEnd: String = row["scope_end_at"],
                      let sampleType = SampleType(rawValue: type),
                      try LocalStore.generation(sampleType, in: db) == row["generation_number"] as String else {
                    try db.execute(sql: "UPDATE visibility_outbox SET state = 'superseded' WHERE id = ?", arguments: [id])
                    continue
                }
                let states = try String.fetchSet(db, sql: "SELECT DISTINCT state FROM event_outbox WHERE domain = ?",
                                                arguments: [SampleType(rawValue: type)!.domain.rawValue])
                // A scan is finalization, never part of the batch that delivers
                // the identities it reconciles. Retryable items must be ACKed first.
                // Dead letters don't block it: the server never stored them, and the
                // "complete" coverage that follows the scan starts after them.
                if !states.isDisjoint(with: ["pending", "assigned"]) { continue }
                let members = try String.fetchAll(db, sql: """
                    SELECT source_record_id FROM generation_members WHERE type = ? AND generation = ? ORDER BY source_record_id
                    """, arguments: [type, row["generation"] as String])
                scans.append((id, .object([
                    "scan_id": .string(row["scan_id"]),
                    "healthkit_type": .string(Normalizer.healthKitTypes[SampleType(rawValue: type)!.domain]!),
                    "scope_start_at": .string(row["scope_start_at"]),
                    "scope_end_at": .string(scopeEnd),
                    "members": .array(members.map(JSONValue.string)),
                ])))
                if encoded().count > maxBytes {
                    scans.removeLast()
                    if !events.isEmpty || !coverage.isEmpty || !scans.isEmpty { break }
                    try db.execute(sql: "UPDATE visibility_outbox SET state = 'withheld' WHERE id = ?", arguments: [id])
                }
            }
            let zoneChanged = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'sent_zone'")
                != deviceZone
            if events.isEmpty && coverage.isEmpty && scans.isEmpty && !zoneChanged { return nil }
            let body = encoded()
            let eventIDs = events.map { $0.1.uuidString.lowercased() }
            try db.execute(sql: """
                INSERT INTO upload_requests (request_id, body, event_ids, outbox_ids, coverage_ids, visibility_ids,
                                             next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [requestID.uuidString.lowercased(), body, eventIDs.joined(separator: ","),
                                 events.map { String($0.0) }.joined(separator: ","),
                                 coverage.map { String($0.0) }.joined(separator: ","),
                                 scans.map { String($0.0) }.joined(separator: ","), now.wire, now.wire])
            for (id, _, _) in events {
                try db.execute(sql: "UPDATE event_outbox SET state = 'assigned', request_id = ? WHERE id = ?",
                               arguments: [requestID.uuidString.lowercased(), id])
            }
            for (id, _) in coverage {
                try db.execute(sql: "UPDATE coverage_outbox SET state = 'assigned', request_id = ? WHERE id = ?",
                               arguments: [requestID.uuidString.lowercased(), id])
            }
            for (id, _) in scans {
                try db.execute(sql: "UPDATE visibility_outbox SET state = 'assigned', request_id = ? WHERE id = ?",
                               arguments: [requestID.uuidString.lowercased(), id])
            }
            return UploadRequest(requestID: requestID, body: body, eventIDs: events.map(\.1), attempts: 0,
                                 nextAttemptAt: now)
        }
    }

    /// When the latest dead-lettered event in `domain` (up to outbox `upTo`)
    /// ended. nil if one has no readable time, so nothing can be vouched for.
    static func latestDeadLetterEnd(domain: String, upTo: Int64, in db: Database) throws -> Instant? {
        var latest: Instant?
        for body in try Data.fetchAll(db, sql: """
            SELECT body FROM event_outbox WHERE domain = ? AND id <= ? AND state = 'dead_letter'
            """, arguments: [domain, upTo]) {
            let json = try JSONDecoder().decode(JSONValue.self, from: body)
            guard let text = (json["metadata"]?["sample_end_at"] ?? json["as_of"] ?? json["deleted_at"])?.string,
                  let end = Instant.parse(text) else { return nil }
            latest = max(latest ?? end, end)
        }
        return latest
    }

    static func request(from row: Row) -> UploadRequest {
        let ids: String = row["event_ids"]
        return UploadRequest(requestID: UUID(uuidString: row["request_id"])!, body: row["body"],
                             eventIDs: ids.isEmpty ? [] : ids.split(separator: ",").map { UUID(uuidString: String($0))! },
                             attempts: row["attempts"], nextAttemptAt: Instant.parse(row["next_attempt_at"])!)
    }

    /// Applies a validated response in one transaction.
    public func apply(_ response: SyncResponse, to request: UploadRequest) throws {
        try db.write { db in
            let requestID = request.requestID.uuidString.lowercased()
            for result in response.results {
                let eventID = request.eventIDs[result.index].uuidString.lowercased()
                let state: String
                switch result.status {
                case "accepted", "duplicate": state = "acknowledged"
                case "conflict": state = "conflict"
                default: state = "dead_letter"
                }
                try db.execute(sql: "UPDATE event_outbox SET state = ?, code = ? WHERE client_event_id = ?",
                               arguments: [state, result.code, eventID])
            }
            try db.execute(sql: "UPDATE coverage_outbox SET state = 'acknowledged' WHERE request_id = ?",
                           arguments: [requestID])
            // An acknowledged scan of the current generation completes that
            // type's recovery: the server now knows what is no longer visible.
            for row in try Row.fetchAll(db, sql: "SELECT * FROM visibility_outbox WHERE request_id = ?",
                                        arguments: [requestID]) {
                let type: String = row["type"]
                if let sampleType = SampleType(rawValue: type),
                   try LocalStore.generation(sampleType, in: db) == row["generation_number"] as String,
                   let endText: String = row["scope_end_at"], let end = Instant.parse(endText),
                   let start = Instant.parse(row["scope_start_at"]) {
                    try LocalStore.set(nil, "recovery_\(type)", in: db)
                    let zone = try JSONDecoder().decode(JSONValue.self, from: request.body)["device_timezone"]?.string ?? "UTC"
                    _ = try LocalStore.enqueueCoverage(.init(domain: sampleType.domain, timezone: zone, start: start,
                                                             end: end), now: end, in: db)
                }
            }
            try db.execute(sql: "UPDATE visibility_outbox SET state = 'acknowledged' WHERE request_id = ?",
                           arguments: [requestID])
            let recovering = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_state WHERE key LIKE 'recovery\\_%' ESCAPE '\\'") ?? 0
            if recovering == 0, try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'last_anchor_recovery'")?
                .hasPrefix("Incomplete") == true {
                try LocalStore.set("Reconciled", "last_anchor_recovery", in: db)
            }
            try db.execute(sql: "UPDATE upload_requests SET state = 'done', last_error = NULL WHERE request_id = ?",
                           arguments: [requestID])
            if let zone = try JSONDecoder().decode(JSONValue.self, from: request.body)["device_timezone"]?.string {
                try LocalStore.set(zone, "sent_zone", in: db)
            }
            if let revision = response.revision {
                let known = Int64(try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'acknowledged_revision'") ?? "0") ?? 0
                try LocalStore.set(String(max(known, revision)), "acknowledged_revision", in: db)
            }
        }
    }

    public func reschedule(_ request: UploadRequest, attempts: Int, next: Instant, error: String) throws {
        try db.write {
            try $0.execute(sql: "UPDATE upload_requests SET attempts = ?, next_attempt_at = ?, last_error = ? WHERE request_id = ?",
                           arguments: [attempts, next.wire, error, request.requestID.uuidString.lowercased()])
        }
    }

    /// `paused` (409) or `quarantined` (422): not retried automatically.
    public func setRequestState(_ request: UploadRequest, _ state: String, error: String) throws {
        try db.write {
            try $0.execute(sql: "UPDATE upload_requests SET state = ?, last_error = ? WHERE request_id = ?",
                           arguments: [state, error, request.requestID.uuidString.lowercased()])
        }
    }

    /// After a definitive 413: retire the request and return its items to the
    /// queue with their event IDs, to be sent in smaller new requests.
    public func split(_ request: UploadRequest) throws {
        try db.write { db in
            let requestID = request.requestID.uuidString.lowercased()
            try db.execute(sql: "UPDATE upload_requests SET state = 'superseded', last_error = 'TOO_LARGE' WHERE request_id = ?",
                           arguments: [requestID])
            let coverageCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM coverage_outbox WHERE request_id = ?",
                                                 arguments: [requestID]) ?? 0
            let scanCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM visibility_outbox WHERE request_id = ?",
                                             arguments: [requestID]) ?? 0
            let itemCount = request.eventIDs.count + coverageCount + scanCount
            try LocalStore.set(String(max(1, itemCount / 2)), "max_items", in: db)
            if request.eventIDs.count == 1 && coverageCount == 0 && scanCount == 0 {
                try db.execute(sql: "UPDATE event_outbox SET state = 'dead_letter', code = 'TOO_LARGE' WHERE request_id = ?",
                               arguments: [requestID])
            } else {
                try db.execute(sql: "UPDATE event_outbox SET state = 'pending', request_id = NULL WHERE request_id = ?",
                               arguments: [requestID])
            }
            let coverageState = itemCount == 1 && coverageCount == 1 ? "withheld" : "pending"
            try db.execute(sql: "UPDATE coverage_outbox SET state = ?, request_id = NULL WHERE request_id = ?",
                           arguments: [coverageState, requestID])
            try db.execute(sql: "UPDATE visibility_outbox SET state = ?, request_id = NULL WHERE request_id = ?",
                           arguments: [itemCount == 1 && scanCount == 1 ? "withheld" : "pending", requestID])
            if itemCount == 0 { try LocalStore.set("ENVELOPE_TOO_LARGE", "paused", in: db) }
        }
    }

    /// Keeps a returned state only if it is at least as new as the stored one,
    /// ordered by (input_revision, run_id). Returns whether it was stored.
    @discardableResult
    public func storeState(_ state: ReturnedState) throws -> Bool {
        try db.write { db in
            if let stored = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'state_order'") {
                let parts = stored.split(separator: ",").compactMap { Int64($0) }
                if parts.count == 2, (state.inputRevision, state.runID) < (parts[0], parts[1]) { return false }
            }
            try LocalStore.set("\(state.inputRevision),\(state.runID)", "state_order", in: db)
            try LocalStore.set(String(decoding: try JSONEncoder().encode(state), as: UTF8.self), "state", in: db)
            return true
        }
    }

    public func storedState() throws -> ReturnedState? {
        guard let text = try value("state") else { return nil }
        return try JSONDecoder().decode(ReturnedState.self, from: Data(text.utf8))
    }

    public func pendingRetryAt() throws -> Instant? {
        try db.read { db in
            let value = try String.fetchOne(db, sql: """
                SELECT next_attempt_at FROM upload_requests WHERE state = 'pending' AND attempts > 0
                ORDER BY created_at, request_id LIMIT 1
                """)
            return value.flatMap(Instant.parse)
        }
    }

    public func openRequests() throws -> [(requestID: UUID, state: String, attempts: Int, lastError: String?)] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT request_id, state, attempts, last_error FROM upload_requests
                WHERE state IN ('pending', 'paused', 'quarantined') ORDER BY created_at
                """).map { (UUID(uuidString: $0["request_id"])!, $0["state"], $0["attempts"], $0["last_error"]) }
        }
    }
}
