import Foundation

public protocol BackgroundSyncClient: Sendable {
    func syncAll(maxRequests: Int) async -> [SyncOutcome]
    func refreshState() async -> StateRefresh
}
extension SyncEngine: BackgroundSyncClient {}

/// The background coordinator used by the app. Owns cancellation across
/// suspension points and coalesces observers into one extra bounded pass.
@MainActor
public final class BackgroundSyncRunner {
    private var task: Task<Bool, Never>?
    private var generation = UUID()
    private var rerun = false
    public enum Result: String, Sendable { case refreshed, calculationPending, uploadDue, failed, cancelled }
    public private(set) var lastResult: Result = .cancelled
    static let maxRequests = 3
    private let timeoutNanoseconds: UInt64
    public init(timeoutNanoseconds: UInt64 = 20_000_000_000) { self.timeoutNanoseconds = timeoutNanoseconds }

    public func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        rerun = false
    }

    public func run(client: any BackgroundSyncClient,
                    publish: @escaping @MainActor () -> Void) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let task {
            rerun = true
            return await task.value
        }
        let token = generation
        lastResult = .refreshed
        let work = Task { @MainActor [weak self] in
            guard let self else { return false }
            var successful = true
            for pass in 0..<2 {
                self.rerun = false
                let outcomes = await client.syncAll(maxRequests: Self.maxRequests)
                var result = Result.refreshed
                for outcome in outcomes {
                    switch outcome {
                    case .retryScheduled, .paused, .quarantined, .protocolError: successful = false
                    case .sent(_, "pending") where result == .refreshed: result = .calculationPending
                    case .notDue, .busy: result = .uploadDue
                    default: break
                    }
                }
                // Stopping on a successful send means the request budget ran out.
                switch outcomes.last {
                case .sent?, .split?: if outcomes.count >= Self.maxRequests { result = .uploadDue }
                default: break
                }
                self.lastResult = result
                guard !Task.isCancelled, self.generation == token else { return false }
                // An idle queue may still have a calculation awaiting publication.
                let refreshed = await client.refreshState()
                if case .failed = refreshed { successful = false }
                guard !Task.isCancelled, self.generation == token else { return false }
                publish()
                if !self.rerun || pass == 1 { break }
            }
            if !successful { self.lastResult = .failed }
            return successful
        }
        task = work
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
            work.cancel()
        }
        defer { deadline.cancel() }
        let completed = await work.value
        if generation == token { task = nil }
        return completed
    }
}
