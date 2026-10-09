import Foundation

/// Provenance of one HealthKit sample, as the calculation needs it.
public struct EventMeta: Hashable {
    public let healthKitType: String
    public let sourceName: String
    public let sourceBundleID: String
    public let productType: String?
    public let timezone: String
    public let sampleStart: Instant
    public let sampleEnd: Instant
}

/// A canonical event (backend `canonical_events.py`), read from its JSON.
public struct EngineEvent: Hashable, Sendable {
    public enum Kind: Hashable {
        case point(metric: String, observedAt: Instant, value: Double)
        case interval(stage: String, start: Instant, end: Instant)
        case workout(type: String, start: Instant, end: Instant, durationMinutes: Double)
        case snapshot(day: LocalDay, timezone: String, asOf: Instant, queriedAt: Instant, steps: Int)
        case delete
    }

    public let eventID: String  // lowercase UUID text: orders exactly like the UUID's integer
    public let source: String
    public let recordID: String
    public let eventType: String
    public let kind: Kind
    public let meta: EventMeta?
    /// Canonical JSON without the client event ID: equal means the same provider content.
    public let content: Data
    public let full: Data

    public enum ParseError: Error { case invalid(String) }

    public init(json: JSONValue) throws {
        func text(_ value: JSONValue?, _ name: String) throws -> String {
            guard let text = value?.string else { throw ParseError.invalid(name) }
            return text
        }
        func instant(_ value: JSONValue?, _ name: String) throws -> Instant {
            guard let parsed = Instant.parse(try text(value, name)) else { throw ParseError.invalid(name) }
            return parsed
        }
        func number(_ value: JSONValue?, _ name: String) throws -> Double {
            switch value {
            case .int(let n)?: return Double(n)
            case .double(let d)?: return d
            default: throw ParseError.invalid(name)
            }
        }
        eventID = try text(json["event_id"], "event_id").lowercased()
        source = try text(json["source"], "source")
        recordID = try text(json["source_record_id"], "source_record_id")
        eventType = try text(json["event_type"], "event_type")
        if let m = json["metadata"] {
            meta = EventMeta(healthKitType: try text(m["healthkit_type"], "healthkit_type"),
                             sourceName: try text(m["source_name"], "source_name"),
                             sourceBundleID: try text(m["source_bundle_id"], "source_bundle_id"),
                             productType: m["device_product_type"]?.string, timezone: try text(m["timezone"], "timezone"),
                             sampleStart: try instant(m["sample_start_at"], "sample_start_at"),
                             sampleEnd: try instant(m["sample_end_at"], "sample_end_at"))
        } else {
            meta = nil
        }
        switch eventType {
        case "point_measurement":
            kind = .point(metric: try text(json["metric"], "metric"), observedAt: try instant(json["observed_at"], "observed_at"),
                          value: try number(json["value"], "value"))
        case "interval":
            kind = .interval(stage: try text(json["value"], "value"), start: try instant(json["start_at"], "start_at"),
                             end: try instant(json["end_at"], "end_at"))
        case "workout":
            kind = .workout(type: try text(json["workout_type"], "workout_type"), start: try instant(json["start_at"], "start_at"),
                            end: try instant(json["end_at"], "end_at"),
                            durationMinutes: try number(json["duration_minutes"], "duration_minutes"))
        case "daily_activity_snapshot":
            guard let day = LocalDay(try text(json["day"], "day")) else { throw ParseError.invalid("day") }
            kind = .snapshot(day: day, timezone: try text(json["timezone"], "timezone"),
                             asOf: try instant(json["as_of"], "as_of"), queriedAt: try instant(json["queried_at"], "queried_at"),
                             steps: Int(try number(json["steps"], "steps")))
        case "delete":
            kind = .delete
        default:
            throw ParseError.invalid("event_type")
        }
        if meta == nil, eventType != "daily_activity_snapshot", eventType != "delete" { throw ParseError.invalid("metadata") }
        guard case .object(var fields) = json else { throw ParseError.invalid("event") }
        full = Self.canonical(fields)
        fields["event_id"] = nil
        content = Self.canonical(fields)
    }

    /// Metadata entry order carries no meaning.
    static func canonical(_ fields: [String: JSONValue]) -> Data {
        var fields = fields
        if case .object(var meta)? = fields["metadata"], case .array(let entries)? = meta["provider_metadata"] {
            meta["provider_metadata"] = .array(entries.sorted { ($0["key"]?.string ?? "") < ($1["key"]?.string ?? "") })
            fields["metadata"] = .object(meta)
        }
        return JSONValue.object(fields).encoded()
    }

    var domain: String {
        switch kind {
        case .point(let metric, _, _): metric == "hrv_sdnn_ms" ? "hrv" : "rhr"
        case .interval: "sleep"
        case .workout: "workout"
        default: "movement"
        }
    }

    /// The local day a record belongs to, in its own timezone.
    var day: LocalDay {
        switch kind {
        case .snapshot(let day, _, _, _, _): return day
        case .point(_, let at, _): return Zone(meta!.timezone)!.day(of: at)
        case .interval(_, _, let end), .workout(_, _, let end, _): return Zone(meta!.timezone)!.day(of: end)
        case .delete: fatalError("a delete has no day")
        }
    }
}

/// One delivery of one event. Retries repeat the event.
public struct EngineObservation: Sendable {
    public let event: EngineEvent
    public let deliveredAt: Instant
    public init(event: EngineEvent, deliveredAt: Instant) {
        self.event = event
        self.deliveredAt = deliveredAt
    }
}

/// A declared query result: whole local days, or an exact interval. Later
/// revisions supersede earlier ones.
public struct EngineCoverage: Sendable {
    public var domain: Domain
    public var timezone: String
    public var complete: Bool
    public var startDay: LocalDay?, endDay: LocalDay?
    public var startAt: Instant?, endAt: Instant?
    public var revision: Int

    public init(domain: Domain, timezone: String, complete: Bool, startDay: LocalDay? = nil, endDay: LocalDay? = nil,
                startAt: Instant? = nil, endAt: Instant? = nil, revision: Int = 0) {
        self.domain = domain
        self.timezone = timezone
        self.complete = complete
        self.startDay = startDay
        self.endDay = endDay
        self.startAt = startAt
        self.endAt = endAt
        self.revision = revision
    }

    var span: (Instant, Instant) {
        if let startAt, let endAt { return (startAt, endAt) }
        let zone = Zone(timezone)!
        return (zone.start(of: startDay!), zone.start(of: zone.adding(days: 1, to: endDay!)))
    }
}

public struct EngineContext: Sendable {
    public var day: LocalDay
    public var timezone: String
    public var effectiveAt: Instant
    public var knownAt: Instant
    public var coverage: [EngineCoverage]
    /// Per-domain import cutoffs (decision D-A, models.py). A listed domain only
    /// uses records and coverage up to its own cutoff; ages are still measured
    /// at effectiveAt. Empty is the original single-cutoff calculation.
    public var cutoffs: [Domain: Instant]

    public init(day: LocalDay, timezone: String, effectiveAt: Instant, knownAt: Instant, coverage: [EngineCoverage],
                cutoffs: [Domain: Instant] = [:]) {
        self.day = day
        self.timezone = timezone
        self.effectiveAt = effectiveAt
        self.knownAt = knownAt
        self.coverage = coverage
        self.cutoffs = cutoffs
    }

    var zone: Zone { Zone(timezone)! }

    /// The latest instant this domain's records and coverage may come from.
    func cutoff(_ domain: Domain) -> Instant { cutoffs[domain] ?? effectiveAt }

    /// Local days first...last are covered when, at every instant of their span
    /// up to effectiveAt, the newest declaration there is complete. Undeclared
    /// time is unknown, never complete.
    func covered(_ domain: Domain, _ first: LocalDay, _ last: LocalDay) -> Bool {
        let start = zone.start(of: first)
        let end = min(zone.start(of: zone.adding(days: 1, to: last)), cutoff(domain))
        if end <= start { return true }
        let windows = coverage.filter { $0.domain == domain }.map { ($0, $0.span) }
            .filter { $0.1.0 < end && $0.1.1 > start }
        var cuts = Set([start, end])
        for (_, (a, b)) in windows { for t in [a, b] where start < t && t < end { cuts.insert(t) } }
        let sorted = cuts.sorted()
        for (pieceStart, pieceEnd) in zip(sorted, sorted.dropFirst()) {
            let here = windows.filter { $0.1.0 <= pieceStart && $0.1.1 >= pieceEnd }.map(\.0)
            guard let newest = here.map(\.revision).max() else { return false }
            if here.contains(where: { $0.revision == newest && !$0.complete }) { return false }
        }
        return true
    }
}

/// Past local days before `day`, oldest first.
func historyDays(_ day: LocalDay, _ count: Int, zone: Zone) -> [LocalDay] {
    (1...count).reversed().map { zone.adding(days: -$0, to: day) }
}

func seconds(_ from: Instant, _ to: Instant) -> Double { Double(to.microseconds - from.microseconds) / 1_000_000 }

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}
