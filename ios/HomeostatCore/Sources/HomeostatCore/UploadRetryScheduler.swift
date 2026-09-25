import Foundation

/// One cancellable foreground wake-up. Deadlines themselves remain in SQLite,
/// so suspending or terminating the app never loses the retry schedule.
@MainActor
public final class UploadRetryScheduler {
    private var task: Task<Void, Never>?
    public init() {}

    public func cancel() {
        task?.cancel()
        task = nil
    }

    public func schedule(at date: Date, action: @escaping @MainActor () async -> Void) {
        cancel()
        task = Task { [weak self] in
            do {
                let seconds = max(0, date.timeIntervalSinceNow)
                try await Task.sleep(nanoseconds: UInt64(min(seconds, 86400) * 1_000_000_000))
                try Task.checkCancellation()
                // Long Retry-After values are rechecked without uploading early.
                if date > Date() {
                    self?.schedule(at: date, action: action)
                    return
                }
                self?.task = nil
                await action()
            } catch { /* Cancellation on background, settings change or upload disable. */ }
        }
    }
}
