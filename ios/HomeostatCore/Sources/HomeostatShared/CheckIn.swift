import Foundation

/// One change to a user's energy check-in, from the app or the widget
/// (Daily_loop_contract.md "Energy entry persistence"). Retrying a command
/// never has a second effect: the app records each `commandID` once.
public struct EntryCommand: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public enum Action: String, Codable, Sendable { case create, edit, delete, undo }
    /// "Does this match how you feel?" for the observation shown at the time.
    public enum Match: String, Codable, Sendable { case yes, notReally = "not_really", unanswered }

    public var version: Int
    public var commandID: UUID
    public var scope: String
    public var action: Action
    public var entryID: UUID
    public var level: ReportedEnergy.Level?
    public var eventAt: Instant
    public var zone: String
    /// Edit, delete and undo apply only to this revision; a newer one wins.
    public var expectedRevision: Int?
    /// Undo: the command whose effect to reverse.
    public var undoes: UUID?
    public var match: Match?
    public var matchRunRef: String?

    public init(commandID: UUID = UUID(), scope: String, action: Action, entryID: UUID,
                level: ReportedEnergy.Level? = nil, eventAt: Instant, zone: String, expectedRevision: Int? = nil,
                undoes: UUID? = nil, match: Match? = nil, matchRunRef: String? = nil) {
        version = Self.currentVersion
        (self.commandID, self.scope, self.action, self.entryID, self.level) = (commandID, scope, action, entryID, level)
        (self.eventAt, self.zone, self.expectedRevision, self.undoes) = (eventAt, zone, expectedRevision, undoes)
        (self.match, self.matchRunRef) = (match, matchRunRef)
    }

    /// A new energy report.
    public static func energy(_ level: ReportedEnergy.Level, at: Instant, zone: String, scope: String) -> EntryCommand {
        EntryCommand(scope: scope, action: .create, entryID: UUID(), level: level, eventAt: at, zone: zone)
    }

    enum CodingKeys: String, CodingKey {
        case version, commandID = "command_id", scope, action, entryID = "entry_id", level, eventAt = "event_at", zone
        case expectedRevision = "expected_revision", undoes, match, matchRunRef = "match_run_ref"
    }
}

/// Check-ins the widget saved for the app to import (System_architecture.md
/// §4.3). One file per command, written atomically, so two processes never
/// need a lock; the app deletes a file only after its database commit.
public struct CheckInInbox: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func shared() -> CheckInInbox? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedWidgetStore.appGroup)
            .map { CheckInInbox(directory: $0.appendingPathComponent("inbox", isDirectory: true)) }
    }

    func folder(_ scope: String) -> URL {
        // Scopes are hashes; keep only safe characters so one can't name another's folder.
        directory.appendingPathComponent(String(scope.filter { $0.isLetter || $0.isNumber || $0 == "-" }), isDirectory: true)
    }

    /// Durable on return; only then may the widget say "Saved".
    public func write(_ command: EntryCommand) throws {
        let folder = folder(command.scope)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(command).write(to: folder.appendingPathComponent("\(command.commandID.uuidString).json"),
                                          options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Waiting commands for `scope`, oldest first. An unreadable or foreign file
    /// comes back with a nil command so the caller can discard it.
    public func pending(scope: String) -> [(url: URL, command: EntryCommand?)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(scope), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.map { url in
            let command = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(EntryCommand.self, from: $0) }
            let valid = command.flatMap { $0.version == EntryCommand.currentVersion && $0.scope == scope ? $0 : nil }
            return (url, valid)
        }.sorted { ($0.command?.eventAt ?? Instant(microseconds: .min)) < ($1.command?.eventAt ?? Instant(microseconds: .min)) }
    }

    public func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The newest energy report still waiting for the app, as the widget shows it.
    public func pendingEnergy(scope: String, day: LocalDay, zone: Zone) -> ReportedEnergy? {
        pending(scope: scope).compactMap(\.command)
            .filter { $0.action == .create && $0.level != nil && zone.day(of: $0.eventAt) == day }
            .last.map { ReportedEnergy(level: $0.level!, at: $0.eventAt, status: .saving) }
    }
}
