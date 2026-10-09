import HomeostatCore
import SwiftUI

/// Today (P1, Daily_loop_contract.md): one observation, its evidence, and an
/// optional energy check-in. Wording comes from DailySummary, the same mapping
/// the widget uses; this view only lays it out.
struct TodayView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingDetails = false

    var body: some View {
        let summary = model.todaySummary
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let state = model.snapshot.state {
                        let avatar = state.widgetState.avatar ?? .unknown
                        LiveAvatarView(identity: model.identity,
                                       avatar: model.isCurrent(state) ? avatar : avatar.withoutDailyTraits)
                            .frame(height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .accessibilityHidden(true)  // the summary below says the same in words
                    }
                    if model.healthAvailable && (model.snapshot.ledger.isEmpty || model.needsHealthAccess) {
                        ConnectHealthCard()
                    }
                    SummaryCard(summary: summary, canExplain: model.snapshot.state != nil) { model.showCurrentExplanation() }
                    if !summary.domains.isEmpty { DomainList(lines: summary.domains) }
                    EnergyCard()  // how you feel today doesn't depend on how fresh the Health data is
                }
                .padding()
            }
            .navigationTitle("Today")
            .toolbar { ToolbarItem { Button("Details") { showingDetails = true } } }
            .refreshable { await model.catchUp() }
            .onAppear { model.refresh() }
        }
        .sheet(isPresented: $showingDetails) { DebugView() }
        .sheet(isPresented: $model.showingExplanation) {
            NavigationStack {
                Group {
                    if let state = model.explanationState {
                        ExplanationView(state: state, message: model.explanationMessage)
                    } else {
                        Text(model.explanationMessage ?? "No result yet.").padding()
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showingExplanation = false } } }
            }
        }
    }
}

struct SummaryCard: View {
    let summary: DailySummary
    /// Any stored result can be opened; "Why?" when it explains a finding.
    let canExplain: Bool
    let explain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.headline).font(.title2.bold())
            if let comparison = summary.comparison { Text(comparison).font(.body) }
            if let updated = summary.updatedAt {
                Text(summary.isStale ? "Updated \(Text(updated.date, style: .relative)) ago"
                                     : "Updated \(Text(updated.date, style: .time))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if canExplain {
                Button(summary.evidence != nil ? "Why?" : "See measurements", action: explain)
                    .frame(minHeight: 44)
                    .accessibilityHint("Shows the measurements behind this")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(summary.isStale ? 0.7 : 1)
        .accessibilityElement(children: .contain)
    }
}

/// First run, or access never granted: the one step that makes everything else work.
struct ConnectHealthCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect Apple Health").font(.headline)
            Text("Homeostat reads sleep, heart rate variability, resting heart rate, steps and workouts. "
                 + "It never writes to Health, and your data stays on this iPhone.")
                .font(.subheadline)
            Button("Connect") { Task { await model.requestAccess() } }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(model.busy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct DomainList: View {
    let lines: [DailySummary.DomainLine]
    static let names = ["sleep": "Sleep", "recovery": "Recovery", "movement": "Steps"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(lines, id: \.id) { line in
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.names[line.id] ?? line.id).font(.headline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let value = line.value { Text(value).font(.body.monospacedDigit()) }
                        Text(status(line.readiness)).font(line.value == nil ? .body : .caption)
                            .foregroundStyle(line.value == nil ? .primary : .secondary)
                        if let at = line.observedAt {
                            Text(observed(at)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// "7:02 AM" today; otherwise with its day, so yesterday's reading isn't read as today's.
    func observed(_ at: Instant) -> String {
        let date = at.date
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday " + date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    func status(_ readiness: DailySummary.Readiness) -> String {
        switch readiness {
        case .ready: "Compared with your usual"
        // Usable days within a window, not a streak (Daily_loop_contract.md).
        case .learning(let usable, let required): "Learning: \(usable) of \(required) days"
        case .missing: "No reading today"
        }
    }
}

struct EnergyCard: View {
    @EnvironmentObject var model: AppModel
    static let labels: [(ReportedEnergy.Level, String)] = [(.low, "Low"), (.okay, "Okay"), (.high, "High")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How's your energy?").font(.headline)
            HStack(spacing: 12) {
                ForEach(Self.labels, id: \.0) { level, label in
                    Button(label) { model.recordEnergy(level) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityLabel("Energy \(label.lowercased())")
                }
            }
            if let report = model.todayReport {
                HStack {
                    Text("You reported \(report.level.rawValue) energy at \(Text(report.at.date, style: .time))")
                        .font(.subheadline)
                    Spacer()
                    if model.lastEnergy != nil {
                        Button("Undo") { model.undoEnergy() }.frame(minHeight: 44)
                    }
                }
            }
            if model.lastEnergy != nil, !model.matchAnswered {
                HStack {
                    Text("Does today's summary match how you feel?").font(.subheadline)
                    Spacer()
                    Button("Yes") { model.answerMatch(.yes) }.frame(minHeight: 44)
                    Button("Not really") { model.answerMatch(.notReally) }.frame(minHeight: 44)
                }
            }
            if let message = model.energyMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
