import CoreGraphics
import Foundation

/// A place you work at: its own camera and its own calibration for the screens there.
struct Profile: Codable, Identifiable, Equatable {
    /// A screen calibrated in this profile, with the arrangement it had then.
    struct Screen: Codable, Equatable {
        var uuid: String
        var name: String
        var frame: CGRect
    }

    var id: String
    var name: String
    /// AVCaptureDevice.uniqueID (empty = system default).
    var cameraID: String
    var screens: [Screen]

    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : name }
}

/// Stores profiles in `profiles.json` and one calibration file per profile.
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var activeID = ""
    /// Pick the best-fitting profile when screens or cameras are connected/disconnected.
    @Published var autoSwitch: Bool { didSet { save() } }

    /// Called after the active profile changed.
    var onActiveChange: ((Profile) -> Void)?
    /// Called after the active profile's camera changed.
    var onCameraChange: (() -> Void)?

    private let directory: URL

    private struct Index: Codable {
        var profiles: [Profile]
        var activeID: String
        var autoSwitch: Bool
    }

    static let defaultDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FocusTracker", isDirectory: true)

    init(directory: URL = ProfileStore.defaultDirectory) {
        self.directory = directory
        let fm = FileManager.default
        try? fm.createDirectory(at: directory.appendingPathComponent("profiles"), withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: directory.appendingPathComponent("profiles.json")),
           let index = try? JSONDecoder().decode(Index.self, from: data), let first = index.profiles.first {
            autoSwitch = index.autoSwitch
            profiles = index.profiles
            activeID = index.profiles.contains { $0.id == index.activeID } ? index.activeID : first.id
        } else {
            // First run, or upgrade from the single-calibration version.
            autoSwitch = true
            let profile = Profile(id: UUID().uuidString, name: "Default",
                                  cameraID: UserDefaults.standard.string(forKey: "cameraID") ?? "", screens: [])
            let legacy = directory.appendingPathComponent("calibration.json")
            if fm.fileExists(atPath: legacy.path) {
                try? fm.moveItem(at: legacy, to: calibrationURL(for: profile.id))
            }
            profiles = [profile]
            activeID = profile.id
            save()
        }
    }

    var active: Profile { profiles.first { $0.id == activeID } ?? profiles[0] }

    func calibrationURL(for id: String) -> URL {
        directory.appendingPathComponent("profiles").appendingPathComponent("\(id).json")
    }

    // MARK: - Editing

    @discardableResult
    func create(name: String, cameraID: String) -> Profile {
        let profile = Profile(id: UUID().uuidString, name: name, cameraID: cameraID, screens: [])
        profiles.append(profile)
        save()
        return profile
    }

    func rename(_ id: String, to name: String) {
        update(id) { $0.name = name }
    }

    func delete(_ id: String) {
        guard profiles.count > 1, profiles.contains(where: { $0.id == id }) else { return }
        profiles.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: calibrationURL(for: id))
        if activeID == id {
            activeID = profiles[0].id
            save()
            onActiveChange?(active)
        } else {
            save()
        }
    }

    func activate(_ id: String) {
        guard id != activeID, profiles.contains(where: { $0.id == id }) else { return }
        activeID = id
        save()
        onActiveChange?(active)
    }

    func setCamera(_ cameraID: String) {
        guard active.cameraID != cameraID else { return }
        update(activeID) { $0.cameraID = cameraID }
        onCameraChange?()
    }

    func setScreens(_ screens: [Profile.Screen]) {
        update(activeID) { $0.screens = screens }
    }

    private func update(_ id: String, _ change: (inout Profile) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&profiles[i])
        save()
    }

    private func save() {
        let index = Index(profiles: profiles, activeID: activeID, autoSwitch: autoSwitch)
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: directory.appendingPathComponent("profiles.json"), options: .atomic)
    }

    // MARK: - Matching

    /// The profile that fits the connected hardware best: all its screens connected, ideally in the
    /// same arrangement, with its camera present. `nil` if no calibrated profile fits.
    func bestMatch(displays: [(uuid: String, frame: CGRect)], cameras: Set<String>) -> Profile? {
        let connected = Dictionary(displays.map { ($0.uuid, $0.frame) }, uniquingKeysWith: { a, _ in a })
        var best: (profile: Profile, score: Int)?
        for profile in profiles where !profile.screens.isEmpty {
            guard profile.screens.allSatisfy({ connected[$0.uuid] != nil }) else { continue }
            var score = profile.screens.count * 10 - abs(displays.count - profile.screens.count) * 3
            score += profile.screens.filter { screen in
                guard let frame = connected[screen.uuid] else { return false }
                return abs(frame.minX - screen.frame.minX) < 2 && abs(frame.minY - screen.frame.minY) < 2
                    && frame.size == screen.frame.size
            }.count * 2
            if !profile.cameraID.isEmpty { score += cameras.contains(profile.cameraID) ? 4 : -8 }
            if profile.id == activeID { score += 1 } // ties keep the current profile
            if best == nil || score > best!.score { best = (profile, score) }
        }
        return best?.profile
    }
}
