import Foundation
import HomeostatCore
import HomeostatShared

/// M2 prototype (Plan/Plan.md §4 path 3): writes the engine inputs snapshot to the
/// App Group and times the widget's future work on it (read, decode, engine) in
/// the app, with the memory footprint. A stand-in for the widget's own run until
/// M3 moves the engine into the widget.
nonisolated enum EngineInputsProbe {
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedWidgetStore.appGroup)?
            .appendingPathComponent("engine/engine_inputs.json")
    }

    /// The snapshot is built from the app run's own inputs and recalculated at the
    /// same `now`, so the result must match the app's field for field.
    static func run(_ local: LocalStore.LocalRun, scope: String, now: Instant) throws -> String {
        guard let url = fileURL else { return "M2 snapshot: none (no App Group)" }
        let app = local.state
        let data = try local.snapshot(scope: scope)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let before = ProbeLog.footprintMB()
        let started = ContinuousClock.now
        let result = try LocalStore.calculate(snapshot: try Data(contentsOf: url), now: now)
        let elapsed = started.duration(to: .now).components
        let after = ProbeLog.footprintMB()
        var differs: [String] = []
        if result.revision != app.inputRevision { differs.append("revision \(app.inputRevision)→\(result.revision)") }
        if result.effective != app.effectiveAt { differs.append("effective") }
        if result.healthState != app.healthState { differs.append("healthState") }
        if result.widgetState != app.widgetState { differs.append("widgetState") }
        let oldest = local.oldestEvent.map { String($0.wire.prefix(10)) } ?? "none"
        return String(format: "M2 snapshot: %d KB, %d events from %@, read+decode+engine %.0f ms, footprint %.1f→%.1f MB, result %@",
                      data.count / 1024, local.eventCount, oldest, Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
                      before, after, differs.isEmpty ? "matches app" : "DIFFERS: " + differs.joined(separator: ", "))
    }

}
