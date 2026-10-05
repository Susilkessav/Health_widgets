import SwiftUI
import XCTest
@testable import HomeostatShared

/// Renders the placeholder avatar for every channel value, identity option and
/// framing. Set AVATAR_SHEET=/path.png to also write a contact sheet for review.
@MainActor
final class AvatarRenderTests: XCTestCase {
    func pixels(_ view: some View, _ size: CGSize) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data else { return nil }
        return data as Data
    }

    func testEveryStateIdentityAndFramingRenders() {
        let end = NOW.adding(seconds: -600)
        var seen = Set<Data>()
        for eyes in AvatarState.Eyes.allCases {
            for posture in AvatarState.Posture.allCases {
                for activity in AvatarState.Activity.allCases {
                    let avatar = AvatarState(
                        eyes: eyes, eyesIntensity: eyes == .neutral ? 0 : 0.8, posture: posture, motion: .high,
                        activity: activity,
                        effects: [.init(kind: .sweat, peak: 1, startedAt: end, halfLifeMinutes: 20)]
                            + (activity == .none ? [] : [.init(kind: .glow, peak: 1, startedAt: end, halfLifeMinutes: 360)]),
                        uncertainty: .calibrating)
                    for framing in [AvatarFraming.fullBody, .waistUp] {
                        let image = pixels(AvatarView(identity: AvatarIdentity(), avatar: avatar, time: NOW, zone: CHICAGO,
                                                      framing: framing), CGSize(width: 80, height: 120))
                        XCTAssertNotNil(image)
                        seen.insert(image ?? Data())
                    }
                }
            }
        }
        XCTAssertEqual(seen.count, 3 * 3 * 4 * 2, "each state should look different")
        for skin in 0..<AvatarIdentity.skinTones {
            for hair in 0..<AvatarIdentity.hairStyles {
                let identity = AvatarIdentity(skinTone: skin, hairStyle: hair, hairColor: skin, glasses: hair == 1,
                                              outfit: hair, body: skin % 2)
                XCTAssertNotNil(pixels(AvatarView(identity: identity, avatar: .unknown, time: NOW, zone: CHICAGO),
                                       CGSize(width: 80, height: 120)))
            }
        }
        // Out-of-range identity values draw the default instead of crashing.
        XCTAssertNotNil(pixels(AvatarView(identity: AvatarIdentity(skinTone: 99, hairStyle: -1, hairColor: 7, outfit: 9, body: 5),
                                          avatar: .unknown, time: NOW, zone: CHICAGO), CGSize(width: 80, height: 120)))
    }

    func testContactSheet() throws {
        guard let path = ProcessInfo.processInfo.environment["AVATAR_SHEET"] else { throw XCTSkip("set AVATAR_SHEET") }
        let end = NOW.adding(seconds: -600)
        let trained = instant("2026-09-22T22:50:00Z")
        let workout: [AvatarState.Effect] = [.init(kind: .sweat, peak: 1, startedAt: trained, halfLifeMinutes: 20),
                                             .init(kind: .glow, peak: 1, startedAt: trained, halfLifeMinutes: 160)]
        let cases: [(String, AvatarState, Instant)] = [
            ("standing, day", AvatarState(), NOW),
            ("tired, low, morning", AvatarState(eyes: .tired, eyesIntensity: 0.9, posture: .low), instant("2026-09-22T12:30:00Z")),
            ("walking, upright", AvatarState(eyes: .rested, eyesIntensity: 0.8, posture: .upright, motion: .high), NOW),
            ("still", AvatarState(motion: .low), NOW),
            ("catching breath", AvatarState(activity: .strength, effects: workout), instant("2026-09-22T23:00:00Z")),
            ("stretching", AvatarState(activity: .strength, effects: workout), instant("2026-09-23T00:30:00Z")),
            ("calibrating, night", AvatarState(uncertainty: .calibrating), instant("2026-09-23T03:00:00Z")),
        ]
        let identities = [AvatarIdentity(), AvatarIdentity(skinTone: 4, hairStyle: 1, hairColor: 1, glasses: true, outfit: 1, body: 1),
                          AvatarIdentity(skinTone: 0, hairStyle: 2, hairColor: 2, outfit: 2)]
        let sheet = VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(identities.enumerated()), id: \.offset) { _, identity in
                HStack(spacing: 8) {
                    ForEach(Array(cases.enumerated()), id: \.offset) { _, item in
                        VStack(spacing: 2) {
                            HStack(spacing: 4) {
                                AvatarView(identity: identity, avatar: item.1, time: item.2, zone: CHICAGO, framing: .waistUp)
                                    .frame(width: 90, height: 90)
                                AvatarView(identity: identity, avatar: item.1, time: item.2, zone: CHICAGO)
                                    .frame(width: 70, height: 140)
                            }
                            Text(item.0).font(.system(size: 10))
                        }
                    }
                }
            }
        }.padding(8).background(.white)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
