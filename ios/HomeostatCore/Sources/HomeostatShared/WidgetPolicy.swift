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

    /// The avatar a display draws (decided 2026-10-05). Today's result keeps its
    /// traits, dimmed by the widget once stale; an earlier day's keeps only the
    /// clock-driven workout effects. A missing or invalid avatar draws `.unknown`.
    ///
    /// When iOS redacts private content (Lock Screen, StandBy), the avatar is
    /// neutral: the person's look and the lighting, no health traits, effects or
    /// marker, since tired eyes say as much as the hidden text (decided 2026-10-05).
    public static func avatar(_ display: Display, redacted: Bool = false) -> AvatarState? {
        if redacted { return avatar(display).map { _ in AvatarState() } }
        return switch display {
        case .fresh(let cache), .stale(let cache): cache.widgetState.avatar ?? .unknown
        case .earlierDay(let cache): (cache.widgetState.avatar ?? .unknown).withoutDailyTraits
        case .empty, .unreadable: nil
        }
    }

    /// The instants at which the display changes: now, when it turns stale, the
    /// next local midnight, the next lighting change and the avatar's fading
    /// steps (one half-life apart until faded) up to that midnight. Strictly increasing.
    public static func timelineDates(_ result: SharedWidgetStore.ReadResult, now: Instant, zone: Zone) -> [Instant] {
        var dates = [now]
        if case .state(let cache) = result {
            let midnight = nextMidnight(after: now, zone: zone)
            dates.append(cache.widgetState.freshness.lastUpdatedAt.adding(seconds: staleAfterSeconds + 1))
            dates.append(midnight)
            let today = zone.day(of: now)
            dates += Lighting.boundaries.map { zone.instant(on: today, hour: $0) }
            // Only valid effects: a sub-minute half-life would make a zero step and loop forever.
            for effect in cache.widgetState.avatar?.effects ?? [] where effect.isValid {
                let step = Int64(effect.halfLifeMinutes * 60)
                var at = effect.startedAt.adding(seconds: step)
                while at <= effect.fadedAt, at < midnight {
                    dates.append(at)
                    at = at.adding(seconds: step)
                }
                dates.append(effect.fadedAt)
            }
            dates = dates.filter { $0 <= midnight }
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
