import Combine
import CryptoKit
import Foundation
import HealthKit
import HomeostatCore
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
    }

    @Published var baseURL: String = UserDefaults.standard.string(forKey: "baseURL") ?? "http://localhost:8000"
    @Published var hasAPIKey = Keychain.read("api-key") != nil
    /// Reading Health data and sending it to the server are separate choices.
    @Published var uploadEnabled = UserDefaults.standard.bool(forKey: "uploadEnabled")
    @Published var snapshot = Snapshot()
    @Published var importErrors: [String: String] = [:]
    @Published var lastSync: SyncOutcome?
    @Published var lastStateStatus: String?
    @Published var busy = false
    @Published var configurationError: String?

    let healthAvailable = HKHealthStore.isHealthDataAvailable()
    let healthStore = HKHealthStore()
    private(set) var store: LocalStore?
    private var importer: ImportEngine?
    private var syncer: SyncEngine?
    private var observersRegistered = false
    private var foreground = false
    private let uploadRetry = UploadRetryScheduler()
    private var uploadTask: Task<Void, Never>?
    private var uploadGeneration = 0
    private var uploadAgain = false

    private func cancelUploads() {
        uploadGeneration += 1
        uploadAgain = false
        uploadRetry.cancel()
        uploadTask?.cancel()
        uploadTask = nil
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active {
            Task { await upload() }
        } else {
            cancelUploads()
        }
    }
    private let log = Logger(subsystem: "com.susil.homeostat", category: "sync")  // counts and codes only

    var isConfigured: Bool { store != nil }

    init() {
        try? openStore()
    }

    // MARK: - Configuration

    func saveSettings(baseURL: String, apiKey: String?) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(self.baseURL, forKey: "baseURL")
        if let apiKey, !apiKey.isEmpty {
            Keychain.write(apiKey, for: "api-key")
            hasAPIKey = true
        }
        do {
            try openStore()
            configurationError = nil
        } catch {
            configurationError = "Couldn't open local storage: \(error.localizedDescription)"
        }
        refresh()
    }

    func setUploadEnabled(_ enabled: Bool) {
        if !enabled { cancelUploads() }
        uploadEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "uploadEnabled")
        if enabled && foreground { Task { await upload() } }
    }

    /// One store file per backend and account: changing either never sends an
    /// old queue to a new user.
    private func openStore() throws {
        cancelUploads()
        importer = nil
        syncer = nil
        guard let url = URL(string: baseURL), let key = Keychain.read("api-key") else {
            store = nil
            return
        }
        let scope = SHA256.hash(data: Data("\(url.absoluteString)|\(key)".utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        var directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true  // imported health data isn't backed up
        try directory.setResourceValues(values)
        let path = directory.appendingPathComponent("homeostat-\(scope).sqlite").path
        let store = try LocalStore(path: path)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
        self.store = store
        let source = HealthKitSource(store: healthStore)
        importer = ImportEngine(store: store, source: source)
        syncer = SyncEngine(store: store, config: BackendConfig(baseURL: url, apiKey: key), transport: URLSessionTransport())
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

    /// Launch, foreground and manual Sync: import everything, then upload.
    func catchUp() async {
        guard let importer, !busy else { return }
        busy = true
        defer { busy = false }
        importErrors = await importer.catchUp()
        log.info("import finished with \(self.importErrors.count, privacy: .public) error(s)")
        await upload()
        refresh()
    }

    func refreshHistory() async {
        guard let importer else { return }
        busy = true
        defer { busy = false }
        do {
            try await importer.refreshSteps(full: true)
        } catch {
            importErrors["steps"] = String(describing: error)
        }
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
        uploadRetry.cancel()
        let generation = uploadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            let outcomes = await syncer.syncAll()
            guard !Task.isCancelled, self.uploadGeneration == generation else { return }
            self.lastSync = outcomes.last
            if case .sent(_, let status)? = outcomes.last(where: { if case .sent = $0 { true } else { false } }) {
                self.lastStateStatus = status
            }
            self.log.info("sync finished: \(outcomes.count, privacy: .public) step(s)")
            self.refresh()
            // Polling state must not delay a due upload retry.
            if case .idle? = outcomes.last { await self.pollState() }
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
        case .sent, .split: next = Date() // continue after the bounded batch limit
        default: next = nil
        }
        uploadAgain = false
        if let next {
            uploadRetry.schedule(at: next) { [weak self] in await self?.upload() }
        }
    }

    /// Polls the published state while the app is active, with bounded backoff.
    func pollState() async {
        guard let syncer else { return }
        for delay in [0, 2, 4, 8, 16, 32] as [UInt64] {
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let refresh = await syncer.refreshState()
            self.refresh()
            if case .stored = refresh, snapshot.state.map({ $0.inputRevision >= Int64(snapshot.acknowledgedRevision ?? "0") ?? 0 }) == true {
                return
            }
            if case .failed = refresh { return }
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
                    await self?.handleObserverUpdate(type)
                    completion()
                    Task { await self?.upload() }
                }
            }
            healthStore.execute(query)
            healthStore.enableBackgroundDelivery(for: hkType, frequency: .immediate) { _, _ in }
        }
    }

    private func handleObserverUpdate(_ type: SampleType?) async {
        guard let importer else { return }
        do {
            if let type {
                _ = try await importer.drain(type)
            } else {
                try await importer.refreshSteps(full: false)  // step changes refresh statistics, not raw samples
            }
        } catch {
            importErrors[type?.rawValue ?? "steps"] = String(describing: error)
        }
        refresh()
    }

    // MARK: - Debug snapshot

    func refresh() {
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
        next.state = try? store.storedState()
        snapshot = next
    }
}
