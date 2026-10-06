import Foundation
import GRDB
import XCTest
@testable import HomeostatCore

/// Replays a copy of an iPhone's database through the Swift engine at the
/// checkpoints backend/app/device_check.py chose, for it to compare:
///
///     HOMEOSTAT_DEVICE_DB=store.sqlite HOMEOSTAT_DEVICE_CHECKPOINTS=python.json \
///     HOMEOSTAT_DEVICE_OUT=swift.json swift test --filter DeviceReplayTests
///
/// Skipped unless those are set.
final class DeviceReplayTests: XCTestCase {
    func testReplayADeviceDatabase() throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["HOMEOSTAT_DEVICE_DB"], let checkpoints = env["HOMEOSTAT_DEVICE_CHECKPOINTS"],
              let out = env["HOMEOSTAT_DEVICE_OUT"] else { throw XCTSkip("no device database given") }
        let zone = env["HOMEOSTAT_DEVICE_ZONE"] ?? "America/Chicago"
        // Opening runs migrations, so first make a read-only SQLite backup
        // (a raw file copy would miss committed WAL contents).
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("device-\(UUID()).sqlite")
        var configuration = Configuration()
        configuration.readonly = true
        try DatabaseQueue(path: source, configuration: configuration).backup(to: DatabaseQueue(path: copy.path))
        defer { try? FileManager.default.removeItem(at: copy) }
        let store = try LocalStore(path: copy.path)
        let inputs = try XCTUnwrap(try store.localInputs(zone: zone))

        guard case .object(let wanted) = try JSONDecoder().decode(JSONValue.self,
                                                                   from: Data(contentsOf: URL(fileURLWithPath: checkpoints))) else {
            return XCTFail("checkpoints aren't an object")
        }
        var results: [String: JSONValue] = [:]
        for (name, entry) in wanted {
            let effective = try XCTUnwrap(entry["effective_at"]?.string.flatMap(Instant.parse))
            results[name] = try replay(store, inputs: inputs, effective: effective, zone: zone)
        }
        try JSONValue.object(results).encoded().write(to: URL(fileURLWithPath: out))
    }

    private func replay(_ store: LocalStore, inputs: LocalInputs, effective: Instant, zone: String) throws -> JSONValue {
        let lastDelivery = inputs.observations.map(\.deliveredAt).max() ?? effective
        let features = try store.localFeatures(inputs, effective: effective, knownAt: max(effective, lastDelivery), zone: zone)
        let state = computeHealthState(features)
        return .object([
            "features": features.json, "health_state": state.json,
            "widget_state": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(mapWidgetState(state))),
        ])
    }

    func testReplayOfAnInitializedEmptyDatabase() throws {
        let store = try LocalStore(path: nil)
        try store.setValue(NOW.adding(seconds: -30 * 86400).wire, for: "import_lower_bound")
        try store.setValue(NOW.wire, for: "covered_through_sleep")
        let inputs = try XCTUnwrap(try store.localInputs(zone: CHICAGO))
        XCTAssertTrue(inputs.observations.isEmpty)
        let result = try replay(store, inputs: inputs, effective: NOW, zone: CHICAGO)
        XCTAssertEqual(result["widget_state"]?["avatar"]?["eyes"], .string("neutral"))
    }

    func testSnapshotIncludesCommittedWALAndDoesNotOverwriteAnExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(path: directory.appendingPathComponent("live.sqlite").path)
        try store.db.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
        try store.setValue("committed", for: "snapshot_probe")
        let export = directory.appendingPathComponent("export.sqlite")
        try store.exportSnapshot(to: export)
        XCTAssertEqual(try LocalStore(path: export.path).value("snapshot_probe"), "committed")
        XCTAssertThrowsError(try store.exportSnapshot(to: export))
    }
}
