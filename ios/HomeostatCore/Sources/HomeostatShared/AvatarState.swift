import Foundation

/// How HealthState appears on the avatar (backend `avatar_state.py`,
/// Plan/G2_plan.md section 4). Lighting and fading are not stored: they come
/// from the time the avatar is drawn, so widget timeline entries change them
/// without a recalculation.
public struct AvatarState: Codable, Hashable, Sendable {
    public enum Eyes: String, Codable, Sendable, CaseIterable { case neutral, rested, tired }
    public enum Posture: String, Codable, Sendable, CaseIterable { case upright, neutral, low }
    public enum Motion: String, Codable, Sendable, CaseIterable { case low, typical, high }
    public enum Activity: String, Codable, Sendable, CaseIterable { case none, cardio, strength, mobility }
    public enum Uncertainty: String, Codable, Sendable, CaseIterable { case none, calibrating, lowConfidence = "low_confidence" }
    /// An input with no reading today (decided 2026-10-05): explained in words, never drawn.
    public enum Input: String, Codable, Sendable, CaseIterable {
        case sleep, hrv, rhr, movement

        public var displayName: String {
            switch self {
            case .sleep: "sleep"
            case .hrv: "HRV"
            case .rhr: "resting heart rate"
            case .movement: "steps"
            }
        }
    }

    public struct Effect: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable { case sweat, glow }
        public var kind: Kind
        public var peak: Double
        public var startedAt: Instant
        public var halfLifeMinutes: Double

        public init(kind: Kind, peak: Double, startedAt: Instant, halfLifeMinutes: Double) {
            self.kind = kind
            self.peak = peak
            self.startedAt = startedAt
            self.halfLifeMinutes = halfLifeMinutes
        }

        /// Below this an effect is not drawn (decision D4).
        public static let cutoff = 0.05
        /// Half-lives a cache may carry: at least a minute (so timeline steps
        /// always advance) and at most a week (so fade times can't overflow).
        public static let halfLifeRange = 1.0...10_080.0

        /// Same rules as backend `avatar_state.py`; NaN fails every range check.
        public var isValid: Bool { (0...1).contains(peak) && Self.halfLifeRange.contains(halfLifeMinutes) }

        /// A start up to this far ahead counts as started: watch and phone clocks
        /// can differ slightly (decided 2026-10-05).
        public static let clockGraceSeconds: Int64 = 300

        /// peak · 0.5^(elapsed / half-life); 0 before the start (beyond the grace) and once faded.
        public func intensity(at time: Instant) -> Double {
            guard isValid else { return 0 }
            let elapsed = time.microseconds - startedAt.microseconds
            guard elapsed >= -Self.clockGraceSeconds * 1_000_000 else { return 0 }
            let minutes = max(0, Double(elapsed) / 60_000_000)
            let value = peak * pow(0.5, minutes / halfLifeMinutes)
            return value < Self.cutoff ? 0 : value
        }

        /// When the effect drops below the cutoff.
        public var fadedAt: Instant {
            guard isValid, peak >= Self.cutoff else { return startedAt }
            let minutes = halfLifeMinutes * log2(peak / Self.cutoff)
            var at = startedAt.adding(seconds: Int64((minutes * 60).rounded(.up)))
            // At an exact half-life boundary the value may still equal the
            // cutoff. Schedule the first whole second which actually hides it.
            while intensity(at: at) > 0 { at = at.adding(seconds: 1) }
            return at
        }

        /// First whole-second render time where a categorical threshold ends.
        func firstAtOrBelow(_ threshold: Double) -> Instant {
            guard peak > threshold else { return startedAt }
            let seconds = halfLifeMinutes * 60 * log2(peak / threshold)
            var at = startedAt.adding(seconds: Int64(seconds.rounded(.up)))
            while intensity(at: at) > threshold { at = at.adding(seconds: 1) }
            return at
        }

        enum CodingKeys: String, CodingKey {
            case kind, peak, startedAt = "started_at", halfLifeMinutes = "half_life_minutes"
        }
    }

    /// Driver ids behind each channel that differs from neutral, for tap-to-explain (G3).
    public struct Evidence: Codable, Hashable, Sendable {
        public var eyes: [String]
        public var posture: [String]
        public var motion: [String]
        public var workout: [String]

        public init(eyes: [String] = [], posture: [String] = [], motion: [String] = [], workout: [String] = []) {
            self.eyes = eyes
            self.posture = posture
            self.motion = motion
            self.workout = workout
        }
    }

    public var version: String
    public var eyes: Eyes
    public var eyesIntensity: Double
    public var posture: Posture
    public var motion: Motion
    public var activity: Activity
    public var effects: [Effect]
    public var uncertainty: Uncertainty
    public var evidence: Evidence
    public var missingInputs: [Input]

    public init(version: String = "avatar-state@0.1.0", eyes: Eyes = .neutral, eyesIntensity: Double = 0,
                posture: Posture = .neutral, motion: Motion = .typical, activity: Activity = .none,
                effects: [Effect] = [], uncertainty: Uncertainty = .none, evidence: Evidence = Evidence(),
                missingInputs: [Input] = []) {
        self.version = version
        self.eyes = eyes
        self.eyesIntensity = eyesIntensity
        self.posture = posture
        self.motion = motion
        self.activity = activity
        self.effects = effects
        self.uncertainty = uncertainty
        self.evidence = evidence
        self.missingInputs = missingInputs
    }

    /// What a G1 cache (no avatar) or an invalid avatar shows: neutral, honestly marked as unknown.
    public static let unknown = AvatarState(uncertainty: .lowConfidence)

    /// Versions this build can draw.
    public static let supportedVersionPrefix = "avatar-state@0.1."

    /// The backend contract's invariants (avatar_state.py), checked before a
    /// cached avatar is drawn or scheduled.
    public var isValid: Bool {
        let kinds = effects.map(\.kind)
        return version.hasPrefix(Self.supportedVersionPrefix)
            && (0...1).contains(eyesIntensity) && (eyes == .neutral) == (eyesIntensity == 0)
            && Set(kinds).count == kinds.count
            && kinds.contains(.glow) == (activity != .none)
            && effects.allSatisfy(\.isValid)
            && (eyes != .neutral) == !evidence.eyes.isEmpty && (posture != .neutral) == !evidence.posture.isEmpty
            && (motion != .typical) == !evidence.motion.isEmpty && !effects.isEmpty == !evidence.workout.isEmpty
            && [evidence.eyes, evidence.posture, evidence.motion, evidence.workout].joined().allSatisfy { !$0.isEmpty }
            && missingInputs == Input.allCases.filter(missingInputs.contains)  // unique, fixed order
    }

    /// For a result from an earlier day (decided 2026-10-05): yesterday's eyes,
    /// posture and movement don't pose as today's. Workout effects stay, since
    /// they fade by the clock.
    public var withoutDailyTraits: AvatarState {
        AvatarState(version: version, activity: activity, effects: effects,
                    evidence: Evidence(workout: evidence.workout))
    }

    public func intensity(of kind: Effect.Kind, at time: Instant) -> Double {
        effects.first { $0.kind == kind }?.intensity(at: time) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case version, eyes, eyesIntensity = "eyes_intensity", posture, motion, activity, effects, uncertainty, evidence
        case missingInputs = "missing_inputs"
    }
}

/// Environment lighting from the local time the avatar is drawn.
public enum Lighting: String, Sendable, CaseIterable {
    case morning, day, evening, night

    public init(at time: Instant, zone: Zone) {
        switch zone.wallClock(of: time).hour {
        case 5..<11: self = .morning
        case 11..<17: self = .day
        case 17..<21: self = .evening
        default: self = .night
        }
    }

    /// Local hours at which the lighting changes.
    public static let boundaries = [5, 11, 17, 21]
}

/// The user's chosen appearance (decision D5). Device-only; health data never
/// changes it, and the avatar mapper never sees it.
public struct AvatarIdentity: Codable, Hashable, Sendable {
    public static let skinTones = 5, hairStyles = 3, hairColors = 5, outfits = 3, bodies = 2
    /// The file format. 1 = these fields; files written before versioning had no
    /// "schema" and read as 1. Bump with a migration in init(from:) when fields change.
    public static let currentSchema = 1

    public var skinTone: Int
    public var hairStyle: Int
    public var hairColor: Int
    public var glasses: Bool
    public var outfit: Int
    public var body: Int

    public init(skinTone: Int = 2, hairStyle: Int = 0, hairColor: Int = 0, glasses: Bool = false, outfit: Int = 0,
                body: Int = 0) {
        self.skinTone = skinTone
        self.hairStyle = hairStyle
        self.hairColor = hairColor
        self.glasses = glasses
        self.outfit = outfit
        self.body = body
    }

    /// Out-of-range choices (from a newer or corrupt file) fall back to defaults.
    public var valid: AvatarIdentity {
        func pick(_ value: Int, _ count: Int, _ fallback: Int) -> Int { (0..<count).contains(value) ? value : fallback }
        let base = AvatarIdentity()
        return AvatarIdentity(skinTone: pick(skinTone, Self.skinTones, base.skinTone),
                              hairStyle: pick(hairStyle, Self.hairStyles, base.hairStyle),
                              hairColor: pick(hairColor, Self.hairColors, base.hairColor), glasses: glasses,
                              outfit: pick(outfit, Self.outfits, base.outfit), body: pick(body, Self.bodies, base.body))
    }

    enum CodingKeys: String, CodingKey {
        case schema, skinTone = "skin_tone", hairStyle = "hair_style", hairColor = "hair_color", glasses, outfit, body
    }

    public struct NewerSchema: Error {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A newer app's format: don't guess at it (the store keeps it and shows the default).
        guard try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1 <= Self.currentSchema else { throw NewerSchema() }
        self.init(skinTone: try c.decode(Int.self, forKey: .skinTone), hairStyle: try c.decode(Int.self, forKey: .hairStyle),
                  hairColor: try c.decode(Int.self, forKey: .hairColor), glasses: try c.decode(Bool.self, forKey: .glasses),
                  outfit: try c.decode(Int.self, forKey: .outfit), body: try c.decode(Int.self, forKey: .body))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentSchema, forKey: .schema)
        try c.encode(skinTone, forKey: .skinTone)
        try c.encode(hairStyle, forKey: .hairStyle)
        try c.encode(hairColor, forKey: .hairColor)
        try c.encode(glasses, forKey: .glasses)
        try c.encode(outfit, forKey: .outfit)
        try c.encode(body, forKey: .body)
    }
}

/// The identity file in the App Group, next to the widget cache.
public struct AvatarIdentityStore: Sendable {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("avatar", isDirectory: true).appendingPathComponent("identity.json")
    }

    public static func shared() -> AvatarIdentityStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedWidgetStore.appGroup)
            .map(AvatarIdentityStore.init(directory:))
    }

    /// The saved identity, or the default when there is none or it can't be read.
    public func read() -> AvatarIdentity {
        guard let data = try? Data(contentsOf: fileURL),
              let identity = try? JSONDecoder().decode(AvatarIdentity.self, from: data) else { return AvatarIdentity() }
        return identity.valid
    }

    public func write(_ identity: AvatarIdentity) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(identity.valid).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
