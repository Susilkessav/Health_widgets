import Foundation
import HealthKit
import HomeostatCore

/// HealthKit behind `HealthDataSource`. Reads only; never writes to HealthKit.
final class HealthKitSource: HealthDataSource, @unchecked Sendable {
    let store: HKHealthStore

    init(store: HKHealthStore) {
        self.store = store
    }

    static let stepType = HKQuantityType(.stepCount)

    static func sampleType(_ type: SampleType) -> HKSampleType {
        switch type {
        case .sleep: HKCategoryType(.sleepAnalysis)
        case .hrv: HKQuantityType(.heartRateVariabilitySDNN)
        case .rhr: HKQuantityType(.restingHeartRate)
        case .workout: HKWorkoutType.workoutType()
        }
    }

    /// Every type Homeostat reads (G1 plan section 6).
    static var readTypes: Set<HKObjectType> {
        Set(SampleType.allCases.map(sampleType) + [stepType])
    }

    func anchoredPage(_ type: SampleType, since lowerBound: Instant, anchor: Data?, limit: Int) async throws -> AnchoredPage {
        var queryAnchor: HKQueryAnchor?
        if let anchor {
            // A stored anchor that no longer decodes triggers recovery, never a silent reset.
            guard let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: anchor) else {
                throw HealthSourceError.corruptAnchor
            }
            queryAnchor = decoded
        }
        // No strict-start option: samples overlapping [lowerBound, now] are included.
        let predicate = HKQuery.predicateForSamples(withStart: lowerBound.date, end: nil, options: [])
        let result: (added: [HKSample], deleted: [HKDeletedObject], anchor: HKQueryAnchor)
        switch type {
        case .workout:
            result = try await run(HKAnchoredObjectQueryDescriptor(
                predicates: [.workout(predicate)], anchor: queryAnchor, limit: limit))
        case .sleep:
            result = try await run(HKAnchoredObjectQueryDescriptor(
                predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
                anchor: queryAnchor, limit: limit))
        case .hrv, .rhr:
            result = try await run(HKAnchoredObjectQueryDescriptor(
                predicates: [.quantitySample(type: Self.sampleType(type) as! HKQuantityType, predicate: predicate)],
                anchor: queryAnchor, limit: limit))
        }
        let archived = try NSKeyedArchiver.archivedData(withRootObject: result.anchor, requiringSecureCoding: true)
        return AnchoredPage(samples: result.added.compactMap(Self.raw), deleted: result.deleted.map(\.uuid),
                            anchor: archived, hasMore: result.added.count + result.deleted.count >= limit)
    }

    private func run<S: HKSample>(_ descriptor: HKAnchoredObjectQueryDescriptor<S>) async throws
        -> (added: [HKSample], deleted: [HKDeletedObject], anchor: HKQueryAnchor) {
        let result = try await descriptor.result(for: store)
        return (result.addedSamples, result.deletedObjects, result.newAnchor)
    }

    func hourlySteps(from start: Instant, to end: Instant, zone: String) async throws -> [HourlyBucket] {
        guard end > start else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start.date, end: end.date, options: [])
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: Self.stepType, predicate: predicate), options: .cumulativeSum,
            anchorDate: start.date, intervalComponents: DateComponents(hour: 1))
        let collection = try await descriptor.result(for: store)
        var buckets: [HourlyBucket] = []
        // HealthKit merges overlapping sources itself; a successful empty bucket is 0.
        collection.enumerateStatistics(from: start.date, to: end.date) { statistics, _ in
            let steps = statistics.sumQuantity()?.doubleValue(for: .count()) ?? 0
            buckets.append(HourlyBucket(start: Instant(statistics.startDate), end: min(end, Instant(statistics.endDate)),
                                        steps: Int64(steps.rounded())))
        }
        return buckets
    }

    // MARK: - HealthKit sample -> RawSample

    static func raw(_ sample: HKSample) -> RawSample? {
        let kind: RawSample.Kind
        switch sample {
        case let quantity as HKQuantitySample where quantity.quantityType == HKQuantityType(.heartRateVariabilitySDNN):
            kind = .hrvSDNN(milliseconds: quantity.quantity.doubleValue(for: .secondUnit(with: .milli)))
        case let quantity as HKQuantitySample where quantity.quantityType == HKQuantityType(.restingHeartRate):
            kind = .restingHR(beatsPerMinute: quantity.quantity.doubleValue(for: .count().unitDivided(by: .minute())))
        case let category as HKCategorySample:
            kind = .sleep(sleepStage(category.value))
        case let workout as HKWorkout:
            kind = .workout(activityType: activityName(workout.workoutActivityType), durationMinutes: workout.duration / 60)
        default:
            return nil
        }
        var metadata: [String: String] = [:]
        for (key, value) in sample.metadata ?? [:] where key != HKMetadataKeyTimeZone {
            metadata[key] = stringify(value)
        }
        let revision = sample.sourceRevision
        return RawSample(uuid: sample.uuid, kind: kind, start: Instant(sample.startDate), end: Instant(sample.endDate),
                         sourceName: revision.source.name, sourceBundleID: revision.source.bundleIdentifier,
                         sourceRevision: revision.version, productType: revision.productType,
                         sampleTimeZone: sample.metadata?[HKMetadataKeyTimeZone] as? String, metadata: metadata,
                         rawCategoryValue: (sample as? HKCategorySample)?.value)
    }

    static func sleepStage(_ value: Int) -> SleepStage? {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .inBed: .inBed
        case .awake: .awake
        case .asleepUnspecified: .asleepUnspecified
        case .asleepCore: .asleepCore
        case .asleepDeep: .asleepDeep
        case .asleepREM: .asleepREM
        default: nil  // quarantined, never guessed
        }
    }

    /// Names the widget's label table knows; any other type keeps a stable raw identifier.
    static func activityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .traditionalStrengthTraining: "traditional_strength_training"
        case .functionalStrengthTraining: "functional_strength_training"
        case .running: "running"
        case .walking: "walking"
        case .cycling: "cycling"
        case .yoga: "yoga"
        case .swimming: "swimming"
        case .hiking: "hiking"
        default: "hk_activity_\(type.rawValue)"
        }
    }

    static func stringify(_ value: Any) -> String {
        switch value {
        case let text as String: text
        case let date as Date: Instant(date).wire
        case let quantity as HKQuantity: quantity.description
        case let number as NSNumber: number.stringValue
        default: String(describing: value)
        }
    }
}
