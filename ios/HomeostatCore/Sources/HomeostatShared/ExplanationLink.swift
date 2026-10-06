import Foundation

/// Local widget links never resolve a result from another installation/account.
public struct ExplanationLink: Equatable, Sendable {
    public let scope: String
    public let runID: Int64

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "homeostat", parts.host == "explain",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty, parts.fragment == nil,
              let items = parts.queryItems, items.count == 2,
              items.filter({ $0.name == "scope" }).count == 1,
              items.filter({ $0.name == "run" }).count == 1,
              let scope = items.first(where: { $0.name == "scope" })?.value, !scope.isEmpty,
              let text = items.first(where: { $0.name == "run" })?.value,
              !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let run = Int64(text), run >= 0 else { return nil }
        self.scope = scope
        runID = run
    }

    public enum Resolution: Equatable, Sendable {
        case current, updated, unavailable
    }

    public func resolve(scope currentScope: String?, run currentRun: Int64?) -> Resolution {
        guard currentScope == scope, let currentRun, currentRun >= runID else { return .unavailable }
        return currentRun == runID ? .current : .updated
    }
}
