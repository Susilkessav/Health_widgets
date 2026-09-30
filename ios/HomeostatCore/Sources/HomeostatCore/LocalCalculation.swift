import Foundation
import GRDB

/// On-device calculation (Plan/On_device_plan.md): the phone's own event log
/// and import coverage, through the Swift engine, as the state the widget
/// shows. No network.
extension LocalStore {
    static let coveredTypes: [(key: String, domain: Domain)] =
        SampleType.allCases.map { ($0.rawValue, $0.domain) } + [("steps", .movement)]

    /// Today's result as of the common import cutoff, or nil before any import.
    public func calculateLocally(now: Instant, zone: String, settings: EngineSettings = .standard) throws -> ReturnedState? {
        guard let lower = try value("import_lower_bound").flatMap(Instant.parse) else { return nil }
        var through: [Domain: Instant] = [:]
        for (key, domain) in Self.coveredTypes {
            if let end = try value("covered_through_\(key)").flatMap(Instant.parse) { through[domain] = end }
        }
        // Every domain's result is "as of" the same instant: the earliest one
        // any domain's import reached today (recalc.import_cutoff). A domain
        // stuck before today doesn't pull the result back a day; it just
        // isn't covered today.
        let calendar = Zone(zone)!
        let today = calendar.start(of: calendar.day(of: now))
        let effective = min(now, through.values.filter { $0 > today }.min() ?? now)
        let observations = try localObservations()
        let coverage = try through.map { domain, end in
            EngineCoverage(domain: domain, timezone: zone, complete: try !quarantined(domain, lower, end),
                           startAt: lower, endAt: max(end, lower))
        }
        let day = calendar.day(of: effective)
        let features = try calculateFeatures(observations, EngineContext(day: day, timezone: zone, effectiveAt: effective,
                                                                        knownAt: now, coverage: coverage), settings)
        let state = computeHealthState(features, settings)
        let run = try db.write { db -> Int64 in
            let next = (Int64(try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'local_run'") ?? "") ?? 0) + 1
            try LocalStore.set(String(next), "local_run", in: db)
            return next
        }
        let revision = try db.read { try Int64.fetchOne($0, sql: "SELECT MAX(id) FROM event_outbox") } ?? 0
        return ReturnedState(day: day.description, effectiveAt: effective, inputRevision: revision, runID: run,
                             isToday: true, healthState: state.json, widgetState: mapWidgetState(state))
    }

    /// Every imported event, uploaded or not, minus records a completed
    /// re-read of their type no longer returned (deleted or hidden while an
    /// anchor was lost). Tombstones stay: they remove records wherever seen.
    func localObservations() throws -> [EngineObservation] {
        try db.read { db in
            var hidden: [String: Set<String>] = [:]  // HealthKit type -> visible record IDs
            for type in SampleType.allCases {
                guard let generation = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?",
                                                           arguments: ["covered_generation_\(type.rawValue)"]),
                      try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?",
                                          arguments: ["covered_through_\(type.rawValue)"]) != nil else { continue }
                hidden[Normalizer.healthKitTypes[type.domain]!] = Set(try String.fetchAll(db, sql: """
                    SELECT source_record_id FROM generation_members WHERE type = ? AND generation = ?
                    """, arguments: [type.rawValue, generation]))
            }
            // ponytail: parses the whole log each run; prune events older than the
            // 28-day baseline + 7-day workout window if this ever shows up in profiles.
            return try Row.fetchAll(db, sql: "SELECT body, created_at FROM event_outbox ORDER BY id").compactMap { row in
                let body: Data = row["body"]
                guard let event = try? EngineEvent(json: JSONDecoder().decode(JSONValue.self, from: body)),
                      let at = Instant.parse(row["created_at"]) else { return nil }
                if let meta = event.meta, let visible = hidden[meta.healthKitType], !visible.contains(event.recordID) {
                    return nil
                }
                return EngineObservation(event: event, deliveredAt: at)
            }
        }
    }

    /// An unresolved quarantined sample overlapping the window means the log
    /// may be missing data there, so the window can't be vouched for.
    func quarantined(_ domain: Domain, _ start: Instant, _ end: Instant) throws -> Bool {
        try db.read {
            try Bool.fetchOne($0, sql: """
                SELECT 1 FROM quarantine WHERE domain = ? AND resolved_at IS NULL
                AND (sample_start IS NULL OR sample_end IS NULL OR (sample_start < ? AND sample_end >= ?))
                """, arguments: [domain.rawValue, end.microseconds, start.microseconds]) ?? false
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
