import Darwin
import Foundation

/// A small rolling text log in the App Group, written by the widget and shown by
/// the app (M2 prototype: the widget's HealthKit step read). Event names, counts,
/// durations and error codes; kept on this device only.
public enum ProbeLog {
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedWidgetStore.appGroup)?
            .appendingPathComponent("widget/probe_log.txt")
    }

    public static func append(_ line: String, keep: Int = 40) {
        guard let url = fileURL else { return }
        let entry = ISO8601DateFormatter().string(from: Date()) + " " + line
        let lines = (lines() + [entry]).suffix(keep)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(lines.joined(separator: "\n").utf8)
            .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Oldest first.
    public static func lines() -> [String] {
        guard let url = fileURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// The process's physical memory footprint in MB, as Xcode's memory gauge shows it; -1 if unavailable.
    public static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
