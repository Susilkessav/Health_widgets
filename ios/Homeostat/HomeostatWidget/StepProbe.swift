import HealthKit
import HomeostatShared
import os

/// M2 prototype (Master plan §4 path 3): can the widget read today's steps from
/// HealthKit itself, with the app swiped away and with it running? Logs the
/// result (no samples is not 0 steps), the time it took, any error code and the
/// widget process's memory footprint to ProbeLog. Read-only; the app
/// grants Health access.
enum StepProbe {
    static let log = Logger(subsystem: "com.susil.homeostat", category: "widget")

    static func run() async {
        guard HKHealthStore.isHealthDataAvailable() else { return record("widget steps: Health data unavailable") }
        let started = ContinuousClock.now
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let before = ProbeLog.footprintMB()
        let store = HKHealthStore()
        let outcome: String = await withCheckedContinuation { done in
            // Resume once: with HealthKit's answer, or "timeout" after 5 s (stopping the query) so the widget never hangs.
            let lock = NSLock()
            var finished = false
            func finish(_ text: String) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                done.resume(returning: text)
            }
            let query = HKStatisticsQuery(quantityType: HKQuantityType(.stepCount), quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, statistics, error in
                if let error = error as NSError? {
                    finish(error.domain == HKErrorDomain && error.code == HKError.Code.errorNoData.rawValue
                           ? "no step samples today" : "error \(error.domain):\(error.code)")
                } else if let sum = statistics?.sumQuantity() {
                    finish("\(Int(sum.doubleValue(for: .count()))) steps today")
                } else {
                    finish("no step samples today")
                }
            }
            store.execute(query)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                store.stop(query)
                finish("timeout after 5 s")
            }
        }
        let elapsed = started.duration(to: .now).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        record("widget steps: \(outcome) (" + String(format: "%.0f ms, footprint %.1f→%.1f MB", ms, before, ProbeLog.footprintMB()) + ")")
    }

    static func record(_ line: String) {
        log.notice("\(line, privacy: .public)")
        ProbeLog.append(line)
    }
}
