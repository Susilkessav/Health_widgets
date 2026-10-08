import BackgroundTasks
import HomeostatCore
import UIKit
import WidgetKit

/// HealthKit background delivery and refresh tasks can launch the app with no
/// UI scene, so everything they need is set up here, not in a SwiftUI view
/// (Step 14-16 plan section 8).
final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        model.trace("protected data available (unlocked)")
        Task { await model.retryDeferredImport() }
    }

    func applicationProtectedDataWillBecomeUnavailable(_ application: UIApplication) {
        model.trace("protected data unavailable (locked)")
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppModel.refreshTaskID, using: .main) { [model] task in
            guard let task = task as? BGAppRefreshTask else { return task.setTaskCompleted(success: false) }
            MainActor.assumeIsolated { model.handleRefreshTask(task) }
        }
        model.refresh()
        if model.snapshot.ledger.contains(where: { $0.status == "requested" }) {
            model.registerObservers()
        }
        model.scheduleRefresh()
        // "Earlier day" and stale entries depend on the clock and zone.
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                WidgetCenter.shared.reloadTimelines(ofKind: AppModel.widgetKind)
            }
        }
        return true
    }
}
