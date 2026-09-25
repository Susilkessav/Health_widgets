import Foundation

/// A HealthKit sample, already read out of HealthKit's own types by the app's
/// adapter. Keeping this neutral lets normalization be tested without HealthKit.
public struct RawSample: Hashable, Codable, Sendable {
    public enum Kind: Hashable, Codable, Sendable {
        case hrvSDNN(milliseconds: Double)
        case restingHR(beatsPerMinute: Double)
        /// `nil` stage: a sleep value this app doesn't recognize.
        case sleep(SleepStage?)
        case workout(activityType: String, durationMinutes: Double)
    }

    public var uuid: UUID
    public var kind: Kind
    public var start: Instant
    public var end: Instant
    public var sourceName: String
    public var sourceBundleID: String
    public var sourceRevision: String?
    public var productType: String?
    /// HKMetadataKeyTimeZone, if the sample had one.
    public var sampleTimeZone: String?
    /// Other metadata, already stringified (ISO 8601 dates, "<value> <unit>" quantities).
    public var metadata: [String: String]
    /// Original category value, including values unknown to this app version.
    public var rawCategoryValue: Int?

    public init(uuid: UUID, kind: Kind, start: Instant, end: Instant, sourceName: String, sourceBundleID: String,
                sourceRevision: String? = nil, productType: String? = nil, sampleTimeZone: String? = nil,
                metadata: [String: String] = [:], rawCategoryValue: Int? = nil) {
        self.uuid = uuid
        self.kind = kind
        self.start = start
        self.end = end
        self.sourceName = sourceName
        self.sourceBundleID = sourceBundleID
        self.sourceRevision = sourceRevision
        self.productType = productType
        self.sampleTimeZone = sampleTimeZone
        self.metadata = metadata
        self.rawCategoryValue = rawCategoryValue
    }

    public var domain: Domain {
        switch kind {
        case .hrvSDNN: .hrv
        case .restingHR: .rhr
        case .sleep: .sleep
        case .workout: .workout
        }
    }
}

/// Why a sample couldn't become a canonical event. Stored durably, never skipped.
public struct Quarantined: Hashable, Sendable {
    public var domain: Domain
    public var sourceRecordID: String
    public var reason: String
}

public enum Normalized: Hashable, Sendable {
    case event(CanonicalEvent)
    case quarantined(Quarantined)
}

/// Maps raw samples to canonical events. Enforces the same rules the backend
/// contracts do, so a sample the server would reject is quarantined here.
public struct Normalizer: Sendable {
    /// Used when a sample carries no valid timezone of its own.
    public let deviceZone: String

    public init(deviceZone: String) {
        self.deviceZone = deviceZone
    }

    static let healthKitTypes: [Domain: String] = [
        .hrv: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
        .rhr: "HKQuantityTypeIdentifierRestingHeartRate",
        .sleep: "HKCategoryTypeIdentifierSleepAnalysis",
        .workout: "HKWorkoutTypeIdentifier",
    ]

    public func normalize(_ sample: RawSample, eventID: UUID) -> Normalized {
        let recordID = sample.uuid.uuidString.lowercased()
        func reject(_ reason: String) -> Normalized {
            .quarantined(Quarantined(domain: sample.domain, sourceRecordID: recordID, reason: reason))
        }
        guard !sample.sourceName.trimmingCharacters(in: .whitespaces).isEmpty,
              !sample.sourceBundleID.trimmingCharacters(in: .whitespaces).isEmpty else {
            return reject("MISSING_SOURCE")
        }
        guard sample.end >= sample.start else { return reject("END_BEFORE_START") }

        // The sample's own zone when it has a valid one, else the device zone now.
        let zone: String, zoneSource: SampleMetadata.TimezoneSource
        if let own = sample.sampleTimeZone, Zone(own) != nil {
            (zone, zoneSource) = (own, .sampleMetadata)
        } else {
            (zone, zoneSource) = (deviceZone, .deviceAtIngestion)
        }
        let metadata = SampleMetadata(
            healthKitType: Normalizer.healthKitTypes[sample.domain]!, sourceName: sample.sourceName,
            sourceBundleID: sample.sourceBundleID,
            sourceRevision: sample.sourceRevision.flatMap { $0.isEmpty ? nil : $0 },
            deviceProductType: sample.productType.flatMap { $0.isEmpty ? nil : $0 },
            timezone: zone, timezoneSource: zoneSource, sampleStart: sample.start, sampleEnd: sample.end,
            providerMetadata: sample.metadata)

        switch sample.kind {
        case .hrvSDNN(let value), .restingHR(let value):
            guard value.isFinite, value > 0 else { return reject("NON_POSITIVE_VALUE") }
            let metric: CanonicalEvent.Point.Metric = sample.domain == .hrv ? .hrvSDNN : .restingHR
            // Observed when the measurement completed: the sample's end.
            return .event(.point(.init(eventID: eventID, sourceRecordID: recordID, metric: metric,
                                       observedAt: sample.end, value: value, metadata: metadata)))
        case .sleep(let stage):
            guard let stage else { return reject("UNKNOWN_SLEEP_VALUE") }
            guard sample.start < sample.end else { return reject("ZERO_LENGTH_INTERVAL") }
            return .event(.interval(.init(eventID: eventID, sourceRecordID: recordID, stage: stage,
                                          start: sample.start, end: sample.end, metadata: metadata)))
        case .workout(let activity, let minutes):
            guard sample.start < sample.end else { return reject("ZERO_LENGTH_INTERVAL") }
            guard !activity.isEmpty else { return reject("MISSING_WORKOUT_TYPE") }
            let elapsed = Double(sample.end.microseconds - sample.start.microseconds) / 60_000_000
            guard minutes.isFinite, minutes >= 0, minutes <= elapsed + 1 else { return reject("DURATION_EXCEEDS_INTERVAL") }
            return .event(.workout(.init(eventID: eventID, sourceRecordID: recordID, workoutType: activity,
                                         start: sample.start, end: sample.end, durationMinutes: minutes,
                                         metadata: metadata)))
        }
    }
}
