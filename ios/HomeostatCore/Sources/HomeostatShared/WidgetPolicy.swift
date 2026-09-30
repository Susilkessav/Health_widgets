import Foundation

/// How old what the widget shows is (Step 14-16 plan section 6). Display
/// policy only: it never interprets health values.
public enum WidgetPolicy {
    /// Stale after 90 minutes without newer data (decided 2026-09-25).
    public static let staleAfterSeconds: Int64 = 90 * 60

    public enum Display: Equatable, Sendable {
        case fresh(WidgetCache)
        case stale(WidgetCache)
        /// A state for a day before the device's current local day.
        case earlierDay(WidgetCache)
        case empty
        case unreadable(SharedWidgetStore.Unreadable)
    }

    public static func isStale(_ cache: WidgetCache, now: Instant) -> Bool {
        // A clock that runs behind the server's makes the age negative: fresh.
        now.microseconds - cache.widgetState.freshness.lastUpdatedAt.microseconds > staleAfterSeconds * 1_000_000
    }

    public static func display(_ result: SharedWidgetStore.ReadResult, now: Instant, zone: Zone) -> Display {
        switch result {
        case .none: return .empty
        case .unreadable(let reason): return .unreadable(reason)
        case .state(let cache):
            if cache.day != zone.day(of: now) { return .earlierDay(cache) }
            return isStale(cache, now: now) ? .stale(cache) : .fresh(cache)
        }
    }

    /// The instants at which the display changes: now, when it turns stale and
    /// the next local midnight. Strictly increasing.
    public static func timelineDates(_ result: SharedWidgetStore.ReadResult, now: Instant, zone: Zone) -> [Instant] {
        var dates = [now]
        if case .state(let cache) = result {
            dates.append(cache.widgetState.freshness.lastUpdatedAt.adding(seconds: staleAfterSeconds + 1))
            dates.append(nextMidnight(after: now, zone: zone))
        }
        return Array(Set(dates.filter { $0 >= now })).sorted()
    }

    /// When the widget should re-read the cache even without an app reload.
    public static func reloadAfter(now: Instant, zone: Zone) -> Instant {
        min(now.adding(seconds: 1800), nextMidnight(after: now, zone: zone).adding(seconds: 60))
    }

    static func nextMidnight(after now: Instant, zone: Zone) -> Instant {
        zone.start(of: zone.adding(days: 1, to: zone.day(of: now)))
    }
}
