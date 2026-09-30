import Foundation
import Security

/// Shared only with this app's entitled App Group; ingestion keys stay private.
public enum WidgetCredentialStore {
    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.susil.homeostat.widget",
         kSecAttrAccessGroup as String: SharedWidgetStore.appGroup,
         kSecAttrAccount as String: id]
    }
    public static func read(_ id: String) -> String? {
        var q = query(id); q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public static func write(_ token: String, id: String) throws {
        let q = query(id)
        let values: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(q.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    public static func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Ephemeral, bounded response reader. Redirects are rejected so credentials
/// can never be forwarded to another host or downgraded to HTTP.
public final class BoundedHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    public static func send(_ request: URLRequest, maxBytes: Int = 262_144,
                            timeout: TimeInterval = 10) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        let delegate = BoundedHTTP()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask {
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse,
                      response.expectedContentLength <= maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
                    data.append(byte)
                }
                return (data, response)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                session.invalidateAndCancel()
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

public struct WidgetPublication: Decodable, Sendable {
    public struct Published: Decodable, Sendable {
        public var day: LocalDay
        public var timezone: String
        public var inputRevision: Int64
        public var runID: Int64
        public var widgetState: WidgetState
        enum CodingKeys: String, CodingKey {
            case day, timezone, inputRevision = "input_revision", runID = "run_id", widgetState = "widget_state"
        }
    }
    public var schema: Int
    public var accountID: UUID
    public var calculationStatus: String
    public var acceptedRevision: Int64
    public var published: Published?
    enum CodingKeys: String, CodingKey {
        case schema, accountID = "account_id", calculationStatus = "calculation_status"
        case acceptedRevision = "accepted_revision", published
    }
}

public enum WidgetClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// A lease covers concurrent timelines, and expires if the extension dies.
    public static func refresh(store: SharedWidgetStore, now: Instant = Instant(Date()),
                               credential: @Sendable (String) -> String? = { WidgetCredentialStore.read($0) },
                               transport: Transport = { try await BoundedHTTP.send($0) }) async {
        let lease = UUID()
        let configuration: WidgetBackendConfiguration?
        do {
            configuration = try store.coordinated { manifest in
                manifest.fetch.timelineGeneratedAt = now
                guard let config = manifest.configuration, config.syncEnabled,
                      !manifest.fetch.unauthorized,
                      (manifest.fetch.nextAttemptAt ?? now) <= now,
                      (manifest.fetch.leaseUntil ?? now) <= now,
                      config.baseURL.scheme == "https" || (config.allowInsecureDevelopment && config.baseURL.scheme == "http")
                else { return nil }
                manifest.fetch.leaseID = lease
                manifest.fetch.leaseUntil = now.adding(seconds: 20)
                return config
            }
        } catch { return }
        guard let configuration else { return }
        var publication: WidgetPublication?
        var errorCode: String?
        var unauthorized = false
        var retryAfter: Int64 = 0
        if let token = credential(configuration.credentialID) {
            var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/widget/current"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 10
            do {
                let active = try store.manifest()
                guard active.configuration?.generation == configuration.generation,
                      active.configuration?.syncEnabled == true, active.fetch.leaseID == lease,
                      !Task.isCancelled else { return }
                let (data, response) = try await transport(request)
                if response.statusCode == 200 {
                    let decoded = try JSONDecoder().decode(WidgetPublication.self, from: data)
                    guard decoded.schema == 1, decoded.accountID == configuration.accountID,
                          ["ready", "pending", "failed", "no_state"].contains(decoded.calculationStatus),
                          decoded.acceptedRevision >= 0 else { throw URLError(.cannotParseResponse) }
                    if let published = decoded.published {
                        guard SharedWidgetStore.supported(published.widgetState.version),
                              !published.widgetState.presentation.headline.isEmpty,
                              !published.widgetState.presentation.icon.isEmpty,
                              published.inputRevision <= decoded.acceptedRevision,
                              published.runID > 0 else { throw URLError(.cannotParseResponse) }
                    }
                    publication = decoded
                } else {
                    unauthorized = response.statusCode == 401
                    errorCode = "http_\(response.statusCode)"
                    if let header = response.value(forHTTPHeaderField: "Retry-After") {
                        if let seconds = Int64(header) { retryAfter = max(0, seconds) }
                        else {
                            let formatter = DateFormatter()
                            formatter.locale = Locale(identifier: "en_US_POSIX")
                            formatter.timeZone = TimeZone(secondsFromGMT: 0)
                            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                            if let date = formatter.date(from: header) { retryAfter = max(0, Int64(date.timeIntervalSince(now.date))) }
                        }
                    }
                }
            } catch { errorCode = "fetch_failed" }
        } else { errorCode = "credential_unavailable" }
        try? store.coordinated { manifest in
            guard manifest.configuration?.generation == configuration.generation,
                  manifest.fetch.leaseID == lease else { return }
            manifest.fetch.leaseID = nil
            manifest.fetch.leaseUntil = nil
            manifest.fetch.lastError = errorCode
            manifest.fetch.unauthorized = unauthorized
            if let publication {
                manifest.fetch.failures = 0
                manifest.fetch.lastCheckedAt = now
                manifest.fetch.calculationStatus = publication.calculationStatus
                manifest.fetch.acceptedRevision = publication.acceptedRevision
                if let published = publication.published {
                    let cache = WidgetCache(scope: configuration.scope, day: published.day,
                        inputRevision: published.inputRevision, runID: published.runID, widgetState: published.widgetState)
                    if manifest.cache == nil || (cache.inputRevision, cache.runID) >= (manifest.cache!.inputRevision, manifest.cache!.runID) {
                        manifest.cache = cache
                    }
                }
                manifest.fetch.nextAttemptAt = now.adding(seconds: 1800)
            } else {
                manifest.fetch.failures = min(3, manifest.fetch.failures + 1)
                let backoff: Int64 = [1800, 3600, 7200][manifest.fetch.failures - 1]
                manifest.fetch.nextAttemptAt = now.adding(seconds: max(backoff, min(retryAfter, 7 * 86400)))
            }
        }
    }
}
