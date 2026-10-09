import Foundation
import XCTest
@testable import HomeostatShared

/// Shares the Core tests' fixtures directory (written by the Python tests).
let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../HomeostatCoreTests/Fixtures").standardized

func instant(_ text: String) -> Instant { Instant.parse(text)! }

let NOW = instant("2026-09-22T18:00:00Z")  // 13:00 in Chicago
let CHICAGO = Zone("America/Chicago")!

func widget(_ headline: String = "Shorter sleep", updated: Instant = NOW, version: String = "widget-state@0.1.0")
    -> WidgetState {
    WidgetState(version: version, effectiveAt: updated,
                presentation: .init(icon: "😴", headline: headline, detail: "5h 58m"),
                primaryTrait: .init(id: "sleep", explainable: true), freshness: .init(lastUpdatedAt: updated))
}

func cache(_ revision: Int64, run: Int64 = 1, scope: String = "a", day: LocalDay = CHICAGO.day(of: NOW),
           widget state: WidgetState = widget()) -> WidgetCache {
    WidgetCache(scope: scope, day: day, inputRevision: revision, runID: run, widgetState: state)
}

final class SharedWidgetStoreTests: XCTestCase {
    var store: SharedWidgetStore!

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SharedWidgetStore(directory: directory)
    }

    func testAWrittenStateReadsBackIdentically() throws {
        XCTAssertEqual(store.read(), .none)
        XCTAssertEqual(try store.write(cache(1), now: NOW), .written(meaningful: true))
        XCTAssertEqual(store.read(), .state(cache(1)))
        XCTAssertEqual(try store.write(cache(1), now: NOW), .unchanged)
    }

    func testOrderingIsByRevisionThenRunWithinOneScope() throws {
        _ = try store.write(cache(5, run: 9), now: NOW)
        XCTAssertEqual(try store.write(cache(4, run: 99), now: NOW), .ignoredOlder)
        XCTAssertEqual(try store.write(cache(5, run: 8), now: NOW), .ignoredOlder)
        XCTAssertEqual(try store.write(cache(5, run: 10, widget: widget("Longer sleep")), now: NOW),
                       .written(meaningful: true))
        // Another account's state replaces it whatever its order.
        XCTAssertEqual(try store.write(cache(1, scope: "b"), now: NOW), .written(meaningful: true))
        XCTAssertEqual(store.read(), .state(cache(1, scope: "b")))
    }

    /// M3: a widget result is a step read over one app run (Plan.md §4).
    func testWidgetStepReadsOrderWithinOneAppRun() throws {
        func read(_ minutes: Int64, run: Int64 = 9) -> WidgetCache {
            var c = cache(5, run: run, widget: widget("\(minutes) min", updated: NOW.adding(seconds: minutes * 60)))
            c.stepsThrough = NOW.adding(seconds: minutes * 60)
            return c
        }
        _ = try store.write(cache(5, run: 9), now: NOW)                                   // the app's result
        XCTAssertEqual(try store.write(read(30), now: NOW), .written(meaningful: true))     // newer read over it
        XCTAssertEqual(try store.write(read(15), now: NOW), .ignoredOlder)                  // two widget runs: newer wins
        XCTAssertEqual(try store.write(cache(5, run: 9), now: NOW), .ignoredOlder)          // app republish can't undo the read
        XCTAssertEqual(try store.write(read(45, run: 8), now: NOW), .ignoredOlder)          // read on an old app run
        XCTAssertEqual(store.read(), .state(read(30)))
        XCTAssertEqual(try store.write(cache(5, run: 10), now: NOW), .written(meaningful: true))  // any new app run wins
    }

    func testOnlyVisibleChangesAreMeaningful() throws {
        _ = try store.write(cache(1), now: NOW)
        let later = NOW.adding(seconds: 600)
        XCTAssertEqual(try store.write(cache(2, widget: widget(updated: later)), now: later),
                       .written(meaningful: true))  // refresh the already-published stale deadline
        let muchLater = later.adding(seconds: WidgetPolicy.staleAfterSeconds + 60)
        XCTAssertEqual(try store.write(cache(3, widget: widget(updated: muchLater)), now: muchLater),
                       .written(meaningful: true))  // the stored one had gone stale
        XCTAssertEqual(try store.write(cache(4, day: LocalDay(year: 2026, month: 9, day: 23),
                                             widget: widget(updated: muchLater)), now: muchLater),
                       .written(meaningful: true))  // a new day
    }

    func testInvalidInputKeepsThePreviousFile() throws {
        _ = try store.write(cache(1), now: NOW)
        XCTAssertEqual(try store.write(cache(2, widget: widget(" ")), now: NOW), .invalid)
        XCTAssertEqual(try store.write(cache(2, widget: widget(version: "widget-state@1.0.0")), now: NOW), .invalid)
        XCTAssertEqual(store.read(), .state(cache(1)))
    }

    func testUnknownFormatsAndDamageAreReportedNotCrashed() throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var future = try JSONEncoder().encode(cache(1, widget: widget(version: "widget-state@9.0.0")))
        try future.write(to: store.fileURL)
        XCTAssertEqual(store.read(), .unreadable(.version))
        future = Data(#"{"schema": 9, "something": "new"}"#.utf8)
        try future.write(to: store.fileURL)
        XCTAssertEqual(store.read(), .unreadable(.version))
        try Data("{not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.read(), .unreadable(.unavailable))
        try store.clear()
        XCTAssertEqual(store.read(), .none)
        try store.clear()  // clearing twice is fine
    }

    /// Python -> Swift: every distinct payload the backend can produce decodes and caches.
    func testEveryBackendWidgetStateDecodesAndCaches() throws {
        let text = try String(contentsOf: fixtures.appendingPathComponent("widget_states.jsonl"), encoding: .utf8)
        let states = try text.split(separator: "\n").map { try JSONDecoder().decode(WidgetState.self, from: Data($0.utf8)) }
        XCTAssertEqual(Set(states.map(\.primaryTrait.id)),
                       ["sleep", "recovery", "movement", "workout", "calibration", "typical", "no_data"])
        for (index, state) in states.enumerated() {
            guard case .written = try store.write(cache(Int64(index + 1), widget: state), now: NOW) else {
                return XCTFail("fixture line \(index + 1) was not written")
            }
            XCTAssertEqual(store.read(), .state(cache(Int64(index + 1), widget: state)))
        }
    }
}

final class WidgetPolicyTests: XCTestCase {
    func display(_ c: WidgetCache?, at now: Instant, zone: Zone = CHICAGO) -> WidgetPolicy.Display {
        WidgetPolicy.display(c.map(SharedWidgetStore.ReadResult.state) ?? .none, now: now, zone: zone)
    }

    func testFreshUntilNinetyMinutesThenStale() {
        let c = cache(1)
        XCTAssertEqual(display(c, at: NOW.adding(seconds: 90 * 60)), .fresh(c))
        XCTAssertEqual(display(c, at: NOW.adding(seconds: 90 * 60 + 1)), .stale(c))
    }

    func testAClockBehindTheServerCountsAsFresh() {
        let c = cache(1)
        XCTAssertEqual(display(c, at: NOW.adding(seconds: -3600)), .fresh(c))
    }

    func testAnEarlierDayIsNeverShownAsToday() {
        let c = cache(1)
        let midnight = instant("2026-09-23T05:00:00Z")
        XCTAssertEqual(display(c, at: midnight.adding(seconds: -1)), .stale(c))
        XCTAssertEqual(display(c, at: midnight), .earlierDay(c))
        // After flying west the device's day can still be the state's day.
        XCTAssertEqual(display(c, at: midnight, zone: Zone("America/Los_Angeles")!), .stale(c))
    }

    func testEmptyAndUnreadable() {
        XCTAssertEqual(display(nil, at: NOW), .empty)
        XCTAssertEqual(WidgetPolicy.display(.unreadable(.version), now: NOW, zone: CHICAGO), .unreadable(.version))
        XCTAssertEqual(WidgetPolicy.timelineDates(.none, now: NOW, zone: CHICAGO), [NOW])
    }

    func testLocalDaysParse() {
        XCTAssertEqual(LocalDay("2026-09-22"), LocalDay(year: 2026, month: 9, day: 22))
        XCTAssertNil(LocalDay("22/09/2026"))
    }

    func testTimelineChangesAtStaleLightingAndMidnight() {
        // 13:00 in Chicago: stale at 14:30:01, evening light at 17:00, night at 21:00, then midnight.
        let dates = WidgetPolicy.timelineDates(.state(cache(1)), now: NOW, zone: CHICAGO)
        XCTAssertEqual(dates, [NOW, NOW.adding(seconds: 90 * 60 + 1), instant("2026-09-22T22:00:00Z"),
                               instant("2026-09-23T02:00:00Z"), instant("2026-09-23T05:00:00Z")])
        // Already stale: the stale instant is in the past and dropped.
        let later = NOW.adding(seconds: 4 * 3600)
        XCTAssertEqual(WidgetPolicy.timelineDates(.state(cache(1)), now: later, zone: CHICAGO),
                       [later, instant("2026-09-23T02:00:00Z"), instant("2026-09-23T05:00:00Z")])
    }

    func testTimelineFollowsTheAvatarFadingUntilMidnight() {
        // Sweat starts 17:50Z, half-life 20 min, peak 1: entries every 20 min until it fades below
        // 0.05 (4.32 half-lives = 86m27s, 19:16:27Z); the glow steps every 6 h until midnight.
        let end = instant("2026-09-22T17:50:00Z")
        var state = widget()
        state.avatar = AvatarState(activity: .strength, effects: [
            .init(kind: .sweat, peak: 1, startedAt: end, halfLifeMinutes: 20),
            .init(kind: .glow, peak: 1, startedAt: end, halfLifeMinutes: 360)])
        let dates = WidgetPolicy.timelineDates(.state(cache(1, widget: state)), now: NOW, zone: CHICAGO)
        XCTAssertEqual(Array(dates.prefix(7)), [NOW, instant("2026-09-22T18:10:00Z"), instant("2026-09-22T18:30:00Z"),
                                                instant("2026-09-22T18:50:00Z"), instant("2026-09-22T19:10:00Z"),
                                                instant("2026-09-22T19:16:27Z"), instant("2026-09-22T19:30:01Z")])
        XCTAssertTrue(dates.contains(instant("2026-09-22T23:50:00Z")))  // first glow half-life
        XCTAssertEqual(dates.last, instant("2026-09-23T05:00:00Z"))
        XCTAssertEqual(dates, Array(Set(dates)).sorted())
    }

    func testEffectsFadeByHalfLife() {
        let start = instant("2026-09-22T17:00:00Z")
        let sweat = AvatarState.Effect(kind: .sweat, peak: 0.8, startedAt: start, halfLifeMinutes: 20)
        XCTAssertEqual(sweat.intensity(at: start.adding(seconds: -360)), 0)    // 6 min early: not started
        XCTAssertEqual(sweat.intensity(at: start.adding(seconds: -300)), 0.8)  // 5 min early: clock grace
        XCTAssertEqual(sweat.intensity(at: start.adding(seconds: -60)), 0.8)
        XCTAssertEqual(sweat.intensity(at: start), 0.8)
        XCTAssertEqual(sweat.intensity(at: start.adding(seconds: 1200)), 0.4, accuracy: 1e-12)
        XCTAssertEqual(sweat.intensity(at: start.adding(seconds: 2400)), 0.2, accuracy: 1e-12)
        XCTAssertEqual(sweat.intensity(at: sweat.fadedAt.adding(seconds: 1)), 0)  // below the cutoff
        XCTAssertGreaterThan(sweat.intensity(at: sweat.fadedAt.adding(seconds: -60)), 0)
        XCTAssertEqual(AvatarState.Effect(kind: .glow, peak: 0.01, startedAt: start, halfLifeMinutes: 360)
            .intensity(at: start), 0)
    }

    func testLightingFollowsLocalTime() {
        XCTAssertEqual(Lighting(at: instant("2026-09-22T12:00:00Z"), zone: CHICAGO), .morning)  // 07:00
        XCTAssertEqual(Lighting(at: NOW, zone: CHICAGO), .day)
        XCTAssertEqual(Lighting(at: instant("2026-09-22T23:00:00Z"), zone: CHICAGO), .evening)
        XCTAssertEqual(Lighting(at: instant("2026-09-23T04:00:00Z"), zone: CHICAGO), .night)
    }

    func testOldAndNewCachesBothRead() throws {
        let store = SharedWidgetStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertEqual(try store.write(cache(1), now: NOW), .written(meaningful: true))
        guard case .state(let old) = store.read() else { return XCTFail() }
        XCTAssertNil(old.widgetState.avatar)  // a G1 0.1.0 cache still renders
        var state = widget(version: "widget-state@0.2.0")
        state.avatar = AvatarState(eyes: .tired, eyesIntensity: 0.6, evidence: .init(eyes: ["sleep_duration"]))
        XCTAssertEqual(try store.write(cache(2, widget: state), now: NOW), .written(meaningful: true))
        XCTAssertEqual(store.read(), .state(cache(2, widget: state)))
        // Only the avatar changed: still a reason to reload the widget.
        var tired = state
        tired.avatar?.eyesIntensity = 0.9
        XCTAssertEqual(try store.write(cache(3, widget: tired), now: NOW), .written(meaningful: true))
        XCTAssertEqual(try store.write(cache(4, widget: widget(version: "widget-state@0.3.0")), now: NOW), .invalid)
    }

    func testIdentityRoundTripsAndFallsBackToDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let identities = AvatarIdentityStore(directory: directory)
        XCTAssertEqual(identities.read(), AvatarIdentity())
        let mine = AvatarIdentity(skinTone: 4, hairStyle: 2, hairColor: 3, glasses: true, outfit: 1, body: 1)
        try identities.write(mine)
        XCTAssertEqual(identities.read(), mine)
        try Data(#"{"skin_tone": 99, "hair_style": 1, "hair_color": 0, "glasses": false, "outfit": 0, "body": 0}"#.utf8)
            .write(to: identities.fileURL)
        XCTAssertEqual(identities.read(), AvatarIdentity(hairStyle: 1))
        try Data("not json".utf8).write(to: identities.fileURL)
        XCTAssertEqual(identities.read(), AvatarIdentity())
    }

    func testMidnightFollowsDSTAndSkippedMidnights() {
        // Fall back: 1 Nov 2026 has 25 hours in Chicago.
        let fallBack = instant("2026-11-01T12:00:00Z")
        XCTAssertEqual(WidgetPolicy.nextMidnight(after: fallBack, zone: CHICAGO), instant("2026-11-02T06:00:00Z"))
        // Santiago skips midnight on 6 Sep 2026: the day starts at 01:00.
        let santiago = Zone("America/Santiago")!
        XCTAssertEqual(WidgetPolicy.nextMidnight(after: instant("2026-09-05T12:00:00Z"), zone: santiago),
                       instant("2026-09-06T04:00:00Z"))
        XCTAssertEqual(WidgetPolicy.reloadAfter(now: fallBack, zone: CHICAGO), fallBack.adding(seconds: 1800))
    }
}

final class AvatarDescriptionTests: XCTestCase {
    func testDescribesWhatIsShownWithoutJudging() {
        let end = instant("2026-09-22T17:50:00Z")
        let busy = AvatarState(eyes: .tired, eyesIntensity: 0.7, posture: .low, motion: .high, activity: .strength,
                               effects: [.init(kind: .sweat, peak: 1, startedAt: end, halfLifeMinutes: 20),
                                         .init(kind: .glow, peak: 1, startedAt: end, halfLifeMinutes: 360)],
                               uncertainty: .lowConfidence)
        XCTAssertEqual(AvatarDescription.text(busy, at: NOW),
                       "Avatar; tired-looking eyes: shorter sleep than usual; lower posture: recovery signals below usual; "
                       + "livelier movement: more active than usual; sweat drops: workout just finished; "
                       + "strength glow: recent workout; question mark: some signals have low confidence or missing data")
        // Faded effects are no longer described.
        XCTAssertEqual(AvatarDescription.text(busy, at: NOW.adding(seconds: 2 * 86_400)),
                       "Avatar; tired-looking eyes: shorter sleep than usual; lower posture: recovery signals below usual; "
                       + "livelier movement: more active than usual; question mark: some signals have low confidence or missing data")
        XCTAssertEqual(AvatarDescription.text(AvatarState(), at: NOW), "Avatar, typical look")
        XCTAssertEqual(AvatarDescription.text(AvatarState(eyes: .tired, eyesIntensity: 0.2), at: NOW),
                       "Avatar; slightly tired-looking eyes: shorter sleep than usual")
        XCTAssertEqual(AvatarPalette.skinNames.count, AvatarIdentity.skinTones)
        XCTAssertEqual(AvatarPalette.hairColorNames.count, AvatarIdentity.hairColors)
        let banned = try! NSRegularExpression(pattern: #"\b(bad|poor|unhealthy|lazy|sick|fail\w*|feel\w*)\b"#, options: .caseInsensitive)
        for eyes in AvatarState.Eyes.allCases {
            for posture in AvatarState.Posture.allCases {
                for motion in AvatarState.Motion.allCases {
                    let text = AvatarDescription.text(AvatarState(eyes: eyes, eyesIntensity: eyes == .neutral ? 0 : 0.5,
                                                                  posture: posture, motion: motion), at: NOW)
                    XCTAssertNil(banned.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), text)
                }
            }
        }
    }
}

/// Review item 3 (G2_review_2026_10_05.md): a bad cached avatar keeps the text and draws `.unknown`.
final class AvatarValidationTests: XCTestCase {
    let end = instant("2026-09-22T17:50:00Z")

    func valid() -> AvatarState {
        AvatarState(eyes: .tired, eyesIntensity: 0.6, activity: .strength, effects: [
            .init(kind: .sweat, peak: 0.9, startedAt: end, halfLifeMinutes: 20),
            .init(kind: .glow, peak: 0.9, startedAt: end, halfLifeMinutes: 160)],
                    evidence: .init(eyes: ["sleep_duration"], workout: ["last_workout"]))
    }

    func testTheBackendRulesHold() {
        XCTAssertTrue(valid().isValid)
        XCTAssertTrue(AvatarState().isValid)
        XCTAssertTrue(AvatarState.unknown.isValid)
        var bad: [AvatarState] = []
        for change in [
            { (a: inout AvatarState) in a.version = "avatar-state@0.2.0" },
            { $0.eyesIntensity = 1.5 },
            { $0.eyesIntensity = .nan },
            { $0.eyes = .neutral },                                   // neutral eyes need intensity 0
            { $0.eyesIntensity = 0 },                                 // tired eyes need intensity > 0
            { $0.activity = .none },                                  // glow needs an activity
            { $0.effects.removeLast() },                              // activity needs a glow
            { $0.effects.append($0.effects[0]) },                     // one effect of each kind
            { $0.effects[0].peak = -0.1 },
            { $0.effects[0].halfLifeMinutes = 0.001 },                // would make a zero timeline step
            { $0.effects[0].halfLifeMinutes = 1e300 },                // would overflow the fade time
            { $0.effects[0].halfLifeMinutes = .infinity },
            { $0.evidence.eyes = [] },                                // tired eyes need their reading
            { $0.evidence.posture = ["resting_hr"] },                 // neutral posture has none
            { $0.evidence.workout = [""] },
        ] {
            var a = valid()
            change(&a)
            bad.append(a)
        }
        for (index, a) in bad.enumerated() { XCTAssertFalse(a.isValid, "case \(index)") }
    }

    func decode(_ avatar: String) throws -> WidgetState {
        let json = #"{"version": "widget-state@0.2.0", "effective_at": "2026-09-22T18:00:00Z", "#
            + #""presentation": {"icon": "😴", "headline": "Shorter sleep", "detail": "5h 58m"}, "#
            + #""primary_trait": {"id": "sleep", "explainable": true}, "#
            + #""freshness": {"last_updated_at": "2026-09-22T18:00:00Z"}"# + avatar + "}"
        return try JSONDecoder().decode(WidgetState.self, from: Data(json.utf8))
    }

    func testAMalformedOrInvalidAvatarKeepsTheText() throws {
        let good = #", "avatar": {"version": "avatar-state@0.1.0", "eyes": "tired", "eyes_intensity": 0.6, "#
            + #""posture": "neutral", "motion": "typical", "activity": "none", "effects": [], "uncertainty": "none", "#
            + #""evidence": {"eyes": ["sleep_duration"], "posture": [], "motion": [], "workout": []}, "missing_inputs": []}"#
        XCTAssertEqual(try decode(good).avatar,
                       AvatarState(eyes: .tired, eyesIntensity: 0.6, evidence: .init(eyes: ["sleep_duration"])))
        for avatar in [
            "",                                                                     // missing
            #", "avatar": null"#,
            #", "avatar": "tired""#,                                                 // wrong type
            good.replacingOccurrences(of: #""tired""#, with: #""sleepy""#),           // unknown value
            good.replacingOccurrences(of: "0.6", with: "7"),                          // out of range
            good.replacingOccurrences(of: "avatar-state@0.1.0", with: "avatar-state@0.2.0"),  // newer version
            good.replacingOccurrences(of: #""eyes": ["sleep_duration"]"#, with: #""eyes": []"#),  // no evidence
            good.replacingOccurrences(of: #""effects": []"#, with:
                #""effects": [{"kind": "sweat", "peak": 1, "started_at": "2026-09-22T17:50:00Z", "half_life_minutes": 0.0001}]"#),
        ] {
            let state = try decode(avatar)
            XCTAssertNil(state.avatar, avatar)
            XCTAssertEqual(state.presentation.headline, "Shorter sleep")
        }
    }

    func testTheTimelineSkipsUnusableEffectsAndStaysShort() {
        var state = widget()
        state.avatar = valid()
        state.avatar?.effects[0].halfLifeMinutes = 0.0001  // only possible in memory; decoding drops it
        state.avatar?.effects[1].halfLifeMinutes = 1e300
        let dates = WidgetPolicy.timelineDates(.state(cache(1, widget: state)), now: NOW, zone: CHICAGO)
        XCTAssertEqual(dates, [NOW, NOW.adding(seconds: 90 * 60 + 1), instant("2026-09-22T22:00:00Z"),
                               instant("2026-09-23T02:00:00Z"), instant("2026-09-23T05:00:00Z")])
        // Valid extremes stay bounded: a 1-minute half-life fades in 5 steps.
        state.avatar = AvatarState(effects: [.init(kind: .sweat, peak: 1, startedAt: NOW, halfLifeMinutes: 1)])
        XCTAssertLessThan(WidgetPolicy.timelineDates(.state(cache(1, widget: state)), now: NOW, zone: CHICAGO).count, 15)
    }
}

final class AvatarIdentitySaveTests: XCTestCase {
    /// Review item 16: the identity file carries a schema version.
    func testIdentityFilesAreVersioned() throws {
        let store = AvatarIdentityStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try store.write(AvatarIdentity(skinTone: 1))
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        XCTAssertEqual(written["schema"] as? Int, AvatarIdentity.currentSchema)
        // Files from before versioning (no "schema") still read.
        try Data(#"{"skin_tone": 4, "hair_style": 2, "hair_color": 1, "glasses": true, "outfit": 2, "body": 1}"#.utf8)
            .write(to: store.fileURL)
        XCTAssertEqual(store.read(), AvatarIdentity(skinTone: 4, hairStyle: 2, hairColor: 1, glasses: true, outfit: 2, body: 1))
        // A newer app's format isn't guessed at.
        try Data(#"{"schema": 2, "skin_tone": 4, "hair_style": 2, "hair_color": 1, "glasses": true, "outfit": 2, "body": 1}"#.utf8)
            .write(to: store.fileURL)
        XCTAssertEqual(store.read(), AvatarIdentity())
    }

    /// Review item 16: a failed write throws (the app then keeps the old look) and
    /// leaves the previously saved identity readable.
    func testAFailedWriteThrowsAndKeepsTheSavedIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AvatarIdentityStore(directory: directory)
        let saved = AvatarIdentity(skinTone: 3, glasses: true)
        try store.write(saved)
        // Replace the file with a directory: the atomic write can no longer land.
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.write(AvatarIdentity(skinTone: 0)))
        // Unreadable now, so the default shows rather than a half-written look.
        XCTAssertEqual(store.read(), AvatarIdentity())

        let fresh = AvatarIdentityStore(directory: directory.appendingPathComponent("other"))
        try fresh.write(saved)
        XCTAssertEqual(fresh.read(), saved)
    }
}


/// Old results (decided 2026-10-05): today's keeps its traits; an earlier day's keeps only workout effects.
final class OldResultAvatarTests: XCTestCase {
    func testAnEarlierDayDropsDailyTraitsButKeepsWorkoutEffects() {
        let end = instant("2026-09-21T23:00:00Z")
        let avatar = AvatarState(eyes: .tired, eyesIntensity: 0.8, posture: .low, motion: .high, activity: .cardio,
                                 effects: [.init(kind: .glow, peak: 1, startedAt: end, halfLifeMinutes: 160)],
                                 uncertainty: .lowConfidence,
                                 evidence: .init(eyes: ["sleep_duration"], posture: ["sleep_duration", "resting_hr"],
                                                 motion: ["steps_so_far"], workout: ["last_workout"]))
        XCTAssertTrue(avatar.isValid)
        var state = widget()
        state.avatar = avatar
        let c = cache(1, widget: state)
        XCTAssertEqual(WidgetPolicy.avatar(.fresh(c)), avatar)
        XCTAssertEqual(WidgetPolicy.avatar(.stale(c)), avatar)  // same day: still true, the widget dims it
        let earlier = WidgetPolicy.avatar(.earlierDay(c))
        XCTAssertEqual(earlier, AvatarState(activity: .cardio, effects: avatar.effects,
                                            evidence: .init(workout: ["last_workout"])))
        XCTAssertTrue(earlier?.isValid == true)
        XCTAssertEqual(WidgetPolicy.avatar(.fresh(cache(1))), .unknown)  // a G1 cache without an avatar
        XCTAssertNil(WidgetPolicy.avatar(.empty))
    }
}

/// The app's bundled demo results (backend tests/engine/test_demo_states.py) are real
/// engine output; every one must decode with a valid avatar, or the demo shows `.unknown`.
final class DemoStatesTests: XCTestCase {
    func testEveryBundledDemoResultHasAValidAvatar() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../Homeostat/Homeostat/Demo/demo_states.json").standardized
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(entries.count, 10)
        for entry in entries {
            let json = try JSONSerialization.data(withJSONObject: try XCTUnwrap(entry["widget_state"]))
            XCTAssertNotNil(try JSONDecoder().decode(WidgetState.self, from: json).avatar, "\(entry["name"] ?? "?")")
        }
    }
}


/// Decided 2026-10-05: redacted widgets show a neutral avatar; missing inputs are named, not drawn.
final class PrivacyAndMissingInputTests: XCTestCase {
    func testARedactedWidgetShowsNoHealthTraits() {
        let end = instant("2026-09-22T17:50:00Z")
        var state = widget()
        state.avatar = AvatarState(eyes: .tired, eyesIntensity: 0.8, posture: .low, activity: .strength,
                                   effects: [.init(kind: .glow, peak: 1, startedAt: end, halfLifeMinutes: 160)],
                                   uncertainty: .lowConfidence, missingInputs: [.hrv])
        for display in [WidgetPolicy.Display.fresh(cache(1, widget: state)), .stale(cache(1, widget: state)),
                        .earlierDay(cache(1, widget: state))] {
            XCTAssertEqual(WidgetPolicy.avatar(display, redacted: true), AvatarState())
            XCTAssertNotEqual(WidgetPolicy.avatar(display), AvatarState())
        }
        XCTAssertNil(WidgetPolicy.avatar(.empty, redacted: true))
    }

    func testMissingInputsAreDescribedAndValidated() {
        let a = AvatarState(missingInputs: [.hrv, .rhr])
        XCTAssertTrue(a.isValid)
        XCTAssertEqual(AvatarDescription.text(a, at: NOW), "Avatar; no reading today for HRV, resting heart rate")
        XCTAssertFalse(AvatarState(missingInputs: [.rhr, .hrv]).isValid)  // fixed order
        XCTAssertFalse(AvatarState(missingInputs: [.hrv, .hrv]).isValid)
        XCTAssertEqual(a.withoutDailyTraits.missingInputs, [])             // an earlier day's gaps aren't today's
    }
}


/// D10 (decided 2026-10-05): the pose follows the situation, highest priority first.
final class AvatarPoseTests: XCTestCase {
    func testThePoseFollowsTheSituation() {
        let end = instant("2026-09-22T17:50:00Z")
        let workout = AvatarState(motion: .high, activity: .strength, effects: [
            .init(kind: .sweat, peak: 1, startedAt: end, halfLifeMinutes: 20),
            .init(kind: .glow, peak: 1, startedAt: end, halfLifeMinutes: 160)])
        XCTAssertEqual(AvatarPose(workout, at: end.adding(seconds: 600)), .catchingBreath)  // beats walking
        XCTAssertEqual(AvatarPose(workout, at: end.adding(seconds: 2 * 3600)), .stretching)  // sweat gone, glow 0.59
        XCTAssertEqual(AvatarPose(workout, at: end.adding(seconds: 4 * 3600)), .walking)     // glow 0.35: done stretching
        XCTAssertEqual(AvatarPose(AvatarState(motion: .low), at: NOW), .still)
        XCTAssertEqual(AvatarPose(AvatarState(posture: .low), at: NOW), .standing)  // posture shifts any pose
        XCTAssertEqual(AvatarPose(AvatarState(), at: NOW), .standing)
        // A redacted widget's neutral avatar always stands.
        XCTAssertEqual(AvatarPose(WidgetPolicy.avatar(.fresh(cache(1)), redacted: true)!, at: NOW), .standing)
    }
}

/// The hand-written Instant.parse (2026-10-06, for load speed) must equal the
/// earlier regex + Calendar parser on every valid timestamp.
final class InstantParseTests: XCTestCase {
    /// The previous implementation, kept as the reference.
    static func reference(_ text: String) -> Instant? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$"#
        guard let match = text.wholeMatch(of: try! Regex(pattern)) else { return nil }
        func group(_ i: Int) -> String? { match.output[i].substring.map(String.init) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let base = calendar.date(from: DateComponents(year: Int(group(1)!), month: Int(group(2)!), day: Int(group(3)!),
                                                      hour: Int(group(4)!), minute: Int(group(5)!), second: Int(group(6)!)))!
        var micros = Int64(base.timeIntervalSince1970) * 1_000_000
        if let fraction = group(7) { micros += Int64((fraction + "000000").prefix(6))! }
        let zone = group(8)!
        if zone != "Z" {
            let sign: Int64 = zone.hasPrefix("-") ? -1 : 1
            micros -= sign * (Int64(zone.dropFirst().prefix(2))! * 3600 + Int64(zone.suffix(2))! * 60) * 1_000_000
        }
        return Instant(microseconds: micros)
    }

    func testMatchesTheReferenceOnValidTimestamps() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            let year = Int.random(in: 1900...2100, using: &rng), month = Int.random(in: 1...12, using: &rng)
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            let maxDay = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
            var text = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, Int.random(in: 1...maxDay, using: &rng),
                              Int.random(in: 0...23, using: &rng), Int.random(in: 0...59, using: &rng),
                              Int.random(in: 0...59, using: &rng))
            let digits = Int.random(in: 0...9, using: &rng)
            if digits > 0 { text += "." + (0..<digits).map { _ in String(Int.random(in: 0...9, using: &rng)) }.joined() }
            text += Bool.random(using: &rng) ? "Z"
                : String(format: "%@%02d:%02d", Bool.random(using: &rng) ? "+" : "-",
                         Int.random(in: 0...14, using: &rng), [0, 30, 45].randomElement(using: &rng)!)
            XCTAssertEqual(Instant.parse(text), Self.reference(text), text)
        }
        XCTAssertEqual(Instant.parse("2026-09-22T18:00:00Z"), NOW)
        XCTAssertEqual(Instant.parse("2024-02-29T23:59:59.999999999+00:00"), Self.reference("2024-02-29T23:59:59.999999999+00:00"))
        XCTAssertEqual(Instant.parse("1969-12-31T23:59:59.5Z")?.microseconds, -500_000)
    }

    func testRejectsMalformedAndImpossibleTimestamps() {
        for text in ["", "2026-09-22", "2026-09-22T18:00:00", "2026-09-22 18:00:00Z", "2026-09-22T18:00:00z",
                     "2026-09-22T18:00:00.Z", "2026-09-22T18:00:00.1234567890Z", "2026-09-22T18:00:00+0500",
                     "2026-09-22T18:00:00Zjunk", "2026-13-01T00:00:00Z", "2026-02-29T00:00:00Z", "2026-04-31T00:00:00Z",
                     "2026-09-22T24:00:00Z", "2026-09-22T18:60:00Z", "2026-09-22T18:00:60Z", "0000-01-01T00:00:00Z",
                     "2026-09-22T18:00:00+24:00", "2026-09-22T18:00:00+05:60", "２０２６-09-22T18:00:00Z"] {
            XCTAssertNil(Instant.parse(text), text)
        }
    }
}
