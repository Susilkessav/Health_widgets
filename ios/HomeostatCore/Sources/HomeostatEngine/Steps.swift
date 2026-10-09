import Foundation

public struct HourlyBucket: Hashable, Sendable {
    public var start: Instant, end: Instant, steps: Int64
    public init(start: Instant, end: Instant, steps: Int64) {
        self.start = start
        self.end = end
        self.steps = steps
    }
}

/// Cumulative snapshots for one local day: one per completed hourly boundary
/// (the last is the day's closing boundary) plus, for today, one at `through`.
public func stepSnapshots(day: LocalDay, zone: Zone, buckets: [HourlyBucket], through: Instant,
                          queriedAt: Instant, makeID: () -> UUID = UUID.init) -> [CanonicalEvent.Snapshot] {
    let dayEnd = zone.start(of: zone.adding(days: 1, to: day))
    var total: Int64 = 0
    var result: [CanonicalEvent.Snapshot] = []
    for bucket in buckets.sorted(by: { $0.start < $1.start }) {
        total += bucket.steps
        if bucket.end <= through && bucket.end <= dayEnd {
            result.append(.init(eventID: makeID(), day: day, timezone: zone.identifier, asOf: bucket.end,
                                queriedAt: queriedAt, steps: total))
        }
    }
    if through < dayEnd && result.last?.asOf != through {
        result.append(.init(eventID: makeID(), day: day, timezone: zone.identifier, asOf: through,
                            queriedAt: queriedAt, steps: total))
    }
    return result
}
