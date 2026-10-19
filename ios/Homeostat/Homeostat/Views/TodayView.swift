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
        let lighting = Lighting(at: Instant(model.displayNow), zone: .current)
        let explain: (() -> Void)? = model.snapshot.state == nil ? nil : { model.showCurrentExplanation() }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.healthAvailable && (model.snapshot.ledger.isEmpty || model.needsHealthAccess) {
                        ConnectHealthCard()
                    }
                    SummaryCard(summary: summary, explain: explain)
                    if !summary.domains.isEmpty { DomainList(lines: summary.domains, explain: explain) }
                    EnergyCard()  // how you feel today doesn't depend on how fresh the Health data is
                }
                .padding()
                .animation(.smooth, value: summary)
            }
            .fontDesign(.rounded)
            .background { SkyBackground(lighting: lighting) }
            .navigationTitle(lighting.greeting)
            .navigationSubtitle(model.displayNow.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            .toolbar { ToolbarItem { Button("Details", systemImage: "slider.horizontal.3") { showingDetails = true } } }
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

extension Lighting {
    var greeting: String {
        switch self {
        case .morning: "Good morning"
        case .day: "Good afternoon"
        case .evening: "Good evening"
        case .night: "Hello"
        }
    }
}

/// A soft wash of the avatar's sky for the time of day: the light, never the health state.
struct SkyBackground: View {
    let lighting: Lighting
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let base = Color(.systemGroupedBackground)
        if contrast == .increased {
            base.ignoresSafeArea()
        } else {
            let (a, b) = tones
            let k = scheme == .dark ? 0.35 : 0.55
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.35], [0.6, 0.3], [1, 0.4],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: [
                a.opacity(k), b.opacity(k), a.opacity(k * 0.8),
                b.opacity(k * 0.5), a.opacity(k * 0.4), b.opacity(k * 0.5),
                .clear, .clear, .clear,
            ])
            .background(base)
            .ignoresSafeArea()
        }
    }

    var tones: (Color, Color) {
        switch lighting {
        case .morning: (Color(red: 1, green: 0.78, blue: 0.55), Color(red: 1, green: 0.9, blue: 0.7))
        case .day: (Color(red: 0.55, green: 0.78, blue: 1), Color(red: 0.7, green: 0.92, blue: 0.95))
        case .evening: (Color(red: 0.85, green: 0.6, blue: 0.85), Color(red: 1, green: 0.7, blue: 0.6))
        case .night: (Color(red: 0.35, green: 0.38, blue: 0.85), Color(red: 0.55, green: 0.4, blue: 0.85))
        }
    }
}

extension View {
    /// The one card surface on Today: Liquid Glass over the sky.
    func card() -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

/// Icon and color per domain or measurement: a category, never a grade.
enum DomainStyle {
    static func of(_ id: String) -> (symbol: String, color: Color) {
        switch id {
        case "sleep", "sleep_duration": ("moon.zzz.fill", .indigo)
        case "recovery", "hrv_sdnn": ("waveform.path.ecg", .pink)
        case "resting_hr": ("heart.fill", .pink)
        case "movement", "steps_so_far": ("figure.walk", .orange)
        case "last_workout": ("figure.strengthtraining.traditional", .teal)
        default: ("circle.dotted", .secondary)
        }
    }
}

struct SummaryCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    let summary: DailySummary
    /// Any stored result can be opened ("Why?" when it explains a finding); nil without one.
    let explain: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let state = model.snapshot.state {
                let avatar = state.widgetState.avatar ?? .unknown
                LiveAvatarView(identity: model.identity,
                               avatar: model.isCurrent(state) ? avatar : avatar.withoutDailyTraits)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)  // the summary below says the same in words
            }
            Text(summary.headline).font(.title2.bold())
            if let comparison = summary.comparison {
                Text(comparison).font(.body).foregroundStyle(.secondary).contentTransition(.numericText())
            }
            // Large text: the button goes under the time instead of breaking mid-word.
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                                                      : AnyLayout(HStackLayout())
            layout {
                if let updated = summary.updatedAt {
                    // Freshness of the data, not a health signal.
                    Label {
                        Text(summary.isStale ? "Updated \(Text(updated.date, style: .relative)) ago"
                                             : "Updated \(Text(updated.date, style: .time))")
                    } icon: {
                        Circle().fill(summary.isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint)).frame(width: 7, height: 7)
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                if let explain {
                    Button(summary.evidence != nil ? "Why?" : "Readings", systemImage: "chevron.right", action: explain)
                        .labelStyle(TrailingIcon())
                        .buttonStyle(.glass)
                        .frame(minHeight: 44)
                        .accessibilityHint("Shows the measurements behind this")
                }
            }
        }
        .card()
        .opacity(summary.isStale ? 0.7 : 1)
        .accessibilityElement(children: .contain)
    }
}

struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.caption.weight(.bold))
        }
    }
}

/// First run, or access never granted: the one step that makes everything else work.
struct ConnectHealthCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connect Apple Health", systemImage: "heart.text.square.fill")
                .font(.headline)
                .symbolRenderingMode(.multicolor)
            Text("Homeostat reads sleep, heart rate variability, resting heart rate, steps and workouts. "
                 + "It never writes to Health, and your data stays on this iPhone.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Connect") { Task { await model.requestAccess() } }
                .buttonStyle(.glassProminent)
                .frame(minHeight: 44)
                .disabled(model.busy)
        }
        .card()
    }
}

struct DomainList: View {
    let lines: [DailySummary.DomainLine]
    /// Opens the explanation; nil when there is no result to explain.
    let explain: (() -> Void)?
    static let names = ["sleep": "Sleep", "recovery": "Recovery", "movement": "Steps"]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                if index > 0 { Divider() }
                if let explain {
                    Button(action: explain) { DomainRow(line: line, chevron: true) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows the measurements behind this")
                } else {
                    DomainRow(line: line, chevron: false)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

struct DomainRow: View {
    let line: DailySummary.DomainLine
    let chevron: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconSize = 40.0

    var body: some View {
        let style = DomainStyle.of(line.id)
        // Large text: stack the value under the name instead of squeezing both.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                                                  : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            Image(systemName: style.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(style.color)
                .frame(width: iconSize, height: iconSize)
                .background(style.color.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(DomainList.names[line.id] ?? line.id).font(.headline)
                Text(status).font(.caption).foregroundStyle(.secondary)
                if case .learning(let usable, let required) = line.readiness {
                    ProgressView(value: Double(usable), total: Double(max(required, 1)))
                        .tint(style.color)
                        .accessibilityHidden(true)  // the caption says the same
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                if let value = line.value {
                    Text(value).font(.body.weight(.semibold).monospacedDigit())
                        .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                        .contentTransition(.numericText())
                }
                if let at = line.observedAt {
                    Text(observed(at)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if chevron && !typeSize.isAccessibilitySize {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    var status: String {
        switch line.readiness {
        case .ready: "Compared with your usual"
        // Usable days within a window, not a streak (Daily_loop_contract.md).
        case .learning(let usable, let required): "Learning: \(usable) of \(required) days"
        case .missing: "No reading today"
        }
    }

    /// "7:02 AM" today; otherwise with its day, so yesterday's reading isn't read as today's.
    func observed(_ at: Instant) -> String {
        let date = at.date
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday " + date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}

struct EnergyCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    static let labels: [(ReportedEnergy.Level, String, String)] = [
        (.low, "Low", "battery.25percent"), (.okay, "Okay", "battery.50percent"), (.high, "High", "battery.100percent"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How's your energy?").font(.headline)
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                ForEach(Self.labels, id: \.0) { level, label, symbol in
                    let chosen = model.todayReport?.level == level
                    Button { model.recordEnergy(level) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: symbol).font(.title3)
                            Text(label).font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(chosen ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
                    .accessibilityLabel("Energy \(label.lowercased())")
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            if let report = model.todayReport {
                HStack {
                    Label {
                        Text("You reported \(report.level.rawValue) energy at \(Text(report.at.date, style: .time))")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    }
                    .font(.subheadline)
                    Spacer()
                    if model.lastEnergy != nil {
                        Button("Undo") { model.undoEnergy() }.frame(minHeight: 44)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if model.lastEnergy != nil, !model.matchAnswered {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Does today's summary match how you feel?").font(.subheadline)
                    HStack {
                        Button("Yes") { model.answerMatch(.yes) }.buttonStyle(.glass).frame(minHeight: 44)
                        Button("Not really") { model.answerMatch(.notReally) }.buttonStyle(.glass).frame(minHeight: 44)
                    }
                }
                .transition(.opacity)
            }
            if let message = model.energyMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
            }
        }
        .card()
        .sensoryFeedback(.success, trigger: model.todayReport) { _, new in new != nil }
        .animation(.smooth, value: model.todayReport)
        .animation(.smooth, value: model.matchAnswered)
    }
}
