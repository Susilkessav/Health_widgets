import HomeostatCore
import SwiftUI

/// What is behind the widget (G1 demo item 12; Step 14-16 plan section 7).
/// Shows the stored HealthState as the server computed it: nothing here is
/// recalculated, and a missing value says so.
struct ExplanationView: View {
    let state: ReturnedState

    var health: JSONValue { state.healthState }

    var body: some View {
        List {
            Section {
                let p = state.widgetState.presentation
                Text("\(p.icon) \(p.headline)").font(.headline)
                if let detail = p.detail { Text(detail) }
                if let secondary = p.secondary { Text(secondary).foregroundStyle(.secondary) }
                if !state.widgetState.primaryTrait.explainable {
                    Text("Not enough data to explain this").foregroundStyle(.secondary)
                }
                LabeledContent("Day", value: state.isToday ? "\(state.day) (today)" : state.day)
                LabeledContent("Data as of", value: state.effectiveAt.date.formatted(date: .abbreviated, time: .shortened))
            }
            Section("States") {
                ForEach(["sleep", "recovery", "movement", "workout"], id: \.self) { domain in
                    let block = health[domain]
                    LabeledContent(domain.capitalized) {
                        VStack(alignment: .trailing) {
                            Text(text(block?["state"]))
                            Text("confidence \(text(block?["confidence"]))"
                                 + (block?["severity"].map { ", severity \(text($0))" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Drivers") {
                if case .array(let drivers)? = health["drivers"], !drivers.isEmpty {
                    ForEach(Array(drivers.enumerated()), id: \.offset) { _, driver in
                        DriverRow(driver: driver)
                    }
                } else {
                    Text("No drivers")
                }
            }
            Section("Calibration") {
                let calibration = health["calibration"]
                LabeledContent("Status", value: text(calibration?["status"]))
                LabeledContent("Usable days", value: "\(text(calibration?["usable_days"])) / \(text(calibration?["required_days"]))")
                if case .object(let domains)? = calibration?["domains"] {
                    ForEach(domains.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: text(domains[key]))
                    }
                }
            }
            Section("Versions") {
                LabeledContent("Engine", value: text(health["engine_version"]))
                LabeledContent("Features", value: text(health["feature_version"]))
                LabeledContent("Config", value: String(text(health["config_sha256"]).prefix(12)))
                LabeledContent("Revision / run", value: "\(state.inputRevision) / \(state.runID)")
            }
        }
        .navigationTitle("Why this state")
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
