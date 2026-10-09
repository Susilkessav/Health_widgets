import HomeostatCore
import SwiftUI

/// What is behind the widget (Product.md §4 explanation layers): what it means,
/// the measurements in plain words, then provenance under "Technical details".
/// Shows the stored result: nothing here is recalculated, and a missing value says so.
struct ExplanationView: View {
    let state: ReturnedState
    var message: String? = nil
    @EnvironmentObject private var model: AppModel
    @State private var showingDetails = false

    var health: JSONValue { state.healthState }

    /// The same summary sentence the app and widget show for this result.
    var summary: DailySummary? {
        guard let day = LocalDay(state.day) else { return nil }
        return .make(.fresh(WidgetCache(scope: "", day: day, inputRevision: state.inputRevision, runID: state.runID,
                                        widgetState: state.widgetState,
                                        facts: DisplayFacts(healthState: state.healthState))))
    }

    var body: some View {
        List {
            Section {
                if let message { Text(message).foregroundStyle(.secondary) }
                Text(summary?.headline ?? state.widgetState.presentation.headline).font(.headline)
                if let comparison = summary?.comparison { Text(comparison) }
                if let secondary = state.widgetState.presentation.secondary { Text(secondary).foregroundStyle(.secondary) }
                if !state.widgetState.primaryTrait.explainable {
                    Text(summary?.kind == .learning
                         ? "Comparisons start once Homeostat knows your usual for a measurement (14 usable days)."
                         : "Not enough data to explain this yet").foregroundStyle(.secondary)
                }
                LabeledContent("Data as of", value: state.effectiveAt.date.formatted(date: .abbreviated, time: .shortened)
                               + (model.isCurrent(state) ? "" : " (an earlier day)"))
            }
            Section {
                if case .array(let drivers)? = health["drivers"], !drivers.isEmpty {
                    ForEach(Array(drivers.enumerated()), id: \.offset) { _, driver in MeasurementRow(driver: driver) }
                } else {
                    Text("No measurements yet")
                }
                if let missing = state.widgetState.avatar?.missingInputs, !missing.isEmpty {
                    LabeledContent(model.isCurrent(state) ? "No reading today" : "No reading for this result",
                                   value: missing.map(\.displayName).joined(separator: ", "))
                }
            } header: {
                Text("Measurements")
            } footer: {
                Text("“Usually” is your own typical value from recent weeks, not a target.")
            }
            Section {
                DisclosureGroup("Technical details", isExpanded: $showingDetails) {
                    ForEach(["sleep", "recovery", "movement", "workout"], id: \.self) { domain in
                        let block = health[domain]
                        LabeledContent(domain.capitalized) {
                            VStack(alignment: .trailing) {
                                Text(text(block?["state"]))
                                Text("data support \(text(block?["confidence"]))"
                                     + (block?["severity"].map { ", severity \(text($0))" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    let calibration = health["calibration"]
                    LabeledContent("Usable days", value: "\(text(calibration?["usable_days"])) / \(text(calibration?["required_days"]))")
                    if case .object(let domains)? = calibration?["domains"] {
                        ForEach(domains.keys.sorted(), id: \.self) { key in
                            LabeledContent("Usable days, \(key)", value: text(domains[key]))
                        }
                    }
                    if case .array(let drivers)? = health["drivers"] {
                        ForEach(Array(drivers.enumerated()), id: \.offset) { _, driver in DriverRow(driver: driver) }
                    }
                    LabeledContent("Engine", value: text(health["engine_version"]))
                    LabeledContent("Features", value: text(health["feature_version"]))
                    LabeledContent("Config", value: String(text(health["config_sha256"]).prefix(12)))
                    LabeledContent("Revision / run", value: "\(state.inputRevision) / \(state.runID)")
                }
            }
        }
        .navigationTitle("Why this")
    }
}

/// One measurement in plain words: value, your usual, when, and where from.
private struct MeasurementRow: View {
    let driver: JSONValue
    static let names = ["sleep_duration": "Sleep", "hrv_sdnn": "Heart rate variability", "resting_hr": "Resting heart rate",
                        "steps_so_far": "Steps so far", "last_workout": "Last workout"]

    var body: some View {
        let id = driver["id"]?.string ?? ""
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.names[id] ?? id).font(.headline)
            if let value = number(driver["value"]) {
                Text(id == "last_workout" ? "Ended \(format(value, id)) ago" : format(value, id)
                     + (number(driver["baseline"]).map { " · usually \(format($0, id, usual: true))\(id == "steps_so_far" ? " by now" : "")" } ?? ""))
                let when = driver["observed_at"]?.string.flatMap(Instant.parse)?.date
                let source = driver["source"]?.string
                Text([when?.formatted(date: .abbreviated, time: .shortened), source].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No reading for this result").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    func format(_ value: Double, _ id: String, usual: Bool = false) -> String {
        switch id {
        case "sleep_duration", "last_workout":
            let minutes = Int((value * 60).rounded())
            return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
        // An empty HealthKit result is imported as 0, so a measured 0 is "nothing recorded".
        case "steps_so_far": return !usual && value.rounded() == 0 ? "No steps recorded yet" : "\(Int(value.rounded()).formatted()) steps"
        case "hrv_sdnn": return "\(Int(value.rounded())) ms"
        case "resting_hr": return "\(Int(value.rounded())) bpm"
        default: return value.formatted()
        }
    }

    func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let n)?: Double(n)
        case .double(let d)?: d
        default: nil
        }
    }
}

private struct DriverRow: View {
    let driver: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text(driver["domain"])).font(.headline)
            let unit = driver["unit"]?.string.map { " \($0)" } ?? ""
            if driver["value"] == nil || driver["value"] == .null {
                Text("No data").foregroundStyle(.secondary)
            } else {
                Text("Value \(text(driver["value"]))\(unit) · baseline \(text(driver["baseline"]))\(unit)")
                Text("Difference \(text(driver["difference"]))\(unit) · confidence \(text(driver["confidence"]))")
            }
            Text("Source \(text(driver["source"])) · observed \(text(driver["observed_at"]))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A JSON value as the server sent it; missing or null reads "—".
private func text(_ value: JSONValue?) -> String {
    switch value {
    case .string(let s)?: s
    case .int(let n)?: String(n)
    case .double(let d)?: d.formatted(.number.precision(.fractionLength(0...2)))
    case .bool(let b)?: b ? "yes" : "no"
    default: "—"
    }
}
