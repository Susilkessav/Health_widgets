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
                    SummaryCard(summary: summary) { model.showCurrentExplanation() }
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
                if let state = model.explanationState {
                    ExplanationView(state: state, message: model.explanationMessage)
                } else {
                    Text(model.explanationMessage ?? "No result yet.").padding()
                }
            }
        }
    }
}

struct SummaryCard: View {
    let summary: DailySummary
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
            if summary.evidence != nil {
                Button("Why?", action: explain)
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
                        Text(status(line.readiness))
                        if let at = line.observedAt {
                            Text(at.date, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    Text("Does this match how you feel?").font(.subheadline)
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
