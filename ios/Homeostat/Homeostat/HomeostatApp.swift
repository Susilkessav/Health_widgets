import HomeostatCore
import SwiftUI

@main
struct HomeostatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DebugView()
                .environmentObject(delegate.model)
                .task {
                    delegate.model.setForeground(scenePhase == .active)
                    if scenePhase == .active, delegate.model.snapshot.ledger.contains(where: { $0.status == "requested" }) {
                        await delegate.model.foregroundCatchUp()
                    }
                }
                .onOpenURL { url in
                    if url.host() == "explain" { delegate.model.openExplanation() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            delegate.model.setForeground(phase == .active)
            // Foreground catch-up is the guaranteed path; background delivery is best effort.
            guard phase == .active else { return }
            delegate.model.publishWidget(foreground: true)
            if delegate.model.snapshot.ledger.contains(where: { $0.status == "requested" }) {
                Task { await delegate.model.foregroundCatchUp() }
            }
        }
    }
}
