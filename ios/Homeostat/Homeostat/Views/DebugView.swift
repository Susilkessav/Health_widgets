import HomeostatCore
import SwiftUI

/// Development screen (Step 9-13 plan section 4). Health values may appear
/// here for the user; the API key never does.
struct DebugView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                stateSection
                Section("Health data") {
                    if !model.healthAvailable {
                        Text("Health data isn't available on this device.")
                    }
                    ForEach(model.snapshot.ledger, id: \.type) { row in
                        LabeledContent(row.type) {
                            Text(visibility(row)).foregroundStyle(row.firstVisibleAt == nil ? .secondary : .primary)
                        }
                    }
                    if model.snapshot.ledger.isEmpty {
                        Text("Access not requested yet")
                    }
                }
                Section("Import") {
                    LabeledContent("History from", value: model.snapshot.lowerBound ?? "—")
                    ForEach(SampleType.allCases, id: \.self) { type in
                        LabeledContent("Last \(type.rawValue) query",
                                       value: model.importErrors[type.rawValue].map { "Error: \($0)" }
                                           ?? model.snapshot.lastQueries[type.rawValue] ?? "—")
                    }
                    if let error = model.importErrors["steps"] {
                        LabeledContent("Steps", value: "Error: \(error)")
                    }
                    if let recovery = model.snapshot.anchorRecovery {
                        LabeledContent("Anchor recovery", value: recovery)
                    }
                }
                Section("Upload queue") {
                    let c = model.snapshot.counts
                    LabeledContent("Pending", value: "\(c.pending + c.assigned)")
                    LabeledContent("Acknowledged", value: "\(c.acknowledged)")
                    LabeledContent("Conflicts", value: "\(c.conflict)")
                    LabeledContent("Dead letters", value: "\(c.deadLetter)")
                    LabeledContent("Quarantined samples", value: "\(c.quarantined)")
                    LabeledContent("Coverage pending / withheld", value: "\(c.coveragePending) / \(c.coverageWithheld)")
                    ForEach(model.snapshot.requests, id: \.requestID) { request in
                        LabeledContent("Request \(request.state)",
                                       value: "\(request.attempts) attempts \(request.lastError ?? "")")
                    }
                    LabeledContent("Last sync", value: model.lastSync.map(describe) ?? "—")
                    LabeledContent("Server revision", value: model.snapshot.acknowledgedRevision ?? "—")
                    if let paused = model.snapshot.paused {
                        Button("Uploads paused (\(paused)): resume") { Task { await model.resumeUploads() } }
                    }
                }
                Section {
                    Toggle("Send Health data to the server", isOn: Binding(
                        get: { model.uploadEnabled }, set: { model.setUploadEnabled($0) }))
                    Button("Request Health access") { Task { await model.requestAccess() } }
                    Button("Sync now") { Task { await model.catchUp() } }
                    Button("Refresh step history") { Task { await model.refreshHistory() } }
                }
                .disabled(model.busy || !model.isConfigured)
            }
            .navigationTitle("Homeostat")
            .toolbar {
                ToolbarItem { Button("Settings") { showingSettings = true } }
                ToolbarItem(placement: .topBarLeading) { if model.busy { ProgressView() } }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .refreshable { await model.catchUp() }
            .onAppear { model.refresh() }
        }
    }

    @ViewBuilder var stateSection: some View {
        Section("State") {
            if let state = model.snapshot.state {
                let widget = state.widgetState.presentation
                Text("\(widget.icon) \(widget.headline)").font(.headline)
                if let detail = widget.detail { Text(detail) }
                if let secondary = widget.secondary { Text(secondary).foregroundStyle(.secondary) }
                LabeledContent("For", value: state.isToday ? "today (\(state.day))" : state.day)
                LabeledContent("Updated", value: state.widgetState.freshness.lastUpdatedAt.date
                    .formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Revision / run", value: "\(state.inputRevision) / \(state.runID)")
            } else {
                Text(model.lastStateStatus == "pending" ? "Awaiting calculation" : "No state yet")
            }
            if model.lastStateStatus == "pending" {
                Text("Awaiting calculation").foregroundStyle(.secondary)
            }
        }
    }

    /// Never "granted" or "denied": HealthKit hides read permission.
    func visibility(_ row: LocalStore.LedgerRow) -> String {
        if let seen = row.lastVisibleAt { return "data visible (last \(seen.prefix(16)))" }
        return row.status == "requested" ? "No data visible yet" : "Not requested"
    }

    func describe(_ outcome: SyncOutcome) -> String {
        switch outcome {
        case .idle: "Up to date"
        case .busy: "Already syncing"
        case .notDue(let until): "Retrying at \(until.date.formatted(date: .omitted, time: .standard))"
        case .sent(_, let status): "Sent (state \(status))"
        case .retryScheduled(let at, let reason):
            reason == "NETWORK" ? "Offline: retrying at \(at.date.formatted(date: .omitted, time: .standard))"
                : "\(reason): retrying at \(at.date.formatted(date: .omitted, time: .standard))"
        case .paused(let reason): "Paused: \(reason)"
        case .quarantined(let reason): "Request quarantined: \(reason)"
        case .split: "Request split"
        case .protocolError(let reason): "Protocol error: \(reason)"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var baseURL = ""
    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("On a real iPhone use your Mac's LAN address, not localhost.")) {
                    TextField("Backend URL", text: $baseURL).textInputAutocapitalization(.never).keyboardType(.URL)
                    SecureField(model.hasAPIKey ? "API key (saved)" : "API key", text: $apiKey)
                }
                if let error = model.configurationError { Text(error).foregroundStyle(.red) }
                Section(footer: Text("Homeostat reads sleep, HRV, resting heart rate, workouts and steps. When "
                                     + "sending is on, they're sent to the backend above.")) { EmptyView() }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.saveSettings(baseURL: baseURL, apiKey: apiKey.isEmpty ? nil : apiKey)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { baseURL = model.baseURL }
        }
    }
}
