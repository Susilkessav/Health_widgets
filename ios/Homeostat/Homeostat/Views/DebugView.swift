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
                    if model.needsHealthAccess {
                        Button("Health access isn't granted for this version: grant it") {
                            Task { await model.requestAccess() }
                        }
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
                                       value: model.importErrors[type.rawValue].map(describeImportError)
                                           ?? model.snapshot.lastQueries[type.rawValue] ?? "—")
                    }
                    if let error = model.importErrors["steps"] {
                        LabeledContent("Steps", value: describeImportError(error))
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
                    LabeledContent("Visibility scans pending", value: "\(c.scansPending)")
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
                Section("Widget step probe (M2)") {
                    let probe = ProbeLog.lines().reversed().prefix(10)
                    if probe.isEmpty { Text("The widget hasn't run the probe yet") }
                    ForEach(Array(probe.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Section("Background log") {
                    if model.snapshot.backgroundLog.isEmpty { Text("No background events yet") }
                    ForEach(Array(model.snapshot.backgroundLog.prefix(20).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Section("Background and widget") {
                    ForEach(model.snapshot.diagnostics.keys.sorted(), id: \.self) { key in
                        LabeledContent(key.replacingOccurrences(of: "_", with: " "), value: model.snapshot.diagnostics[key] ?? "—")
                    }
                    if let manifest = model.widgetDiagnostics {
                        LabeledContent("Widget last check", value: manifest.fetch.lastCheckedAt?.wire ?? "—")
                        LabeledContent("Widget next attempt", value: manifest.fetch.nextAttemptAt?.wire ?? "—")
                        LabeledContent("Widget calculation", value: manifest.fetch.calculationStatus ?? "—")
                        LabeledContent("Widget error", value: manifest.fetch.lastError ?? "—")
                        LabeledContent("Widget run", value: manifest.cache.map { String($0.runID) } ?? "—")
                        LabeledContent("Timeline generated", value: manifest.fetch.timelineGeneratedAt?.wire ?? "—")
                    }
                }
                Section(footer: Text("Results are calculated on this iPhone. Sending to a server is optional "
                                     + "and only keeps a copy there for later.")) {
                    Toggle("Send Health data to the server", isOn: Binding(
                        get: { model.uploadEnabled }, set: { model.setUploadEnabled($0) }))
                        .disabled(!model.isSignedIn)
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
                // An earlier day's result doesn't show its eyes, posture or movement as today's.
                let avatar = state.widgetState.avatar ?? .unknown
                LiveAvatarView(identity: model.identity, avatar: model.isCurrent(state) ? avatar : avatar.withoutDailyTraits)
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
                let widget = state.widgetState.presentation
                Text("\(widget.icon) \(widget.headline)").font(.headline)
                if let detail = widget.detail { Text(detail) }
                if let secondary = widget.secondary { Text(secondary).foregroundStyle(.secondary) }
                LabeledContent("For", value: model.isCurrent(state) ? "today (\(state.day))" : state.day)
                LabeledContent("Updated", value: state.widgetState.freshness.lastUpdatedAt.date
                    .formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Revision / run", value: "\(state.inputRevision) / \(state.runID)")
                NavigationLink("Why this state") { ExplanationView(state: state) }
            } else {
                Text("No result yet. Request Health access and sync.")
            }
        }
        Section("Avatar") {
            NavigationLink("Customize avatar") { AvatarEditorView() }
            NavigationLink("Avatar demo") { AvatarDemoView() }
        }
    }

    func describeImportError(_ code: String) -> String {
        code == AppModel.accessNotDetermined ? "Health access not granted" : "Error: \(code)"
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
    @State private var enrollmentKey = ""
    @State private var pairingCode = ""
    @State private var devices: [AppModel.Device]?
    @State private var newCode: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("On a real iPhone use your Mac's LAN address, not localhost.")) {
                    TextField("Backend URL", text: $baseURL).textInputAutocapitalization(.never).keyboardType(.URL)
                }
                Section(header: Text("Sign in"), footer: Text("Only needed the first time on this device: the "
                                     + "server's enrollment key creates a new account, or a pairing code from a "
                                     + "signed-in device joins that account.")) {
                    SecureField(model.hasAPIKey ? "Enrollment key (signed in)" : "Enrollment key", text: $enrollmentKey)
                    TextField("Pairing code", text: $pairingCode).textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                if let error = model.configurationError { Text(error).foregroundStyle(.red) }
                if model.isSignedIn { devicesSection }
                Section(footer: Text("Homeostat reads sleep, HRV, resting heart rate, workouts and steps. When "
                                     + "sending is on, they're sent to the backend above.")) { EmptyView() }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await model.saveSettings(baseURL: baseURL,
                                                        enrollmentKey: enrollmentKey.isEmpty ? nil : enrollmentKey,
                                                        pairingCode: pairingCode.isEmpty ? nil : pairingCode) { dismiss() }
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.savingSettings) }
            }
            .disabled(model.savingSettings)
            .onAppear { baseURL = model.baseURL }
            .task { devices = await model.listDevices() }
        }
    }

    @ViewBuilder var devicesSection: some View {
        Section(header: Text("Devices on this account"),
                footer: Text("Removing a device signs it out and stops its widget.")) {
            if let devices {
                ForEach(devices) { device in
                    LabeledContent(device.name, value: device.current ? "This device" : String(device.created_at.prefix(10)))
                        .swipeActions {
                            if !device.current {
                                Button("Remove", role: .destructive) {
                                    Task {
                                        if await model.removeDevice(device.device_id) { self.devices = await model.listDevices() }
                                    }
                                }
                            }
                        }
                }
            } else {
                Text("Devices are shown once this device is signed in.").foregroundStyle(.secondary)
            }
            if let newCode {
                LabeledContent("Pairing code", value: newCode).font(.body.monospaced())
                Text("Enter it on the other device within 10 minutes.").font(.caption).foregroundStyle(.secondary)
            } else if devices != nil {
                Button("Add another device") { Task { newCode = await model.createPairingCode() } }
            }
        }
    }
}
