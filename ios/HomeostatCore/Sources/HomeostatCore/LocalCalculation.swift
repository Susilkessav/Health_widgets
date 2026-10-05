import Foundation
import GRDB

/// What the on-device calculation reads, from one database snapshot so the
/// events, coverage and revision always belong together.
struct LocalInputs {
    let lower: Instant
    /// How far each domain's last complete import reached.
    let through: [Domain: Instant]
    let observations: [EngineObservation]
    let coverage: [EngineCoverage]
    /// The newest event in the log (the result's input revision).
    let revision: Int64
}

/// On-device calculation (Plan/On_device_plan.md): the phone's own event log
/// and import coverage, through the Swift engine, as the state the widget
/// shows. No network. backend/app/device_check.py rebuilds the same inputs.
extension LocalStore {
    static let coveredTypes: [(key: String, domain: Domain)] =
        SampleType.allCases.map { ($0.rawValue, $0.domain) } + [("steps", .movement)]

    /// Today's result as of the common import cutoff, or nil before any import.
    public func calculateLocally(now: Instant, zone: String, settings: EngineSettings = .standard) throws -> ReturnedState? {
        guard let inputs = try localInputs(zone: zone) else { return nil }
        // Every domain's result is "as of" the same instant: the earliest one
        // any domain's import reached today (recalc.import_cutoff). A domain
        // stuck before today doesn't pull the result back a day; it just
        // isn't covered today.
        let calendar = Zone(zone)!
        let today = calendar.start(of: calendar.day(of: now))
        let effective = min(now, inputs.through.values.filter { $0 > today }.min() ?? now)
        let state = computeHealthState(try localFeatures(inputs, effective: effective, knownAt: now, zone: zone,
                                                         settings: settings), settings)
        let run = try db.write { db -> Int64 in
            let next = (Int64(try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'local_run'") ?? "") ?? 0) + 1
            try LocalStore.set(String(next), "local_run", in: db)
            return next
        }
        return ReturnedState(day: calendar.day(of: effective).description, effectiveAt: effective,
                             inputRevision: inputs.revision, runID: run, isToday: true, healthState: state.json,
                             widgetState: mapWidgetState(state))
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
            return LocalInputs(lower: lower, through: through, observations: try Self.observations(db),
                               coverage: coverage,
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
        // ponytail: parses the whole log each run; prune events older than the
        // 28-day baseline + 7-day workout window if this ever shows up in profiles.
        return try Row.fetchAll(db, sql: "SELECT body, created_at FROM event_outbox ORDER BY id").compactMap { row in
            let body: Data = row["body"]
            guard let event = try? EngineEvent(json: JSONDecoder().decode(JSONValue.self, from: body)),
                  let at = Instant.parse(row["created_at"]) else { return nil }
            if let meta = event.meta, let ids = visible[meta.healthKitType], !ids.contains(event.recordID) {
                return nil
            }
            return EngineObservation(event: event, deliveredAt: at)
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
