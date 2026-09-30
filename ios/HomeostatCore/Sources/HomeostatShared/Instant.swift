import Foundation

/// A UTC instant at whole-microsecond precision.
///
/// The backend stores and hashes times at microsecond precision, and step
/// snapshot IDs embed Python's `datetime.isoformat()` text. Holding integer
/// microseconds (never a floating-point `Date`) makes both exact.
public struct Instant: Hashable, Comparable, Codable, Sendable {
    public let microseconds: Int64

    public init(microseconds: Int64) {
        self.microseconds = microseconds
    }

    /// Rounds a `Date` to the nearest microsecond.
    public init(_ date: Date) {
        microseconds = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    public var date: Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
    }

    public static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.microseconds < rhs.microseconds }

    public func adding(seconds: Int64) -> Instant { Instant(microseconds: microseconds + seconds * 1_000_000) }

    /// `YYYY-MM-DDTHH:MM:SS[.ffffff]` in UTC, with the fraction only when non-zero,
    /// exactly as Python's `isoformat()` writes it.
    private var utcText: String {
        let seconds = Int64((Double(microseconds) / 1_000_000).rounded(.down))
        let fraction = microseconds - seconds * 1_000_000
        let parts = Instant.utcCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        var text = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", parts.year!, parts.month!, parts.day!,
                          parts.hour!, parts.minute!, parts.second!)
        if fraction != 0 {
            text += String(format: ".%06lld", fraction)
        }
        return text
    }

    /// Python `utc(dt).isoformat()`: used inside step snapshot IDs.
    public var pythonISO: String { utcText + "+00:00" }

    /// The wire form: ISO 8601 in UTC with a `Z` suffix.
    public var wire: String { utcText + "Z" }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = Instant.parse(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "not an ISO 8601 instant"))
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wire)
    }

    /// Parses ISO 8601 with an offset or `Z`, keeping up to six fractional digits.
    public static func parse(_ text: String) -> Instant? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$"#
        guard let match = text.wholeMatch(of: try! Regex(pattern)) else { return nil }
        func group(_ index: Int) -> String? {
            match.output[index].substring.map(String.init)
        }
        var components = DateComponents()
        components.year = Int(group(1)!)
        components.month = Int(group(2)!)
        components.day = Int(group(3)!)
        components.hour = Int(group(4)!)
        components.minute = Int(group(5)!)
        components.second = Int(group(6)!)
        guard let base = utcCalendar.date(from: components) else { return nil }
        var micros = Int64(base.timeIntervalSince1970) * 1_000_000
        if let fraction = group(7) {
            let padded = (fraction + "000000").prefix(6)
            micros += Int64(padded)!
        }
        let zone = group(8)!
        if zone != "Z" {
            let sign: Int64 = zone.hasPrefix("-") ? -1 : 1
            let hours = Int64(zone.dropFirst().prefix(2))!
            let minutes = Int64(zone.suffix(2))!
            micros -= sign * (hours * 3600 + minutes * 60) * 1_000_000
        }
        return Instant(microseconds: micros)
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

/// A local calendar day, `YYYY-MM-DD`.
public struct LocalDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int, month: Int, day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Parses `YYYY-MM-DD`.
    public init?(_ text: String) {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    public init(from decoder: Decoder) throws {
        guard let day = LocalDay(try decoder.singleValueContainer().decode(String.self)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a date"))
        }
        self = day
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Local-day arithmetic in an explicit IANA zone. Mirrors the backend's rules:
/// a day starts at its first existing instant (01:00 where DST skips midnight).
public struct Zone: Sendable {
    public let identifier: String
    let calendar: Calendar

    public init?(_ identifier: String) {
        guard let timeZone = TimeZone(identifier: identifier) else { return nil }
        self.identifier = identifier
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    public func day(of instant: Instant) -> LocalDay {
        let parts = calendar.dateComponents([.year, .month, .day], from: instant.date)
        return LocalDay(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// The first instant of a local day.
    public func start(of day: LocalDay) -> Instant {
        // Noon always exists; startOfDay then finds the day's first valid instant.
        let noon = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))!
        return Instant(calendar.startOfDay(for: noon))
    }

    public func adding(days: Int, to day: LocalDay) -> LocalDay {
        let noon = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))!
        return self.day(of: Instant(calendar.date(byAdding: .day, value: days, to: noon)!))
    }

    /// The instant of `hour`:00 on a local day (the earlier one if repeated).
    public func instant(on day: LocalDay, hour: Int) -> Instant {
        Instant(calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour))!)
    }

    /// Seconds since local midnight on the wall clock, ignoring fractions.
    public func wallSeconds(of instant: Instant) -> Int {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: instant.date)
        return parts.hour! * 3600 + parts.minute! * 60 + parts.second!
    }

    /// The local wall-clock time of an instant, as (hour, minute).
    public func wallClock(of instant: Instant) -> (hour: Int, minute: Int) {
        let parts = calendar.dateComponents([.hour, .minute], from: instant.date)
        return (parts.hour!, parts.minute!)
    }
}
