import Foundation
import XCTest
@testable import HomeostatCore

private actor BackgroundClient: BackgroundSyncClient {
    var sends = 0
    var reads = 0
    var extraRequests = 0
    let entered: XCTestExpectation?
    var continuation: CheckedContinuation<Void, Never>?

    init(entered: XCTestExpectation? = nil) { self.entered = entered }
    func syncAll(maxRequests: Int) async -> [SyncOutcome] {
        sends += 1
        if let entered {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
            if !Task.isCancelled { extraRequests += 1 }
        }
        return [.idle]
    }
    func refreshState() async -> StateRefresh { reads += 1; return .stored }
    func release() { continuation?.resume(); continuation = nil }
    func counts() -> [Int] { [sends, reads, extraRequests] }
}

@MainActor
final class BackgroundSyncRunnerTests: XCTestCase {
    func testIdlePassFetchesServerPublicationAndPublishesWithoutPolling() async {
        let runner = BackgroundSyncRunner()
        let client = BackgroundClient()
        var published = 0
        let done = await runner.run(client: client) { published += 1 }
        let counts = await client.counts()
        XCTAssertTrue(done)
        XCTAssertEqual(counts, [1, 1, 0])
        XCTAssertEqual(published, 1)
    }

    func testDisableOrExpirationStopsRemainingRequestsAndCachePublication() async {
        let runner = BackgroundSyncRunner()
        let entered = expectation(description: "first request in flight")
        let client = BackgroundClient(entered: entered)
        var published = false
        let work = Task { await runner.run(client: client) { published = true } }
        await fulfillment(of: [entered], timeout: 2)
        runner.cancel() // same path as upload disable, scope change and expiration
        await client.release()
        let done = await work.value
        let counts = await client.counts()
        XCTAssertFalse(done)
        XCTAssertFalse(published)
        XCTAssertEqual(counts, [1, 0, 0])
    }

    func testCancelledOldAccountCannotPublishAfterReplacementRun() async {
        let runner = BackgroundSyncRunner()
        let entered = expectation(description: "old account in flight")
        let old = BackgroundClient(entered: entered)
        var oldPublished = false
        let oldWork = Task { await runner.run(client: old) { oldPublished = true } }
        await fulfillment(of: [entered], timeout: 2)
        runner.cancel()
        let replacement = BackgroundClient()
        var newPublished = false
        let done = await runner.run(client: replacement) { newPublished = true }
        await old.release()
        _ = await oldWork.value
        XCTAssertTrue(done)
        XCTAssertTrue(newPublished)
        XCTAssertFalse(oldPublished)
    }
}

private struct FailedBackgroundClient: BackgroundSyncClient {
    let failUpload: Bool
    func syncAll(maxRequests: Int) async -> [SyncOutcome] { failUpload ? [.paused(reason: "UNAUTHORIZED")] : [.idle] }
    func refreshState() async -> StateRefresh { failUpload ? .stored : .failed(reason: "NETWORK") }
}

extension BackgroundSyncRunnerTests {
    func testUploadOrGetFailuresAreNotReportedAsSuccessfulRefresh() async {
        for failedUpload in [true, false] {
            let runner = BackgroundSyncRunner()
            let result = await runner.run(client: FailedBackgroundClient(failUpload: failedUpload)) {}
            XCTAssertFalse(result)
            XCTAssertEqual(runner.lastResult, .failed)
        }
    }
}

private actor SlowBackgroundClient: BackgroundSyncClient {
    var reads = 0
    func syncAll(maxRequests: Int) async -> [SyncOutcome] {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        return [.idle]
    }
    func refreshState() async -> StateRefresh { reads += 1; return .stored }
    func readCount() -> Int { reads }
}

extension BackgroundSyncRunnerTests {
    func testTotalDeadlineCancelsWorkBeforeAnotherRequest() async {
        let runner = BackgroundSyncRunner(timeoutNanoseconds: 20_000_000)
        let client = SlowBackgroundClient()
        let start = Date()
        let done = await runner.run(client: client) { XCTFail("expired pass cannot publish") }
        let reads = await client.readCount()
        XCTAssertFalse(done)
        XCTAssertEqual(reads, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}

private struct ScriptedClient: BackgroundSyncClient {
    let outcomes: [SyncOutcome]
    func syncAll(maxRequests: Int) async -> [SyncOutcome] { outcomes }
    func refreshState() async -> StateRefresh { .olderIgnored }
}

extension BackgroundSyncRunnerTests {
    func testResultSaysUploadDueOnlyWhenWorkIsLeft() async {
        let id = UUID()
        let cases: [([SyncOutcome], BackgroundSyncRunner.Result)] = [
            ([.sent(requestID: id, stateStatus: "published"), .idle], .refreshed),
            ([.sent(requestID: id, stateStatus: "pending"), .idle], .calculationPending),
            (Array(repeating: .sent(requestID: id, stateStatus: "published"), count: 3), .uploadDue),
            ([.notDue(until: NOW)], .uploadDue),
        ]
        for (outcomes, expected) in cases {
            let runner = BackgroundSyncRunner()
            _ = await runner.run(client: ScriptedClient(outcomes: outcomes)) {}
            XCTAssertEqual(runner.lastResult, expected, "\(outcomes)")
        }
    }
}
