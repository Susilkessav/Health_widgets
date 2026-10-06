import ImageIO
import SwiftUI
import XCTest
@testable import HomeostatShared

/// PNG references for the prototype renderer. Review changes deliberately;
/// UPDATE_AVATAR_SNAPSHOTS=1 updates them, ordinary runs never write them.
@MainActor
final class AvatarSnapshotTests: XCTestCase {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Avatar")

    func normalized(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    func testPrototypeReferences() throws {
        let update = ProcessInfo.processInfo.environment["UPDATE_AVATAR_SNAPSHOTS"] == "1"
        let night = instant("2026-09-23T03:00:00Z")
        let workout = AvatarState(activity: .strength, effects: [
            .init(kind: .sweat, peak: 1, startedAt: NOW.adding(seconds: -600), halfLifeMinutes: 20),
            .init(kind: .glow, peak: 1, startedAt: NOW.adding(seconds: -600), halfLifeMinutes: 160)],
            evidence: .init(workout: ["last_workout"]))
        let tired = AvatarState(eyes: .tired, eyesIntensity: 0.8, posture: .low, uncertainty: .lowConfidence,
                               evidence: .init(eyes: ["sleep_duration"], posture: ["hrv", "rhr"]))
        let scenes: [(String, AvatarState, Instant)] = [
            ("neutral", AvatarState(), NOW), ("tired", tired, NOW),
            ("workout", workout, NOW), ("night-calibrating", AvatarState(uncertainty: .calibrating), night),
            ("redacted", AvatarState(), night),
        ]
        if update { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        func check(_ view: some View, _ file: String) throws {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let path = root.appendingPathComponent(file)
            if update {
                let bitmap = NSBitmapImageRep(cgImage: image)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
                return
            }
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(path as CFURL, nil), "missing snapshot: \(file)")
            let expected = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, expected.width)
            XCTAssertEqual(image.height, expected.height)
            let a = try normalized(image), b = try normalized(expected)
            guard a.count == b.count else { return XCTFail("snapshot size differs") }
            var sum = 0.0
            for index in a.indices { sum += abs(Double(a[index]) - Double(b[index])) }
            XCTAssertLessThan(sum / Double(a.count * 255), 0.002, "visual regression: \(file)")
        }
        let identity = AvatarIdentity(skinTone: 4, hairStyle: 1, glasses: true, outfit: 1)
        for (name, avatar, at) in scenes {
            for small in [false, true] {
                for dark in [false, true] {
                    let size = small ? CGSize(width: 158, height: 95) : CGSize(width: 92, height: 158)
                    let view = AvatarView(identity: identity, avatar: avatar, time: at, zone: CHICAGO,
                                          framing: small ? .waistUp : .fullBody)
                        .frame(width: size.width, height: size.height)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    try check(view, "\(name)-\(small ? "small" : "medium")-\(dark ? "dark" : "light").png")
                }
            }
        }
        // Display modes (review item 13): tinted keeps only opacity; increased contrast adds outlines.
        for (name, avatar, at) in scenes where ["tired", "workout"].contains(name) {
            let size = CGSize(width: 92, height: 158)
            try check(AvatarView(identity: identity, avatar: avatar, time: at, zone: CHICAGO, accented: true)
                .frame(width: size.width, height: size.height), "\(name)-medium-tinted.png")
            try check(AvatarView(identity: identity, avatar: avatar, time: at, zone: CHICAGO)
                .frame(width: size.width, height: size.height)
                .environment(\._colorSchemeContrast, .increased), "\(name)-medium-contrast.png")
        }
    }
}
