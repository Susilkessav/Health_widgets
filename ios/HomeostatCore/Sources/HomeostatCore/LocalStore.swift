import Foundation
import GRDB

/// The app-private durable store (Step 9-13 plan section 5).
///
/// Invariants:
/// - A HealthKit page's events, provider index, deletions, quarantine and new
///   anchor commit in one transaction, or none of them do. An anchor never
///   advances before its data is durable.
/// - An upload request's exact bytes are stored before they are sent; a retry
///   resends those bytes, never a rebuilt request.
/// - One store belongs to one backend and account (the app opens a separate
///   file per scope), so an old queue can never reach a new user.
public final class LocalStore: Sendable {
    public let db: DatabaseQueue

    /// `path == nil` opens an in-memory store (tests).
    public init(path: String?) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        db = try path.map { try DatabaseQueue(path: $0, configuration: configuration) }
            ?? DatabaseQueue(configuration: configuration)
        try LocalStore.migrator.migrate(db)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE authorization_ledger (
                    type TEXT PRIMARY KEY, status TEXT NOT NULL, requested_at TEXT, last_error TEXT,
                    first_visible_at TEXT, last_visible_at TEXT);
                CREATE TABLE query_anchors (
                    type TEXT NOT NULL, predicate_version TEXT NOT NULL, anchor BLOB NOT NULL, updated_at TEXT NOT NULL,
                    PRIMARY KEY (type, predicate_version));
                CREATE TABLE provider_records (
                    source_record_id TEXT NOT NULL, event_type TEXT NOT NULL, content_hash TEXT NOT NULL,
                    client_event_id TEXT NOT NULL, PRIMARY KEY (source_record_id, event_type, content_hash));
                CREATE TABLE deletions (source_record_id TEXT PRIMARY KEY, deleted_at TEXT NOT NULL);
                CREATE TABLE step_buckets (
                    timezone TEXT NOT NULL, day TEXT NOT NULL, as_of TEXT NOT NULL, steps INTEGER NOT NULL,
                    PRIMARY KEY (timezone, day, as_of));
                CREATE TABLE quarantine (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, domain TEXT NOT NULL, source_record_id TEXT NOT NULL,
                    reason TEXT NOT NULL, created_at TEXT NOT NULL, UNIQUE (domain, source_record_id, reason));
                CREATE TABLE event_outbox (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, client_event_id TEXT NOT NULL UNIQUE,
                    domain TEXT NOT NULL, event_type TEXT NOT NULL, body BLOB NOT NULL,
                    state TEXT NOT NULL DEFAULT 'pending'
                        CHECK (state IN ('pending', 'assigned', 'acknowledged', 'conflict', 'dead_letter')),
                    request_id TEXT, code TEXT, created_at TEXT NOT NULL);
                CREATE INDEX event_outbox_state ON event_outbox (state, id);
                CREATE TABLE coverage_outbox (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, domain TEXT NOT NULL, timezone TEXT NOT NULL,
                    start_at TEXT NOT NULL, end_at TEXT NOT NULL, status TEXT NOT NULL,
                    depends_on_outbox_id INTEGER NOT NULL,
                    state TEXT NOT NULL DEFAULT 'pending'
                        CHECK (state IN ('pending', 'assigned', 'acknowledged', 'withheld')),
                    request_id TEXT, created_at TEXT NOT NULL);
                CREATE TABLE upload_requests (
                    request_id TEXT PRIMARY KEY, body BLOB NOT NULL, event_ids TEXT NOT NULL,
                    outbox_ids TEXT NOT NULL, coverage_ids TEXT NOT NULL,
                    state TEXT NOT NULL DEFAULT 'pending'
                        CHECK (state IN ('pending', 'done', 'paused', 'quarantined', 'superseded')),
                    attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at TEXT NOT NULL, last_error TEXT,
                    created_at TEXT NOT NULL);
                CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
        }
        migrator.registerMigration("v2_repairable_imports") { db in
            try db.execute(sql: """
                ALTER TABLE quarantine ADD COLUMN raw_sample BLOB;
                ALTER TABLE quarantine ADD COLUMN sample_start INTEGER;
                ALTER TABLE quarantine ADD COLUMN sample_end INTEGER;
                ALTER TABLE quarantine ADD COLUMN resolved_at TEXT;
                CREATE TABLE provider_timezones (source_record_id TEXT PRIMARY KEY, timezone TEXT NOT NULL);
                """)
            // Existing outbox bodies retain the first assigned fallback zone.
            for row in try Row.fetchAll(db, sql: "SELECT body FROM event_outbox ORDER BY id") {
                let body: Data = row["body"]
                let json = try JSONDecoder().decode(JSONValue.self, from: body)
                if let id = json["source_record_id"]?.string,
                   let zone = json["metadata"]?["timezone"]?.string,
                   json["metadata"]?["timezone_source"]?.string == "device_at_ingestion" {
                    try db.execute(sql: "INSERT OR IGNORE INTO provider_timezones VALUES (?, ?)", arguments: [id, zone])
                }
            }
            // Old recovery reset every type; old quarantine lacks repair data.
            // Re-read only affected types, keeping deletion recovery incomplete.
            let hadRecovery = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'last_anchor_recovery'") != nil
            let legacyDomains = try String.fetchSet(db, sql: "SELECT DISTINCT domain FROM quarantine WHERE raw_sample IS NULL")
            let affected = SampleType.allCases.filter { hadRecovery || legacyDomains.contains($0.domain.rawValue) }
            if !affected.isEmpty {
                let lower = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'import_lower_bound'")
                    .flatMap(Instant.parse)
                let now = Instant(Date())
                let old = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'query_generation'") ?? "1"
                for type in affected {
                    try LocalStore.set(String((Int(old) ?? 1) + 1), "query_generation_\(type.rawValue)", in: db)
                    try LocalStore.set("incomplete", "recovery_\(type.rawValue)", in: db)
                    try db.execute(sql: "UPDATE coverage_outbox SET state = 'withheld' WHERE domain = ? AND status = 'complete' AND state = 'pending'",
                                   arguments: [type.domain.rawValue])
                    if let lower, lower < now {
                        _ = try LocalStore.enqueueCoverage(.init(domain: type.domain, timezone: "UTC", start: lower,
                                                                 end: now, status: "unavailable"), now: now, in: db)
                    }
                }
                try LocalStore.set("Incomplete: earlier import requires deletion reconciliation", "last_anchor_recovery", in: db)
            }
            // The old refresh flag was not committed atomically. Revalidate it.
            try db.execute(sql: "DELETE FROM sync_state WHERE key = 'steps_full_refresh_day'")
        }
        return migrator
    }

    // MARK: - sync_state

    public func value(_ key: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [key]) }
    }

    public func setValue(_ value: String?, for key: String) throws {
        try db.write { try LocalStore.set(value, key, in: $0) }
    }

    static func set(_ value: String?, _ key: String, in db: Database) throws {
        if let value {
            try db.execute(sql: "INSERT INTO sync_state (key, value) VALUES (?, ?) "
                           + "ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
        } else {
            try db.execute(sql: "DELETE FROM sync_state WHERE key = ?", arguments: [key])
        }
    }

    // MARK: - Authorization ledger (never "granted"/"denied": HealthKit hides that)

    public struct LedgerRow: Equatable, Sendable {
        public var type: String, status: String, requestedAt: String?, lastError: String?
        public var firstVisibleAt: String?, lastVisibleAt: String?
    }

    public func recordAuthorizationRequest(types: [String], at: Instant, error: String?) throws {
        try db.write { db in
            for type in types {
                try db.execute(sql: """
                    INSERT INTO authorization_ledger (type, status, requested_at, last_error) VALUES (?, 'requested', ?, ?)
                    ON CONFLICT(type) DO UPDATE SET status = 'requested', requested_at = excluded.requested_at,
                        last_error = excluded.last_error
                    """, arguments: [type, at.wire, error])
            }
        }
    }

    public func ledger() throws -> [LedgerRow] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM authorization_ledger ORDER BY type").map {
                LedgerRow(type: $0["type"], status: $0["status"], requestedAt: $0["requested_at"],
                          lastError: $0["last_error"], firstVisibleAt: $0["first_visible_at"],
                          lastVisibleAt: $0["last_visible_at"])
            }
        }
    }

    // MARK: - Anchors and the atomic page commit

    public func anchor(type: String, predicateVersion: String) throws -> Data? {
        try db.read {
            try Data.fetchOne($0, sql: "SELECT anchor FROM query_anchors WHERE type = ? AND predicate_version = ?",
                              arguments: [type, predicateVersion])
        }
    }

    public struct PageResult: Equatable, Sendable {
        public var newEvents = 0, skippedDuplicates = 0, deletions = 0, quarantined = 0
    }

    /// Normalize one anchored page and persist everything it implies, plus its
    /// new anchor, in a single transaction. `beforeCommit` lets tests fail the
    /// transaction at its last moment.
    public func commitPage(type: String, domain: Domain, predicateVersion: String, samples: [RawSample],
                           deleted: [UUID], newAnchor: Data, normalizer: Normalizer, now: Instant,
                           makeID: () -> UUID = UUID.init,
                           beforeCommit: (() throws -> Void)? = nil) throws -> PageResult {
        try db.write { db in
            var result = PageResult()
            for sample in samples {
                let normalized = try LocalStore.normalize(sample, using: normalizer, eventID: makeID(), in: db)
                switch normalized {
                case .event(let event):
                    if try LocalStore.enqueueIfNew(event, domain: domain, now: now, in: db) {
                        result.newEvents += 1
                    } else {
                        result.skippedDuplicates += 1
                    }
                    try LocalStore.resolveQuarantine(sample.uuid.uuidString.lowercased(), now: now, in: db)
                case .quarantined(let item):
                    let encoder = JSONEncoder()
                    encoder.nonConformingFloatEncodingStrategy = .convertToString(
                        positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
                    try db.execute(sql: """
                        INSERT INTO quarantine (domain, source_record_id, reason, created_at, raw_sample, sample_start, sample_end)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(domain, source_record_id, reason) DO UPDATE SET
                            raw_sample = excluded.raw_sample, sample_start = excluded.sample_start,
                            sample_end = excluded.sample_end, resolved_at = NULL
                        """, arguments: [item.domain.rawValue, item.sourceRecordID, item.reason, now.wire,
                                         try encoder.encode(sample), min(sample.start, sample.end).microseconds,
                                         max(sample.start, sample.end).microseconds])
                    result.quarantined += 1
                }
            }
            for uuid in deleted {
                let recordID = uuid.uuidString.lowercased()
                try LocalStore.resolveQuarantine(recordID, now: now, in: db)
                // The first observation's time is kept so retries never change it.
                guard try String.fetchOne(db, sql: "SELECT deleted_at FROM deletions WHERE source_record_id = ?",
                                          arguments: [recordID]) == nil else { continue }
                try db.execute(sql: "INSERT INTO deletions (source_record_id, deleted_at) VALUES (?, ?)",
                               arguments: [recordID, now.wire])
                let event = CanonicalEvent.delete(.init(eventID: makeID(), sourceRecordID: recordID, deletedAt: now))
                try LocalStore.insertOutbox(event, domain: domain, now: now, in: db)
                result.deletions += 1
            }
            if !samples.isEmpty {
                try db.execute(sql: """
                    INSERT INTO authorization_ledger (type, status, first_visible_at, last_visible_at)
                        VALUES (?, 'not_requested', ?, ?)
                    ON CONFLICT(type) DO UPDATE SET first_visible_at = COALESCE(first_visible_at, excluded.first_visible_at),
                        last_visible_at = excluded.last_visible_at
                    """, arguments: [type, now.wire, now.wire])
            }
            try db.execute(sql: """
                INSERT INTO query_anchors (type, predicate_version, anchor, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(type, predicate_version) DO UPDATE SET anchor = excluded.anchor, updated_at = excluded.updated_at
                """, arguments: [type, predicateVersion, newAnchor, now.wire])
            try beforeCommit?()
            return result
        }
    }

    static func normalize(_ sample: RawSample, using normalizer: Normalizer, eventID: UUID,
                          in db: Database) throws -> Normalized {
        let id = sample.uuid.uuidString.lowercased()
        if sample.sampleTimeZone.flatMap(Zone.init) == nil {
            try db.execute(sql: "INSERT OR IGNORE INTO provider_timezones VALUES (?, ?)",
                           arguments: [id, normalizer.deviceZone])
        }
        let zone = try String.fetchOne(db, sql: "SELECT timezone FROM provider_timezones WHERE source_record_id = ?",
                                       arguments: [id]) ?? normalizer.deviceZone
        return Normalizer(deviceZone: zone).normalize(sample, eventID: eventID)
    }

    static func resolveQuarantine(_ recordID: String, now: Instant, in db: Database) throws {
        try db.execute(sql: "UPDATE quarantine SET resolved_at = ? WHERE source_record_id = ? AND resolved_at IS NULL",
                       arguments: [now.wire, recordID])
    }

    /// Retry durable samples after a normalizer upgrade. Unknown legacy rows
    /// without raw data remain unresolved until the provider is queried again.
    @discardableResult
    public func reprocessQuarantine(normalizer: Normalizer, now: Instant) throws -> Int {
        try db.write { db in
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(
                positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            var repaired = 0
            for row in try Row.fetchAll(db, sql: "SELECT raw_sample FROM quarantine WHERE resolved_at IS NULL AND raw_sample IS NOT NULL") {
                let data: Data = row["raw_sample"]
                let raw = try decoder.decode(RawSample.self, from: data)
                if case .event(let event) = try LocalStore.normalize(raw, using: normalizer, eventID: UUID(), in: db) {
                    _ = try LocalStore.enqueueIfNew(event, domain: raw.domain, now: now, in: db)
                    try LocalStore.resolveQuarantine(raw.uuid.uuidString.lowercased(), now: now, in: db)
                    repaired += 1
                }
            }
            return repaired
        }
    }

    /// Invalidates the affected domain immediately, even if the fresh query fails.
    public func beginAnchorRecovery(type: SampleType, lower: Instant, zone: String, now: Instant) throws {
        try db.write { db in
            let key = "query_generation_\(type.rawValue)"
            let old = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [key])
                ?? String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'query_generation'") ?? "1"
            try LocalStore.set(String((Int(old) ?? 1) + 1), key, in: db)
            try LocalStore.set("incomplete", "recovery_\(type.rawValue)", in: db)
            try LocalStore.set("Incomplete: \(type.rawValue) at \(now.wire); deletion reconciliation required",
                               "last_anchor_recovery", in: db)
            try db.execute(sql: "UPDATE coverage_outbox SET state = 'withheld' WHERE domain = ? AND status = 'complete' AND state = 'pending'",
                           arguments: [type.domain.rawValue])
            _ = try LocalStore.enqueueCoverage(.init(domain: type.domain, timezone: zone, start: lower,
                                                     end: now, status: "unavailable"), now: now, in: db)
        }
    }

    /// Inserts an event unless identical provider content is already recorded.
    static func enqueueIfNew(_ event: CanonicalEvent, domain: Domain, now: Instant, in db: Database) throws -> Bool {
        let known = try Bool.fetchOne(db, sql: """
            SELECT 1 FROM provider_records WHERE source_record_id = ? AND event_type = ? AND content_hash = ?
            """, arguments: [event.sourceRecordID, event.eventType, event.contentHash]) ?? false
        if known { return false }
        try db.execute(sql: """
            INSERT INTO provider_records (source_record_id, event_type, content_hash, client_event_id) VALUES (?, ?, ?, ?)
            """, arguments: [event.sourceRecordID, event.eventType, event.contentHash, event.eventID.uuidString.lowercased()])
        try insertOutbox(event, domain: domain, now: now, in: db)
        return true
    }

    static func insertOutbox(_ event: CanonicalEvent, domain: Domain, now: Instant, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO event_outbox (client_event_id, domain, event_type, body, created_at) VALUES (?, ?, ?, ?, ?)
            """, arguments: [event.eventID.uuidString.lowercased(), domain.rawValue, event.eventType,
                             event.json.encoded(), now.wire])
    }

    // MARK: - Step statistics

    /// Enqueues snapshots whose total differs from the last one recorded for
    /// the same bucket (new totals, including decreases, are new observations;
    /// unchanged re-reads are not). Optionally declares movement coverage in the
    /// same transaction.
    public func commitSnapshots(_ snapshots: [CanonicalEvent.Snapshot], coverage: CoverageDeclaration?,
                                now: Instant, fullRefreshDay: String? = nil,
                                beforeCommit: (() throws -> Void)? = nil) throws -> Int {
        try db.write { db in
            var added = 0
            for snapshot in snapshots {
                let last = try Int64.fetchOne(db, sql: """
                    SELECT steps FROM step_buckets WHERE timezone = ? AND day = ? AND as_of = ?
                    """, arguments: [snapshot.timezone, snapshot.day.description, snapshot.asOf.wire])
                if last == snapshot.steps { continue }
                try db.execute(sql: """
                    INSERT INTO step_buckets (timezone, day, as_of, steps) VALUES (?, ?, ?, ?)
                    ON CONFLICT(timezone, day, as_of) DO UPDATE SET steps = excluded.steps
                    """, arguments: [snapshot.timezone, snapshot.day.description, snapshot.asOf.wire, snapshot.steps])
                try LocalStore.insertOutbox(.snapshot(snapshot), domain: .movement, now: now, in: db)
                added += 1
            }
            if let coverage { _ = try LocalStore.enqueueCoverage(coverage, now: now, in: db) }
            if let fullRefreshDay { try LocalStore.set(fullRefreshDay, "steps_full_refresh_day", in: db) }
            try beforeCommit?()
            return added
        }
    }

    // MARK: - Coverage

    public struct CoverageDeclaration: Hashable, Sendable {
        public var domain: Domain, timezone: String, start: Instant, end: Instant, status: String
        public init(domain: Domain, timezone: String, start: Instant, end: Instant, status: String = "complete") {
            self.domain = domain
            self.timezone = timezone
            self.start = start
            self.end = end
            self.status = status
        }
    }

    /// Declares coverage after the events it vouches for. A quarantined sample
    /// in the domain suppresses "complete" coverage; returns whether it was queued.
    @discardableResult
    public func enqueueCoverage(_ declaration: CoverageDeclaration, now: Instant) throws -> Bool {
        try db.write { try LocalStore.enqueueCoverage(declaration, now: now, in: $0) }
    }

    static func enqueueCoverage(_ declaration: CoverageDeclaration, now: Instant, in db: Database) throws -> Bool {
        if declaration.status == "complete",
           try Bool.fetchOne(db, sql: """
               SELECT 1 FROM quarantine WHERE domain = ? AND resolved_at IS NULL
               AND (sample_start IS NULL OR sample_end IS NULL OR (sample_start < ? AND sample_end >= ?))
               """, arguments: [declaration.domain.rawValue, declaration.end.microseconds, declaration.start.microseconds]) ?? false {
            return false
        }
        let dependsOn = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM event_outbox") ?? 0
        try db.execute(sql: """
            INSERT INTO coverage_outbox (domain, timezone, start_at, end_at, status, depends_on_outbox_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [declaration.domain.rawValue, declaration.timezone, declaration.start.wire,
                             declaration.end.wire, declaration.status, dependsOn, now.wire])
        return true
    }

    // MARK: - Counts for the debug screen

    public struct Counts: Equatable, Sendable {
        public var pending = 0, assigned = 0, acknowledged = 0, conflict = 0, deadLetter = 0
        public var quarantined = 0, coveragePending = 0, coverageWithheld = 0, openRequests = 0
        public init() {}
    }

    public func counts() throws -> Counts {
        try db.read { db in
            var counts = Counts()
            for row in try Row.fetchAll(db, sql: "SELECT state, COUNT(*) AS n FROM event_outbox GROUP BY state") {
                let n: Int = row["n"]
                switch row["state"] as String {
                case "pending": counts.pending = n
                case "assigned": counts.assigned = n
                case "acknowledged": counts.acknowledged = n
                case "conflict": counts.conflict = n
                default: counts.deadLetter = n
                }
            }
            counts.quarantined = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM quarantine WHERE resolved_at IS NULL") ?? 0
            counts.coveragePending = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM coverage_outbox WHERE state IN ('pending', 'assigned')") ?? 0
            counts.coverageWithheld = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM coverage_outbox WHERE state = 'withheld'") ?? 0
            counts.openRequests = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM upload_requests WHERE state IN ('pending', 'paused', 'quarantined')") ?? 0
            return counts
        }
    }
}
