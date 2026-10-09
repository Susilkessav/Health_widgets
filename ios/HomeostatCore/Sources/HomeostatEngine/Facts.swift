import Foundation

extension DisplayFacts {
    /// The facts in a HealthState, from its JSON (the shape stored with every
    /// result and returned by the snapshot path). Nil if the shape is unexpected.
    public init?(healthState s: JSONValue) {
        func number(_ value: JSONValue?) -> Double? {
            switch value {
            case .int(let n)?: Double(n)
            case .double(let d)?: d
            default: nil
            }
        }
        func domain(_ name: String) -> Domain? {
            guard let state = s[name]?["state"]?.string, let confidence = number(s[name]?["confidence"]) else { return nil }
            return Domain(state: state, confidence: confidence)
        }
        guard let sleep = domain("sleep"), let recovery = domain("recovery"), let movement = domain("movement"),
              let workout = domain("workout"), let required = number(s["calibration"]?["required_days"]),
              case .object(let days)? = s["calibration"]?["domains"], case .array(let drivers)? = s["drivers"] else {
            return nil
        }
        let measures = drivers.compactMap { d -> Measure? in
            guard let id = d["id"]?.string, let domain = d["domain"]?.string else { return nil }
            return Measure(id: id, domain: domain, value: number(d["value"]), baseline: number(d["baseline"]),
                           unit: d["unit"]?.string, observedAt: d["observed_at"]?.string.flatMap(Instant.parse),
                           confidence: number(d["confidence"]) ?? 0)
        }
        self.init(sleep: sleep, recovery: recovery, movement: movement, workout: workout, measures: measures,
                  learningDays: days.compactMapValues { number($0).map(Int.init) }, requiredDays: Int(required))
    }
}
