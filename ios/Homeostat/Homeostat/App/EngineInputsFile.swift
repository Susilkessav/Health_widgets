import Foundation
import HomeostatCore

/// Writes the widget's input file (EngineSnapshot) after each app run, so the
/// widget can recalculate with its own step read (Plan/Plan.md §4 path 3).
nonisolated enum EngineInputsFile {
    static func write(_ run: LocalStore.LocalRun, scope: String) -> String {
        guard let url = SharedWidgetStore.engineInputsURL else { return "engine inputs: no App Group" }
        do {
            let data = try run.snapshot(scope: scope)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let oldest = run.oldestEvent.map { String($0.wire.prefix(10)) } ?? "none"
            return "engine inputs: \(data.count / 1024) KB, \(run.eventCount) events from \(oldest), run \(run.state.runID)"
        } catch {
            remove()  // never leave an older run's inputs behind
            return "engine inputs: not written (\(error))"
        }
    }

    static func remove() {
        if let url = SharedWidgetStore.engineInputsURL { try? FileManager.default.removeItem(at: url) }
    }
}
