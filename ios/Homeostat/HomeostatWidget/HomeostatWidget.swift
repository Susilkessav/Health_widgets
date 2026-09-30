import HomeostatShared
import SwiftUI
import WidgetKit

/// The Home Screen widget (Step 14-16 plan section 5). It only renders the
/// server's WidgetState: no HealthKit or health calculation in the extension. The one
/// decision it makes is how old what it shows is (WidgetPolicy).

struct Entry: TimelineEntry {
    let date: Date
    let display: WidgetPolicy.Display
}

struct Provider: TimelineProvider {
    static let sample = WidgetCache(
        scope: "sample", day: LocalDay(year: 2026, month: 9, day: 22), inputRevision: 0, runID: 0,
        widgetState: WidgetState(effectiveAt: Instant(Date()),
                                 presentation: .init(icon: "🙂", headline: "Typical day",
                                                     detail: "Sleep, recovery and movement as usual"),
                                 primaryTrait: .init(id: "typical", explainable: true),
                                 freshness: .init(lastUpdatedAt: Instant(Date()))))

    func read() -> SharedWidgetStore.ReadResult {
        SharedWidgetStore.shared()?.read() ?? .unreadable(.unavailable)
    }

    var zone: Zone { Zone(TimeZone.current.identifier) ?? Zone("UTC")! }

    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), display: .fresh(Self.sample))
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        let result = read()
        let now = Instant(Date())
        if context.isPreview, case .state = result {} else if context.isPreview {
            return completion(placeholder(in: context))  // the gallery shows a sample until there is data
        }
        completion(Entry(date: now.date, display: WidgetPolicy.display(result, now: now, zone: zone)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        Task {
            if let store = SharedWidgetStore.shared() { await WidgetClient.refresh(store: store) }
            let result = read()
            let now = Instant(Date())
            let zone = self.zone
            let entries = WidgetPolicy.timelineDates(result, now: now, zone: zone).map {
                Entry(date: $0.date, display: WidgetPolicy.display(result, now: $0, zone: zone))
            }
            let retry = (try? SharedWidgetStore.shared()?.manifest())?.fetch.nextAttemptAt
            let next = max(now.adding(seconds: 60), retry ?? WidgetPolicy.reloadAfter(now: now, zone: zone))
            completion(Timeline(entries: entries, policy: .after(next.date)))
        }
    }
}

// MARK: - Parts every size is built from (large can reuse them later)

struct HeadlineBlock: View {
    let presentation: WidgetState.Presentation
    var iconSize: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(presentation.icon).font(.system(size: iconSize))
            Text(presentation.headline)
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }
}

struct DetailLine: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text).font(.subheadline).lineLimit(2).minimumScaleFactor(0.8).privacySensitive()
        }
    }
}

struct SecondaryLine: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2).privacySensitive()
        }
    }
}

struct FreshnessLine: View {
    let display: WidgetPolicy.Display

    var body: some View {
        Group {
            switch display {
            case .fresh(let cache):
                Text("Updated \(Text(cache.widgetState.freshness.lastUpdatedAt.date, style: .time))")
            case .stale(let cache):
                Text("Updated \(Text(cache.widgetState.freshness.lastUpdatedAt.date, style: .relative)) ago")
            case .earlierDay:
                Text("Open Homeostat to update")
            case .empty, .unreadable:
                EmptyView()
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

struct DayLabel: View {
    let day: LocalDay

    var body: some View {
        let zone = Zone(TimeZone.current.identifier) ?? Zone("UTC")!
        let yesterday = zone.adding(days: -1, to: zone.day(of: Instant(Date())))
        Text(day == yesterday ? "Yesterday" : zone.start(of: day).date.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated)))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Layouts

struct HomeostatWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .combine)
            .widgetURL(link)
    }

    var link: URL? {
        switch entry.display {
        case .fresh(let cache), .stale(let cache), .earlierDay(let cache):
            var parts = URLComponents(string: "homeostat://explain")!
            parts.queryItems = [.init(name: "scope", value: cache.scope), .init(name: "run", value: String(cache.runID))]
            return parts.url
        default: return nil
        }
    }

    @ViewBuilder var content: some View {
        switch entry.display {
        case .fresh(let cache), .stale(let cache), .earlierDay(let cache):
            stateLayout(cache).opacity(isStale ? 0.6 : 1)
        case .empty:
            message("🙂", "Open Homeostat to get started")
        case .unreadable(.version):
            message("⬆️", "Update Homeostat")
        case .unreadable(.unavailable):
            message("🙂", "Open Homeostat")
        }
    }

    var isStale: Bool {
        if case .stale = entry.display { return true }
        return false
    }

    @ViewBuilder func stateLayout(_ cache: WidgetCache) -> some View {
        let p = cache.widgetState.presentation
        let earlier: Bool = { if case .earlierDay = entry.display { return true } else { return false } }()
        switch family {
        case .systemMedium:
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if earlier { DayLabel(day: cache.day) }
                    HeadlineBlock(presentation: p, iconSize: 40)
                    DetailLine(text: p.detail)
                    SecondaryLine(text: p.secondary)
                    Spacer(minLength: 0)
                    FreshnessLine(display: entry.display)
                }
                Spacer(minLength: 0)
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                if earlier { DayLabel(day: cache.day) }
                HeadlineBlock(presentation: p)
                DetailLine(text: p.detail)
                Spacer(minLength: 0)
                FreshnessLine(display: entry.display)
            }
        }
    }

    func message(_ icon: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(icon).font(.system(size: 34))
            Text(text).font(.headline).lineLimit(3).minimumScaleFactor(0.8)
        }
    }
}

struct HomeostatWidget: Widget {
    let kind = "HomeostatWidget"  // unchanged, so widgets already added keep working

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            HomeostatWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Homeostat")
        .description("How today compares with your usual, from your Health data.")
        .supportedFamilies([.systemSmall, .systemMedium])  // large later (plan section 5)
    }
}

// MARK: - Previews: every display state, and the longest backend strings

private func previewCache(_ presentation: WidgetState.Presentation, trait: String = "sleep",
                          updated: Date = Date(), day: LocalDay? = nil) -> WidgetCache {
    let zone = Zone(TimeZone.current.identifier)!
    return WidgetCache(scope: "preview", day: day ?? zone.day(of: Instant(Date())), inputRevision: 1, runID: 1,
                       widgetState: WidgetState(effectiveAt: Instant(updated), presentation: presentation,
                                                primaryTrait: .init(id: trait, explainable: true),
                                                freshness: .init(lastUpdatedAt: Instant(updated))))
}

private let shorterSleep = WidgetState.Presentation(icon: "😴", headline: "Shorter sleep", detail: "5h 58m",
                                                    secondary: "Strength training completed recently")
private let longest = WidgetState.Presentation(icon: "🔋", headline: "Recovery signals above usual",
                                               detail: "Based on sleep, HRV and resting HR",
                                               secondary: "Strength training completed recently")
private let calibrating = WidgetState.Presentation(icon: "🙂", headline: "Learning your baseline",
                                                   detail: "9 / 14 usable days")
private let noData = WidgetState.Presentation(icon: "⏳", headline: "Waiting for new data",
                                              detail: "Open Homeostat to sync Health data")

#Preview("Small", as: .systemSmall) {
    HomeostatWidget()
} timeline: {
    Entry(date: .now, display: .fresh(previewCache(shorterSleep)))
    Entry(date: .now, display: .fresh(previewCache(longest, trait: "recovery")))
    Entry(date: .now, display: .stale(previewCache(shorterSleep, updated: .now.addingTimeInterval(-3 * 3600))))
    Entry(date: .now, display: .earlierDay(previewCache(shorterSleep, day: LocalDay(year: 2026, month: 9, day: 21))))
    Entry(date: .now, display: .fresh(previewCache(calibrating, trait: "calibration")))
    Entry(date: .now, display: .fresh(previewCache(noData, trait: "no_data")))
    Entry(date: .now, display: .empty)
    Entry(date: .now, display: .unreadable(.version))
}

#Preview("Medium", as: .systemMedium) {
    HomeostatWidget()
} timeline: {
    Entry(date: .now, display: .fresh(previewCache(shorterSleep)))
    Entry(date: .now, display: .fresh(previewCache(longest, trait: "recovery")))
    Entry(date: .now, display: .stale(previewCache(longest, updated: .now.addingTimeInterval(-3 * 3600))))
    Entry(date: .now, display: .fresh(previewCache(calibrating, trait: "calibration")))
}
