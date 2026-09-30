import Foundation

// Swift port of backend/app/engine.py (DailyFeatures -> HealthState) and
// backend/app/presentation.py (HealthState -> WidgetState). Pure; checked
// against the Python output by EngineParityTests.

public let engineVersion = "state-engine@0.1.0"

public struct Driver: Sendable {
    public var id: String, domain: String, confidence: Double
    public var value: Double?, baseline: Double?, difference: Double?
    public var unit: String?, source: String?, observedAt: Instant?
}

public struct HealthState: Sendable {
    public struct Domain: Sendable { public var state: String, confidence: Double, severity: Double?, type: String? }
    public var effectiveAt: Instant
    public var calibrationDays: [String: Int]  // sleep, hrv, rhr, movement
    public var requiredDays: Int
    public var calibrationReady: Bool
    public var calibrationUsableDays: Int
    public var sleep: Domain, recovery: Domain, movement: Domain, workout: Domain
    public var drivers: [Driver]

    func domainReady(_ domain: String) -> Bool { calibrationDays[domain]! >= requiredDays }

    func block(_ domain: String) -> Domain {
        switch domain {
        case "sleep": sleep
        case "recovery": recovery
        case "movement": movement
        default: workout
        }
    }
}

let recoveryInputs = ["sleep", "hrv", "rhr"]
let adverse = ["sleep": "below_baseline", "hrv": "below_usual", "rhr": "above_usual"]
let movementSource = "HealthKit statistics"  // merged statistics, not one device

public func computeHealthState(_ f: DailyFeatures, _ settings: EngineSettings = .standard) -> HealthState {
    // A recovery input votes only with a ready baseline, a classification and some data support.
    let blocks: [String: (ready: Bool, state: String, confidence: Double)] = [
        "sleep": (f.sleep.ready, f.sleep.state, f.sleep.confidence),
        "hrv": (f.hrv.ready, f.hrv.state, f.hrv.confidence),
        "rhr": (f.rhr.ready, f.rhr.state, f.rhr.confidence),
    ]
    let used = recoveryInputs.filter { blocks[$0]!.ready && !["missing", "calibrating"].contains(blocks[$0]!.state)
                                        && blocks[$0]!.confidence > 0 }
    var recovery = HealthState.Domain(state: "insufficient_data", confidence: 0, severity: nil, type: nil)
    if used.count >= 2 {
        func isState(_ domain: String, _ state: String) -> Bool { used.contains(domain) && blocks[domain]!.state == state }
        let state = used.filter { isState($0, adverse[$0]!) }.count >= 2 ? "strained"
            : isState("hrv", "above_usual") && isState("rhr", "below_usual") && !isState("sleep", "below_baseline")
                ? "favorable" : "typical"
        recovery = .init(state: state, confidence: used.map { blocks[$0]!.confidence }.min()! * Double(used.count) / 3,
                         severity: nil, type: nil)
    }

    let days = ["sleep": f.sleep.usableDays, "hrv": f.hrv.usableDays, "rhr": f.rhr.usableDays,
                "movement": f.movement.usableDays]
    let participating = days.values.filter { $0 > 0 }
    let usable = participating.min() ?? 0

    var severity: Double?
    if ["below_baseline", "above_baseline"].contains(f.sleep.state), let delta = f.sleep.deltaHours {
        severity = min(abs(delta * 60) / settings.sleepSeverityFullMinutes, 1.0)
    }
    return HealthState(
        effectiveAt: f.effectiveAt, calibrationDays: days, requiredDays: settings.minimumValidDays,
        calibrationReady: !participating.isEmpty && usable >= settings.minimumValidDays, calibrationUsableDays: usable,
        sleep: .init(state: f.sleep.state, confidence: f.sleep.confidence, severity: severity, type: nil),
        recovery: recovery,
        movement: .init(state: f.movement.state, confidence: f.movement.confidence, severity: nil, type: nil),
        workout: .init(state: f.workout.state, confidence: f.workout.confidence, severity: nil, type: f.workout.type),
        drivers: drivers(f))
}

/// Fixed order. A ready baseline without a current value is explained with confidence 0.
func drivers(_ f: DailyFeatures) -> [Driver] {
    var result: [Driver] = []
    func add(_ id: String, _ domain: String, _ confidence: Double, _ value: Double?, _ baseline: Double?, _ unit: String,
             _ source: String?, _ observedAt: Instant?, difference: Double? = nil) {
        guard value != nil || baseline != nil else { return }
        var difference = difference
        if difference == nil, let value, let baseline { difference = value - baseline }
        result.append(Driver(id: id, domain: domain, confidence: value != nil ? confidence : 0, value: value,
                             baseline: baseline, difference: difference, unit: unit,
                             source: value != nil ? source : nil, observedAt: observedAt))
    }
    add("sleep_duration", "sleep", f.sleep.confidence, f.sleep.hours, f.sleep.baselineHours, "hours", f.sleep.source,
        f.sleep.sleepEnd, difference: f.sleep.deltaHours)
    add("hrv_sdnn", "hrv", f.hrv.confidence, f.hrv.value, f.hrv.baseline, "ms", f.hrv.sourceName, f.hrv.observedAt)
    add("resting_hr", "rhr", f.rhr.confidence, f.rhr.value, f.rhr.baseline, "bpm", f.rhr.sourceName, f.rhr.observedAt)
    add("steps_so_far", "movement", f.movement.confidence, f.movement.steps.map(Double.init), f.movement.expectedStepsNow,
        "steps", movementSource, f.movement.asOf)
    if f.workout.end != nil {
        add("last_workout", "workout", f.workout.confidence, f.workout.hoursSince, nil, "hours since end",
            f.workout.sourceName, f.workout.end)
    }
    return result
}

// MARK: - Presentation (presentation.py)

let minDisplayConfidence = 0.5
let workoutLabels = [
    "traditional_strength_training": "Strength training", "functional_strength_training": "Strength training",
    "running": "Run", "walking": "Walk", "cycling": "Ride", "yoga": "Yoga", "swimming": "Swim", "hiking": "Hike",
]
let inputNames = ["sleep": "sleep", "hrv": "HRV", "rhr": "resting HR"]

/// P1-P8 in priority order: attention-worthy deviations, a fresh workout,
/// positive deviations, then a recent workout.
let rules: [(domain: String, state: String, icon: String, headline: String)] = [
    ("sleep", "below_baseline", "😴", "Shorter sleep"),
    ("recovery", "strained", "🪫", "Recovery signals below usual"),
    ("movement", "behind_usual", "🚶", "Less active than usual"),
    ("workout", "just_completed", "🏋️", "Workout complete"),
    ("sleep", "above_baseline", "🛌", "Longer sleep"),
    ("recovery", "favorable", "🔋", "Recovery signals above usual"),
    ("movement", "ahead_of_usual", "🚶", "More active than usual"),
    ("workout", "recent_workout", "🏋️", "Recent workout"),
]

func formatHours(_ hours: Double) -> String {
    let minutes = Int((hours * 60 + 0.5).rounded(.down))  // half-up
    return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
}

func formatSteps(_ steps: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.usesGroupingSeparator = true
    formatter.groupingSeparator = ","
    formatter.groupingSize = 3
    return formatter.string(from: NSNumber(value: Int((steps + 0.5).rounded(.down))))! + " steps"
}

func joinNames(_ names: [String]) -> String {
    names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
}

func workoutLabel(_ type: String?) -> String { workoutLabels[type ?? ""] ?? "Workout" }

public func mapWidgetState(_ s: HealthState) -> WidgetState {
    func displayable(_ domain: String) -> Bool { s.block(domain).confidence >= minDisplayConfidence }
    func driver(_ domain: String) -> Driver? { s.drivers.first { $0.domain == domain } }
    let usedInputs = s.drivers.filter { inputNames[$0.domain] != nil && $0.value != nil && $0.baseline != nil
                                         && $0.confidence > 0 }.map(\.domain)
    func supported(_ domain: String) -> Bool {
        if domain == "recovery" { return usedInputs.count >= 2 }
        guard let found = driver(domain) else { return false }
        return domain == "workout" ? found.observedAt != nil : found.value != nil && found.baseline != nil
    }

    let matches = rules.filter { s.block($0.domain).state == $0.state && displayable($0.domain) }
    let trait: String, icon: String, headline: String, detail: String, named: [String]
    var secondary: String?
    if let primary = matches.first {
        (trait, icon, headline, named) = (primary.domain, primary.icon, primary.headline, [primary.domain])
        switch primary.domain {
        case "sleep": detail = formatHours(driver("sleep")!.value!)
        case "movement": detail = formatSteps(driver("movement")!.value!)
        case "workout": detail = workoutLabel(s.workout.type)
        default: detail = "Based on " + joinNames(usedInputs.map { inputNames[$0]! })
        }
        if trait != "workout", ["just_completed", "recent_workout"].contains(s.workout.state), displayable("workout") {
            secondary = "\(workoutLabel(s.workout.type)) completed recently"
        } else {
            secondary = matches.dropFirst().first { $0.domain != trait }?.headline
        }
    } else {
        let typical = ["sleep", "recovery", "movement"].filter { s.block($0).state == "typical" && displayable($0) }
        let evidence = s.calibrationDays.values.contains { $0 > 0 } || s.drivers.contains { $0.value != nil }
        if !s.calibrationReady && evidence {
            (trait, icon, headline, named) = ("calibration", "🙂", "Learning your baseline", [])
            detail = "\(s.calibrationUsableDays) / \(s.requiredDays) usable days"
        } else if !typical.isEmpty {
            (trait, icon, headline, named) = ("typical", "🙂", "Typical day", typical)
            let listed = joinNames(typical)
            detail = listed.prefix(1).uppercased() + listed.dropFirst() + " as usual"
        } else {
            (trait, icon, headline, named) = ("no_data", "⏳", "Waiting for new data", [])
            detail = "Open Homeostat to sync Health data"
        }
    }
    return WidgetState(effectiveAt: s.effectiveAt,
                       presentation: .init(icon: icon, headline: headline, detail: detail, secondary: secondary),
                       primaryTrait: .init(id: trait, explainable: !named.isEmpty && named.allSatisfy(supported)),
                       freshness: .init(lastUpdatedAt: s.effectiveAt))
}

// MARK: - JSON, in the backend's shapes (health_state.py, features.py)

private func number(_ value: Double?) -> JSONValue { value.map(JSONValue.double) ?? .null }
private func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
private func time(_ value: Instant?) -> JSONValue { value.map { .string($0.wire) } ?? .null }

extension HealthState {
    public var json: JSONValue {
        func domain(_ d: Domain, severity: Bool = false, type: Bool = false) -> JSONValue {
            var fields: [String: JSONValue] = ["state": .string(d.state), "confidence": .double(d.confidence)]
            if severity { fields["severity"] = number(d.severity) }
            if type { fields["type"] = text(d.type) }
            return .object(fields)
        }
        let status = calibrationReady ? "ready" : "calibrating"
        return .object([
            "version": .string("health-state@0.1.0"), "engine_version": .string(engineVersion),
            "feature_version": .string(featuresVersion), "config_sha256": .string(EngineSettings.configSHA256),
            "effective_at": .string(effectiveAt.wire),
            "calibration": .object([
                "required_days": .int(Int64(requiredDays)), "status": .string(status),
                "usable_days": .int(Int64(calibrationUsableDays)),
                "domains": .object(calibrationDays.mapValues { .int(Int64($0)) }),
            ]),
            "sleep": domain(sleep, severity: true), "recovery": domain(recovery), "movement": domain(movement),
            "workout": domain(workout, type: true),
            "drivers": .array(drivers.map { d in .object([
                "id": .string(d.id), "domain": .string(d.domain), "confidence": .double(d.confidence),
                "value": number(d.value), "baseline": number(d.baseline), "difference": number(d.difference),
                "unit": text(d.unit), "source": text(d.source), "observed_at": time(d.observedAt),
            ]) }),
        ])
    }
}

extension DailyFeatures {
    public var json: JSONValue {
        func baselined(_ status: Bool, _ usable: Int, _ required: Int, _ confidence: Double, _ state: String)
            -> [String: JSONValue] {
            ["baseline_status": .string(status ? "ready" : "calibrating"), "usable_days": .int(Int64(usable)),
             "required_days": .int(Int64(required)), "confidence": .double(confidence), "state": .string(state)]
        }
        func point(_ p: PointFeatures, metric: String?, unit: String) -> JSONValue {
            var fields = baselined(p.ready, p.usableDays, p.requiredDays, p.confidence, p.state)
            fields.merge(["value": number(p.value), "observed_at": time(p.observedAt),
                          "source_record_id": text(p.recordID), "source_name": text(p.sourceName),
                          "baseline": number(p.baseline), "mad": number(p.mad), "robust_z": number(p.robustZ),
                          "unit": .string(unit)]) { $1 }
            if let metric { fields["metric"] = .string(metric) }
            return .object(fields)
        }
        var sleepFields = baselined(sleep.ready, sleep.usableDays, sleep.requiredDays, sleep.confidence, sleep.state)
        sleepFields.merge([
            "hours": number(sleep.hours), "sleep_start": time(sleep.sleepStart), "sleep_end": time(sleep.sleepEnd),
            "span_hours": number(sleep.spanHours), "in_bed_hours": number(sleep.inBedHours),
            "awake_minutes": number(sleep.awakeMinutes), "timezone": text(sleep.timezone), "source": text(sleep.source),
            "source_policy_version": text(sleep.sourcePolicyVersion), "baseline_hours": number(sleep.baselineHours),
            "baseline_mad_hours": number(sleep.baselineMadHours), "delta_hours": number(sleep.deltaHours),
            "ratio": number(sleep.ratio),
        ]) { $1 }
        var movementFields = baselined(movement.ready, movement.usableDays, movement.requiredDays, movement.confidence,
                                       movement.state)
        movementFields.merge([
            "steps": movement.steps.map { .int(Int64($0)) } ?? .null, "as_of": time(movement.asOf),
            "source_record_id": text(movement.recordID), "expected_steps_now": number(movement.expectedStepsNow),
            "ratio": number(movement.ratio),
        ]) { $1 }
        return .object([
            "version": .string(featuresVersion), "config_sha256": .string(EngineSettings.configSHA256),
            "day": .string(day.description), "timezone": .string(timezone), "effective_at": .string(effectiveAt.wire),
            "sleep": .object(sleepFields), "hrv": point(hrv, metric: "hrv_sdnn_ms", unit: "ms"),
            "rhr": point(rhr, metric: nil, unit: "bpm"), "movement": .object(movementFields),
            "workout": .object([
                "state": .string(workout.state), "confidence": .double(workout.confidence), "type": text(workout.type),
                "last_workout_start": time(workout.start), "last_workout_end": time(workout.end),
                "source_record_id": text(workout.recordID), "source_name": text(workout.sourceName),
                "hours_since": number(workout.hoursSince), "workout_minutes_today": number(workout.minutesToday),
                "workout_minutes_last_7d": number(workout.minutesLast7d),
            ]),
        ])
    }
}
