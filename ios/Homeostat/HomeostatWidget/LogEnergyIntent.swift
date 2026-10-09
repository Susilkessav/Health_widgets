import AppIntents
import HomeostatShared
import WidgetKit

enum EnergyLevel: String, AppEnum {
    case low, okay, high

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Energy"
    static let caseDisplayRepresentations: [EnergyLevel: DisplayRepresentation] = [
        .low: "Low", .okay: "Okay", .high: "High",
    ]
    var level: ReportedEnergy.Level { ReportedEnergy.Level(rawValue: rawValue)! }
}

/// The widget's energy check-in (System_architecture.md §4.3). Runs in the
/// widget process: it writes one command to the App Group inbox and never
/// touches the app's database. The app imports it on its next run.
struct LogEnergyIntent: AppIntent {
    static let title: LocalizedStringResource = "Record energy"
    static let isDiscoverable = false

    @Parameter(title: "Energy") var energy: EnergyLevel

    init() {}
    init(_ energy: EnergyLevel) { self.energy = energy }

    func perform() async throws -> some IntentResult {
        // Only for the account whose result is on screen; no result, no check-in.
        guard case .state(let cache)? = SharedWidgetStore.shared()?.read(), let inbox = CheckInInbox.shared() else {
            return .result()
        }
        try inbox.write(.energy(energy.level, at: Instant(Date()), zone: TimeZone.current.identifier, scope: cache.scope))
        return .result()  // WidgetKit reloads the timeline, which shows the pending entry
    }
}
