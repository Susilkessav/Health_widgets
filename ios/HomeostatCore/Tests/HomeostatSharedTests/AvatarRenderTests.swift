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
                            + (activity == .none ? [] : [.init(kind: .glow, peak: 1, startedAt: end, halfLifeMinutes: 160)]),
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

/// Display modes (review item 13) for visual review: set AVATAR_MODES_SHEET=/path.png.
/// Tinted is simulated as iOS draws it: only opacity survives, in one tint colour.
@MainActor
final class AvatarModesSheetTests: XCTestCase {
    func tinted(_ image: CGImage) throws -> CGImage {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB(), info = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: space, bitmapInfo: info))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: pixels.count, by: 4) {  // tint (0.55, 0.75, 1.0) over a dark background
            let a = Double(pixels[i + 3]) / 255
            pixels[i] = UInt8(30 + a * (140 - 30)); pixels[i + 1] = UInt8(34 + a * (190 - 34))
            pixels[i + 2] = UInt8(48 + a * (255 - 48)); pixels[i + 3] = 255
        }
        let out = try XCTUnwrap(CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: info))
        return try XCTUnwrap(out.makeImage())
    }

    func testModesSheet() throws {
        guard let path = ProcessInfo.processInfo.environment["AVATAR_MODES_SHEET"] else { throw XCTSkip("set AVATAR_MODES_SHEET") }
        let start = NOW.adding(seconds: -600)
        let scenes: [AvatarState] = [
            AvatarState(posture: .upright, evidence: .init(posture: ["hrv_sdnn"])),
            AvatarState(evidence: .init()),
            AvatarState(eyes: .tired, eyesIntensity: 0.9, posture: .low, uncertainty: .lowConfidence,
                        evidence: .init(eyes: ["sleep_duration"], posture: ["sleep_duration"])),
            AvatarState(motion: .low, evidence: .init(motion: ["steps_so_far"])),
            AvatarState(motion: .high, evidence: .init(motion: ["steps_so_far"])),
            AvatarState(activity: .strength, effects: [.init(kind: .sweat, peak: 1, startedAt: start, halfLifeMinutes: 20),
                                                        .init(kind: .glow, peak: 1, startedAt: start, halfLifeMinutes: 160)],
                        evidence: .init(workout: ["last_workout"])),
        ]
        let identity = AvatarIdentity(skinTone: 4, hairStyle: 1, glasses: true, outfit: 1)
        var rows: [[CGImage]] = []
        for mode in 0..<4 {  // standard, dark, increased contrast, tinted
            var row: [CGImage] = []
            for avatar in scenes {
                let view = AvatarView(identity: identity, avatar: avatar, time: NOW, zone: CHICAGO, accented: mode == 3)
                    .frame(width: 92, height: 158)
                    .environment(\.colorScheme, mode == 1 ? .dark : .light)
                    .environment(\._colorSchemeContrast, mode == 2 ? .increased : .standard)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                row.append(mode == 3 ? try tinted(image) : image)
            }
            rows.append(row)
        }
        let cellW = rows[0][0].width, cellH = rows[0][0].height, gap = 12
        let w = scenes.count * (cellW + gap), h = rows.count * (cellH + gap)
        let canvas = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(gray: 1, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (r, row) in rows.enumerated() {
            for (c, image) in row.enumerated() {
                canvas.draw(image, in: CGRect(x: c * (cellW + gap), y: h - (r + 1) * (cellH + gap), width: cellW, height: cellH))
            }
        }
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(canvas.makeImage()))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
