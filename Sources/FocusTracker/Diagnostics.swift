import AppKit

/// Optional JSON-lines log of features and decisions, for tuning accuracy with real data.
/// Contains no images — only numbers, screen names and app names.
final class Diagnostics {
    static let shared = Diagnostics()

    private(set) var fileURL: URL?
    private var handle: FileHandle?
    private let start = CACurrentMediaTime()

    var isRecording: Bool { handle != nil }

    func startRecording() {
        guard handle == nil else { return }
        let dir = ProfileStore.defaultDirectory.appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = dir.appendingPathComponent("diagnostics-\(formatter.string(from: Date())).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        fileURL = url
        log("start", ["displays": Displays.all().map { ["name": $0.name, "uuid": $0.uuid, "bounds": "\($0.bounds)"] }])
    }

    func stopRecording() {
        try? handle?.close()
        handle = nil
    }

    func log(_ event: String, _ fields: [String: Any]) {
        guard let handle else { return }
        var entry = fields
        entry["event"] = event
        entry["t"] = (CACurrentMediaTime() - start).rounded(toPlaces: 3)
        guard JSONSerialization.isValidJSONObject(entry),
              var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        handle.write(data)
    }

    static func features(_ f: GazeFeatures) -> [Double] {
        f.vector.map { $0.rounded(toPlaces: 4) }
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
