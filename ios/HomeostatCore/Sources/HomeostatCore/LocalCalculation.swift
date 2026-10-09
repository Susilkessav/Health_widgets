import Foundation
import GRDB

/// On-device calculation (Plan/specs/On_device_plan.md): the phone's own event log
/// and import coverage, through the Swift engine, as the state the widget
/// shows. No network. backend/app/device_check.py rebuilds the same inputs.
extension LocalStore {
    static let coveredTypes: [(key: String, domain: Domain)] =
        SampleType.allCases.map { ($0.rawValue, $0.domain) } + [("steps", .movement)]

    /// Today's result as of the common import cutoff, or nil before any import.
    public func calculateLocally(now: Instant, zone: String, settings: EngineSettings = .standard) throws -> ReturnedState? {
        try localRun(now: now, zone: zone, settings: settings)?.state
    }

    /// The result together with the exact inputs it was calculated from, so the
    /// widget snapshot never comes from a second, possibly newer, database read.
    public struct LocalRun: Sendable {
        public let state: ReturnedState
        let inputs: LocalInputs
        let zone: String
        let now: Instant

        public var eventCount: Int { inputs.observations.count }

        /// When the earliest observation happened (not when it was delivered).
        public var oldestEvent: Instant? {
            inputs.observations.compactMap { observation -> Instant? in
                switch observation.event.kind {
                case .point(_, let at, _): at
                case .interval(_, let start, _), .workout(_, let start, _, _): start
                case .snapshot(_, _, let asOf, _, _): asOf
                case .delete: nil
                }
            }.min()
        }

        /// The widget's input file for this run (EngineSnapshot); throws `tooLarge` above the cap.
        public func snapshot(scope: String) throws -> Data {
            try EngineSnapshot.encode(inputs, header: .init(
                scope: scope, zone: zone, day: Zone(zone)!.day(of: state.effectiveAt),
                inputRevision: state.inputRevision, runID: state.runID, effective: state.effectiveAt, knownAt: now))
        }
    }

    public func localRun(now: Instant, zone: String, settings: EngineSettings = .standard) throws -> LocalRun? {
        guard let inputs = try localInputs(zone: zone) else { return nil }
        let (state, effective) = try LocalEngine.evaluate(inputs, now: now, zone: zone, settings: settings)
        let calendar = Zone(zone)!
        let run = try db.write { db -> Int64 in
            let next = (Int64(try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'local_run'") ?? "") ?? 0) + 1
            try LocalStore.set(String(next), "local_run", in: db)
            return next
        }
        return LocalRun(state: ReturnedState(day: calendar.day(of: effective).description, effectiveAt: effective,
                                             inputRevision: inputs.revision, runID: run, isToday: true,
                                             healthState: state.json, widgetState: mapWidgetState(state)),
                        inputs: inputs, zone: zone, now: now)
    }

    func localFeatures(_ inputs: LocalInputs, effective: Instant, knownAt: Instant, zone: String,
                       settings: EngineSettings = .standard) throws -> DailyFeatures {
        try calculateFeatures(inputs.observations, EngineContext(
            day: Zone(zone)!.day(of: effective), timezone: zone, effectiveAt: effective, knownAt: knownAt,
            coverage: inputs.coverage), settings)
    }

    func localInputs(zone: String) throws -> LocalInputs? {
        try db.read { db in
            func value(_ key: String) throws -> String? {
                try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [key])
            }
            guard let lower = try value("import_lower_bound").flatMap(Instant.parse) else { return nil }
            var through: [Domain: Instant] = [:]
            for (key, domain) in Self.coveredTypes {
                if let end = try value("covered_through_\(key)").flatMap(Instant.parse) { through[domain] = end }
            }
            let coverage = try through.map { domain, end in
                // An unresolved quarantined sample in the window means the log may
                // be missing data there, so the window can't be vouched for.
                let quarantined = try Bool.fetchOne(db, sql: """
                    SELECT 1 FROM quarantine WHERE domain = ? AND resolved_at IS NULL
                    AND (sample_start IS NULL OR sample_end IS NULL OR (sample_start < ? AND sample_end >= ?))
                    """, arguments: [domain.rawValue, end.microseconds, lower.microseconds]) ?? false
                return EngineCoverage(domain: domain, timezone: zone, complete: !quarantined, startAt: lower,
                                      endAt: max(end, lower))
            }
            let visible = try Self.visibleRows(db)
            return LocalInputs(lower: lower, through: through, observations: visible.map(\.observation),
                               rows: visible.map { ($0.body, $0.createdAt) }, coverage: coverage,
                               revision: try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM event_outbox") ?? 0)
        }
    }

    /// Every imported event, uploaded or not, minus records a completed
    /// re-read of their type no longer returned (deleted or hidden while an
    /// anchor was lost). Tombstones stay: they remove records wherever seen.
    func localObservations() throws -> [EngineObservation] {
        try db.read(Self.observations)
    }

    static func observations(_ db: Database) throws -> [EngineObservation] {
        try visibleRows(db).map(\.observation)
    }

    static func visibleRows(_ db: Database) throws -> [(body: Data, createdAt: String, observation: EngineObservation)] {
        var visible: [String: Set<String>] = [:]  // HealthKit type -> record IDs the last re-read returned
        for type in SampleType.allCases {
            guard let generation = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?",
                                                       arguments: ["covered_generation_\(type.rawValue)"]),
                  try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?",
                                      arguments: ["covered_through_\(type.rawValue)"]) != nil else { continue }
            visible[Normalizer.healthKitTypes[type.domain]!] = Set(try String.fetchAll(db, sql: """
                SELECT source_record_id FROM generation_members WHERE type = ? AND generation = ?
                """, arguments: [type.rawValue, generation]))
        }
        // ponytail: parses the whole log each run (~1,700 events: about 0.1 s on a
        // phone after the 2026-10-06 parsing fixes); prune events older than the
        // 28-day baseline + 7-day workout window if a profile shows it matters again.
        return try Row.fetchAll(db, sql: "SELECT body, created_at FROM event_outbox ORDER BY id").compactMap { row in
            let body: Data = row["body"]
            let created: String = row["created_at"]
            guard let event = try? EngineEvent(json: JSONValue.parse(body)), let at = Instant.parse(created) else { return nil }
            if let meta = event.meta, let ids = visible[meta.healthKitType], !ids.contains(event.recordID) {
                return nil
            }
            return (body, created, EngineObservation(event: event, deliveredAt: at))
        }
    }

    /// The on-device result, kept apart from any server state.
    public func storeLocalState(_ state: ReturnedState) throws {
        try setValue(String(decoding: try JSONEncoder().encode(state), as: UTF8.self), for: "local_state")
    }

    public func storedLocalState() throws -> ReturnedState? {
        guard let text = try value("local_state") else { return nil }
        return try JSONDecoder().decode(ReturnedState.self, from: Data(text.utf8))
    }
}
