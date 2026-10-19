import HealthKit
import HomeostatEngine
import HomeostatShared
import os

/// Widget self-refresh (Plan/Plan.md §4 path 3, M3): read today's steps from
/// HealthKit and recalculate the app's last run with them, through the same
/// engine the app uses. Read-only. Any failure keeps the cached result.
enum WidgetRefresh {
    static let log = Logger(subsystem: "com.susil.homeostat", category: "widget")

    enum StepRead: CustomStringConvertible {
        case steps(Int64), noSamples, failed(String), timedOut, unavailable
        var description: String {
            switch self {
            case .steps(let n): "\(n) steps"
            case .noSamples: "no step samples today"  // never treated as 0 steps
            case .failed(let code): "error \(code)"
            case .timedOut: "timeout after 5 s"
            case .unavailable: "Health data unavailable"
            }
        }
    }

    static func run(now: Date = Date()) async {
        guard let shared = SharedWidgetStore.shared(), case .state(let cache) = shared.read(),
              let url = SharedWidgetStore.engineInputsURL, let inputs = try? EngineSnapshot.read(from: url) else {
            return record("widget refresh: skipped (no cached result, unreadable or oversized inputs)")
        }
        let started = ContinuousClock.now, before = ProbeLog.footprintMB()
        let at = Instant(now)
        let read = await readSteps(from: Calendar.current.startOfDay(for: now), to: now)
        var outcome = "kept cache"
        if case .steps(let steps) = read {
            do {
                let result = try EngineSnapshot.calculate(inputs, now: at, steps: .init(steps: steps, at: at))
                let header = result.header
                if header.scope == cache.scope, header.inputRevision == cache.inputRevision, header.runID == cache.runID,
                   header.zone == TimeZone.current.identifier {
                    let next = WidgetCache(scope: cache.scope, day: header.day, inputRevision: cache.inputRevision,
                                           runID: cache.runID, widgetState: result.widgetState, stepsThrough: at,
                                           facts: DisplayFacts(healthState: result.healthState), report: cache.report)
                    outcome = "\(try shared.write(next, now: at))"
                } else {
                    outcome = "kept cache (inputs from another run or zone)"
                }
            } catch {
                outcome = "kept cache (\(error))"
            }
        }
        let elapsed = started.duration(to: .now).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        record("widget refresh: \(read) → \(outcome) ("
               + String(format: "%.0f ms, footprint %.1f→%.1f MB", ms, before, ProbeLog.footprintMB()) + ")")
    }

    /// Today's cumulative steps, or why there are none. The query is stopped at the deadline.
    static func readSteps(from start: Date, to end: Date) async -> StepRead {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let store = HKHealthStore()
        return await withCheckedContinuation { done in
            let lock = NSLock()
            var finished = false
            func finish(_ read: StepRead) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                done.resume(returning: read)
            }
            let query = HKStatisticsQuery(quantityType: HKQuantityType(.stepCount), quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, statistics, error in
                if let error = error as NSError? {
                    finish(error.domain == HKErrorDomain && error.code == HKError.Code.errorNoData.rawValue
                           ? .noSamples : .failed("\(error.domain):\(error.code)"))
                } else if let sum = statistics?.sumQuantity() {
                    finish(.steps(Int64(sum.doubleValue(for: .count()))))
                } else {
                    finish(.noSamples)
                }
            }
            store.execute(query)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                store.stop(query)
                finish(.timedOut)
            }
        }
    }

    static func record(_ line: String) {
        log.notice("\(line, privacy: .public)")
        ProbeLog.append(line)
    }
}
