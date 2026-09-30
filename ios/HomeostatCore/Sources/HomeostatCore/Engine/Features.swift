import Foundation

// Swift port of backend/app/features (selection, sleep, points, movement,
// workouts, calculate). The Python code is the reference; EngineParityTests
// holds this to its output for every synthetic scenario. Keep the two in step.

public let featuresVersion = "features@0.2.0"

// MARK: - Selection (selection.py)

public enum EngineInputError: Error { case clientEventIDReused(String) }

struct Selection {
    struct Conflict { let domain: String, day: LocalDay, recordID: String }
    let records: [EngineEvent]
    let conflicts: [Conflict]
    let tombstoned: [String]

    func conflictDays(_ domain: String) -> Set<LocalDay> { Set(conflicts.filter { $0.domain == domain }.map(\.day)) }
}

/// Deliveries by knownAt -> exact retries collapse by client ID -> provider
/// records compared without client ID -> contradictory versions quarantined
/// -> tombstones remove their provider IDs, whenever the original arrived.
func selectVisible(_ observations: [EngineObservation], knownAt: Instant) throws -> Selection {
    var byClient: [String: EngineEvent] = [:]
    for observation in observations where observation.deliveredAt <= knownAt {
        let event = observation.event
        if let prior = byClient[event.eventID], prior.full != event.full {
            throw EngineInputError.clientEventIDReused(event.eventID)
        }
        byClient[event.eventID] = event
    }
    let visible = byClient.values.sorted { $0.eventID < $1.eventID }
    let deleted = Set(visible.filter { $0.eventType == "delete" }.map(\.recordID))
    var providers: [[String]: [EngineEvent]] = [:]
    for event in visible where event.eventType != "delete" {
        providers[[event.source, event.recordID, event.eventType], default: []].append(event)
    }
    var records: [EngineEvent] = [], conflicts: [Selection.Conflict] = [], tombstoned = Set<String>()
    for key in providers.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
        let versions = providers[key]!
        if deleted.contains(key[1]) {
            tombstoned.insert(key[1])  // a tombstone wins even over a conflict
        } else if Set(versions.map(\.content)).count > 1 {
            conflicts.append(.init(domain: versions[0].domain, day: versions[0].day, recordID: key[1]))
        } else {
            records.append(versions.min { $0.eventID < $1.eventID }!)  // reimports add no weight
        }
    }
    return Selection(records: records, conflicts: conflicts, tombstoned: tombstoned.sorted())
}

// MARK: - Results

/// Per-domain data support, assembled into confidence (calculate.py).
struct Support {
    var present = false
    var ageHours = 0.0
    var weight = 1.0
}

public struct SleepFeatures: Sendable {
    public var state = "calibrating", ready = false, usableDays = 0, requiredDays = 14, confidence = 0.0
    public var hours: Double?, sleepStart: Instant?, sleepEnd: Instant?, spanHours: Double?
    public var inBedHours: Double?, awakeMinutes: Double?, timezone: String?, source: String?, sourcePolicyVersion: String?
    public var baselineHours: Double?, baselineMadHours: Double?, deltaHours: Double?, ratio: Double?
}

public struct PointFeatures: Sendable {
    public var state = "calibrating", ready = false, usableDays = 0, requiredDays = 14, confidence = 0.0
    public var value: Double?, observedAt: Instant?, recordID: String?, sourceName: String?
    public var baseline: Double?, mad: Double?, robustZ: Double?
}

public struct MovementFeatures: Sendable {
    public var state = "calibrating", ready = false, usableDays = 0, requiredDays = 14, confidence = 0.0
    public var steps: Int?, asOf: Instant?, recordID: String?, expectedStepsNow: Double?, ratio: Double?
}

public struct WorkoutFeatures: Sendable {
    public var state = "missing", confidence = 0.0
    public var type: String?, start: Instant?, end: Instant?, recordID: String?, sourceName: String?, hoursSince: Double?
    public var minutesToday: Double?, minutesLast7d: Double?
}

public struct DailyFeatures: Sendable {
    public var day: LocalDay, timezone: String, effectiveAt: Instant
    public var sleep: SleepFeatures, hrv: PointFeatures, rhr: PointFeatures
    public var movement: MovementFeatures, workout: WorkoutFeatures
    public var diagnostics: [String]
}

// MARK: - Sleep (sleep.py)

typealias Span = (start: Instant, end: Instant)

func union(_ spans: [Span]) -> [Span] {
    var merged: [Span] = []
    for span in spans.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
        if let last = merged.last, span.start <= last.end {
            merged[merged.count - 1] = (last.start, max(span.end, last.end))
        } else {
            merged.append(span)
        }
    }
    return merged
}

func subtract(_ spans: [Span], _ cuts: [Span]) -> [Span] {
    var result: [Span] = []
    for span in spans {
        var pieces = [span]
        for cut in cuts {
            pieces = pieces.flatMap { s, e in
                [(s, min(e, cut.start)), (max(s, cut.end), e)].filter { $0.0 < $0.1 }.map { Span($0.0, $0.1) }
            }
        }
        result += pieces
    }
    return result
}

func clip(_ spans: [Span], _ start: Instant, _ end: Instant) -> [Span] {
    spans.compactMap { s, e in min(e, end) > max(s, start) ? (max(s, start), min(e, end)) : nil }
}

func minutes(_ spans: [Span]) -> Double { spans.reduce(0.0) { $0 + seconds($1.start, $1.end) } / 60 }

struct Episode {
    let group: SourceRank
    let timezone: String
    let start: Instant, end: Instant  // first and last retained asleep instants
    let asleepMinutes: Double
    let awakeMinutes: Double?
    let inBedMinutes: Double?
    let contradictionMinutes: Double
    let recordIDs: [String]

    var wakeDay: LocalDay { Zone(timezone)!.day(of: end) }
}

private func span(_ event: EngineEvent) -> Span {
    guard case .interval(_, let start, let end) = event.kind else { fatalError("not an interval") }
    return (start, end)
}

private func stage(_ event: EngineEvent) -> String {
    guard case .interval(let stage, _, _) = event.kind else { fatalError("not an interval") }
    return stage
}

/// Duration is the union of asleep stages minus overlapping awake time of the
/// same source. In-bed records describe an episode but never create or bridge one.
func buildEpisodes(_ intervals: [EngineEvent], _ settings: EngineSettings) -> [Episode] {
    let gap = Int64(settings.episodeGapMinutes * 60 * 1_000_000)
    var bySource: [SourceKey: [EngineEvent]] = [:]
    for event in intervals {
        bySource[SourceKey(group: settings.group(of: event.meta!), zone: event.meta!.timezone), default: []].append(event)
    }
    var episodes: [Episode] = []
    for key in bySource.keys.sorted() {
        let members = bySource[key]!
        let stages = members.filter { stage($0) != "in_bed" }.sorted {
            let a = span($0), b = span($1)
            return (a.start, a.end, $0.recordID) < (b.start, b.end, $1.recordID)
        }
        var clusters: [[EngineEvent]] = []
        var clusterEnd = Instant(microseconds: 0)
        for event in stages {
            let (start, end) = span(event)
            if !clusters.isEmpty && start.microseconds - clusterEnd.microseconds <= gap {
                clusters[clusters.count - 1].append(event)
                clusterEnd = max(clusterEnd, end)
            } else {
                clusters.append([event])
                clusterEnd = end
            }
        }
        struct Draft { var start: Instant, end: Instant, asleep: Double, awake: Double?, contradiction: Double
                       var records: [EngineEvent], inBed: [EngineEvent] }
        var drafts: [Draft] = []
        for cluster in clusters {
            let asleep = union(cluster.filter { stage($0).hasPrefix("asleep_") }.map(span))
            let awake = union(cluster.filter { stage($0) == "awake" }.map(span))
            let net = subtract(asleep, awake)  // contradictory time is never sleep
            guard let first = net.first, let last = net.last else { continue }
            let hasAwake = cluster.contains { stage($0) == "awake" }
            drafts.append(Draft(start: first.start, end: last.end, asleep: minutes(net),
                                awake: hasAwake ? minutes(clip(awake, first.start, last.end)) : nil,
                                contradiction: minutes(asleep) - minutes(net), records: cluster, inBed: []))
        }
        // Each in-bed record belongs to the one episode it overlaps most (earliest on ties).
        let inBed = members.filter { stage($0) == "in_bed" }.sorted {
            let a = span($0), b = span($1)
            return (a.start, a.end) < (b.start, b.end)
        }
        for record in inBed {
            let (start, end) = span(record)
            var best: (overlap: Int64, index: Int)?
            for (index, draft) in drafts.enumerated() {
                let overlap = min(end, draft.end).microseconds - max(start, draft.start).microseconds
                if best == nil || overlap > best!.overlap { best = (overlap, index) }
            }
            if let best, best.overlap > 0 { drafts[best.index].inBed.append(record) }
        }
        for draft in drafts {
            episodes.append(Episode(
                group: key.group, timezone: key.zone, start: draft.start, end: draft.end, asleepMinutes: draft.asleep,
                awakeMinutes: draft.awake, inBedMinutes: draft.inBed.isEmpty ? nil : minutes(union(draft.inBed.map(span))),
                contradictionMinutes: draft.contradiction, recordIDs: (draft.records + draft.inBed).map(\.recordID).sorted()))
        }
    }
    return episodes
}

struct SourceKey: Hashable, Comparable {
    let group: SourceRank, zone: String
    static func < (a: SourceKey, b: SourceKey) -> Bool { a.group != b.group ? a.group < b.group : a.zone < b.zone }
}

func inOvernightWindow(_ episode: Episode, _ settings: EngineSettings) -> Bool {
    let zone = Zone(episode.timezone)!, day = episode.wakeDay
    let start = zone.instant(on: zone.adding(days: -1, to: day), hour: settings.overnightStartHour)
    let end = zone.instant(on: day, hour: settings.overnightEndHour)
    return episode.start < end && episode.end > start
}

/// The longest overnight episode waking on `day`, from `group` or else from
/// the highest-priority group that has one.
func primary(_ episodes: [Episode], _ day: LocalDay, _ settings: EngineSettings, group: SourceRank? = nil) -> Episode? {
    var candidates = episodes.filter { $0.wakeDay == day && inOvernightWindow($0, settings) }
    guard let chosen = group ?? candidates.map(\.group).min() else { return nil }
    candidates = candidates.filter { $0.group == chosen }
    return candidates.min {
        if $0.asleepMinutes != $1.asleepMinutes { return $0.asleepMinutes > $1.asleepMinutes }
        if $0.end != $1.end { return $0.end > $1.end }
        return $0.recordIDs.lexicographicallyPrecedes($1.recordIDs)
    }
}

func eligibleEpisodes(_ selection: Selection, _ context: EngineContext, _ settings: EngineSettings) -> [Episode] {
    let intervals = selection.records.filter {
        if case .interval(_, _, let end) = $0.kind { return end <= context.effectiveAt }
        return false
    }
    let conflicted = selection.conflictDays("sleep")
    return buildEpisodes(intervals, settings).filter { !conflicted.contains($0.wakeDay) }
}

func calculateSleep(_ episodes: [Episode], _ selection: Selection, _ context: EngineContext,
                    _ settings: EngineSettings, _ support: inout Support, _ diagnostics: inout [String]) -> SleepFeatures {
    let day = context.day
    let window = historyDays(day, settings.windowDays, zone: context.zone)
    let current = primary(episodes, day, settings)
    let group = current?.group ?? episodes
        .filter { window.contains($0.wakeDay) && inOvernightWindow($0, settings) }.map(\.group).min()
    let values = group.map { g in window.compactMap { primary(episodes, $0, settings, group: g) }.map { $0.asleepMinutes / 60 } } ?? []
    var f = SleepFeatures()
    f.ready = values.count >= settings.minimumValidDays
    f.usableDays = values.count
    f.requiredDays = settings.minimumValidDays
    if selection.conflictDays("sleep").contains(day) { diagnostics.append("sleep_conflict:\(day)") }
    if f.ready {
        let baseline = median(values)
        f.baselineHours = baseline
        f.baselineMadHours = median(values.map { abs($0 - baseline) })
    }
    guard let current else {
        f.state = f.ready ? "missing" : "calibrating"
        return f
    }
    let hours = current.asleepMinutes / 60
    f.hours = hours
    f.sleepStart = current.start
    f.sleepEnd = current.end
    f.spanHours = seconds(current.start, current.end) / 3600
    f.inBedHours = current.inBedMinutes.map { $0 / 60 }
    f.awakeMinutes = current.awakeMinutes
    f.timezone = current.timezone
    f.source = current.group.id
    f.sourcePolicyVersion = settings.sourcePolicyVersion
    if current.contradictionMinutes != 0 {
        diagnostics.append("sleep_awake_overlap_minutes:\(String(format: "%g", current.contradictionMinutes))")
    }
    if current.timezone != context.timezone { diagnostics.append("sleep_timezone:\(current.timezone)") }
    support = Support(present: true, ageHours: seconds(current.end, context.effectiveAt) / 3600, weight: current.group.weight)
    guard f.ready, let baseline = f.baselineHours else {
        f.state = "calibrating"
        return f
    }
    let deltaMinutes = (hours - baseline) * 60
    f.deltaHours = hours - baseline
    f.ratio = hours / baseline
    f.state = deltaMinutes <= -settings.sleepBelowMinutes ? "below_baseline"
        : deltaMinutes >= settings.sleepAboveMinutes ? "above_baseline" : "typical"
    return f
}

// MARK: - HRV and resting HR (points.py)

let robustScale = 1.4826

private func observed(_ event: EngineEvent) -> (at: Instant, value: Double) {
    guard case .point(_, let at, let value) = event.kind else { fatalError("not a point") }
    return (at, value)
}

/// One reading per local day, fixed so it doesn't drift through the day:
/// the latest inside that night's primary sleep, else the first after waking
/// that day, else (no primary sleep) the first of the day.
func dailyReading(_ readings: [EngineEvent], _ day: LocalDay, _ episode: Episode?) -> EngineEvent? {
    func before(_ a: EngineEvent, _ b: EngineEvent) -> Bool { (observed(a).at, a.recordID) < (observed(b).at, b.recordID) }
    let onDay = readings.filter { Zone($0.meta!.timezone)!.day(of: observed($0).at) == day }
    guard let episode else { return onDay.min(by: before) }
    let inside = readings.filter { episode.start <= observed($0).at && observed($0).at <= episode.end }
    if !inside.isEmpty { return inside.max(by: before) }
    return onDay.filter { observed($0).at > episode.end }.min(by: before)
}

func calculatePoints(_ metric: String, _ selection: Selection, _ context: EngineContext, _ settings: EngineSettings,
                     _ primaries: [LocalDay: Episode], _ support: inout Support,
                     _ diagnostics: inout [String]) -> PointFeatures {
    let domain = metric == "hrv_sdnn_ms" ? "hrv" : "rhr"
    let effective = context.effectiveAt
    var byGroup: [SourceRank: [EngineEvent]] = [:]
    for reading in selection.records {
        // A point counts once both its observation and its original sample have ended.
        guard case .point(let m, let at, _) = reading.kind, m == metric, at <= effective,
              reading.meta!.sampleEnd <= effective else { continue }
        byGroup[settings.group(of: reading.meta!), default: []].append(reading)
    }
    let day = context.day, conflicted = selection.conflictDays(domain)
    let window = historyDays(day, settings.windowDays, zone: context.zone).filter { !conflicted.contains($0) }
    func reading(_ group: SourceRank, _ when: LocalDay) -> EngineEvent? {
        dailyReading(byGroup[group] ?? [], when, primaries[when])
    }
    let groups = byGroup.keys.sorted()
    let currentGroup = conflicted.contains(day) ? nil : groups.first { reading($0, day) != nil }
    let group = currentGroup ?? groups.first { g in window.contains { reading(g, $0) != nil } }
    let values = group.map { g in window.compactMap { reading(g, $0) }.map { observed($0).value } } ?? []
    var f = PointFeatures()
    f.ready = values.count >= settings.minimumValidDays
    f.usableDays = values.count
    f.requiredDays = settings.minimumValidDays
    if conflicted.contains(day) { diagnostics.append("\(domain)_conflict:\(day)") }
    if f.ready {
        let center = median(values)
        f.baseline = center
        f.mad = median(values.map { abs($0 - center) })
    }
    guard let currentGroup, let current = reading(currentGroup, day) else {
        f.state = f.ready ? "missing" : "calibrating"
        return f
    }
    let (at, value) = observed(current)
    f.value = value
    f.observedAt = at
    f.recordID = current.recordID
    f.sourceName = current.meta!.sourceName
    support = Support(present: true, ageHours: seconds(at, effective) / 3600, weight: currentGroup.weight)
    guard f.ready, let baseline = f.baseline, let mad = f.mad else {
        f.state = "calibrating"
        return f
    }
    let z = (value - baseline) / max(robustScale * mad, settings.scaleFloor)
    f.robustZ = z
    f.state = z < settings.zLower ? "below_usual" : z > settings.zUpper ? "above_usual" : "typical"
    return f
}

// MARK: - Movement (movement.py)

private struct Snap {
    let event: EngineEvent
    let day: LocalDay, timezone: String, asOf: Instant, queriedAt: Instant, steps: Int
    var bucket: String { "\(timezone)|\(day)|\(asOf.microseconds)" }

    init?(_ event: EngineEvent) {
        guard case .snapshot(let day, let timezone, let asOf, let queriedAt, let steps) = event.kind else { return nil }
        (self.event, self.day, self.timezone, self.asOf, self.queriedAt, self.steps) = (event, day, timezone, asOf, queriedAt, steps)
    }

    /// Wall-clock minutes within its own day (1440 for the closing boundary),
    /// so 13:00 compares with 13:00 across DST and trips.
    var wallMinutes: Double {
        let zone = Zone(timezone)!
        if asOf == zone.start(of: zone.adding(days: 1, to: day)) { return 1440 }
        return Double(zone.wallSeconds(of: asOf)) / 60
    }
}

private enum Resolved { case read(Snap), conflict }

/// The latest query for one bucket; contradictory totals at that time conflict.
private func resolve(_ reads: [Snap]) -> Resolved {
    let latest = reads.map(\.queriedAt).max()!
    let newest = reads.filter { $0.queriedAt == latest }
    if Set(newest.map(\.steps)).count != 1 { return .conflict }
    return .read(newest.min { $0.event.eventID < $1.event.eventID }!)
}

private func ordered(_ buckets: [[Snap]], reportZone: String) -> [[Snap]] {
    // Latest position first; equal positions prefer the report zone, then zone name.
    buckets.sorted { a, b in
        let (x, y) = (a[0], b[0])
        if x.wallMinutes != y.wallMinutes { return x.wallMinutes > y.wallMinutes }
        if x.asOf != y.asOf { return x.asOf > y.asOf }
        if (x.timezone != reportZone) != (y.timezone != reportZone) { return x.timezone == reportZone }
        return x.timezone < y.timezone
    }
}

private func buckets(_ snaps: [Snap]) -> [[Snap]] {
    Dictionary(grouping: snaps, by: \.bucket).values.map { $0 }
}

func calculateMovement(_ selection: Selection, _ context: EngineContext, _ settings: EngineSettings,
                       _ support: inout Support, _ diagnostics: inout [String]) -> MovementFeatures {
    let effective = context.effectiveAt, day = context.day
    let snaps = selection.records.compactMap(Snap.init).filter { $0.asOf <= effective && $0.queriedAt <= context.knownAt }
    let byDay = Dictionary(grouping: snaps, by: \.day)
    var f = MovementFeatures()
    f.requiredDays = settings.minimumValidDays
    var current: Snap?
    let target: Double
    if let first = ordered(buckets(byDay[day] ?? []), reportZone: context.timezone).first {
        target = first[0].wallMinutes
        switch resolve(first) {  // never falls back to an older bucket
        case .read(let snap): current = snap
        case .conflict: diagnostics.append("movement_conflict:\(day)")
        }
    } else {
        let zone = context.zone
        target = zone.day(of: effective) > day ? 1440 : Double(zone.wallSeconds(of: effective)) / 60
    }
    var values: [Double] = []
    for when in historyDays(day, settings.windowDays, zone: context.zone) {
        let comparable = buckets(byDay[when] ?? []).filter {
            target - settings.comparisonWindowMinutes <= $0[0].wallMinutes && $0[0].wallMinutes <= target
        }
        guard let chosen = ordered(comparable, reportZone: context.timezone).first else { continue }
        switch resolve(chosen) {
        case .read(let snap): values.append(Double(snap.steps))
        case .conflict: diagnostics.append("movement_history_conflict:\(when)")  // invalidates that day
        }
    }
    f.ready = values.count >= settings.minimumValidDays
    f.usableDays = values.count
    if f.ready { f.expectedStepsNow = median(values) }
    guard let current else {
        f.state = f.ready ? "missing" : "calibrating"
        return f
    }
    f.steps = current.steps
    f.asOf = current.asOf
    f.recordID = current.event.recordID
    support = Support(present: true, ageHours: seconds(current.asOf, effective) / 3600)
    guard f.ready, let expected = f.expectedStepsNow else {
        f.state = "calibrating"
        return f
    }
    if expected == 0 {  // nothing expected yet: the ratio is undefined
        f.state = "typical"
        return f
    }
    let ratio = Double(current.steps) / expected
    f.ratio = ratio
    f.state = ratio < settings.behindRatio ? "behind_usual" : ratio > settings.aheadRatio ? "ahead_of_usual" : "typical"
    return f
}

// MARK: - Workouts (workouts.py)

private struct Workout {
    let event: EngineEvent
    let type: String, start: Instant, end: Instant, durationMinutes: Double

    init?(_ event: EngineEvent) {
        guard case .workout(let type, let start, let end, let duration) = event.kind else { return nil }
        (self.event, self.type, self.start, self.end, self.durationMinutes) = (event, type, start, end, duration)
    }
}

/// Overlapping workouts split into disjoint segments; each goes to the
/// highest-priority source, then the latest end, then provider ID.
private func segments(_ workouts: [Workout], _ settings: EngineSettings) -> [(Instant, Instant, Workout)] {
    let bounds = Set(workouts.flatMap { [$0.start, $0.end] }).sorted()
    return zip(bounds, bounds.dropFirst()).compactMap { start, end in
        let covering = workouts.filter { $0.start <= start && $0.end >= end }
        let winner = covering.min { a, b in
            let (ga, gb) = (settings.group(of: a.event.meta!), settings.group(of: b.event.meta!))
            if ga != gb { return ga < gb }
            if a.end != b.end { return a.end > b.end }
            return a.event.recordID < b.event.recordID
        }
        return winner.map { (start, end, $0) }
    }
}

/// Active duration spread over wall time (pause locations are unknown).
private func activeMinutes(_ pieces: [(Instant, Instant, Workout)], _ from: Instant, _ to: Instant) -> Double {
    pieces.reduce(0.0) { total, piece in
        let (start, end, workout) = piece
        let overlap = seconds(max(start, from), min(end, to)) / 60
        guard overlap > 0 else { return total }
        return total + overlap * min(workout.durationMinutes / (seconds(workout.start, workout.end) / 60), 1.0)
    }
}

func calculateWorkouts(_ selection: Selection, _ context: EngineContext, _ settings: EngineSettings,
                       _ diagnostics: inout [String]) -> WorkoutFeatures {
    let day = context.day, effective = context.effectiveAt, zone = context.zone
    var f = WorkoutFeatures()
    let firstDay = min(zone.adding(days: -(settings.totalsDays - 1), to: day),
                       zone.day(of: effective.adding(seconds: -Int64(settings.recentHours * 3600))))
    let conflicted = selection.conflictDays("workout")
    diagnostics += conflicted.sorted().map { "workout_conflict:\($0)" }
    if !conflicted.isEmpty || !context.covered(.workout, firstDay, day) { return f }  // unknown isn't absence

    let workouts = selection.records.compactMap(Workout.init).filter { $0.end <= effective }
    let pieces = segments(workouts, settings)
    f.minutesToday = activeMinutes(pieces, zone.start(of: day), effective)
    f.minutesLast7d = activeMinutes(pieces, zone.start(of: zone.adding(days: -(settings.totalsDays - 1), to: day)), effective)
    f.confidence = 1
    // The last workout must win some time.
    let winners = Dictionary(pieces.map { ($0.2.event.recordID, $0.2) }, uniquingKeysWith: { a, _ in a }).values
    guard let last = winners.max(by: { ($0.end, $0.event.recordID) < ($1.end, $1.event.recordID) }) else {
        f.state = "none_recent"
        return f
    }
    let hoursSince = seconds(last.end, effective) / 3600
    f.type = last.type
    f.start = last.start
    f.end = last.end
    f.recordID = last.event.recordID
    f.sourceName = last.event.meta!.sourceName
    f.hoursSince = hoursSince
    f.state = hoursSince <= settings.justCompletedHours ? "just_completed"
        : hoursSince <= settings.recentHours ? "recent_workout" : "none_recent"
    return f
}

// MARK: - Assembly and confidence (calculate.py)

func freshness(_ ageHours: Double, _ rules: EngineSettings.Freshness) -> Double {
    if ageHours <= rules.fullHours { return 1 }
    return max(0, 1 - (ageHours - rules.fullHours) / (rules.zeroHours - rules.fullHours))
}

/// maturity x freshness x coverage x source weight: data support, not a
/// probability of any health condition.
func confidence(_ support: Support, usableDays: Int, _ domain: Domain, _ context: EngineContext,
                _ settings: EngineSettings) -> Double {
    guard support.present else { return 0 }
    let maturity = min(Double(usableDays) / Double(settings.minimumValidDays), 1.0)
    let coverage = context.covered(domain, context.day, context.day) ? 1.0 : 0.0
    return maturity * freshness(support.ageHours, settings.freshness[domain]!) * coverage * support.weight
}

public func calculateFeatures(_ observations: [EngineObservation], _ context: EngineContext,
                              _ settings: EngineSettings = .standard) throws -> DailyFeatures {
    let selection = try selectVisible(observations, knownAt: context.knownAt)
    let episodes = eligibleEpisodes(selection, context, settings)
    let days = historyDays(context.day, settings.windowDays, zone: context.zone) + [context.day]
    var primaries: [LocalDay: Episode] = [:]
    for day in days { primaries[day] = primary(episodes, day, settings) }

    var diagnostics: [String] = []
    var sleepSupport = Support(), hrvSupport = Support(), rhrSupport = Support(), movementSupport = Support()
    var sleep = calculateSleep(episodes, selection, context, settings, &sleepSupport, &diagnostics)
    var hrv = calculatePoints("hrv_sdnn_ms", selection, context, settings, primaries, &hrvSupport, &diagnostics)
    var rhr = calculatePoints("resting_hr_bpm", selection, context, settings, primaries, &rhrSupport, &diagnostics)
    var movement = calculateMovement(selection, context, settings, &movementSupport, &diagnostics)
    let workout = calculateWorkouts(selection, context, settings, &diagnostics)
    sleep.confidence = confidence(sleepSupport, usableDays: sleep.usableDays, .sleep, context, settings)
    hrv.confidence = confidence(hrvSupport, usableDays: hrv.usableDays, .hrv, context, settings)
    rhr.confidence = confidence(rhrSupport, usableDays: rhr.usableDays, .rhr, context, settings)
    movement.confidence = confidence(movementSupport, usableDays: movement.usableDays, .movement, context, settings)
    diagnostics += selection.conflicts.map { "conflict:\($0.domain):\($0.day):\($0.recordID)" }
    return DailyFeatures(day: context.day, timezone: context.timezone, effectiveAt: context.effectiveAt,
                         sleep: sleep, hrv: hrv, rhr: rhr, movement: movement, workout: workout,
                         diagnostics: diagnostics.sorted())
}
