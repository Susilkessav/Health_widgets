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

    /// Parses `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`, keeping up to six fractional
    /// digits (truncated). Rejects impossible dates and times, as the Python contracts do.
    /// Hand-written: every stored event carries several timestamps, and the earlier
    /// regex + Calendar version made loading the event log take ~0.45 s on a phone.
    public static func parse(_ text: String) -> Instant? {
        let b = Array(text.utf8)
        func digits(_ at: Int, _ count: Int) -> Int? {
            guard at + count <= b.count else { return nil }
            var value = 0
            for i in at..<(at + count) {
                let d = Int(b[i]) - 48
                guard (0...9).contains(d) else { return nil }
                value = value * 10 + d
            }
            return value
        }
        func at(_ i: Int, _ c: Character) -> Bool { i < b.count && b[i] == c.asciiValue! }
        guard b.count >= 20, at(4, "-"), at(7, "-"), at(10, "T"), at(13, ":"), at(16, ":"),
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              year >= 1, (1...12).contains(month), hour < 24, minute < 60, second < 60 else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        guard (1...monthDays).contains(day) else { return nil }

        var i = 19
        var micros: Int64 = 0
        if at(i, ".") {
            i += 1
            let start = i
            while i < b.count, (48...57).contains(b[i]) { i += 1 }
            let count = i - start
            guard (1...9).contains(count) else { return nil }
            for k in 0..<6 { micros = micros * 10 + (k < count ? Int64(b[start + k] - 48) : 0) }
        }
        var offset: Int64 = 0
        if at(i, "Z") {
            i += 1
        } else if at(i, "+") || at(i, "-") {
            guard at(i + 3, ":"), let h = digits(i + 1, 2), let m = digits(i + 4, 2), h < 24, m < 60 else { return nil }
            offset = (at(i, "-") ? -1 : 1) * Int64(h * 3600 + m * 60)
            i += 6
        } else {
            return nil
        }
        guard i == b.count else { return nil }

        // Days since 1970-01-01 (Howard Hinnant's days_from_civil).
        let y = Int64(month <= 2 ? year - 1 : year), era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400, mp = Int64((month + 9) % 12)
        let doy = (153 * mp + 2) / 5 + Int64(day) - 1
        let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
        let seconds = days * 86_400 + Int64(hour * 3600 + minute * 60 + second) - offset
        return Instant(microseconds: seconds * 1_000_000 + micros)
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
