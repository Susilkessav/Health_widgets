import Foundation

/// What the app shares with the widget (Step 14-16 plan section 4). No health
/// payload: the widget needs only what it renders and how old it is.
public struct WidgetCache: Codable, Hashable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    /// Hash of the backend and account; a different one is another user's state.
    public var scope: String
    public var day: LocalDay
    public var inputRevision: Int64
    public var runID: Int64
    public var widgetState: WidgetState
    /// Set when the widget recalculated this run with its own step read (M3):
    /// the read's time. Nil for the app's own result.
    public var stepsThrough: Instant?
    /// What DailySummary needs beyond the headline (P1). Nil in older caches.
    public var facts: DisplayFacts?
    /// Today's newest saved energy report (P1), shown beside the result.
    public var report: ReportedEnergy?

    public init(scope: String, day: LocalDay, inputRevision: Int64, runID: Int64, widgetState: WidgetState,
                stepsThrough: Instant? = nil, facts: DisplayFacts? = nil, report: ReportedEnergy? = nil) {
        schema = Self.currentSchema
        self.scope = scope
        self.day = day
        self.inputRevision = inputRevision
        self.runID = runID
        self.widgetState = widgetState
        self.stepsThrough = stepsThrough
        self.facts = facts
        self.report = report
    }

    enum CodingKeys: String, CodingKey {
        case schema, scope, day, inputRevision = "input_revision", runID = "run_id"
        case widgetState = "widget_state", stepsThrough = "steps_through", facts, report
    }
}

/// Coordinated App Group manifest shared by the app and widget processes.
public struct SharedWidgetStore: Sendable {
    public static let appGroup = "group.com.susil.homeostat"
    /// widget-state versions this build can render (plan section 4).
    public static let supportedVersionPrefixes = ["widget-state@0.1.", "widget-state@0.2."]

    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("widget", isDirectory: true)
            .appendingPathComponent("widget_state.json")
    }

    /// The app's calculation inputs for the widget's own recalculation (EngineSnapshot, M3).
    public static var engineInputsURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("engine/engine_inputs.json")
    }

    /// The shared container, or nil if the App Group entitlement is missing.
    public static func shared() -> SharedWidgetStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map(SharedWidgetStore.init(directory:))
    }

    public enum Unreadable: Equatable, Sendable {
        /// A newer app wrote a format this widget doesn't know.
        case version
        /// Corrupt, or not readable yet (before the first unlock).
        case unavailable
    }

    public enum ReadResult: Equatable, Sendable {
        case none
        case state(WidgetCache)
        case unreadable(Unreadable)
    }

    public func read() -> ReadResult {
        do {
            return try coordinated(readOnly: true) { manifest in
                guard let cache = manifest.cache else { return .none }
                guard cache.schema == WidgetCache.currentSchema, Self.supported(cache.widgetState.version) else {
                    return .unreadable(.version)
                }
                return .state(cache)
            }
        } catch {
            if let data = try? Data(contentsOf: fileURL), let probe = try? JSONDecoder().decode(Probe.self, from: data),
               ![1, 2].contains(probe.schema) { return .unreadable(.version) }
            return .unreadable(.unavailable)
        }
    }

    public func manifest() throws -> WidgetManifest {
        try coordinated(readOnly: true) { $0 }
    }

    /// All readers and writers in both processes coordinate this same file.
    /// Never perform network or Keychain work inside the synchronous closure.
    public func coordinated<T>(reset: Bool = false, recoverCorrupt: Bool = false, readOnly: Bool = false,
                               _ body: (inout WidgetManifest) throws -> T) throws -> T {
        if readOnly, !FileManager.default.fileExists(atPath: fileURL.path) {
            var empty = WidgetManifest()
            return try body(&empty)
        }
        if !readOnly {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let access: (URL) -> Void = { url in
            result = Result {
                let data = try? Data(contentsOf: url)
                var manifest: WidgetManifest
                if reset { manifest = WidgetManifest() }
                else if let data {
                    if let probe = try? JSONDecoder().decode(Probe.self, from: data),
                       ![1, 2].contains(probe.schema) { throw CocoaError(.fileReadUnknown) }
                    if let decoded = try? JSONDecoder().decode(WidgetManifest.self, from: data) {
                        guard decoded.schema == 2 else { throw CocoaError(.fileReadUnknown) }
                        manifest = decoded
                    } else {
                        // Version one cache is usable offline until the app configures fetching.
                        manifest = WidgetManifest()
                        do { manifest.cache = try JSONDecoder().decode(WidgetCache.self, from: data) }
                        catch { if !recoverCorrupt { throw error } }
                    }
                } else if FileManager.default.fileExists(atPath: url.path) {
                    throw CocoaError(.fileReadNoPermission)
                } else { manifest = WidgetManifest() }
                let originalCache = manifest.cache
                let value = try body(&manifest)
                if readOnly { return value }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var encoded = try encoder.encode(manifest)
                // Fetch metadata updates must preserve a newer nested avatar
                // that this reader intentionally renders as unknown.
                if !reset, let data,
                   let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   raw["schema"] as? Int == 2,
                   var next = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
                    for (key, value) in raw where !["schema", "cache", "configuration", "fetch"].contains(key) {
                        next[key] = value
                    }
                    if originalCache == manifest.cache, let cache = raw["cache"] { next["cache"] = cache }
                    encoded = try JSONSerialization.data(withJSONObject: next, options: [.sortedKeys])
                }
                if data != encoded {
                    try encoded.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                return value
            }
        }
        if readOnly {
            coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinationError, byAccessor: access)
        } else {
            coordinator.coordinate(writingItemAt: fileURL, options: [], error: &coordinationError, byAccessor: access)
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    public func activate(_ configuration: WidgetBackendConfiguration) throws {
        try coordinated(recoverCorrupt: true) { manifest in
            if manifest.configuration?.scope != configuration.scope { manifest.cache = nil }
            manifest.configuration = configuration
            manifest.fetch = .init()
        }
    }

    private struct Probe: Decodable {
        struct Version: Decodable { var version: String? }
        var schema: Int
        var widgetState: Version?
        enum CodingKeys: String, CodingKey { case schema, widgetState = "widget_state" }
    }

    static func supported(_ version: String?) -> Bool {
        guard let version else { return false }
        return supportedVersionPrefixes.contains { version.hasPrefix($0) }
    }

    public enum WriteResult: Equatable, Sendable {
        case written(meaningful: Bool)
        case unchanged
        /// Older than the stored state by (input_revision, run_id), or the same
        /// run with an older step read (no read counts as oldest).
        case ignoredOlder
        /// Failed validation; the previous file is kept.
        case invalid
    }

    /// Writes `cache` unless it is invalid, older than the stored one for the
    /// same scope, or byte-identical. `meaningful` says whether the widget
    /// would look different, which decides a timeline reload (plan section 8).
    public func write(_ cache: WidgetCache, now: Instant) throws -> WriteResult {
        var cache = cache
        let presentation = cache.widgetState.presentation
        guard Self.supported(cache.widgetState.version), cache.schema == WidgetCache.currentSchema,
              !presentation.headline.trimmingCharacters(in: .whitespaces).isEmpty,
              !presentation.icon.isEmpty else { return .invalid }
        return try coordinated { manifest in
            if let configuration = manifest.configuration, configuration.scope != cache.scope { return .invalid }
            let previous = manifest.cache?.scope == cache.scope ? manifest.cache : nil
            if let previous {
                let run = (cache.inputRevision, cache.runID), stored = (previous.inputRevision, previous.runID)
                if run < stored { return .ignoredOlder }
                if run == stored {
                    // The app owns the energy report: a widget step read keeps the stored one,
                    // even if the app changed it after the widget read the cache.
                    if cache.stepsThrough != nil { cache.report = previous.report }
                    // A widget step read only replaces an older one, and the app republishing
                    // the same run never undoes a newer read; it can still update the report.
                    let none = Instant(microseconds: .min)
                    if (cache.stepsThrough ?? none) < (previous.stepsThrough ?? none) {
                        guard cache.stepsThrough == nil, cache.report != previous.report else { return .ignoredOlder }
                        var merged = previous
                        merged.report = cache.report
                        manifest.cache = merged
                        return .written(meaningful: true)
                    }
                }
            }
            if previous == cache { return .unchanged }
            manifest.cache = cache
            // A new app publication is also a successful check of the server.
            manifest.fetch.lastCheckedAt = now
            manifest.fetch.nextAttemptAt = now.adding(seconds: 1800)
            return .written(meaningful: Self.meaningful(from: previous, to: cache, now: now))
        }
    }

    static func meaningful(from previous: WidgetCache?, to next: WidgetCache, now: Instant) -> Bool {
        guard let previous else { return true }
        return previous.widgetState.presentation != next.widgetState.presentation
            || previous.widgetState.primaryTrait != next.widgetState.primaryTrait
            || previous.day != next.day
            || previous.widgetState.freshness != next.widgetState.freshness
            || previous.widgetState.avatar != next.widgetState.avatar
            || previous.report != next.report
            || WidgetPolicy.isStale(previous, now: now)  // a fresh time must replace a stale look
    }

    /// Called when the account or backend changes: another user's state must not show.
    public func clear() throws {
        try coordinated(reset: true) { $0 = WidgetManifest() }
    }
}

public struct WidgetBackendConfiguration: Codable, Equatable, Sendable {
    public var scope: String
    public var generation: UUID
    public var baseURL: URL
    public var accountID: UUID
    public var credentialID: String
    public var syncEnabled: Bool
    public var allowInsecureDevelopment: Bool

    public init(scope: String, baseURL: URL, accountID: UUID, credentialID: String,
                syncEnabled: Bool, allowInsecureDevelopment: Bool = false) {
        self.scope = scope; self.generation = UUID(); self.baseURL = baseURL
        self.accountID = accountID; self.credentialID = credentialID
        self.syncEnabled = syncEnabled; self.allowInsecureDevelopment = allowInsecureDevelopment
    }
}

public struct WidgetFetchStatus: Codable, Equatable, Sendable {
    public var lastCheckedAt: Instant?
    public var nextAttemptAt: Instant?
    public var failures = 0
    public var unauthorized = false
    public var leaseID: UUID?
    public var leaseUntil: Instant?
    public var lastError: String?
    public var calculationStatus: String?
    public var acceptedRevision: Int64?
    public var timelineGeneratedAt: Instant?
    public init() {}
}

public struct WidgetManifest: Codable, Equatable, Sendable {
    public var schema = 2
    public var configuration: WidgetBackendConfiguration?
    public var cache: WidgetCache?
    public var fetch = WidgetFetchStatus()
    public init() {}
}
