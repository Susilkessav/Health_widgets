import Foundation
import GRDB

/// The result of one check-in command. A repeated command returns the outcome
/// recorded the first time.
public enum EntryOutcome: Equatable, Sendable {
    case applied(revision: Int)
    /// The entry changed since the command was made (or the ID is taken); nothing was overwritten.
    case conflict(current: Int)
    case notFound
    case rejected
}

/// User-reported energy check-ins (Daily_loop_contract.md). Stored apart from
/// measured data; nothing here changes a calculation. Every command applies
/// once, in one transaction; deletions are tombstones so a late command can't
/// bring an entry back.
extension LocalStore {
    @discardableResult
    public func apply(_ command: EntryCommand, now: Instant) throws -> EntryOutcome {
        try db.write { db in
            if let recorded = try String.fetchOne(db, sql: "SELECT outcome FROM entry_command WHERE command_id = ?",
                                                  arguments: [command.commandID.uuidString]) {
                return Self.decode(recorded)
            }
            let entry = try Row.fetchOne(db, sql: "SELECT value, deleted, revision FROM subjective_entry WHERE id = ?",
                                         arguments: [command.entryID.uuidString])
            let current: (value: String, deleted: Bool, revision: Int)? = entry.map { ($0["value"], $0["deleted"], $0["revision"]) }
            var outcome: EntryOutcome
            var before: (value: String?, deleted: Bool?) = (current?.value, current?.deleted)

            switch command.action {
            case .create:
                if let current { outcome = .conflict(current: current.revision); break }
                guard command.version == EntryCommand.currentVersion, let level = command.level else { outcome = .rejected; break }
                try db.execute(sql: """
                    INSERT INTO subjective_entry (id, kind, value, event_at, event_us, zone, created_at, updated_at,
                                                  revision, match_answer, match_run_ref)
                    VALUES (?, 'energy', ?, ?, ?, ?, ?, ?, 1, ?, ?)
                    """, arguments: [command.entryID.uuidString, level.rawValue, command.eventAt.wire,
                                     command.eventAt.microseconds, command.zone, now.wire, now.wire,
                                     command.match?.rawValue, command.matchRunRef])
                outcome = .applied(revision: 1)
            case .edit, .delete:
                guard let current else { outcome = .notFound; break }
                guard !current.deleted, command.expectedRevision == current.revision else {
                    outcome = .conflict(current: current.revision); break
                }
                let next = current.revision + 1
                if command.action == .delete {
                    try db.execute(sql: "UPDATE subjective_entry SET deleted = 1, revision = ?, updated_at = ? WHERE id = ?",
                                   arguments: [next, now.wire, command.entryID.uuidString])
                } else {
                    try db.execute(sql: """
                        UPDATE subjective_entry SET value = COALESCE(?, value), match_answer = COALESCE(?, match_answer),
                            match_run_ref = COALESCE(?, match_run_ref), revision = ?, updated_at = ? WHERE id = ?
                        """, arguments: [command.level?.rawValue, command.match?.rawValue, command.matchRunRef, next,
                                         now.wire, command.entryID.uuidString])
                }
                outcome = .applied(revision: next)
            case .undo:
                guard let current, let undone = command.undoes,
                      let original = try Row.fetchOne(db, sql: """
                          SELECT entry_id, revision, before_value, before_deleted FROM entry_command
                          WHERE command_id = ? AND outcome LIKE 'applied:%'
                          """, arguments: [undone.uuidString]),
                      (original["entry_id"] as String) == command.entryID.uuidString else { outcome = .notFound; break }
                // Only the latest change can be undone; a newer edit wins and is reported.
                guard (original["revision"] as Int?) == current.revision, command.expectedRevision == current.revision else {
                    outcome = .conflict(current: current.revision); break
                }
                let value: String? = original["before_value"], wasDeleted: Bool? = original["before_deleted"]
                let next = current.revision + 1
                try db.execute(sql: "UPDATE subjective_entry SET value = ?, deleted = ?, revision = ?, updated_at = ? WHERE id = ?",
                               arguments: [value ?? current.value, value == nil ? true : (wasDeleted ?? false), next,
                                           now.wire, command.entryID.uuidString])
                outcome = .applied(revision: next)
            }
            if case .applied = outcome {} else { before = (nil, nil) }
            let revision: Int? = if case .applied(let r) = outcome { r } else { nil }
            try db.execute(sql: """
                INSERT INTO entry_command (command_id, entry_id, action, applied_at, outcome, revision, before_value, before_deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [command.commandID.uuidString, command.entryID.uuidString, command.action.rawValue,
                                 now.wire, Self.encode(outcome), revision, before.value, before.deleted])
            return outcome
        }
    }

    /// Today's newest saved energy report in `zone`, or nil.
    public func latestEnergy(on day: LocalDay, zone: Zone) throws -> ReportedEnergy? {
        let start = zone.start(of: day), end = zone.start(of: zone.adding(days: 1, to: day))
        return try db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT value, event_at FROM subjective_entry
                WHERE kind = 'energy' AND deleted = 0 AND event_us >= ? AND event_us < ?
                ORDER BY event_us DESC, updated_at DESC LIMIT 1
                """, arguments: [start.microseconds, end.microseconds])
        }.flatMap { row in
            guard let level = ReportedEnergy.Level(rawValue: row["value"]), let at = Instant.parse(row["event_at"]) else { return nil }
            return ReportedEnergy(level: level, at: at, status: .saved)
        }
    }

    /// Applies the widget's waiting check-ins. A file is removed only after its
    /// command is recorded; a failed transaction leaves it for the next try.
    /// Unreadable, foreign-scope or other-version files are discarded.
    @discardableResult
    public func ingest(_ inbox: CheckInInbox, scope: String, now: Instant) -> Int {
        var applied = 0
        for (url, command) in inbox.pending(scope: scope) {
            guard let command else { inbox.remove(url); continue }
            guard let outcome = try? apply(command, now: now) else { continue }
            if case .applied = outcome { applied += 1 }
            inbox.remove(url)
        }
        return applied
    }

    static func encode(_ outcome: EntryOutcome) -> String {
        switch outcome {
        case .applied(let r): "applied:\(r)"
        case .conflict(let r): "conflict:\(r)"
        case .notFound: "not_found"
        case .rejected: "rejected"
        }
    }

    static func decode(_ text: String) -> EntryOutcome {
        let parts = text.split(separator: ":"), number = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        switch parts.first {
        case "applied": return .applied(revision: number)
        case "conflict": return .conflict(current: number)
        case "not_found": return .notFound
        default: return .rejected
        }
    }
}
