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

/// HealthKit import (Step 9-13 plan sections 6-7): one serial drain per type,
/// coalescing triggers, atomic page commits, coverage only after success.
public actor ImportEngine {
    let store: LocalStore
    let source: HealthDataSource
    let clock: @Sendable () -> Instant
    let deviceZone: @Sendable () -> String
    public let lookbackDays: Int
    public let pageLimit: Int
    private var stepsTask: Task<Int, Error>?
    private var stepsTaskID = UUID()
    private var stepsThrough: Instant?
    private var stepsFull = false
    private var cycleTask: Task<[String: String], Error>?
    private var sharedWaiters: [AnyHashable: (waiting: Int, cancelled: Int)] = [:]
    private var cycleAgain = false
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
    public func drain(_ type: SampleType, through: Instant? = nil, maxPages: Int = 100) async throws -> DrainOutcome {
        if running.contains(type) {
            rerun.insert(type)
            return .coalesced
        }
        running.insert(type)
        defer { running.remove(type) }
        var totals = PageTotals()
        repeat {
            rerun.remove(type)
            try await drainOnce(type, through: through ?? clock(), maxPages: maxPages, into: &totals)
        } while rerun.contains(type) && totals.pages < maxPages
        return .drained(totals)
    }

    func drainOnce(_ type: SampleType, through: Instant, maxPages: Int, into totals: inout PageTotals) async throws {
        let lower = try lowerBound()
        var queriedAt = clock()
        while true {
            try Task.checkCancellation()
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
            try Task.checkCancellation()
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
            if totals.pages >= maxPages {
                try store.setValue("pending", for: "import_deferred")
                throw ImportDeferred.pageLimit
            }
        }
        try store.setValue(queriedAt.wire, for: "last_query_\(type.rawValue)")
        // The generation's first full drain is its scan (Step 9-13 plan section 3B).
        try store.enqueueScan(type: type, generation: try predicateVersion(type), scopeStart: lower, now: through)
        totals.coverageQueued = try store.enqueueCoverage(
            .init(domain: type.domain, timezone: deviceZone(), start: lower, end: through,
                  status: try store.value("recovery_\(type.rawValue)") == nil ? "complete" : "unavailable"), now: queriedAt)
        // On-device coverage: a full drain of the current generation has seen
        // everything visible up to `through`. (A new generation clears it.)
        try store.setValue(through.wire, for: "covered_through_\(type.rawValue)")
        try store.setValue(try predicateVersion(type), for: "covered_generation_\(type.rawValue)")
        // Once every type's current generation has been fully re-read, the
        // phone has reconciled; a server (if used) is told by the scan upload.
        if try store.value("last_anchor_recovery")?.hasPrefix("Incomplete") == true,
           try SampleType.allCases.allSatisfy({ try store.value("covered_through_\($0.rawValue)") != nil }) {
            try store.setValue("Reconciled on this iPhone", for: "last_anchor_recovery")
        }
    }

    /// Refreshes cumulative step history: the whole import window (`full`) or
    /// just yesterday and today. Only changed totals are enqueued.
    @discardableResult
    public func refreshSteps(full: Bool, through: Instant? = nil) async throws -> Int {
        let requestedThrough = through ?? clock()
        if let stepsTask {
            let id = stepsTaskID
            let matches = stepsThrough == requestedThrough && (stepsFull || !full)
            let count = try await join(stepsTask)
            if matches { return count }
            try Task.checkCancellation()
            if stepsTaskID == id { self.stepsTask = nil }
            return try await refreshSteps(full: full, through: requestedThrough)
        }
        let id = UUID()
        stepsTaskID = id; stepsThrough = requestedThrough; stepsFull = full
        let task = Task { try await self.refreshStepsOnce(full: full, through: requestedThrough) }
        stepsTask = task
        defer { if stepsTaskID == id { stepsTask = nil } }
        return try await join(task)
    }

    private func refreshStepsOnce(full: Bool, through: Instant) async throws -> Int {
        let zoneID = deviceZone()
        guard let zone = Zone(zoneID) else { return 0 }
        let now = through
        let today = zone.day(of: now)
        var day = full ? try stepHistoryStart(today: today, zone: zone) : zone.adding(days: -1, to: today)
        var perDay: [(LocalDay, [HourlyBucket])] = []
        while day <= today {
            try Task.checkCancellation()
            let start = zone.start(of: day)
            let end = min(now, zone.start(of: zone.adding(days: 1, to: day)))
            perDay.append((day, try await source.hourlySteps(from: start, to: end, zone: zoneID)))
            day = zone.adding(days: 1, to: day)
        }
        try Task.checkCancellation()
        let queriedAt = clock()
        let snapshots = perDay.flatMap { day, buckets in
            stepSnapshots(day: day, zone: zone, buckets: buckets, through: min(now, zone.start(of: zone.adding(days: 1, to: day))),
                          queriedAt: queriedAt)
        }
        let coverageStart = zone.start(of: perDay.first!.0)
        let added = try store.commitSnapshots(
            snapshots, coverage: .init(domain: .movement, timezone: zoneID, start: coverageStart, end: now),
            now: queriedAt, fullRefreshDay: full ? "\(zoneID)|\(today.description)" : nil)
        try store.setValue(now.wire, for: "covered_through_steps")
        return added
    }

    /// Foreground/launch catch-up: every type, plus steps (the whole window once
    /// per local day, otherwise yesterday and today). Returns per-part errors.
    public enum ImportDeferred: Error { case pageLimit }

    public func catchUp(repairHistory: Bool = true) async -> [String: String] {
        if let cycleTask {
            cycleAgain = true
            try? store.setValue("pending", for: "import_deferred")
            return (try? await join(cycleTask)) ?? ["cycle": "cancelled"]
        }
        let task = Task<[String: String], Error> {
            var errors: [String: String] = [:]
            for pass in 0..<2 {
                self.cycleAgain = false
                errors = await self.currentCycle(repairHistory: repairHistory && pass == 0)
                if Task.isCancelled || !self.cycleAgain { break }
            }
            if self.cycleAgain { try? self.store.setValue("pending", for: "import_deferred") }
            return errors
        }
        cycleTask = task
        defer { cycleTask = nil }
        return (try? await join(task)) ?? ["cycle": "cancelled"]
    }

    /// Callers share one import. A cancelled caller keeps waiting for the shared
    /// result, and the import stops only once every caller is cancelled, so a
    /// background task's expiry can't cancel a foreground Sync.
    private func join<T: Sendable>(_ task: Task<T, Error>) async throws -> T {
        sharedWaiters[task, default: (0, 0)].waiting += 1
        defer { sharedWaiters[task] = nil }  // it has finished; later cancellations are moot
        return try await withTaskCancellationHandler { try await task.value } onCancel: {
            Task { await self.waiterCancelled(task) }
        }
    }

    private func waiterCancelled<T>(_ task: Task<T, Error>) {
        guard var counts = sharedWaiters[task] else { return }
        counts.cancelled += 1
        sharedWaiters[task] = counts
        if counts.cancelled >= counts.waiting { task.cancel() }
    }

    private func currentCycle(repairHistory: Bool) async -> [String: String] {
        let through = clock()
        var errors: [String: String] = [:]
        try? store.setValue("pending", for: "import_deferred")
        do { try store.reprocessQuarantine(normalizer: Normalizer(deviceZone: deviceZone()), now: through) }
        catch { errors["quarantine"] = "local_store" }
        for type in SampleType.allCases {
            if Task.isCancelled { errors["cycle"] = "cancelled"; break }
            do { _ = try await drain(type, through: through, maxPages: 20) }
            catch { errors[type.rawValue] = "\((error as NSError).domain):\((error as NSError).code)" }
        }
        if repairHistory && !Task.isCancelled {
            do { try await repairStepHistory(through: through, maxDays: 7) }
            catch { errors["history"] = "\((error as NSError).domain):\((error as NSError).code)" }
        }
        if !Task.isCancelled {
            do { try await refreshSteps(full: false, through: through) }
            catch { errors["steps"] = "\((error as NSError).domain):\((error as NSError).code)" }
        } else { errors["cycle"] = "cancelled" }
        try? store.setValue(errors.isEmpty ? nil : "pending", for: "import_deferred")
        try? store.setValue(through.wire, for: "last_import_cycle")
        let encoded = try? JSONEncoder().encode(errors)
        try? store.setValue(encoded.flatMap { String(data: $0, encoding: .utf8) }, for: "import_errors")
        return errors
    }

    /// Step re-reads go back as far as the first import did. The import lower
    /// bound never moves, so reading from it would grow by a day every day.
    func stepHistoryStart(today: LocalDay, zone: Zone) throws -> LocalDay {
        max(zone.day(of: try lowerBound()), zone.adding(days: -(lookbackDays + 1), to: today))
    }

    /// History repairs checkpoint each day and resume after interruption. The
    /// current-day query always follows so historical coverage cannot pin now.
    private func repairStepHistory(through: Instant, maxDays: Int) async throws {
        let zone = Zone(deviceZone()) ?? Zone("UTC")!
        let today = zone.day(of: through)
        let marker = "\(zone.identifier)|\(today.description)"
        if try store.value("steps_full_refresh_day") == marker { return }
        let cursorKey = "steps_history_cursor_\(zone.identifier)"
        let first = try stepHistoryStart(today: today, zone: zone)
        var day = max(try store.value(cursorKey).flatMap(LocalDay.init) ?? first, first)
        for _ in 0..<maxDays {
            try Task.checkCancellation()
            guard day < today else {
                try store.setValue(marker, for: "steps_full_refresh_day")
                try store.setValue(nil, for: cursorKey)
                return
            }
            let start = zone.start(of: day)
            let end = zone.start(of: zone.adding(days: 1, to: day))
            let buckets = try await source.hourlySteps(from: start, to: end, zone: zone.identifier)
            try Task.checkCancellation()
            let queried = clock()
            _ = try store.commitSnapshots(stepSnapshots(day: day, zone: zone, buckets: buckets, through: end, queriedAt: queried),
                coverage: .init(domain: .movement, timezone: zone.identifier, start: start, end: end), now: queried)
            day = zone.adding(days: 1, to: day)
            try store.setValue(day.description, for: cursorKey)
        }
    }
}
