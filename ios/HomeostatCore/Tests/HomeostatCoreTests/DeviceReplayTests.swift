import Foundation
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
        // Opening runs migrations, so work on a copy.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("device-\(UUID()).sqlite")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let inputs = try XCTUnwrap(try LocalStore(path: copy.path).localInputs(zone: zone))
        let lastDelivery = inputs.observations.map(\.deliveredAt).max()!

        guard case .object(let wanted) = try JSONDecoder().decode(JSONValue.self,
                                                                   from: Data(contentsOf: URL(fileURLWithPath: checkpoints))) else {
            return XCTFail("checkpoints aren't an object")
        }
        var results: [String: JSONValue] = [:]
        for (name, entry) in wanted {
            let effective = try XCTUnwrap(entry["effective_at"]?.string.flatMap(Instant.parse))
            let features = try LocalStore(path: copy.path).localFeatures(inputs, effective: effective,
                                                                          knownAt: max(effective, lastDelivery), zone: zone)
            let state = computeHealthState(features)
            results[name] = .object([
                "features": features.json, "health_state": state.json,
                "widget_state": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(mapWidgetState(state))),
            ])
        }
        try JSONValue.object(results).encoded().write(to: URL(fileURLWithPath: out))
    }
}
