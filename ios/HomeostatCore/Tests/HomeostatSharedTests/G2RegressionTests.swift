import Foundation
import XCTest
@testable import HomeostatShared

final class G2RegressionTests: XCTestCase {
    func testReadingAndFetchMetadataDoNotEraseFutureAvatar() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedWidgetStore(directory: directory)
        XCTAssertEqual(store.read(), .none)
        _ = try store.manifest()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        var state = widget(version: "widget-state@0.2.0")
        state.avatar = AvatarState()
        _ = try store.write(cache(1, widget: state), now: NOW)
        let json = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
            .replacingOccurrences(of: "avatar-state@0.1.0", with: "avatar-state@0.9.0")
        let original = Data(json.utf8)
        try original.write(to: store.fileURL)
        guard case .state(let read) = store.read() else { return XCTFail("text must remain readable") }
        XCTAssertNil(read.widgetState.avatar)
        _ = try store.manifest()
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        try store.coordinated { $0.fetch.lastCheckedAt = NOW.adding(seconds: 10) }
        XCTAssertTrue(String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
            .contains("avatar-state@0.9.0"))
    }

    func testLegacyAndUnknownManifestReadsAreNonmutating() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedWidgetStore(directory: directory)
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = try JSONEncoder().encode(cache(1))
        try legacy.write(to: store.fileURL)
        XCTAssertEqual(store.read(), .state(cache(1)))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), legacy)
        let future = Data(#"{"schema":9,"cache":null,"fetch":{}}"#.utf8)
        try future.write(to: store.fileURL)
        XCTAssertEqual(store.read(), .unreadable(.version))
        XCTAssertThrowsError(try store.coordinated(recoverCorrupt: true) { $0.fetch.lastCheckedAt = NOW })
        XCTAssertEqual(try Data(contentsOf: store.fileURL), future)
    }

    func testDayPolicyIgnoresPersistedTodayAndHandlesTravelAndDST() {
        let before = instant("2026-11-01T04:59:00Z") // Oct 31 in Chicago
        let day = CHICAGO.day(of: before)
        XCTAssertTrue(WidgetPolicy.isCurrent(day: day, effectiveAt: before, now: before, zone: CHICAGO))
        XCTAssertFalse(WidgetPolicy.isCurrent(day: day, effectiveAt: before,
                                              now: before.adding(seconds: 120), zone: CHICAGO))
        XCTAssertFalse(WidgetPolicy.isCurrent(day: day, effectiveAt: before, now: before, zone: Zone("Asia/Tokyo")!))
        for text in ["2026-03-08T08:00:00Z", "2026-11-01T07:00:00Z"] {
            let at = instant(text)
            let dates = WidgetPolicy.timelineDates(.state(cache(1, day: CHICAGO.day(of: at),
                                                               widget: widget(updated: at))), now: at, zone: CHICAGO)
            XCTAssertTrue(dates.contains(WidgetPolicy.nextMidnight(after: at, zone: CHICAGO)))
            XCTAssertEqual(dates, Array(Set(dates)).sorted())
        }
    }

    func testLinksValidateScopeRunAndRejectAmbiguousURLs() {
        let link = ExplanationLink(url: URL(string: "homeostat://explain?scope=a&run=7")!)!
        XCTAssertEqual(link.resolve(scope: "a", run: 7), .current)
        XCTAssertEqual(link.resolve(scope: "a", run: 8), .updated)
        for run in [nil, 6] as [Int64?] { XCTAssertEqual(link.resolve(scope: "a", run: run), .unavailable) }
        XCTAssertEqual(link.resolve(scope: "b", run: 7), .unavailable)
        for url in ["https://explain?scope=a&run=7", "homeostat://explain?scope=a",
                    "homeostat://explain?scope=a&run=-1", "homeostat://explain?scope=a&run=7&run=8",
                    "homeostat://explain?scope=a&scope=b&run=7", "homeostat://explain?scope=&run=7",
                    "homeostat://explain/path?scope=a&run=7"] {
            XCTAssertNil(ExplanationLink(url: URL(string: url)!))
        }
    }

    func testTimelineSchedulesActualDisappearanceAndPoseCrossing() {
        for peak in [0.0, 0.01, 0.05, 0.1, 0.5, 1.0] {
            let effect = AvatarState.Effect(kind: .sweat, peak: peak, startedAt: NOW, halfLifeMinutes: 20)
            XCTAssertEqual(effect.intensity(at: effect.fadedAt), 0)
            if peak >= 0.05 {
                XCTAssertGreaterThan(effect.intensity(at: effect.fadedAt.adding(seconds: -1)), 0)
            }
            var state = widget(updated: NOW)
            state.avatar = AvatarState(effects: [effect], evidence: .init(workout: ["last_workout"]))
            let dates = WidgetPolicy.timelineDates(.state(cache(1, widget: state)), now: NOW, zone: CHICAGO)
            XCTAssertTrue(dates.contains(effect.fadedAt))
        }
        let glow = AvatarState.Effect(kind: .glow, peak: 1, startedAt: NOW, halfLifeMinutes: 160)
        let avatar = AvatarState(activity: .strength, effects: [glow], evidence: .init(workout: ["last_workout"]))
        var state = widget(updated: NOW)
        state.avatar = avatar
        let crossing = glow.firstAtOrBelow(AvatarPose.stretchingGlow)
        XCTAssertEqual(AvatarPose(avatar, at: crossing.adding(seconds: -1)), .stretching)
        XCTAssertEqual(AvatarPose(avatar, at: crossing), .standing)
        XCTAssertTrue(WidgetPolicy.timelineDates(.state(cache(1, widget: state)), now: NOW, zone: CHICAGO).contains(crossing))
        let future = AvatarState.Effect(kind: .sweat, peak: 1, startedAt: NOW.adding(seconds: 600), halfLifeMinutes: 20)
        state.avatar = AvatarState(effects: [future], evidence: .init(workout: ["last_workout"]))
        XCTAssertTrue(WidgetPolicy.timelineDates(.state(cache(1, widget: state)), now: NOW, zone: CHICAGO)
            .contains(future.startedAt.adding(seconds: -AvatarState.Effect.clockGraceSeconds)))
    }
}
