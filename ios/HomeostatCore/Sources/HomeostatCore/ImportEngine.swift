import Foundation

public enum SampleType: String, CaseIterable, Sendable {
    case sleep, hrv, rhr, workout

    public var domain: Domain {
        switch self {
        case .sleep: .sleep
        case .hrv: .hrv
        case .rhr: .rhr
        case .workout: .workout
        }
    }
}

public struct AnchoredPage: Sendable {
    public var samples: [RawSample]
    public var deleted: [UUID]
    public var anchor: Data
    public var hasMore: Bool

    public init(samples: [RawSample], deleted: [UUID], anchor: Data, hasMore: Bool) {
        self.samples = samples
        self.deleted = deleted
        self.anchor = anchor
        self.hasMore = hasMore
    }
}

/// Step totals for one clock hour `[start, end)` in the query's zone, with
/// HealthKit's own merging of overlapping sources (no raw-sample summation).
public struct HourlyBucket: Hashable, Sendable {
    public var start: Instant, end: Instant, steps: Int64
    public init(start: Instant, end: Instant, steps: Int64) {
        self.start = start
        self.end = end
        self.steps = steps
    }
}

public enum HealthSourceError: Error, Equatable, Sendable {
    /// The stored anchor can't be decoded; recovery re-reads from no anchor.
    case corruptAnchor
}

/// HealthKit, behind a protocol so the engines are testable without it.
public protocol HealthDataSource: Sendable {
    /// One anchored page of samples overlapping `[lowerBound, ∞)`, plus deleted UUIDs.
    func anchoredPage(_ type: SampleType, since lowerBound: Instant, anchor: Data?, limit: Int) async throws -> AnchoredPage
    /// Hourly step sums from `start` to `end`, hours anchored at `start` in `zone`.
    /// A successful empty result means no steps visible; failures must throw.
    func hourlySteps(from start: Instant, to end: Instant, zone: String) async throws -> [HourlyBucket]
}

/// Cumulative snapshots for one local day: one per completed hourly boundary
/// (the last is the day's closing boundary) plus, for today, one at `through`.
public func stepSnapshots(day: LocalDay, zone: Zone, buckets: [HourlyBucket], through: Instant,
                          queriedAt: Instant, makeID: () -> UUID = UUID.init) -> [CanonicalEvent.Snapshot] {
    let dayEnd = zone.start(of: zone.adding(days: 1, to: day))
    var total: Int64 = 0
    var result: [CanonicalEvent.Snapshot] = []
    for bucket in buckets.sorted(by: { $0.start < $1.start }) {
        total += bucket.steps
        if bucket.end <= through && bucket.end <= dayEnd {
            result.append(.init(eventID: makeID(), day: day, timezone: zone.identifier, asOf: bucket.end,
                                queriedAt: queriedAt, steps: total))
        }
    }
    if through < dayEnd && result.last?.asOf != through {
        result.append(.init(eventID: makeID(), day: day, timezone: zone.identifier, asOf: through,
                            queriedAt: queriedAt, steps: total))
    }
    return result
}

/// HealthKit import (Step 9-13 plan sections 6-7): one serial drain per type,
/// coalescing triggers, atomic page commits, coverage only after success.
public actor ImportEngine {
    let store: LocalStore
    let source: HealthDataSource
    let clock: @Sendable () -> Instant
    let deviceZone: @Sendable () -> String
    public let lookbackDays: Int
    public let pageLimit: Int
    var running: Set<SampleType> = []
    var rerun: Set<SampleType> = []

    public init(store: LocalStore, source: HealthDataSource,
                clock: @escaping @Sendable () -> Instant = { Instant(Date()) },
                deviceZone: @escaping @Sendable () -> String = { TimeZone.current.identifier },
                lookbackDays: Int = 35, pageLimit: Int = 250) {
        self.store = store
        self.source = source
        self.clock = clock
        self.deviceZone = deviceZone
        self.lookbackDays = lookbackDays
        self.pageLimit = pageLimit
    }

    /// Fixed once per store: 35 prior local days plus one day of overlap for
    /// overnight intervals. Never slid forward while its anchors are reused.
    public func lowerBound() throws -> Instant {
        if let stored = try store.value("import_lower_bound"), let instant = Instant.parse(stored) {
            return instant
        }
        let zone = Zone(deviceZone()) ?? Zone("UTC")!
        let bound = zone.start(of: zone.adding(days: -(lookbackDays + 1), to: zone.day(of: clock())))
        try store.setValue(bound.wire, for: "import_lower_bound")
        return bound
    }

    func predicateVersion(_ type: SampleType = .hrv) throws -> String {
        "overlap-since:\(try lowerBound().wire):generation-\(try store.value("query_generation_\(type.rawValue)") ?? store.value("query_generation") ?? "1")"
    }

    public enum DrainOutcome: Equatable, Sendable {
        case drained(PageTotals)
        case coalesced
    }

    public struct PageTotals: Equatable, Sendable {
        public var pages = 0, newEvents = 0, deletions = 0, quarantined = 0, coverageQueued = false
    }

    /// Drains every available page for one type. If a drain for the type is
    /// already running, this request is folded into one more pass of it.
    public func drain(_ type: SampleType) async throws -> DrainOutcome {
        if running.contains(type) {
            rerun.insert(type)
            return .coalesced
        }
        running.insert(type)
        defer { running.remove(type) }
        var totals = PageTotals()
        repeat {
            rerun.remove(type)
            try await drainOnce(type, into: &totals)
        } while rerun.contains(type)
        return .drained(totals)
    }

    func drainOnce(_ type: SampleType, into totals: inout PageTotals) async throws {
        let lower = try lowerBound()
        var queriedAt = clock()
        while true {
            let version = try predicateVersion(type)
            let anchor = try store.anchor(type: type.rawValue, predicateVersion: version)
            let page: AnchoredPage
            do {
                page = try await source.anchoredPage(type, since: lower, anchor: anchor, limit: pageLimit)
            } catch HealthSourceError.corruptAnchor {
                try store.beginAnchorRecovery(type: type, lower: lower, zone: deviceZone(), now: clock())
                // A nil-anchor query must not retry forever if the provider fails again.
                if anchor == nil { throw HealthSourceError.corruptAnchor }
                continue
            }
            queriedAt = clock()
            let result = try store.commitPage(
                type: type.rawValue, domain: type.domain, predicateVersion: version, samples: page.samples,
                deleted: page.deleted, newAnchor: page.anchor, normalizer: Normalizer(deviceZone: deviceZone()),
                now: queriedAt)
            totals.pages += 1
            totals.newEvents += result.newEvents
            totals.deletions += result.deletions
            totals.quarantined += result.quarantined
            if !page.hasMore { break }
        }
        try store.setValue(queriedAt.wire, for: "last_query_\(type.rawValue)")
        totals.coverageQueued = try store.enqueueCoverage(
            .init(domain: type.domain, timezone: deviceZone(), start: lower, end: queriedAt,
                  status: try store.value("recovery_\(type.rawValue)") == nil ? "complete" : "unavailable"), now: queriedAt)
    }

    /// Refreshes cumulative step history: the whole import window (`full`) or
    /// just yesterday and today. Only changed totals are enqueued.
    @discardableResult
    public func refreshSteps(full: Bool) async throws -> Int {
        let zoneID = deviceZone()
        guard let zone = Zone(zoneID) else { return 0 }
        let now = clock()
        let lower = try lowerBound()
        let today = zone.day(of: now)
        var day = full ? zone.day(of: lower) : zone.adding(days: -1, to: today)
        var perDay: [(LocalDay, [HourlyBucket])] = []
        while day <= today {
            let start = zone.start(of: day)
            let end = min(now, zone.start(of: zone.adding(days: 1, to: day)))
            perDay.append((day, try await source.hourlySteps(from: start, to: end, zone: zoneID)))
            day = zone.adding(days: 1, to: day)
        }
        let queriedAt = clock()
        let snapshots = perDay.flatMap { day, buckets in
            stepSnapshots(day: day, zone: zone, buckets: buckets, through: min(now, zone.start(of: zone.adding(days: 1, to: day))),
                          queriedAt: queriedAt)
        }
        let coverageStart = zone.start(of: perDay.first!.0)
        return try store.commitSnapshots(
            snapshots, coverage: .init(domain: .movement, timezone: zoneID, start: coverageStart, end: now),
            now: queriedAt, fullRefreshDay: full ? "\(zoneID)|\(today.description)" : nil)
    }

    /// Foreground/launch catch-up: every type, plus steps (the whole window once
    /// per local day, otherwise yesterday and today). Returns per-part errors.
    public func catchUp() async -> [String: String] {
        var errors: [String: String] = [:]
        do { try store.reprocessQuarantine(normalizer: Normalizer(deviceZone: deviceZone()), now: clock()) }
        catch { errors["quarantine"] = String(describing: error) }
        for type in SampleType.allCases {
            do { _ = try await drain(type) } catch { errors[type.rawValue] = String(describing: error) }
        }
        do {
            let zone = Zone(deviceZone()) ?? Zone("UTC")!
            let full = try store.value("steps_full_refresh_day") != "\(zone.identifier)|\(zone.day(of: clock()).description)"
            try await refreshSteps(full: full)
        } catch {
            errors["steps"] = String(describing: error)
        }
        return errors
    }
}
