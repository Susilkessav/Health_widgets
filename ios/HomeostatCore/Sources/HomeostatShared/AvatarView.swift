import SwiftUI

/// What part of the full-body avatar a surface shows (decision D9).
public enum AvatarFraming: Sendable {
    /// Medium widget and app.
    case fullBody
    /// Small widget: the face stays readable.
    case waistUp

    /// The visible part of the 100 x 200 avatar space.
    var visible: CGRect {
        switch self {
        case .fullBody: CGRect(x: 0, y: 4, width: 100, height: 196)
        case .waistUp: CGRect(x: 8, y: 8, width: 84, height: 104)
        }
    }
}

/// The body's arrangement for the situation (D10, decided 2026-10-05). Derived
/// from what the avatar already shows, like lighting, so it adds no contract
/// field; a redacted (neutral) avatar always stands. Highest priority first.
/// Posture still raises or lowers the head and shoulders in every pose.
public enum AvatarPose: String, Sendable, CaseIterable {
    /// Workout just finished: hands on hips, feet apart.
    case catchingBreath
    /// Soon after a workout (glow still strong): one arm raised.
    case stretching
    /// More active than usual: mid-stride.
    case walking
    /// Less active than usual: feet together, arms close.
    case still
    case standing

    /// Stretching ends after 51–211 minutes for displayed peaks 0.5–1.
    static let stretchingGlow = 0.4

    public init(_ a: AvatarState, at time: Instant) {
        if a.intensity(of: .sweat, at: time) > 0 {
            self = .catchingBreath
        } else if a.activity != .none, a.intensity(of: .glow, at: time) > Self.stretchingGlow {
            self = .stretching
        } else if a.motion == .high {
            self = .walking
        } else if a.motion == .low {
            self = .still
        } else {
            self = .standing
        }
    }
}

/// Placeholder avatar and environment (G2 T6), drawn with shapes so final art
/// can replace the painter without touching AvatarState, the widget or the app.
/// Static: the app animates it by passing `breath` and `blink`.
public struct AvatarView: View {
    public var identity: AvatarIdentity
    public var avatar: AvatarState
    public var time: Instant
    public var zone: Zone
    public var framing: AvatarFraming
    /// 0...1 breathing phase and eyelid closure from the app's animation.
    public var breath: Double
    public var blink: Double
    /// Tinted or clear Home Screen (WidgetKit's accented/vibrant rendering): iOS keeps
    /// only opacity, so the avatar is drawn as a one-colour figure with see-through features.
    public var accented: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    public init(identity: AvatarIdentity, avatar: AvatarState, time: Instant, zone: Zone,
                framing: AvatarFraming = .fullBody, breath: Double = 0, blink: Double = 0, accented: Bool = false) {
        self.identity = identity
        self.avatar = avatar
        self.time = time
        self.zone = zone
        self.framing = framing
        self.breath = breath
        self.blink = blink
        self.accented = accented
    }

    public var body: some View {
        let painter = AvatarPainter(identity: identity.valid, avatar: avatar, time: time,
                                    lighting: Lighting(at: time, zone: zone), framing: framing,
                                    breath: breath, blink: blink, accented: accented, dark: scheme == .dark,
                                    highContrast: contrast == .increased)
        Canvas { context, size in painter.draw(&context, size) }
            .overlay(alignment: .topLeading) { marker }
            .accessibilityElement()
            .accessibilityLabel(AvatarDescription.text(avatar, at: time))
    }

    @ViewBuilder var marker: some View {
        if let symbol = avatar.uncertainty.symbol {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(contrast == .increased ? .primary : .secondary)
                .padding(4)
                // Tinted: symbol only, since a filled circle would swallow it in a single tint.
                .background(accented ? AnyShapeStyle(.clear)
                            : contrast == .increased ? AnyShapeStyle(.background) : AnyShapeStyle(.thinMaterial), in: Circle())
                .padding(6)
        }
    }
}

extension AvatarState.Uncertainty {
    var symbol: String? {
        switch self {
        case .none: nil
        case .calibrating: "hourglass"
        case .lowConfidence: "questionmark"
        }
    }
}

/// The VoiceOver description: what the avatar shows, never a judgment.
public enum AvatarDescription {
    /// Each part names what is drawn and the recorded cause, never a claim about
    /// how the person feels (G2 review item 15). Order: face, body, workout, marker.
    public static func text(_ a: AvatarState, at time: Instant) -> String {
        var parts: [String] = []
        switch a.eyes {
        case .tired: parts.append((a.eyesIntensity < 0.4 ? "slightly tired-looking eyes" : "tired-looking eyes")
                                  + ": shorter sleep than usual")
        case .rested: parts.append("brighter eyes: longer sleep than usual")
        case .neutral: break
        }
        switch a.posture {
        case .low: parts.append("lower posture: recovery signals below usual")
        case .upright: parts.append("upright posture: recovery signals above usual")
        case .neutral: break
        }
        switch a.motion {
        case .low: parts.append("slower movement: less active than usual")
        case .high: parts.append("livelier movement: more active than usual")
        case .typical: break
        }
        if a.intensity(of: .sweat, at: time) > 0 { parts.append("sweat drops: workout just finished") }
        if a.activity != .none, a.intensity(of: .glow, at: time) > 0 {
            parts.append("\(a.activity.rawValue) glow: recent workout")
        }
        if !a.missingInputs.isEmpty {
            parts.append("no reading today for " + a.missingInputs.map(\.displayName).joined(separator: ", "))
        }
        switch a.uncertainty {
        case .calibrating: parts.append("hourglass: still learning your usual")
        case .lowConfidence: parts.append("question mark: some signals have low confidence or missing data")
        case .none: break
        }
        return parts.isEmpty ? "Avatar, typical look" : "Avatar; " + parts.joined(separator: "; ")
    }
}

private func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

/// Placeholder palette, indexed by AvatarIdentity's choices; also the editor's swatches.
public enum AvatarPalette {
    public static let skins = [rgb(0.98, 0.84, 0.73), rgb(0.93, 0.75, 0.60), rgb(0.84, 0.62, 0.46),
                               rgb(0.65, 0.45, 0.32), rgb(0.45, 0.30, 0.22)]
    public static let hairs = [rgb(0.12, 0.10, 0.10), rgb(0.40, 0.26, 0.16), rgb(0.86, 0.72, 0.45),
                               rgb(0.66, 0.30, 0.16), rgb(0.70, 0.70, 0.72)]
    /// (top, bottom) per outfit.
    public static let outfits = [(rgb(0.20, 0.42, 0.70), rgb(0.32, 0.33, 0.36)), (rgb(0.27, 0.55, 0.42), rgb(0.18, 0.20, 0.32)),
                                 (rgb(0.88, 0.45, 0.36), rgb(0.15, 0.15, 0.17))]
    public static let skinNames = ["Lightest", "Light", "Medium", "Deep", "Deepest"]
    public static let hairColorNames = ["Black", "Brown", "Blonde", "Red", "Grey"]
    public static let hairStyleNames = ["Short", "Long", "Bun"]
    public static let outfitNames = ["Tee", "Hoodie", "Sport"]
    public static let bodyNames = ["Slim", "Broad"]
}

struct AvatarPainter {
    let identity: AvatarIdentity
    let avatar: AvatarState
    let time: Instant
    let lighting: Lighting
    let framing: AvatarFraming
    let breath: Double
    let blink: Double
    var accented = false
    /// Dark mode: a dimmer backdrop so the widget doesn't glare beside dark ones.
    var dark = false
    /// Increased contrast: outlines, eye whites, thicker glasses and no colour wash.
    var highContrast = false

    var sky: Color {
        // Night is already dark; the other skies dim by a quarter in dark mode.
        let k = dark ? 0.75 : 1
        return switch lighting {
        case .morning: rgb(0.99 * k, 0.92 * k, 0.80 * k)
        case .day: rgb(0.84 * k, 0.92 * k, 0.99 * k)
        case .evening: rgb(0.90 * k, 0.78 * k, 0.88 * k)
        case .night: rgb(0.20, 0.22, 0.38)
        }
    }

    /// Identity colours, or a fixed light palette when tinted: iOS turns colour into
    /// opacity there, so lighter parts stay solid and dark details (eyes, mouth) read as cutouts.
    var skin: Color { accented ? rgb(0.97, 0.97, 0.97) : AvatarPalette.skins[identity.skinTone] }
    var hair: Color { accented ? rgb(0.55, 0.55, 0.55) : AvatarPalette.hairs[identity.hairColor] }
    var outfit: (top: Color, bottom: Color) {
        accented ? (rgb(0.78, 0.78, 0.78), rgb(0.62, 0.62, 0.62)) : AvatarPalette.outfits[identity.outfit]
    }
    var ink: Color { rgb(0.17, 0.15, 0.15) }

    /// Tints the avatar to match the light, so one drawing serves every time of day.
    var wash: (Color, Double) {
        switch lighting {
        case .morning: (rgb(1, 0.85, 0.6), 0.10)
        case .day: (.white, 0)
        case .evening: (rgb(1, 0.6, 0.45), 0.14)
        case .night: (rgb(0.35, 0.45, 1), 0.12)
        }
    }

    func draw(_ c: inout GraphicsContext, _ size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        c.clip(to: Path(roundedRect: bounds, cornerRadius: min(size.width, size.height) * 0.12))
        if !accented { drawEnvironment(&c, bounds) }  // tinted: the figure alone, on the system's tint

        // Avatar space: 100 x 200, centred, feet (or waist) on the bottom edge.
        let v = framing.visible
        let scale = min(size.width / v.width, size.height / v.height)
        var a = c
        a.translateBy(x: (size.width - v.width * scale) / 2 - v.minX * scale, y: size.height - v.maxY * scale)
        a.scaleBy(x: scale, y: scale)
        a.drawLayer { layer in
            if accented {
                // Filters apply per drawing operation, so convert the finished figure as one layer.
                layer.addFilter(.luminanceToAlpha)
                layer.drawLayer { figure in drawFigure(&figure) }
                return
            }
            drawFigure(&layer)
            let (color, amount) = wash
            if amount > 0, !accented, !highContrast {
                layer.blendMode = .sourceAtop
                layer.fill(Path(CGRect(x: -50, y: -50, width: 200, height: 300)), with: .color(color.opacity(amount)))
            }
        }
    }

    func drawEnvironment(_ c: inout GraphicsContext, _ r: CGRect) {
        c.fill(Path(r), with: .color(sky))
        let u = min(r.width, r.height)
        let floor = CGRect(x: 0, y: r.height * 0.86, width: r.width, height: r.height * 0.14)
        c.fill(Path(floor), with: .color(.black.opacity(lighting == .night ? 0.18 : 0.06)))
        switch lighting {
        case .morning:
            c.fill(Path(ellipseIn: CGRect(x: r.width - u * 0.30, y: u * 0.10, width: u * 0.16, height: u * 0.16)),
                   with: .color(rgb(0.98, 0.78, 0.40)))
        case .day:
            c.fill(Path(ellipseIn: CGRect(x: r.width - u * 0.28, y: u * 0.07, width: u * 0.14, height: u * 0.14)),
                   with: .color(rgb(1, 0.88, 0.45)))
            c.fill(Path(roundedRect: CGRect(x: u * 0.08, y: u * 0.16, width: u * 0.24, height: u * 0.07), cornerRadius: u * 0.035),
                   with: .color(.white.opacity(0.85)))
        case .evening:
            c.fill(Path(roundedRect: CGRect(x: u * 0.08, y: u * 0.10, width: u * 0.16, height: u * 0.24), cornerRadius: u * 0.02),
                   with: .color(rgb(0.98, 0.78, 0.45).opacity(0.75)))
        case .night:
            let moon = CGRect(x: r.width - u * 0.28, y: u * 0.08, width: u * 0.13, height: u * 0.13)
            c.fill(Path(ellipseIn: moon), with: .color(rgb(0.95, 0.93, 0.80)))
            c.fill(Path(ellipseIn: moon.offsetBy(dx: u * 0.04, dy: -u * 0.02)), with: .color(sky))
            for (x, y) in [(0.12, 0.12), (0.25, 0.22), (0.40, 0.08)] {
                c.fill(Path(ellipseIn: CGRect(x: r.width * x, y: u * y, width: u * 0.018, height: u * 0.018)),
                       with: .color(.white.opacity(0.8)))
            }
        }
    }

    func drawFigure(_ c: inout GraphicsContext) {
        let (top, bottom) = outfit
        let width = identity.body == 0 ? 1.0 : 1.18
        // Posture: upright lifts the head and squares the shoulders; low drops and
        // narrows them and tilts the head (D10: applies in every pose).
        let drop: Double = switch avatar.posture { case .upright: -3; case .neutral: 1; case .low: 6 }
        let squared: Double = switch avatar.posture { case .upright: 1.06; case .neutral: 1; case .low: 0.93 }
        let tilt: Double = avatar.posture == .low ? 6 : 0
        let pose = AvatarPose(avatar, at: time)
        let shoulderY = 62 + drop * 0.6 - breath * 0.8, headY = 34 + drop - breath * 1.0
        let shoulder = 17 * width * squared, hip = 12.5 * width, hipY = 118.0, footY = 186.0

        // Activity glow behind the body.
        let glow = avatar.intensity(of: .glow, at: time)
        if glow > 0, avatar.activity != .none {
            let color = switch avatar.activity {
            case .strength: rgb(1, 0.55, 0.25)
            case .cardio: rgb(0.15, 0.75, 0.65)
            default: rgb(0.62, 0.50, 0.95)
            }
            let halo = CGRect(x: 50 - 38 * width, y: 16, width: 76 * width, height: 176)
            if accented {
                c.stroke(Path(ellipseIn: halo.insetBy(dx: 6, dy: 6)), with: .color(.white.opacity(0.4 + 0.5 * glow)),
                         style: StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
            } else {
            c.fill(Path(ellipseIn: halo), with: .radialGradient(
                Gradient(colors: [color.opacity(0.45 * glow), color.opacity(0)]),
                center: CGPoint(x: halo.midX, y: halo.midY), startRadius: 10, endRadius: 85))
            }
        }

        // Legs and shoes: hip -> knee -> foot per side (left = -1), by pose.
        func leg(_ side: Double) -> (knee: CGPoint, foot: CGPoint) {
            let gap: Double = switch pose { case .catchingBreath: 11; case .still: 4; default: 7.5 }
            if pose == .walking {  // left foot planted, right knee lifted
                return side < 0 ? (CGPoint(x: 44, y: hipY + 34), CGPoint(x: 41, y: footY - 4))
                                : (CGPoint(x: 58, y: hipY + 28), CGPoint(x: 56, y: footY - 14))
            }
            let foot = CGPoint(x: 50 + side * gap, y: footY - 4)
            return (CGPoint(x: (50 + side * hip * 0.5 + foot.x) / 2, y: (hipY + foot.y) / 2), foot)
        }
        for side in [-1.0, 1.0] {
            let (knee, foot) = leg(side)
            var path = Path()
            path.move(to: CGPoint(x: 50 + side * hip * 0.5, y: hipY))
            path.addLine(to: knee)
            path.addLine(to: foot)
            c.stroke(path, with: .color(bottom), style: StrokeStyle(lineWidth: 10 * width, lineCap: .round, lineJoin: .round))
            c.fill(Path(roundedRect: CGRect(x: foot.x - 6 + side * 2, y: foot.y - 2, width: 12, height: 6), cornerRadius: 3),
                   with: .color(accented ? rgb(0.45, 0.45, 0.45) : rgb(0.15, 0.15, 0.17)))
        }

        // Torso and hips.
        var torso = Path()
        torso.move(to: CGPoint(x: 50 - shoulder, y: shoulderY + 6))
        torso.addQuadCurve(to: CGPoint(x: 50 - shoulder + 7, y: shoulderY), control: CGPoint(x: 50 - shoulder, y: shoulderY))
        torso.addLine(to: CGPoint(x: 50 + shoulder - 7, y: shoulderY))
        torso.addQuadCurve(to: CGPoint(x: 50 + shoulder, y: shoulderY + 6), control: CGPoint(x: 50 + shoulder, y: shoulderY))
        torso.addLine(to: CGPoint(x: 50 + hip, y: hipY - 4))
        torso.addLine(to: CGPoint(x: 50 - hip, y: hipY - 4))
        torso.closeSubpath()
        c.fill(Path(roundedRect: CGRect(x: 50 - hip, y: hipY - 8, width: hip * 2, height: 12), cornerRadius: 4),
               with: .color(bottom))
        c.fill(torso, with: .color(top))
        if highContrast { c.stroke(torso, with: .color(ink), lineWidth: 0.9) }

        // Arms (in front of the torso): shoulder -> elbow -> hand per side, skin, then a sleeve.
        func arm(_ side: Double, from s: CGPoint) -> (elbow: CGPoint, hand: CGPoint) {
            switch pose {
            case .catchingBreath:  // hands on hips
                return (CGPoint(x: s.x + side * 11, y: s.y + 22), CGPoint(x: 50 + side * (hip + 1.5), y: hipY - 12))
            case .stretching where side > 0:  // right arm overhead
                return (CGPoint(x: s.x + side * 3, y: s.y - 20), CGPoint(x: s.x + side * 1, y: s.y - 42))
            case .walking:  // bent, pumping
                return (CGPoint(x: s.x + side * 4, y: s.y + 21), CGPoint(x: s.x - side * (side < 0 ? 3 : 1), y: s.y + 33))
            case .still:  // hands together in front
                return (CGPoint(x: s.x + side * 1, y: s.y + 24), CGPoint(x: 50 + side * 2.5, y: hipY - 14))
            default:
                return (CGPoint(x: s.x + side * 3, y: s.y + 22), CGPoint(x: s.x + side * 6, y: s.y + 42))
            }
        }
        for side in [-1.0, 1.0] {
            let from = CGPoint(x: 50 + side * (shoulder - 3), y: shoulderY + 4)
            let (elbow, hand) = arm(side, from: from)
            var path = Path()
            path.move(to: from)
            path.addLine(to: elbow)
            path.addLine(to: hand)
            c.stroke(path, with: .color(skin), style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round))
            var sleeve = Path()
            sleeve.move(to: from)
            sleeve.addLine(to: CGPoint(x: from.x + (elbow.x - from.x) * 0.7, y: from.y + (elbow.y - from.y) * 0.7))
            c.stroke(sleeve, with: .color(top), style: StrokeStyle(lineWidth: 8, lineCap: .round))
        }


        // Head group, tilted about the neck.
        var h = c
        h.translateBy(x: 50, y: shoulderY)
        h.rotate(by: .degrees(tilt))
        h.translateBy(x: -50, y: -shoulderY)
        if identity.hairStyle == 1 {  // long hair sits behind the head and neck
            h.fill(Path(roundedRect: CGRect(x: 35, y: headY - 12, width: 30, height: 34), cornerRadius: 10), with: .color(hair))
        }
        h.fill(Path(CGRect(x: 46, y: headY + 10, width: 8, height: shoulderY - headY - 8)), with: .color(skin))
        h.fill(Path(ellipseIn: CGRect(x: 37, y: headY - 15, width: 26, height: 30)), with: .color(skin))
        if highContrast {
            h.stroke(Path(ellipseIn: CGRect(x: 37, y: headY - 15, width: 26, height: 30)), with: .color(ink), lineWidth: 0.9)
        }
        drawFace(&h, headY: headY, skin: skin)
        drawHair(&h, headY: headY, hair: hair)
        if identity.glasses {
            let frameColor = identity.skinTone >= 3 && !accented ? rgb(0.88, 0.88, 0.90) : rgb(0.15, 0.15, 0.17)
            let frameWidth = highContrast ? 0.95 : 0.65
            for x in [45.5, 54.5] {
                h.stroke(Path(ellipseIn: CGRect(x: x - 3.6, y: headY - 2.4, width: 7.2, height: 6.6)),
                         with: .color(frameColor), lineWidth: frameWidth)
            }
            var bridge = Path()
            bridge.move(to: CGPoint(x: 49.1, y: headY + 0.6))
            bridge.addLine(to: CGPoint(x: 50.9, y: headY + 0.6))
            h.stroke(bridge, with: .color(frameColor), lineWidth: frameWidth)
        }
        let sweat = avatar.intensity(of: .sweat, at: time)
        if sweat > 0 {
            for (x, y) in [(35.5, headY - 3), (64.5, headY + 1), (62.5, headY - 10)] {
                var drop = Path()
                drop.move(to: CGPoint(x: x, y: y - 4.2))
                drop.addQuadCurve(to: CGPoint(x: x, y: y + 2.6), control: CGPoint(x: x + 3.8, y: y + 2))
                drop.addQuadCurve(to: CGPoint(x: x, y: y - 4.2), control: CGPoint(x: x - 3.8, y: y + 2))
                h.fill(drop, with: .color(rgb(0.30, 0.62, 0.95).opacity(min(1, 0.4 + sweat))))
                h.stroke(drop, with: .color(.white.opacity(0.7)), lineWidth: 0.5)
            }
        }
    }

    func drawFace(_ c: inout GraphicsContext, headY: Double, skin: Color) {
        let ink = rgb(0.17, 0.15, 0.15)
        let tired = avatar.eyes == .tired ? avatar.eyesIntensity : 0
        let eyeHeight = avatar.eyes == .rested ? 4.6 : 4.2
        // Eyelid closure: tiredness (up to 70%) or a blink, whichever is lower down.
        let lid = max(tired > 0 ? 0.25 + 0.45 * tired : 0, blink)
        for x in [45.5, 54.5] {
            let eye = CGRect(x: x - 1.9, y: headY + 1 - eyeHeight / 2, width: 3.8, height: eyeHeight)
            if (identity.skinTone >= 3 || highContrast) && !accented {
                c.fill(Path(ellipseIn: eye.insetBy(dx: -0.4, dy: -0.4)), with: .color(.white.opacity(0.9)))
            }
            c.fill(Path(ellipseIn: eye), with: .color(ink))
            if avatar.eyes == .rested {
                c.fill(Path(ellipseIn: CGRect(x: x - 0.4, y: eye.minY + 0.7, width: 1.1, height: 1.1)), with: .color(.white))
            }
            if lid > 0 {
                let cover = CGRect(x: eye.minX - 0.6, y: eye.minY - 0.6, width: eye.width + 1.2, height: eye.height * lid + 0.6)
                c.fill(Path(cover), with: .color(skin))
                var line = Path()
                line.move(to: CGPoint(x: cover.minX + 0.3, y: cover.maxY))
                line.addLine(to: CGPoint(x: cover.maxX - 0.3, y: cover.maxY))
                c.stroke(line, with: .color(ink), lineWidth: 0.7)
            }
            if tired > 0 {
                var shade = Path()
                shade.move(to: CGPoint(x: x - 2.2, y: eye.maxY + 1.1))
                shade.addQuadCurve(to: CGPoint(x: x + 2.2, y: eye.maxY + 1.1), control: CGPoint(x: x, y: eye.maxY + 2.4))
                c.stroke(shade, with: .color(rgb(0.45, 0.30, 0.30).opacity(0.25 + 0.45 * tired)), lineWidth: 0.7)
            }
        }
        // Mouth: a small smile, flat when tired; never sad (principle 3.7).
        var mouth = Path()
        mouth.move(to: CGPoint(x: 46.5, y: headY + 8))
        mouth.addQuadCurve(to: CGPoint(x: 53.5, y: headY + 8),
                           control: CGPoint(x: 50, y: headY + 8 + (tired > 0 ? 0.4 : 2)))
        c.stroke(mouth, with: .color(rgb(0.60, 0.24, 0.18)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
    }

    func drawHair(_ c: inout GraphicsContext, headY: Double, hair: Color) {
        var cap = Path()
        cap.move(to: CGPoint(x: 36.6, y: headY - 1))
        cap.addQuadCurve(to: CGPoint(x: 50, y: headY - 16.5), control: CGPoint(x: 36, y: headY - 16))
        cap.addQuadCurve(to: CGPoint(x: 63.4, y: headY - 1), control: CGPoint(x: 64, y: headY - 16))
        cap.addQuadCurve(to: CGPoint(x: 50, y: headY - 8), control: CGPoint(x: 58, y: headY - 9))
        cap.addQuadCurve(to: CGPoint(x: 36.6, y: headY - 1), control: CGPoint(x: 42, y: headY - 9))
        c.fill(cap, with: .color(hair))
        if identity.hairStyle == 2 {  // bun
            c.fill(Path(ellipseIn: CGRect(x: 44.5, y: headY - 23, width: 11, height: 9)), with: .color(hair))
        }
    }
}
