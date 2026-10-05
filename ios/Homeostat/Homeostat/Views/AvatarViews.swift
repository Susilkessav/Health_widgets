import HomeostatCore
import SwiftUI

extension Zone {
    static var current: Zone { Zone(TimeZone.current.identifier) ?? Zone("UTC")! }
}

/// The app's avatar (G2 T9): breathing and blinking on top of the static
/// AvatarView. Movement sets the breathing pace; tired eyes blink more often
/// and close for longer. Reduce Motion shows the still pose but keeps a
/// once-a-minute clock, so lighting and fading still change.
struct LiveAvatarView: View {
    let identity: AvatarIdentity
    let avatar: AvatarState
    var framing: AvatarFraming = .fullBody
    /// A fixed time for lighting and fading (demo mode); nil follows the clock.
    var time: Date?
    var zone: Zone = .current
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            TimelineView(.everyMinute) { context in frame(context.date, moving: false) }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in frame(context.date, moving: true) }
        }
    }

    func frame(_ date: Date, moving: Bool) -> AvatarView {
        let t = date.timeIntervalSinceReferenceDate
        return AvatarView(identity: identity, avatar: avatar, time: Instant(time ?? date), zone: zone,
                          framing: framing, breath: moving ? breath(t) : 0, blink: moving ? blink(t) : 0)
    }

    var pace: Double {
        switch avatar.motion {
        case .low: 0.7
        case .typical: 1
        case .high: 1.4
        }
    }

    func breath(_ t: Double) -> Double { (sin(t * 2 * .pi * pace / 4) + 1) / 2 }

    func blink(_ t: Double) -> Double {
        let tired = avatar.eyes == .tired
        let period = tired ? 3.0 : 4.5, length = tired ? 0.35 : 0.18
        let phase = t.truncatingRemainder(dividingBy: period)
        return phase < length ? sin(phase / length * .pi) : 0
    }
}

/// Appearance editor (G2 T7). Saves on every change; health data never touches it.
struct AvatarEditorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let identity = Binding(get: { model.identity }, set: { model.saveIdentity($0) })
        Form {
            Section {
                LiveAvatarView(identity: model.identity, avatar: AvatarState())
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
                if let error = model.identitySaveError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Section("Skin") { Swatches(colors: AvatarPalette.skins, names: AvatarPalette.skinNames, selection: identity.skinTone,
                                         label: "Skin tone") }
            Section("Hair") {
                Picker("Style", selection: identity.hairStyle) {
                    ForEach(AvatarPalette.hairStyleNames.indices, id: \.self) { Text(AvatarPalette.hairStyleNames[$0]).tag($0) }
                }
                .pickerStyle(.segmented)
                Swatches(colors: AvatarPalette.hairs, names: AvatarPalette.hairColorNames, selection: identity.hairColor,
                         label: "Hair color")
            }
            Section("Style") {
                Picker("Outfit", selection: identity.outfit) {
                    ForEach(AvatarPalette.outfitNames.indices, id: \.self) { Text(AvatarPalette.outfitNames[$0]).tag($0) }
                }
                Picker("Body", selection: identity.body) {
                    ForEach(AvatarPalette.bodyNames.indices, id: \.self) { Text(AvatarPalette.bodyNames[$0]).tag($0) }
                }
                Toggle("Glasses", isOn: identity.glasses)
            }
            Section {
                Button("Reset to default") { model.saveIdentity(AvatarIdentity()) }
            } footer: {
                Text("Your avatar's look stays on this iPhone. Health data changes how it looks today, never who it is.")
            }
        }
        .navigationTitle("Your avatar")
    }
}

/// Color choices: 44-point targets around 34-point circles, each with a spoken name.
struct Swatches: View {
    let colors: [Color]
    let names: [String]
    @Binding var selection: Int
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(colors.indices, id: \.self) { index in
                Button { selection = index } label: {
                    Circle().fill(colors[index]).frame(width: 34, height: 34)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: selection == index ? 3 : 0).padding(-3))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label): \(names[index])")
                .accessibilityAddTraits(selection == index ? .isSelected : [])
            }
        }
    }
}

/// A real pipeline result bundled for the demo (backend tests/engine/test_demo_states.py).
struct DemoResult: Decodable {
    let name: String
    let dataset: String
    let checkpoint: String
    let timezone: String
    let widgetState: WidgetState

    enum CodingKeys: String, CodingKey { case name, dataset, checkpoint, timezone, widgetState = "widget_state" }

    static let all: [DemoResult] = {
        guard let url = Bundle.main.url(forResource: "demo_states", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DemoResult].self, from: data)) ?? []
    }()
}

/// Demo mode (G2 T10): see the avatar without Health data. "Real results" are
/// synthetic checkpoints run through the actual engine; the slider moves the
/// clock after the result, so fading, lighting and the earlier-day rule show.
/// "Playground" sets every channel by hand, for art review.
struct AvatarDemoView: View {
    @EnvironmentObject var model: AppModel
    @State private var real = true
    @State private var result = 0
    @State private var hoursLater = 0.0
    @State private var preset = 0
    @State private var hour = 9.0
    @State private var minutesSinceWorkout = 10.0

    static let presets: [(name: String, make: (Instant) -> AvatarState)] = [
        ("Typical", { _ in AvatarState() }),
        ("Tired eyes", { _ in AvatarState(eyes: .tired, eyesIntensity: 0.8) }),
        ("Rested eyes, upright", { _ in AvatarState(eyes: .rested, eyesIntensity: 0.7, posture: .upright) }),
        ("Tired eyes, low posture", { _ in AvatarState(eyes: .tired, eyesIntensity: 0.5, posture: .low) }),
        ("Low movement", { _ in AvatarState(motion: .low) }),
        ("High movement", { _ in AvatarState(motion: .high) }),
        ("Strength workout", { end in AvatarState(activity: .strength, effects: [
            .init(kind: .sweat, peak: 1, startedAt: end, halfLifeMinutes: 20),
            .init(kind: .glow, peak: 1, startedAt: end, halfLifeMinutes: 160)]) }),
        ("Cardio workout", { end in AvatarState(activity: .cardio, effects: [
            .init(kind: .sweat, peak: 1, startedAt: end, halfLifeMinutes: 20),
            .init(kind: .glow, peak: 1, startedAt: end, halfLifeMinutes: 160)]) }),
        ("Mobility workout", { end in AvatarState(activity: .mobility, effects: [
            .init(kind: .glow, peak: 0.9, startedAt: end, halfLifeMinutes: 160)]) }),
        ("Uncertain data marker", { _ in AvatarState(uncertainty: .lowConfidence) }),
        ("Calibrating marker", { _ in AvatarState(uncertainty: .calibrating) }),
    ]

    var body: some View {
        Form {
            Picker("Source", selection: $real) {
                Text("Real results").tag(true)
                Text("Playground").tag(false)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            if real { realResults } else { playground }
        }
        .navigationTitle("Avatar demo")
    }

    @ViewBuilder var realResults: some View {
        let results = DemoResult.all
        if results.isEmpty {
            Text("Demo results aren't bundled in this build.")
        } else {
            let item = results[min(result, results.count - 1)]
            let zone = Zone(item.timezone) ?? .current
            let start = item.widgetState.effectiveAt
            let now = start.adding(seconds: Int64(hoursLater * 3600))
            let saved = item.widgetState.avatar ?? .unknown
            // The same earlier-day rule as the widget (WidgetPolicy.avatar).
            let avatar = zone.day(of: now) == zone.day(of: start) ? saved : saved.withoutDailyTraits
            preview(avatar, time: now.date, zone: zone)
            Section {
                let p = item.widgetState.presentation
                Text(p.headline).font(.headline)
                if let detail = p.detail { Text(detail) }
                if let secondary = p.secondary { Text(secondary).foregroundStyle(.secondary) }
                Text("\(item.dataset) @ \(item.checkpoint)").font(.caption).foregroundStyle(.secondary)
            } header: { Text("What the widget says") }
            Section("Result") {
                Picker("Result", selection: $result) {
                    ForEach(results.indices, id: \.self) { Text(results[$0].name).tag($0) }
                }
            }
            Section("\(Int(hoursLater)) hours later: \(now.date.formatted(date: .abbreviated, time: .shortened))") {
                Slider(value: $hoursLater, in: 0...24, step: 0.5)
            }
        }
    }

    @ViewBuilder var playground: some View {
        let time = Calendar.current.date(bySettingHour: Int(hour), minute: Int((hour - hour.rounded(.down)) * 60),
                                         second: 0, of: Date()) ?? Date()
        let avatar = Self.presets[preset].make(Instant(time).adding(seconds: -Int64(minutesSinceWorkout * 60)))
        preview(avatar, time: time, zone: .current)
        Section("Channels") {
            Picker("Set", selection: $preset) {
                ForEach(Self.presets.indices, id: \.self) { Text(Self.presets[$0].name).tag($0) }
            }
        }
        Section("Time of day: \(time.formatted(date: .omitted, time: .shortened))") {
            Slider(value: $hour, in: 0...23.75, step: 0.25)
        }
        Section("Minutes since the workout: \(Int(minutesSinceWorkout))") {
            Slider(value: $minutesSinceWorkout, in: 0...720, step: 5)
        }
    }

    func preview(_ avatar: AvatarState, time: Date, zone: Zone) -> some View {
        Section {
            HStack(spacing: 12) {
                LiveAvatarView(identity: model.identity, avatar: avatar, framing: .waistUp, time: time, zone: zone)
                    .frame(width: 120, height: 120)
                LiveAvatarView(identity: model.identity, avatar: avatar, time: time, zone: zone)
                    .frame(height: 240)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            Text(AvatarDescription.text(avatar, at: Instant(time))).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
