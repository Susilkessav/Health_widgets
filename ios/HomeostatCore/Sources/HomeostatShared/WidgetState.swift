import Foundation

/// The widget payload (backend `widget_state.py`).
public struct WidgetState: Codable, Hashable, Sendable {
    public var version: String
    public var effectiveAt: Instant
    public var presentation: Presentation
    public var primaryTrait: PrimaryTrait
    public var freshness: Freshness
    /// Added in widget-state@0.2.0 (G2); nil in a 0.1.x cache written before it.
    public var avatar: AvatarState?

    public init(version: String = "widget-state@0.2.0", effectiveAt: Instant, presentation: Presentation,
                primaryTrait: PrimaryTrait, freshness: Freshness, avatar: AvatarState? = nil) {
        self.version = version
        self.effectiveAt = effectiveAt
        self.presentation = presentation
        self.primaryTrait = primaryTrait
        self.freshness = freshness
        self.avatar = avatar
    }

    public struct Presentation: Codable, Hashable, Sendable {
        public var icon: String
        public var headline: String
        public var detail: String?
        public var secondary: String?

        public init(icon: String, headline: String, detail: String? = nil, secondary: String? = nil) {
            self.icon = icon
            self.headline = headline
            self.detail = detail
            self.secondary = secondary
        }
    }

    public struct PrimaryTrait: Codable, Hashable, Sendable {
        public var id: String
        public var explainable: Bool

        public init(id: String, explainable: Bool) {
            self.id = id
            self.explainable = explainable
        }
    }

    public struct Freshness: Codable, Hashable, Sendable {
        public var lastUpdatedAt: Instant

        public init(lastUpdatedAt: Instant) { self.lastUpdatedAt = lastUpdatedAt }
        enum CodingKeys: String, CodingKey { case lastUpdatedAt = "last_updated_at" }
    }

    enum CodingKeys: String, CodingKey {
        case version, effectiveAt = "effective_at", presentation, primaryTrait = "primary_trait", freshness, avatar
    }

    /// A malformed, invalid or newer-version avatar decodes as nil, so the
    /// text still shows and the widget draws the neutral `.unknown` avatar.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        effectiveAt = try c.decode(Instant.self, forKey: .effectiveAt)
        presentation = try c.decode(Presentation.self, forKey: .presentation)
        primaryTrait = try c.decode(PrimaryTrait.self, forKey: .primaryTrait)
        freshness = try c.decode(Freshness.self, forKey: .freshness)
        avatar = (try? c.decodeIfPresent(AvatarState.self, forKey: .avatar)).flatMap { $0?.isValid == true ? $0 : nil }
    }
}
