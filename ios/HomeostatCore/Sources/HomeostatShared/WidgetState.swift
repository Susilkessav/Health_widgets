import Foundation

/// The widget payload (backend `widget_state.py`).
public struct WidgetState: Codable, Hashable, Sendable {
    public var version: String
    public var effectiveAt: Instant
    public var presentation: Presentation
    public var primaryTrait: PrimaryTrait
    public var freshness: Freshness

    public init(version: String = "widget-state@0.1.0", effectiveAt: Instant, presentation: Presentation,
                primaryTrait: PrimaryTrait, freshness: Freshness) {
        self.version = version
        self.effectiveAt = effectiveAt
        self.presentation = presentation
        self.primaryTrait = primaryTrait
        self.freshness = freshness
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
        case version, effectiveAt = "effective_at", presentation, primaryTrait = "primary_trait", freshness
    }
}
