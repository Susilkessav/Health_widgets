import HomeostatCore
import SwiftUI

@main
struct HomeostatApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DebugView()
                .environmentObject(model)
                .task {
                    model.setForeground(scenePhase == .active)
                    // Observers are registered early on launch once access was requested.
                    if model.snapshot.ledger.contains(where: { $0.status == "requested" }) || model.isConfigured {
                        model.refresh()
                        if model.snapshot.ledger.contains(where: { $0.status == "requested" }) {
                            model.registerObservers()
                        }
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            model.setForeground(phase == .active)
            // Foreground catch-up is the guaranteed path; background delivery is best effort.
            if phase == .active, model.snapshot.ledger.contains(where: { $0.status == "requested" }) {
                Task { await model.catchUp() }
            }
        }
    }
}
