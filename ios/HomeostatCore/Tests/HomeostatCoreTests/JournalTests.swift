import Foundation
import XCTest
@testable import HomeostatCore
@testable import HomeostatShared

/// Energy check-ins (Daily_loop_contract.md "Energy entry persistence").
final class JournalTests: XCTestCase {
    let zone = Zone(CHICAGO)!
    var store: LocalStore!

    override func setUpWithError() throws {
        store = try LocalStore(path: nil)
    }

    func create(_ level: ReportedEnergy.Level = .low, at: Instant = NOW, entry: UUID = UUID()) -> EntryCommand {
        EntryCommand(scope: "a", action: .create, entryID: entry, level: level, eventAt: at, zone: CHICAGO)
    }

    func change(_ action: EntryCommand.Action, _ entry: UUID, revision: Int, level: ReportedEnergy.Level? = nil,
                undoes: UUID? = nil) -> EntryCommand {
        EntryCommand(scope: "a", action: action, entryID: entry, level: level, eventAt: NOW, zone: CHICAGO,
                     expectedRevision: revision, undoes: undoes)
    }

    func rows() throws -> Int { try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM subjective_entry")! } }
    var today: ReportedEnergy? { try? store.latestEnergy(on: zone.day(of: NOW), zone: zone) }

    func testARetriedCommandHasOneEffect() throws {
        let command = create(.high)
        XCTAssertEqual(try store.apply(command, now: NOW), .applied(revision: 1))
        XCTAssertEqual(try store.apply(command, now: NOW.adding(seconds: 5)), .applied(revision: 1))
        XCTAssertEqual(try rows(), 1)
        XCTAssertEqual(today, ReportedEnergy(level: .high, at: NOW, status: .saved))
    }

    func testTheNewestReportOfTheLocalDayIsShown() throws {
        try store.apply(create(.low, at: NOW.adding(seconds: -3600)), now: NOW)
        try store.apply(create(.okay, at: NOW), now: NOW)
        try store.apply(create(.high, at: NOW.adding(seconds: 12 * 3600)), now: NOW)  // tomorrow in Chicago
        XCTAssertEqual(today?.level, .okay)
    }

    func testAnEditNeedsTheCurrentRevisionAndANewerOneWins() throws {
        let entry = UUID()
        try store.apply(create(.low, entry: entry), now: NOW)
        XCTAssertEqual(try store.apply(change(.edit, entry, revision: 1, level: .okay), now: NOW), .applied(revision: 2))
        XCTAssertEqual(try store.apply(change(.edit, entry, revision: 1, level: .high), now: NOW), .conflict(current: 2))
        XCTAssertEqual(today?.level, .okay)
    }

    func testADeletedEntryCannotBeBroughtBackByALateCommand() throws {
        let entry = UUID()
        try store.apply(create(.low, entry: entry), now: NOW)
        XCTAssertEqual(try store.apply(change(.delete, entry, revision: 1), now: NOW), .applied(revision: 2))
        XCTAssertNil(today)
        XCTAssertEqual(try store.apply(create(.high, entry: entry), now: NOW), .conflict(current: 2))  // delayed widget create
        XCTAssertEqual(try store.apply(change(.edit, entry, revision: 2, level: .high), now: NOW), .conflict(current: 2))
        XCTAssertNil(today)
    }

    func testUndoReversesOnlyTheLatestChange() throws {
        let entry = UUID(), created = create(.low, entry: entry)
        try store.apply(created, now: NOW)
        XCTAssertEqual(try store.apply(change(.undo, entry, revision: 1, undoes: created.commandID), now: NOW),
                       .applied(revision: 2))
        XCTAssertNil(today)  // undoing a create removes it

        let other = UUID(), first = create(.low, entry: other)
        try store.apply(first, now: NOW)
        let deleted = change(.delete, other, revision: 1)
        try store.apply(deleted, now: NOW)
        XCTAssertEqual(try store.apply(change(.undo, other, revision: 2, undoes: deleted.commandID), now: NOW),
                       .applied(revision: 3))
        XCTAssertEqual(today?.level, .low)  // undoing a delete restores it

        let edit = change(.edit, other, revision: 3, level: .high)
        try store.apply(edit, now: NOW)
        try store.apply(change(.edit, other, revision: 4, level: .okay), now: NOW)
        XCTAssertEqual(try store.apply(change(.undo, other, revision: 5, undoes: edit.commandID), now: NOW),
                       .conflict(current: 5))  // a newer edit wins
        XCTAssertEqual(today?.level, .okay)
    }

    func testTheInboxIsImportedOnceAndOnlyForItsScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = CheckInInbox(directory: directory)
        try inbox.write(create(.low, at: NOW.adding(seconds: -60)))
        try inbox.write(create(.high, at: NOW))
        var foreign = create(.okay)
        foreign.scope = "b"
        try inbox.write(foreign)
        try Data("not a command".utf8).write(to: inbox.folder("a").appendingPathComponent("junk.json"))

        XCTAssertEqual(inbox.pendingEnergy(scope: "a", day: zone.day(of: NOW), zone: zone),
                       ReportedEnergy(level: .high, at: NOW, status: .saving))
        XCTAssertEqual(store.ingest(inbox, scope: "a", now: NOW), 2)
        XCTAssertTrue(inbox.pending(scope: "a").isEmpty)        // imported and junk discarded
        XCTAssertEqual(inbox.pending(scope: "b").count, 1)      // another account's file untouched
        XCTAssertEqual(today?.level, .high)
        XCTAssertEqual(store.ingest(inbox, scope: "a", now: NOW), 0)
        XCTAssertEqual(try rows(), 2)
    }
}
