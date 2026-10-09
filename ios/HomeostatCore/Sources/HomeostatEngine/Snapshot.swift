import Foundation

/// What one on-device calculation reads, from one database read so the events,
/// coverage and revision always belong together.
public struct LocalInputs: Sendable {
    public let lower: Instant
    /// How far each domain's last complete import reached.
    public let through: [Domain: Instant]
    public let observations: [EngineObservation]
    /// The stored bytes behind `observations`, in the same order (for the widget snapshot).
    public var rows: [(body: Data, createdAt: String)]
    public let coverage: [EngineCoverage]
    /// The newest event in the log (the result's input revision).
    public let revision: Int64

    public init(lower: Instant, through: [Domain: Instant], observations: [EngineObservation],
                rows: [(body: Data, createdAt: String)] = [], coverage: [EngineCoverage], revision: Int64) {
        self.lower = lower
        self.through = through
        self.observations = observations
        self.rows = rows
        self.coverage = coverage
        self.revision = revision
    }
}

public enum LocalEngine {
    /// Every domain's result is "as of" the same instant: the earliest one any
    /// domain's import reached today (recalc.import_cutoff). A domain stuck
    /// before today doesn't pull the result back a day; it just isn't covered today.
    public static func evaluate(_ inputs: LocalInputs, now: Instant, zone: String,
                                settings: EngineSettings = .standard) throws -> (state: HealthState, effective: Instant) {
        let calendar = Zone(zone)!
        let today = calendar.start(of: calendar.day(of: now))
        let effective = min(now, inputs.through.values.filter { $0 > today }.min() ?? now)
        let features = try calculateFeatures(inputs.observations, EngineContext(
            day: calendar.day(of: effective), timezone: zone, effectiveAt: effective, knownAt: now,
            coverage: inputs.coverage), settings)
        return (computeHealthState(features, settings), effective)
    }
}

/// The app's calculation inputs as one file the widget reads without the
/// database (Plan.md §4 path 3). The app writes it after every run; the widget
/// recalculates from it with its own step read, under the cache's ordering rule.
public enum EngineSnapshot {
    public static let version = "engine-inputs@1"
    /// Above this the app writes no snapshot and the widget keeps the cached result.
    public static let maxBytes = 2_000_000

    /// Which app run the snapshot belongs to. The widget only publishes over the
    /// cached result of this same run (scope, input revision, run ID).
    public struct Header: Equatable, Sendable {
        public let scope: String, zone: String, day: LocalDay
        public let inputRevision: Int64, runID: Int64
        /// The app run's result time and clock.
        public let effective: Instant, knownAt: Instant

        public init(scope: String, zone: String, day: LocalDay, inputRevision: Int64, runID: Int64,
                    effective: Instant, knownAt: Instant) {
            self.scope = scope
            self.zone = zone
            self.day = day
            self.inputRevision = inputRevision
            self.runID = runID
            self.effective = effective
            self.knownAt = knownAt
        }
    }

    /// Today's cumulative steps, read by the widget at `at`.
    public struct StepRead: Sendable {
        public let steps: Int64, at: Instant
        public init(steps: Int64, at: Instant) {
            self.steps = steps
            self.at = at
        }
    }

    public struct Result: Sendable {
        public let header: Header
        public let effective: Instant
        public let healthState: JSONValue
        public let widgetState: WidgetState
    }

    public enum Failure: Error, Equatable {
        case unsupported, malformed, otherSettings, tooLarge
        /// The read is not newer than the app's own step import, or is on another day.
        case notNewer
    }

    public static func encode(_ inputs: LocalInputs, header: Header) throws -> Data {
        let object: [String: Any] = [
            "version": version, "settings": EngineSettings.configSHA256,
            "scope": header.scope, "zone": header.zone, "day": header.day.description,
            "input_revision": header.inputRevision, "run_id": header.runID,
            "effective_at": header.effective.wire, "known_at": header.knownAt.wire,
            "lower": inputs.lower.wire,
            "through": Dictionary(uniqueKeysWithValues: inputs.through.map { ($0.key.rawValue, $0.value.wire) }),
            "complete": Dictionary(uniqueKeysWithValues: inputs.coverage.map { ($0.domain.rawValue, $0.complete) }),
            "events": try inputs.rows.map { ["delivered_at": $0.createdAt, "body": try JSONSerialization.jsonObject(with: $0.body)] },
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        return data
    }

    /// Without `steps`: the app's own calculation at `now`. With `steps`: movement
    /// at the step read; every other domain held at the app run's cutoff (D-A).
    public static func calculate(_ data: Data, now: Instant, steps: StepRead? = nil,
                                 settings: EngineSettings = .standard) throws -> Result {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["version"] as? String == version else { throw Failure.unsupported }
        guard root["settings"] as? String == EngineSettings.configSHA256 else { throw Failure.otherSettings }
        guard let scope = root["scope"] as? String, let zone = root["zone"] as? String, let calendar = Zone(zone),
              let day = (root["day"] as? String).flatMap(LocalDay.init),
              let revision = (root["input_revision"] as? NSNumber)?.int64Value,
              let runID = (root["run_id"] as? NSNumber)?.int64Value,
              let appEffective = (root["effective_at"] as? String).flatMap(Instant.parse),
              let appKnown = (root["known_at"] as? String).flatMap(Instant.parse),
              let lower = (root["lower"] as? String).flatMap(Instant.parse),
              let throughText = root["through"] as? [String: String], let complete = root["complete"] as? [String: Bool],
              let events = root["events"] as? [[String: Any]] else { throw Failure.malformed }
        var through: [Domain: Instant] = [:]
        for (key, value) in throughText {
            guard let domain = Domain(rawValue: key), let at = Instant.parse(value) else { throw Failure.malformed }
            through[domain] = at
        }
        var coverage = try through.map { domain, end in
            guard let isComplete = complete[domain.rawValue] else { throw Failure.malformed }
            return EngineCoverage(domain: domain, timezone: zone, complete: isComplete, startAt: lower, endAt: max(end, lower))
        }
        var observations = try events.map { entry -> EngineObservation in
            guard let body = entry["body"], let at = (entry["delivered_at"] as? String).flatMap(Instant.parse),
                  let event = try? EngineEvent(json: JSONValue(foundation: body)) else { throw Failure.malformed }
            return EngineObservation(event: event, deliveredAt: at)
        }
        let header = Header(scope: scope, zone: zone, day: day, inputRevision: revision, runID: runID,
                            effective: appEffective, knownAt: appKnown)

        guard let steps else {
            let inputs = LocalInputs(lower: lower, through: through, observations: observations, coverage: coverage,
                                     revision: revision)
            let (state, effective) = try LocalEngine.evaluate(inputs, now: now, zone: zone, settings: settings)
            return Result(header: header, effective: effective, healthState: state.json, widgetState: mapWidgetState(state))
        }

        guard steps.at > (through[.movement] ?? appEffective), steps.at >= appEffective,
              calendar.day(of: steps.at) == day else { throw Failure.notNewer }
        let read = CanonicalEvent.snapshot(.init(eventID: UUID(), day: day, timezone: zone, asOf: steps.at,
                                                 queriedAt: steps.at, steps: steps.steps))
        observations.append(EngineObservation(event: try EngineEvent(json: read.json), deliveredAt: steps.at))
        // The query succeeded, so movement is covered up to the read. Coverage
        // for the other domains is untouched: it still ends at their import.
        coverage.append(EngineCoverage(domain: .movement, timezone: zone, complete: true, startAt: lower, endAt: steps.at))
        let held: [Domain] = [.sleep, .hrv, .rhr, .workout]
        let features = try calculateFeatures(observations, EngineContext(
            day: day, timezone: zone, effectiveAt: steps.at, knownAt: max(steps.at, appKnown), coverage: coverage,
            cutoffs: Dictionary(uniqueKeysWithValues: held.map { ($0, appEffective) })), settings)
        let state = computeHealthState(features, settings)
        return Result(header: header, effective: steps.at, healthState: state.json, widgetState: mapWidgetState(state))
    }
}
