import Foundation

/// What the daily summary needs from a calculation beyond the widget headline:
/// each domain's state, learning progress and the measurements behind it.
/// Facts, not wording (System_architecture.md §4.1). The engine builds it from
/// the HealthState; it travels in the widget cache.
public struct DisplayFacts: Codable, Hashable, Sendable {
    public struct Domain: Codable, Hashable, Sendable {
        public var state: String
        public var confidence: Double
        public init(state: String, confidence: Double) {
            self.state = state
            self.confidence = confidence
        }
    }

    /// One measurement behind a domain (a HealthState driver).
    public struct Measure: Codable, Hashable, Sendable {
        public var id: String, domain: String
        public var value: Double?, baseline: Double?, unit: String?
        public var observedAt: Instant?
        public var confidence: Double
        public init(id: String, domain: String, value: Double?, baseline: Double?, unit: String?,
                    observedAt: Instant?, confidence: Double) {
            (self.id, self.domain, self.value, self.baseline) = (id, domain, value, baseline)
            (self.unit, self.observedAt, self.confidence) = (unit, observedAt, confidence)
        }
        enum CodingKeys: String, CodingKey { case id, domain, value, baseline, unit, observedAt = "observed_at", confidence }
    }

    public var sleep: Domain, recovery: Domain, movement: Domain, workout: Domain
    public var measures: [Measure]
    /// Usable baseline days per input (sleep, hrv, rhr, movement), and how many each needs.
    public var learningDays: [String: Int]
    public var requiredDays: Int

    public init(sleep: Domain, recovery: Domain, movement: Domain, workout: Domain, measures: [Measure],
                learningDays: [String: Int], requiredDays: Int) {
        (self.sleep, self.recovery, self.movement, self.workout) = (sleep, recovery, movement, workout)
        (self.measures, self.learningDays, self.requiredDays) = (measures, learningDays, requiredDays)
    }

    enum CodingKeys: String, CodingKey {
        case sleep, recovery, movement, workout, measures, learningDays = "learning_days", requiredDays = "required_days"
    }
}

/// An energy check-in as the summary shows it, kept apart from measured state.
public struct ReportedEnergy: Codable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable, CaseIterable { case low, okay, high }
    public enum Status: String, Codable, Sendable { case saved, saving, notSaved = "not_saved" }
    public var level: Level, at: Instant, status: Status
    public init(level: Level, at: Instant, status: Status) {
        (self.level, self.at, self.status) = (level, at, status)
    }
}

/// The one mapping from a cached result to what the app and widget say
/// (Daily_loop_contract.md). Views choose layout only; no health thresholds
/// live here: states come from the engine.
public struct DailySummary: Equatable, Sendable {
    public static let version = "daily-summary@1"

    public enum Kind: String, Sendable {
        case waiting, learning, change, quiet, earlierDay = "earlier_day", unavailable
    }
    public enum Readiness: Equatable, Sendable {
        case ready
        case learning(usable: Int, required: Int)
        case missing
    }
    public struct DomainLine: Equatable, Sendable {
        public var id: String, readiness: Readiness, observedAt: Instant?
    }
    public enum Action: String, Sendable {
        case openEvidence = "open_evidence", openApp = "open_app", openDataAccess = "open_data_access"
    }

    public var kind: Kind
    public var icon: String
    public var headline: String
    /// One same-domain comparison, or nil.
    public var comparison: String?
    /// Sleep, recovery and movement, each ready, learning or missing.
    public var domains: [DomainLine]
    public var updatedAt: Instant?
    /// Past the 90-minute freshness limit: keep the result, dim it, show its time.
    public var isStale: Bool
    /// The explanation to open (a primary-trait id), when there is one.
    public var evidence: String?
    public var action: Action
    /// The latest energy report, shown alongside, never instead of, the measurement.
    public var report: ReportedEnergy?

    public static func make(_ display: WidgetPolicy.Display, report: ReportedEnergy? = nil) -> DailySummary {
        switch display {
        case .empty:
            return DailySummary(kind: .waiting, icon: "⏳", headline: "Waiting for Health data",
                                comparison: "No records yet: nothing recorded, or Health access is off",
                                domains: [], updatedAt: nil, isStale: false, evidence: nil, action: .openDataAccess,
                                report: report)
        case .unreadable:
            return DailySummary(kind: .unavailable, icon: "⏳", headline: "Open Homeostat to update", comparison: nil,
                                domains: [], updatedAt: nil, isStale: false, evidence: nil, action: .openApp, report: report)
        case .earlierDay(let cache):
            // Today's interpretation is removed; only the date of the last result remains.
            // A report is today's, not an interpretation of old data, so it stays.
            return DailySummary(kind: .earlierDay, icon: "🕰️", headline: "Last result is from an earlier day",
                                comparison: nil, domains: [], updatedAt: cache.widgetState.freshness.lastUpdatedAt,
                                isStale: true, evidence: nil, action: .openApp, report: report)
        case .fresh(let cache):
            return current(cache, stale: false, report: report)
        case .stale(let cache):
            return current(cache, stale: true, report: report)
        }
    }

    static let changeTraits: Set = ["sleep", "recovery", "movement", "workout"]
    static let minDisplayConfidence = 0.5  // the mapper's rule (StateEngine.swift)

    static func current(_ cache: WidgetCache, stale: Bool, report: ReportedEnergy?) -> DailySummary {
        let widget = cache.widgetState, shown = widget.presentation, trait = widget.primaryTrait
        let evidence = trait.explainable ? trait.id : nil
        var summary = DailySummary(kind: .quiet, icon: shown.icon, headline: shown.headline, comparison: shown.detail,
                                   domains: [], updatedAt: widget.freshness.lastUpdatedAt, isStale: stale,
                                   evidence: evidence, action: evidence == nil ? .openApp : .openEvidence, report: report)
        guard let facts = cache.facts else {  // a cache from before facts: show the mapper's words as they are
            summary.kind = changeTraits.contains(trait.id) ? .change
                : trait.id == "calibration" ? .learning : trait.id == "no_data" ? .waiting : .quiet
            return summary
        }
        summary.domains = domainLines(facts)
        if changeTraits.contains(trait.id) {
            summary.kind = .change
            if trait.id == "movement" { summary.headline = stepsHeadline(facts.movement.state) ?? shown.headline }
            summary.comparison = comparison(trait.id, facts) ?? shown.detail
            return summary
        }
        // No change to report. Speak only for domains whose baseline is ready, so a
        // learning domain never hides a ready one, and never claims more than is known.
        let typical = ["sleep", "recovery", "movement"].filter { id in
            let block = facts.block(id)
            return summary.domains.first { $0.id == id }?.readiness == .ready
                && block.state == "typical" && block.confidence >= minDisplayConfidence
        }
        if !typical.isEmpty {
            summary.icon = "🙂"
            summary.headline = "Within your usual range"
            summary.comparison = joined(typical.map { names[$0]! }).capitalizedFirst + " as usual"
            return summary
        }
        let anyEvidence = facts.learningDays.values.contains { $0 > 0 } || facts.measures.contains { $0.value != nil }
        if anyEvidence {
            summary.kind = .learning
            summary.icon = "🙂"
            summary.headline = "Getting to know your usual"
            summary.comparison = nil  // each domain's learning count is in `domains`
        } else {
            summary.kind = .waiting
            summary.icon = "⏳"
            summary.headline = "Waiting for Health data"
            summary.comparison = "No records yet: nothing recorded, or Health access is off"
            summary.action = .openDataAccess
        }
        return summary
    }

    static let names = ["sleep": "sleep", "recovery": "recovery", "movement": "steps"]

    static func domainLines(_ facts: DisplayFacts) -> [DomainLine] {
        func days(_ inputs: [String]) -> Int { inputs.compactMap { facts.learningDays[$0] }.max() ?? 0 }
        func latest(_ domains: [String]) -> Instant? {
            facts.measures.filter { domains.contains($0.domain) && $0.value != nil }.compactMap(\.observedAt).max()
        }
        return [("sleep", ["sleep"]), ("recovery", ["hrv", "rhr"]), ("movement", ["movement"])].map { id, inputs in
            let usable = days(inputs)
            let readiness: Readiness = usable < facts.requiredDays
                ? .learning(usable: min(usable, facts.requiredDays), required: facts.requiredDays)
                : facts.block(id).state == "missing" ? .missing : .ready
            return DomainLine(id: id, readiness: readiness, observedAt: latest(inputs))
        }
    }

    /// Steps alone don't measure all activity (Daily_loop_contract.md).
    static func stepsHeadline(_ state: String) -> String? {
        switch state {
        case "behind_usual": "Fewer steps than usual by this time"
        case "ahead_of_usual": "More steps than usual by this time"
        default: nil
        }
    }

    static func comparison(_ trait: String, _ facts: DisplayFacts) -> String? {
        let measure = facts.measures.first { $0.domain == trait && $0.value != nil }
        guard let value = measure?.value, let usual = measure?.baseline else { return nil }
        switch trait {
        case "sleep": return "\(hours(value)) · usually \(hours(usual))"
        case "movement": return "\(count(value)) steps · usually \(count(usual)) by now"
        default: return nil
        }
    }

    static func hours(_ value: Double) -> String {
        let minutes = Int((value * 60 + 0.5).rounded(.down))
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    static func count(_ value: Double) -> String {
        let digits = String(Int(value.rounded()))
        return String(digits.reversed().enumerated().map { $0 > 0 && $0 % 3 == 0 ? ",\($1)" : "\($1)" }
            .joined().reversed())
    }

    static func joined(_ items: [String]) -> String {
        items.count <= 2 ? items.joined(separator: " and ")
            : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}

extension DisplayFacts {
    func block(_ id: String) -> Domain {
        switch id {
        case "sleep": sleep
        case "recovery": recovery
        case "movement": movement
        default: workout
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
