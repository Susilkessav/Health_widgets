import CryptoKit
import Foundation

/// A JSON value with explicit integers and doubles, encoded with sorted keys.
public indirect enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The same value as `JSONDecoder().decode(JSONValue.self, from:)`, about 15x faster
    /// (the whole event log is parsed on every calculation). Follows the decoder's
    /// number rule: an integral number that fits Int64 is `.int` (also `1.0`, `1e2`),
    /// anything else `.double`. Integers beyond 2^53 written with a fraction or
    /// exponent can differ in the last digit; health events don't contain them.
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONValue(foundation: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(foundation value: Any) {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if !CFNumberIsFloatType(number) {
                // "Q": an unsigned value above Int64.max, which the decoder reads as a double.
                self = String(cString: number.objCType) == "Q" && number.uint64Value > UInt64(Int64.max)
                    ? .double(number.doubleValue) : .int(number.int64Value)
            } else {
                let d = number.doubleValue
                self = d.rounded() == d ? Int64(exactly: d).map(JSONValue.int) ?? .double(d) : .double(d)
            }
        case let text as String: self = .string(text)
        case let array as [Any]: self = .array(array.map(JSONValue.init(foundation:)))
        case let object as [String: Any]: self = .object(object.mapValues(JSONValue.init(foundation:)))
        default: self = .null  // NSNull
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Canonical bytes: sorted keys, no whitespace, `/` unescaped.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try! encoder.encode(self)
    }
}

public enum Domain: String, Codable, Sendable, CaseIterable {
    case sleep, hrv, rhr, movement, workout
}

/// Provenance for one HealthKit sample (backend `SampleMetadata`).
public struct SampleMetadata: Hashable, Sendable {
    public var healthKitType: String
    public var sourceName: String
    public var sourceBundleID: String
    public var sourceRevision: String?
    public var deviceProductType: String?
    public var timezone: String
    public var timezoneSource: TimezoneSource
    public var sampleStart: Instant
    public var sampleEnd: Instant
    public var providerMetadata: [String: String]

    public enum TimezoneSource: String, Sendable {
        case sampleMetadata = "sample_metadata"
        case deviceAtIngestion = "device_at_ingestion"
    }

    var json: JSONValue {
        .object([
            "healthkit_type": .string(healthKitType),
            "source_name": .string(sourceName),
            "source_bundle_id": .string(sourceBundleID),
            "source_revision": sourceRevision.map(JSONValue.string) ?? .null,
            "device_product_type": deviceProductType.map(JSONValue.string) ?? .null,
            "timezone": .string(timezone),
            "timezone_source": .string(timezoneSource.rawValue),
            "sample_start_at": .string(sampleStart.wire),
            "sample_end_at": .string(sampleEnd.wire),
            "provider_metadata": .array(providerMetadata.keys.sorted().map {
                .object(["key": .string($0), "value": .string(providerMetadata[$0]!)])
            }),
        ])
    }
}

/// The canonical events the backend accepts (backend `canonical_events.py`).
public enum CanonicalEvent: Hashable, Sendable {
    case point(Point)
    case interval(Interval)
    case workout(Workout)
    case snapshot(Snapshot)
    case delete(Delete)

    public struct Point: Hashable, Sendable {
        public var eventID: UUID, sourceRecordID: String
        public var metric: Metric, observedAt: Instant, value: Double
        public var metadata: SampleMetadata
        public enum Metric: String, Sendable { case hrvSDNN = "hrv_sdnn_ms", restingHR = "resting_hr_bpm" }
        public var unit: String { metric == .hrvSDNN ? "ms" : "bpm" }
    }

    public struct Interval: Hashable, Sendable {
        public var eventID: UUID, sourceRecordID: String
        public var stage: SleepStage, start: Instant, end: Instant
        public var metadata: SampleMetadata
    }

    public struct Workout: Hashable, Sendable {
        public var eventID: UUID, sourceRecordID: String
        public var workoutType: String, start: Instant, end: Instant, durationMinutes: Double
        public var metadata: SampleMetadata
    }

    /// Cumulative steps for local `day` in `timezone` up to `asOf`, read at `queriedAt`.
    public struct Snapshot: Hashable, Sendable {
        public var eventID: UUID
        public var day: LocalDay, timezone: String, asOf: Instant, queriedAt: Instant, steps: Int64
        public var sourceRecordID: String {
            snapshotRecordID(timezone: timezone, day: day, asOf: asOf, queriedAt: queriedAt, steps: steps)
        }
    }

    public struct Delete: Hashable, Sendable {
        public var eventID: UUID, sourceRecordID: String, deletedAt: Instant
    }

    public var eventID: UUID {
        switch self {
        case .point(let e): e.eventID
        case .interval(let e): e.eventID
        case .workout(let e): e.eventID
        case .snapshot(let e): e.eventID
        case .delete(let e): e.eventID
        }
    }

    public var sourceRecordID: String {
        switch self {
        case .point(let e): e.sourceRecordID
        case .interval(let e): e.sourceRecordID
        case .workout(let e): e.sourceRecordID
        case .snapshot(let e): e.sourceRecordID
        case .delete(let e): e.sourceRecordID
        }
    }

    public var eventType: String {
        switch self {
        case .point: "point_measurement"
        case .interval: "interval"
        case .workout: "workout"
        case .snapshot: "daily_activity_snapshot"
        case .delete: "delete"
        }
    }

    /// The wire JSON. Keys and values follow the Python contracts exactly.
    public var json: JSONValue {
        var fields: [String: JSONValue] = [
            "schema_version": .string("1.0.0"),
            "event_id": .string(eventID.uuidString.lowercased()),
            "source": .string("healthkit"),
            "source_record_id": .string(sourceRecordID),
            "event_type": .string(eventType),
        ]
        switch self {
        case .point(let e):
            fields["metric"] = .string(e.metric.rawValue)
            fields["observed_at"] = .string(e.observedAt.wire)
            fields["value"] = .double(e.value)
            fields["unit"] = .string(e.unit)
            fields["metadata"] = e.metadata.json
        case .interval(let e):
            fields["kind"] = .string("sleep_stage")
            fields["value"] = .string(e.stage.rawValue)
            fields["start_at"] = .string(e.start.wire)
            fields["end_at"] = .string(e.end.wire)
            fields["metadata"] = e.metadata.json
        case .workout(let e):
            fields["workout_type"] = .string(e.workoutType)
            fields["start_at"] = .string(e.start.wire)
            fields["end_at"] = .string(e.end.wire)
            fields["duration_minutes"] = .double(e.durationMinutes)
            fields["metadata"] = e.metadata.json
        case .snapshot(let e):
            fields["day"] = .string(e.day.description)
            fields["timezone"] = .string(e.timezone)
            fields["as_of"] = .string(e.asOf.wire)
            fields["queried_at"] = .string(e.queriedAt.wire)
            fields["steps"] = .int(e.steps)
        case .delete(let e):
            fields["deleted_at"] = .string(e.deletedAt.wire)
        }
        return .object(fields)
    }

    /// Identity of the provider content, excluding the client event ID, for
    /// local dedupe of re-queried samples (the server has its own rule).
    public var contentHash: String {
        guard case .object(var fields) = json else { return "" }
        fields["event_id"] = nil
        return SHA256.hash(data: JSONValue.object(fields).encoded()).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SleepStage: String, Hashable, Codable, Sendable {
    case inBed = "in_bed", awake, asleepUnspecified = "asleep_unspecified"
    case asleepCore = "asleep_core", asleepDeep = "asleep_deep", asleepREM = "asleep_rem"
}

/// Exactly the backend's `snapshot_record_id`: the total is part of the
/// identity, and times use Python's `isoformat()` in UTC.
public func snapshotRecordID(timezone: String, day: LocalDay, asOf: Instant, queriedAt: Instant, steps: Int64) -> String {
    "steps:\(timezone):\(day):\(asOf.pythonISO):\(queriedAt.pythonISO):\(steps)"
}
