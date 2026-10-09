import CryptoKit
import Foundation

/// Immutable phone settings (backend/config/homeostat.yaml, all defaults).
/// Custom settings are not supported by this port: values cannot be mutated
/// while retaining the default configuration identity.
/// Product policies, not clinical thresholds. The phone uses exactly these;
/// `canonicalJSON` is the backend's canonical text of the same values, so the
/// config hash matches the Python engine (checked in EngineParityTests).
public struct EngineSettings: Sendable {
    public struct SourceGroup: Sendable {
        public let id: String
        public let bundleID: String?
        public let bundlePrefix: String?
        public let productTypePrefix: String?
        public let weight = 1.0

        init(id: String, bundleID: String? = nil, bundlePrefix: String? = nil,
             productTypePrefix: String? = nil) {
            self.id = id
            self.bundleID = bundleID
            self.bundlePrefix = bundlePrefix
            self.productTypePrefix = productTypePrefix
        }

        func matches(bundleID: String, productType: String?) -> Bool {
            if let id = self.bundleID, bundleID != id { return false }
            if let prefix = bundlePrefix, !bundleID.hasPrefix(prefix) { return false }
            if let prefix = productTypePrefix { return productType?.hasPrefix(prefix) ?? false }
            return true
        }
    }

    public struct Freshness: Sendable { public let fullHours: Double, zeroHours: Double }

    public let windowDays = 28
    public let minimumValidDays = 14
    public let sleepBelowMinutes = 60.0
    public let sleepAboveMinutes = 60.0
    public let episodeGapMinutes = 90.0
    /// The overnight window: this hour on the previous local day to `overnightEndHour` on the wake day.
    public let overnightStartHour = 18
    public let overnightEndHour = 12
    public let sourcePolicyVersion = "sleep-source-policy@0.1.0"
    public let zLower = -1.0, zUpper = 1.0, scaleFloor = 1.0  // HRV and resting HR alike
    public let behindRatio = 0.70, aheadRatio = 1.30, comparisonWindowMinutes = 60.0
    public let justCompletedHours = 2.0, recentHours = 12.0, totalsDays = 7
    public let sleepSeverityFullMinutes = 120.0
    public let freshness: [Domain: Freshness] = [
        .sleep: .init(fullHours: 24, zeroHours: 48), .hrv: .init(fullHours: 24, zeroHours: 48),
        .rhr: .init(fullHours: 24, zeroHours: 48), .movement: .init(fullHours: 1, zeroHours: 3),
    ]
    /// Matched in order (first match wins); the order is also source priority.
    public let sourceGroups: [SourceGroup] = [
        .init(id: "apple_watch", bundlePrefix: "com.apple.health.", productTypePrefix: "Watch"),
        .init(id: "synthetic_watch", bundleID: "org.homeostat.synthetic.watch"),
        .init(id: "apple_iphone", bundlePrefix: "com.apple.health.", productTypePrefix: "iPhone"),
        .init(id: "synthetic_phone", bundleID: "org.homeostat.synthetic.phone"),
        .init(id: "synthetic_sleep_app", bundleID: "org.homeostat.synthetic.sleepapp"),
    ]

    public init() {}

    public static let standard = EngineSettings()

    /// `settings_payload()` of the defaults, as the backend hashes it.
    static let canonicalJSON = #"{"baseline":{"minimum_valid_days":14,"window_days":28},"calculation_version":"features-calc@0.1.0","freshness":{"hrv":{"full_hours":24.0,"zero_hours":48.0},"movement":{"full_hours":1.0,"zero_hours":3.0},"rhr":{"full_hours":24.0,"zero_hours":48.0},"sleep":{"full_hours":24.0,"zero_hours":48.0}},"hrv":{"lower_z":-1.0,"scale_floor":1.0,"upper_z":1.0},"movement":{"ahead_ratio":1.3,"behind_ratio":0.7,"comparison_window_minutes":60.0},"rhr":{"lower_z":-1.0,"scale_floor":1.0,"upper_z":1.0},"schema_version":1,"sleep":{"above_minutes":60.0,"below_minutes":60.0,"episode_gap_minutes":90.0,"overnight_end":"12:00:00","overnight_start":"18:00:00","source_policy_version":"sleep-source-policy@0.1.0"},"source_groups":[{"bundle_id":null,"bundle_prefix":"com.apple.health.","id":"apple_watch","product_type_prefix":"Watch","weight":1.0},{"bundle_id":"org.homeostat.synthetic.watch","bundle_prefix":null,"id":"synthetic_watch","product_type_prefix":null,"weight":1.0},{"bundle_id":null,"bundle_prefix":"com.apple.health.","id":"apple_iphone","product_type_prefix":"iPhone","weight":1.0},{"bundle_id":"org.homeostat.synthetic.phone","bundle_prefix":null,"id":"synthetic_phone","product_type_prefix":null,"weight":1.0},{"bundle_id":"org.homeostat.synthetic.sleepapp","bundle_prefix":null,"id":"synthetic_sleep_app","product_type_prefix":null,"weight":1.0}],"state":{"sleep_severity_full_minutes":120.0},"workout":{"just_completed_hours":2.0,"recent_hours":12.0,"totals_days":7}}"#

    public static let configSHA256 = SHA256.hash(data: Data(canonicalJSON.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// A source group's place in priority order (configured rank, then id).
struct SourceRank: Hashable, Comparable {
    let rank: Int
    let id: String
    let weight: Double

    static func < (a: SourceRank, b: SourceRank) -> Bool { (a.rank, a.id) < (b.rank, b.id) }
    static func == (a: SourceRank, b: SourceRank) -> Bool { a.rank == b.rank && a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(rank); hasher.combine(id) }
}

extension EngineSettings {
    func group(of meta: EventMeta) -> SourceRank {
        for (rank, group) in sourceGroups.enumerated()
        where group.matches(bundleID: meta.sourceBundleID, productType: meta.productType) {
            return SourceRank(rank: rank, id: group.id, weight: group.weight)
        }
        return SourceRank(rank: sourceGroups.count,
                          id: "unknown:\(meta.sourceBundleID)|\(meta.productType ?? "unknown-device")", weight: 1)
    }
}
