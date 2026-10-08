import BackgroundTasks
import Combine
import CryptoKit
import Foundation
import HealthKit
import HomeostatCore
import UIKit
import WidgetKit
import os

/// Owns the store and engines for the configured backend and account, and
/// drives import, upload and state polling (Step 9-13 plan).
@MainActor
final class AppModel: ObservableObject {
    struct Snapshot {
        var ledger: [LocalStore.LedgerRow] = []
        var counts = LocalStore.Counts()
        var requests: [(requestID: UUID, state: String, attempts: Int, lastError: String?)] = []
        var lastQueries: [String: String] = [:]
        var lowerBound: String?
        var anchorRecovery: String?
        var acknowledgedRevision: String?
        var paused: String?
        var state: ReturnedState?
        var diagnostics: [String: String] = [:]
        /// Newest first (M1 evidence, see trace).
        var backgroundLog: [String] = []
    }

    @Published var baseURL: String = UserDefaults.standard.string(forKey: "baseURL") ?? "http://localhost:8000"
    @Published var hasAPIKey = Keychain.read("api-key") != nil
    /// Reading Health data and sending it to the server are separate choices.
    @Published var uploadEnabled = UserDefaults.standard.bool(forKey: "uploadEnabled")
    @Published var snapshot = Snapshot()
    @Published var importErrors: [String: String] = [:]
    @Published var lastSync: SyncOutcome?
    @Published var busy = false
    @Published var configurationError: String?
    /// Set by the widget's link (homeostat://explain).
    @Published var showingExplanation = false
    @Published var explanationState: ReturnedState?
    @Published var explanationMessage: String?
    @Published var savingSettings = false
    @Published var widgetDiagnostics: WidgetManifest?
    /// The user's avatar appearance (G2 decision D5): device-only, shared with the widget.
    @Published private(set) var identity = AvatarIdentityStore.shared()?.read() ?? AvatarIdentity()

    private struct ActiveSettings: Codable {
        var widget: WidgetBackendConfiguration
        var fileScope: String
        var keyID: String
    }
    private var activeSettings: ActiveSettings? {
        guard let data = UserDefaults.standard.data(forKey: "activeSettings") else { return nil }
        return try? JSONDecoder().decode(ActiveSettings.self, from: data)
    }
    private var activeKey: String? { Keychain.read(activeSettings?.keyID ?? "api-key") }


    nonisolated static let widgetKind = "HomeostatWidget"
    nonisolated static let refreshTaskID = "com.susil.homeostat.refresh"

    let healthAvailable = HKHealthStore.isHealthDataAvailable()
    let healthStore = HKHealthStore()
    private(set) var store: LocalStore?
    private var importer: ImportEngine?
    private var syncer: SyncEngine?
    private var observersRegistered = false
    private var scope: String?
    private let backgroundRunner = BackgroundSyncRunner()
    private var backgroundRefreshWork: Task<Void, Never>?
    private var foreground = false
    private let uploadRetry = UploadRetryScheduler()
    private var uploadTask: Task<Void, Never>?
    private var uploadGeneration = 0
    private var uploadAgain = false
    private var storeGeneration = 0
    private var calculationWork: Task<Void, Never>?
    private var calculationAgain = false
    @Published private(set) var displayNow = Date()
    private var clockSubscriptions = Set<AnyCancellable>()

    private func cancelUploads() {
        backgroundRunner.cancel()
        uploadGeneration += 1
        uploadAgain = false
        uploadRetry.cancel()
        uploadTask?.cancel()
        uploadTask = nil
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active {
            updateDisplayClock()
            scheduleRefresh()
            Task { await upload() }
        } else {
            // Inactive also occurs for permission sheets. Do not cancel an
            // independently owned observer/BGRefresh task here.
            uploadRetry.cancel()
        }
    }
    private let log = Logger(subsystem: "com.susil.homeostat", category: "sync")  // counts and codes only

    var isConfigured: Bool { store != nil }
    /// Signed in to a server (optional: results are calculated on this iPhone).
    var isSignedIn: Bool { activeSettings != nil }

    init() {
        try? openStore()
        Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self, self.foreground else { return }
                self.updateDisplayClock()
            }.store(in: &clockSubscriptions)
        NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateDisplayClock() }.store(in: &clockSubscriptions)
    }

    func updateDisplayClock() { displayNow = Date() }

    func isCurrent(_ state: ReturnedState) -> Bool {
        guard let day = LocalDay(state.day) else { return false }
        return WidgetPolicy.isCurrent(day: day, effectiveAt: state.effectiveAt,
                                      now: Instant(displayNow), zone: .current)
    }

    // MARK: - Configuration

    /// `enrollmentKey` creates a new account; `pairingCode` joins an existing
    /// one. Neither is needed once this device is registered with the server.
    func saveSettings(baseURL: String, enrollmentKey: String?, pairingCode: String?) async -> Bool {
        guard !savingSettings else { return false }
        savingSettings = true
        defer { savingSettings = false }
        // Each save writes the key under a new ID, so the previous settings stay
        // intact until activation. Whichever copy ends up unused is deleted.
        let previousKeyID = activeSettings?.keyID ?? "api-key"
        var unusedKeyID: String?
        defer { if let unusedKeyID { Keychain.delete(unusedKeyID) } }
        do {
            guard var parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil else { throw URLError(.badURL) }
            parts.host = host.lowercased()
            parts.scheme = parts.scheme?.lowercased()
            #if DEBUG
            let allowHTTP = parts.scheme == "http"
            #else
            let allowHTTP = false
            #endif
            guard parts.scheme == "https" || allowHTTP else { throw URLError(.secureConnectionFailed) }
            while parts.path.hasSuffix("/") { parts.path.removeLast() }
            guard let url = parts.url else { throw URLError(.badURL) }
            let key = try await deviceToken(for: url, enrollmentKey: enrollmentKey, pairingCode: pairingCode)
            var request = URLRequest(url: url.appendingPathComponent("v1/account"))
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await BoundedHTTP.send(request)
            struct Account: Decodable { var account_id: UUID }
            if response.statusCode == 401 {
                forgetDevice(for: url)  // removed from its account: register again
                throw SettingsError.deviceRemoved
            }
            guard response.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
            let account = try JSONDecoder().decode(Account.self, from: data).account_id
            let stableScope = Self.hash("\(url.absoluteString)|\(account.uuidString.lowercased())")
            let previous = activeSettings
            let mappingKey = "store-file-\(stableScope)"
            // Preserve the original queue and installation on the first upgrade.
            // Subsequently a credential rotation keeps this verified account scope.
            let legacy = previous == nil && URL(string: self.baseURL)?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == url.absoluteString
                && enrollmentKey != nil && activeKey == enrollmentKey ? Self.hash("\(self.baseURL)|\(enrollmentKey!)") : nil
            let fileScope = UserDefaults.standard.string(forKey: mappingKey)
                ?? (previous?.widget.scope == stableScope ? previous?.fileScope : nil) ?? legacy ?? stableScope
            let candidate = try Self.makeStore(fileScope)
            guard let installation = try candidate.value("installation_id"), let shared = SharedWidgetStore.shared() else {
                throw CocoaError(.fileWriteNoPermission)
            }
            // Persist a provisioning operation before sending, so a lost response
            // retries the same token and operation instead of rotating credentials.
            let operationKey = "widget-operation-\(stableScope)-\(installation)"
            let operation = UserDefaults.standard.string(forKey: operationKey) ?? UUID().uuidString
            UserDefaults.standard.set(operation, forKey: operationKey)
            let credentialID = "\(stableScope)-\(installation)-\(operation)"
            let token: String
            if let saved = WidgetCredentialStore.read(credentialID) { token = saved }
            else { token = try WidgetCredentialStore.newToken(); try WidgetCredentialStore.write(token, id: credentialID) }
            request.url = url.appendingPathComponent("v1/widget/credentials")
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["operation_id": operation,
                "installation_id": installation, "token": token])
            let (provisionData, provisionResponse) = try await BoundedHTTP.send(request)
            if provisionResponse.statusCode == 200,
               let result = try JSONSerialization.jsonObject(with: provisionData) as? [String: Any],
               result["revoked"] as? Bool == true {
                UserDefaults.standard.removeObject(forKey: operationKey)
                configurationError = "Widget access was revoked. Save again to create a new widget credential."
                return false
            }
            guard provisionResponse.statusCode == 200,
                  let provision = try JSONSerialization.jsonObject(with: provisionData) as? [String: Any],
                  provision["revoked"] as? Bool == false else { throw URLError(.userAuthenticationRequired) }
            let keyID = UUID().uuidString
            guard Keychain.write(key, for: keyID) else { throw CocoaError(.fileWriteNoPermission) }
            unusedKeyID = keyID
            let widget = WidgetBackendConfiguration(scope: stableScope, baseURL: url, accountID: account,
                // Results are calculated on this iPhone (Plan/specs/On_device_plan.md), so the
                // widget doesn't fetch server results; that returns with the server.
                credentialID: credentialID, syncEnabled: false, allowInsecureDevelopment: allowHTTP)
            let settings = ActiveSettings(widget: widget, fileScope: fileScope, keyID: keyID)
            let encoded = try JSONEncoder().encode(settings)
            // All fallible validation and persistence is finished before activation.
            try shared.activate(widget)
            cancelUploads()
            UserDefaults.standard.set(encoded, forKey: "activeSettings")
            unusedKeyID = previousKeyID
            UserDefaults.standard.set(fileScope, forKey: mappingKey)
            UserDefaults.standard.set(url.absoluteString, forKey: "baseURL")
            self.baseURL = url.absoluteString
            hasAPIKey = true
            install(store: candidate, scope: stableScope, url: url, key: key)
            configurationError = nil
            refresh()
            publishWidget(foreground: true)
            WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
            scheduleRefresh()
            return true
        } catch let error as SettingsError {
            configurationError = error.message
            return false
        } catch {
            configurationError = "Settings were not activated. Check the server address, key and connection (\((error as NSError).code))."
            return false
        }
    }

    enum SettingsError: Error {
        case needsEnrollment, rejected(Int), deviceRemoved
        var message: String {
            switch self {
            case .needsEnrollment: "Enter the enrollment key to create an account, or a pairing code from a signed-in device."
            case .rejected(let status): status == 401
                ? "The enrollment key or pairing code wasn't accepted. Pairing codes expire after 10 minutes and work once."
                : "The server refused this device (\(status))."
            case .deviceRemoved: "This device was removed from its account. Enter the enrollment key or a new pairing code."
            }
        }
    }

    // MARK: - Device key (backend accounts.py)

    private static func deviceSlot(_ url: URL) -> String { "device|\(url.absoluteString)" }

    /// This device's key for `url`, registering it first if needed. The ID and
    /// token are saved before the request, so a lost response retries the same
    /// registration instead of creating a second device.
    private func deviceToken(for url: URL, enrollmentKey: String?, pairingCode: String?) async throws -> String {
        let slot = Self.deviceSlot(url)
        if UserDefaults.standard.bool(forKey: "\(slot)|registered"), let token = Keychain.read(slot) { return token }
        let deviceID = UserDefaults.standard.string(forKey: "\(slot)|id") ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(deviceID, forKey: "\(slot)|id")
        let token: String
        if let saved = Keychain.read(slot) {
            token = saved
        } else {
            token = try WidgetCredentialStore.newToken()
            guard Keychain.write(token, for: slot) else { throw CocoaError(.fileWriteNoPermission) }
        }
        var body: [String: String] = ["device_id": deviceID, "token": token, "name": UIDevice.current.name]
        var request: URLRequest
        if let code = pairingCode?.trimmingCharacters(in: .whitespaces), !code.isEmpty {
            request = URLRequest(url: url.appendingPathComponent("v1/devices/pair"))
            body["code"] = code
        } else if let key = enrollmentKey, !key.isEmpty {
            request = URLRequest(url: url.appendingPathComponent("v1/accounts"))
            request.setValue(key, forHTTPHeaderField: "X-Homeostat-Key")
        } else {
            throw SettingsError.needsEnrollment
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await BoundedHTTP.send(request)
        switch response.statusCode {
        case 200:
            UserDefaults.standard.set(true, forKey: "\(slot)|registered")
            return token
        case 409:
            forgetDevice(for: url)  // this ID or token can't be used; the next save starts fresh
            throw SettingsError.rejected(409)
        default:
            throw SettingsError.rejected(response.statusCode)
        }
    }

    private func forgetDevice(for url: URL) {
        let slot = Self.deviceSlot(url)
        Keychain.delete(slot)
        UserDefaults.standard.removeObject(forKey: "\(slot)|id")
        UserDefaults.standard.removeObject(forKey: "\(slot)|registered")
    }

    struct Device: Decodable, Identifiable {
        var device_id: String, name: String, created_at: String, current: Bool
        var id: String { device_id }
    }

    /// A signed-in request to this account's server, with the active device key.
    private func accountRequest(_ path: String, method: String = "GET") -> URLRequest? {
        guard let settings = activeSettings, let key = activeKey else { return nil }
        var request = URLRequest(url: settings.widget.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// A single-use code (valid 10 minutes) that adds another device to this account.
    func createPairingCode() async -> String? {
        struct Code: Decodable { var code: String }
        guard let request = accountRequest("v1/pairing-codes", method: "POST"),
              let (data, response) = try? await BoundedHTTP.send(request), response.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Code.self, from: data).code
    }

    func listDevices() async -> [Device]? {
        struct List: Decodable { var devices: [Device] }
        guard let request = accountRequest("v1/devices"),
              let (data, response) = try? await BoundedHTTP.send(request), response.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(List.self, from: data).devices
    }

    /// Signs another device out of this account and revokes its widget.
    func removeDevice(_ id: String) async -> Bool {
        guard let request = accountRequest("v1/devices/\(id)", method: "DELETE"),
              let (_, response) = try? await BoundedHTTP.send(request) else { return false }
        return response.statusCode == 200
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeStore(_ fileScope: String) throws -> LocalStore {
        var directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let path = directory.appendingPathComponent("homeostat-\(fileScope).sqlite").path
        let store = try LocalStore(path: path)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
        return store
    }

    private func install(store: LocalStore, scope: String, url: URL?, key: String?) {
        storeGeneration += 1
        backgroundRefreshWork?.cancel()
        backgroundRefreshWork = nil
        calculationWork?.cancel()
        calculationWork = nil
        calculationAgain = false
        cancelUploads()
        busy = false
        showingExplanation = false
        explanationState = nil
        explanationMessage = nil
        self.store = store; self.scope = scope
        importer = ImportEngine(store: store, source: HealthKitSource(store: healthStore))
        syncer = url.flatMap { url in key.map {
            SyncEngine(store: store, config: BackendConfig(baseURL: url, deviceToken: $0), transport: URLSessionTransport())
        } }
    }

    func setUploadEnabled(_ enabled: Bool) {
        if !enabled { cancelUploads() }
        uploadEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "uploadEnabled")
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        scheduleRefresh()
        if enabled && foreground { Task { await upload() } }
    }

    /// One store file per backend and account: changing either never sends an
    /// old queue to a new user.
    private func openStore() throws {
        if let settings = activeSettings, let key = Keychain.read(settings.keyID) {
            baseURL = settings.widget.baseURL.absoluteString
            hasAPIKey = true
            let store = try Self.makeStore(settings.fileScope)
            install(store: store, scope: settings.widget.scope, url: settings.widget.baseURL, key: key)
            if let shared = SharedWidgetStore.shared(),
               try shared.manifest().configuration?.generation != settings.widget.generation {
                try shared.activate(settings.widget)
            }
        } else if activeSettings == nil, let key = Keychain.read("api-key"), let url = URL(string: baseURL) {
            let legacyScope = Self.hash("\(url.absoluteString)|\(key)")
            install(store: try Self.makeStore(legacyScope), scope: legacyScope, url: url, key: key)
            // Existing installations continue offline. Saving settings registers
            // this device and provisions the widget credential.
        } else {
            // No server: everything happens on this iPhone.
            install(store: try Self.makeStore("device"), scope: "device", url: nil, key: nil)
        }
        publishWidget(foreground: true)
    }

    // MARK: - Widget cache (Step 14-16 plan sections 4 and 8)

    /// Writes the stored state to the App Group and reloads the widget when it
    /// would look different. In the foreground every change reloads: those
    /// reloads don't count against the widget's daily budget.
    /// Set when the last appearance change couldn't be saved; the shown look is then unchanged.
    @Published private(set) var identitySaveError: String?

    /// Shows a new look only once it is saved, so the app and widget never disagree.
    func saveIdentity(_ identity: AvatarIdentity) {
        guard let store = AvatarIdentityStore.shared() else {
            identitySaveError = "Couldn't save your avatar: this build can't reach the shared App Group."
            log.error("avatar identity not saved: no App Group container")
            return
        }
        do {
            try store.write(identity)
            self.identity = identity.valid
            identitySaveError = nil
            WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        } catch {
            identitySaveError = "Couldn't save your avatar. Try again."
            log.error("avatar identity not saved: \((error as NSError).code, privacy: .public)")
        }
    }

    func publishWidget(foreground: Bool) {
        guard let store, let scope, let shared = SharedWidgetStore.shared(),
              let state = try? store.storedLocalState(), let day = LocalDay(state.day) else { return }
        let cache = WidgetCache(scope: scope, day: day, inputRevision: state.inputRevision, runID: state.runID,
                                widgetState: state.widgetState)
        switch try? shared.write(cache, now: Instant(Date())) {
        case .written(let meaningful) where meaningful || foreground:
            WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        default:
            break
        }
    }

    // MARK: - Actions

    func requestAccess() async {
        guard healthAvailable, let store else { return }
        let types = HealthKitSource.readTypes
        var failure: String?
        do {
            try await healthStore.requestAuthorization(toShare: [], read: types)
        } catch {
            failure = (error as NSError).domain + ":\((error as NSError).code)"
        }
        // Records that access was *requested*; HealthKit never reveals read denial.
        try? store.recordAuthorizationRequest(types: SampleType.allCases.map(\.rawValue) + ["steps"],
                                              at: Instant(Date()), error: failure)
        registerObservers()
        await catchUp()
    }

    /// HKError.errorAuthorizationNotDetermined: HealthKit says this build was
    /// never granted access, so every query is refused.
    static let accessNotDetermined = "com.apple.healthkit:5"
    var needsHealthAccess: Bool { importErrors.values.contains(Self.accessNotDetermined) }
    private var askedForAccessThisLaunch = false

    /// App open/foreground: catch up, and if HealthKit reports access was never
    /// granted, show its permission sheet once per launch.
    func foregroundCatchUp() async {
        await catchUp()
        if needsHealthAccess && !askedForAccessThisLaunch {
            askedForAccessThisLaunch = true
            await requestAccess()
        }
    }

    /// Launch, foreground and manual Sync: import everything, then upload.
    func catchUp() async {
        guard let importer, !busy else { return }
        busy = true
        let generation = storeGeneration
        defer { if generation == storeGeneration { busy = false } }
        let errors = await importer.catchUp()
        guard generation == storeGeneration else { return }
        importErrors = errors
        log.info("import finished with \(self.importErrors.count, privacy: .public) error(s)")
        guard generation == storeGeneration, !Task.isCancelled else { return }
        await recalculate()
        scheduleRefresh()
        await upload()
        refresh()
    }

    func refreshHistory() async {
        guard let importer else { return }
        busy = true
        let generation = storeGeneration
        defer { if generation == storeGeneration { busy = false } }
        do {
            try await importer.refreshSteps(full: true)
        } catch {
            importErrors["steps"] = String(describing: error)
        }
        guard generation == storeGeneration, !Task.isCancelled else { return }
        await recalculate()
        scheduleRefresh()
        await upload()
        refresh()
    }

    func upload() async {
        guard uploadEnabled, let syncer else { return }
        if let uploadTask {
            uploadAgain = true
            await uploadTask.value
            return
        }
        defer { scheduleRefresh() }
        uploadRetry.cancel()
        let generation = uploadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            let outcomes = await syncer.syncAll()
            guard !Task.isCancelled, self.uploadGeneration == generation else { return }
            self.lastSync = outcomes.last
            self.log.info("sync finished: \(outcomes.count, privacy: .public) step(s)")
            self.refresh()
        }
        uploadTask = task
        await task.value
        guard uploadGeneration == generation else { return }
        uploadTask = nil
        guard foreground, uploadEnabled, !task.isCancelled else { return }
        let next: Date?
        switch lastSync {
        case .retryScheduled(let at, _), .notDue(let at): next = at.date
        case .protocolError:
            // A failed local commit can leave an older deadline due already.
            // Avoid a foreground spin while storage is unavailable.
            next = (try? store?.pendingRetryAt()).map { max($0.date, Date().addingTimeInterval(2)) }
        case .idle where uploadAgain: next = Date()
        case .busy: next = Date().addingTimeInterval(1) // resume after an in-flight background sender
        case .sent, .split: next = Date() // continue after the bounded batch limit
        default: next = nil
        }
        uploadAgain = false
        if let next {
            uploadRetry.schedule(at: next) { [weak self] in await self?.upload() }
        }
    }

    func resumeUploads() async {
        try? await syncer?.resume()
        await upload()
    }

    // MARK: - HealthKit observers

    /// Observers persist changes and call their completion handler once, without
    /// waiting for an upload. Background delivery is best effort; foreground
    /// catch-up always runs too.
    func registerObservers() {
        guard healthAvailable, !observersRegistered else { return }
        observersRegistered = true
        let pairs: [(HKSampleType, SampleType?)] = SampleType.allCases.map { (HealthKitSource.sampleType($0), $0) }
            + [(HealthKitSource.stepType, nil)]
        for (hkType, type) in pairs {
            let query = HKObserverQuery(sampleType: hkType, predicate: nil) { [weak self] _, completion, error in
                guard error == nil else { completion(); return }
                Task { @MainActor in
                    guard let self else { completion(); return }
                    let localGeneration = self.storeGeneration
                    // Acquire the allowance before releasing HealthKit's wake.
                    let work = Task { @MainActor in await self.handleObserverUpdate(type) }
                    let allowance = BackgroundAllowance("homeostat.import") { [weak self] in
                        work.cancel()
                        if self?.storeGeneration == localGeneration { self?.backgroundRunner.cancel() }
                    }
                    let deadline = Task {
                        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                        work.cancel()
                        if localGeneration == self.storeGeneration { self.backgroundRunner.cancel() }
                    }
                    await work.value
                    completion()
                    if !work.isCancelled, localGeneration == self.storeGeneration { await self.syncAfterChange() }
                    deadline.cancel()
                    allowance.end()
                }
            }
            healthStore.execute(query)
            enableDelivery(hkType, name: type?.rawValue ?? "steps")
        }
    }

    /// Background evidence (M1): a line in the system log and in a rolling log in
    /// the app's database, so a pulled database copy shows what happened while
    /// no debugger was attached. Event names and error codes only, never health values.
    func trace(_ line: String) {
        log.notice("\(line, privacy: .public)")
        guard let store else { return }
        let entry = ISO8601DateFormatter().string(from: Date()) + " " + line
        let lines = ((try? store.value("background_log"))?.split(separator: "\n").map(String.init) ?? []) + [entry]
        try? store.setValue(lines.suffix(60).joined(separator: "\n"), for: "background_log")
    }

    private func handleObserverUpdate(_ type: SampleType?) async {
        guard let importer else { return }
        let name = type?.rawValue ?? "steps"
        let state = UIApplication.shared.applicationState == .active ? "active" : "background"
        trace("observer update: \(name), app \(state), protected data \(UIApplication.shared.isProtectedDataAvailable ? "available" : "locked")")
        let generation = storeGeneration
        let errors = await importer.catchUp(repairHistory: false)
        guard generation == storeGeneration else { return }
        trace(errors.isEmpty ? "observer import \(name): ok"
              : "observer import failed: " + errors.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        importErrors = errors
        await recalculate()
        scheduleRefresh()
    }

    private func enableDelivery(_ type: HKSampleType, name: String) {
        let generation = storeGeneration
        healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { [self] success, error in
            let code = error.map { "\(($0 as NSError).domain):\(($0 as NSError).code)" } ?? "failed"
            Task { @MainActor [weak self] in
                guard let self, generation == self.storeGeneration else { return }
                try? self.store?.setValue(success ? "enabled" : code, for: "background_delivery_\(name)")
            }
        }
    }

    func retryDeferredImport() async {
        let reopened = store == nil
        if reopened { try? openStore() }
        guard let store else { return }
        refresh()
        guard snapshot.ledger.contains(where: { $0.status == "requested" }) else { return }
        registerObservers()
        for type in SampleType.allCases where (try? store.value("background_delivery_\(type.rawValue)")) != "enabled" {
            enableDelivery(HealthKitSource.sampleType(type), name: type.rawValue)
        }
        if (try? store.value("background_delivery_steps")) != "enabled" { enableDelivery(HealthKitSource.stepType, name: "steps") }
        let deferred = (try? store.value("import_deferred")) ?? "none"
        trace("unlock retry: import_deferred \(deferred), store reopened \(reopened)")
        if reopened || deferred != "none" { await catchUp() }
    }

    // MARK: - Background (Step 14-16 plan section 8)

    /// After a HealthKit change: the full foreground path when the app is open,
    /// otherwise one short background pass.
    func syncAfterChange() async {
        if UIApplication.shared.applicationState == .active {
            await upload()
        } else {
            await backgroundSync()
        }
    }

    /// A few requests, then one state fetch and the cache write, inside a
    /// background task. No polling. Callbacks arriving meanwhile coalesce into
    /// one more pass. If time runs out the open request stays queued, and
    /// resending it is idempotent.
    @discardableResult
    func backgroundSync() async -> Bool {
        guard uploadEnabled, let syncer, !Task.isCancelled else { return false }
        let generation = uploadGeneration
        let allowance = BackgroundAllowance("homeostat.sync") { [weak self] in
            guard let self, self.uploadGeneration == generation else { return }
            self.backgroundRunner.cancel()
        }
        let completed = await backgroundRunner.run(client: syncer) { [weak self] in
            guard let self, self.uploadEnabled, self.uploadGeneration == generation else { return }
            self.refresh()
            self.publishWidget(foreground: false)
        }
        if uploadGeneration == generation { scheduleRefresh() }
        allowance.end()
        return completed
    }

    /// Best effort: iOS may run it late or never. Opening the app always catches up.
    func scheduleRefresh() {
        guard let store else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskID)
            return
        }
        let now = Date()
        let zone = Zone(TimeZone.current.identifier) ?? Zone("UTC")!
        let today = zone.day(of: Instant(now))
        var earliest = min(now.addingTimeInterval(1800), zone.start(of: zone.adding(days: 1, to: today)).date.addingTimeInterval(5 * 60))
        if let retry = try? store.pendingRetryAt()?.date { earliest = min(earliest, retry) }
        if let counts = try? store.counts(), counts.pending + counts.assigned + counts.scansPending > 0 {
            earliest = min(earliest, now.addingTimeInterval(3600))
        }
        let requestedDate = max(earliest, now.addingTimeInterval(60))
        let generation = storeGeneration
        BGTaskScheduler.shared.getPendingTaskRequests { [self] pending in
            let scheduled = pending.first(where: { $0.identifier == Self.refreshTaskID })?.earliestBeginDate
            Task { @MainActor [weak self] in
                guard let self, self.storeGeneration == generation else { return }
                if let scheduled, scheduled <= requestedDate { return }
                let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
                request.earliestBeginDate = requestedDate
                do {
                    try await BGTaskScheduler.shared.submitTaskRequest(request)
                    try? store.setValue(Instant(requestedDate).wire, for: "background_next_requested")
                } catch {
                    let code = (error as NSError).code
                    try? store.setValue("schedule_failed:\(code)", for: "background_last_result")
                    self.log.error("background refresh scheduling failed: \(code, privacy: .public)")
                }
            }
        }
    }

    func handleRefreshTask(_ task: BGAppRefreshTask) {
        log.info("background refresh task started")
        try? store?.setValue(Instant(Date()).wire, for: "background_last_started")
        let generation = storeGeneration
        let localStore = store
        let localImporter = importer
        let work = Task { @MainActor in
            let errors = await localImporter?.catchUp(repairHistory: true) ?? [:]
            guard !Task.isCancelled, storeGeneration == generation else {
                task.setTaskCompleted(success: false)
                return
            }
            importErrors = errors
            await recalculate()
            guard !Task.isCancelled, storeGeneration == generation else {
                task.setTaskCompleted(success: false)
                return
            }
            let completed = uploadEnabled ? await backgroundSync() : true
            let success = completed && !Task.isCancelled && storeGeneration == generation && errors.isEmpty
            try? localStore?.setValue(success ? "completed" : "deferred_or_failed", for: "background_last_result")
            task.setTaskCompleted(success: success)
        }
        backgroundRefreshWork = work
        let deadline = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            work.cancel()
            if self.storeGeneration == generation { self.backgroundRunner.cancel() }
        }
        Task { @MainActor in
            await work.value
            deadline.cancel()
            if self.storeGeneration == generation { self.scheduleRefresh() }
        }
        task.expirationHandler = { [weak self] in
            work.cancel()
            Task { @MainActor in
                guard let self, self.storeGeneration == generation else { return }
                self.backgroundRunner.cancel()
                try? localStore?.setValue(Instant(Date()).wire, for: "background_last_expired")
            }
        }
    }

    // MARK: - Debug snapshot

    func refresh() {
        updateDisplayClock()
        guard let store else { return }
        var next = Snapshot()
        next.ledger = (try? store.ledger()) ?? []
        next.counts = (try? store.counts()) ?? LocalStore.Counts()
        next.requests = (try? store.openRequests()) ?? []
        for type in SampleType.allCases {
            next.lastQueries[type.rawValue] = try? store.value("last_query_\(type.rawValue)")
        }
        next.lowerBound = try? store.value("import_lower_bound")
        next.anchorRecovery = try? store.value("last_anchor_recovery")
        next.acknowledgedRevision = try? store.value("acknowledged_revision")
        next.paused = try? store.value("paused")
        next.state = try? store.storedLocalState()
        next.backgroundLog = ((try? store.value("background_log"))?.split(separator: "\n").map(String.init) ?? []).reversed()
        for key in ["import_deferred", "last_import_cycle", "local_calculation_duration_ms", "background_next_requested", "background_last_started",
                    "background_last_result", "background_last_expired"]
                    + (SampleType.allCases.map(\.rawValue) + ["steps"]).map({ "background_delivery_\($0)" }) {
            next.diagnostics[key] = try? store.value(key)
        }
        if let saved = try? store.value("import_errors"), let data = saved.data(using: .utf8),
           let errors = try? JSONDecoder().decode([String: String].self, from: data) { importErrors = errors }
        snapshot = next
        widgetDiagnostics = try? SharedWidgetStore.shared()?.manifest()
    }

    /// Explain a frozen local snapshot; never silently substitute another scope/run.
    func openExplanation(url: URL) {
        refresh()
        explanationState = nil
        explanationMessage = nil
        if let link = ExplanationLink(url: url) {
            switch link.resolve(scope: scope, run: snapshot.state?.runID) {
            case .current: explanationState = snapshot.state
            case .updated:
                explanationState = snapshot.state
                explanationMessage = "This result has been updated since the widget was shown. Showing the latest result."
            case .unavailable: explanationMessage = "The widget's result is no longer available on this device."
            }
        } else {
            explanationMessage = "This widget link is invalid. Open the current result in Homeostat."
        }
        showingExplanation = true
    }

    // MARK: - On-device calculation (Plan/specs/On_device_plan.md)

    /// Calculates today's result on this iPhone and hands it to the widget.
    func recalculate() async {
        guard let store else { return }
        if let calculationWork {
            calculationAgain = true
            await calculationWork.value
            return
        }
        let generation = storeGeneration
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == self.storeGeneration { self.calculationWork = nil } }
            repeat {
                self.calculationAgain = false
                let now = Instant(Date())
                let zone = TimeZone.current.identifier
                let started = ContinuousClock.now
                do {
                    let run = try await Task.detached(priority: .utility) {
                        try store.localRun(now: now, zone: zone)
                    }.value
                    guard generation == self.storeGeneration, !Task.isCancelled else { return }
                    if let run {
                        let result = run.state
                        try store.storeLocalState(result)
                        let ms = started.duration(to: .now).components
                        self.trace("calculation: revision \(result.inputRevision), run \(result.runID), "
                                   + String(format: "%.0f ms", Double(ms.seconds) * 1000 + Double(ms.attoseconds) / 1e15))
                        if let scope = self.scope {
                            let line = await Task.detached(priority: .utility) {
                                (try? EngineInputsProbe.run(run, scope: scope, now: now))
                                    ?? "M2 snapshot: failed"
                            }.value
                            self.trace(line)
                        }
                    }
                } catch {
                    guard generation == self.storeGeneration, !Task.isCancelled else { return }
                    self.log.error("local calculation failed: \(String(describing: type(of: error)), privacy: .public)")
                }
                let elapsed = started.duration(to: .now).components
                let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                try? store.setValue(String(format: "%.2f", milliseconds), for: "local_calculation_duration_ms")
                self.refresh()
                self.publishWidget(foreground: UIApplication.shared.applicationState == .active)
            } while self.calculationAgain && !Task.isCancelled
        }
        calculationWork = work
        await work.value
    }

}

/// Background time from iOS, released exactly once: when the work ends, or
/// when iOS says time is up. Holding it past expiry gets the app terminated,
/// and work that is still finishing (a shared import) mustn't delay that.
@MainActor
final class BackgroundAllowance {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(_ name: String, onExpiry: @escaping @MainActor () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // UIKit calls this on the main thread.
            MainActor.assumeIsolated {
                onExpiry()
                self?.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
