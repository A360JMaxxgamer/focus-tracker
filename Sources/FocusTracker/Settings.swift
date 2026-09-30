import Foundation
import ServiceManagement

/// User preferences, persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    /// How long you must keep facing another target before focus moves.
    @Published var dwellMs: Double { didSet { defaults.set(dwellMs, forKey: "dwellMs") } }
    /// How far (screen fraction) the gaze must go past the current screen's edge before switching away.
    @Published var edgeMargin: Double { didSet { defaults.set(edgeMargin, forKey: "edgeMargin") } }
    /// Quiet time after mouse/trackpad use before focus may move.
    @Published var mouseQuietMs: Double { didSet { defaults.set(mouseQuietMs, forKey: "mouseQuietMs") } }
    /// Quiet time after the last keystroke before focus may move to another screen.
    @Published var typingBeatMs: Double { didSet { defaults.set(typingBeatMs, forKey: "typingBeatMs") } }
    /// Switch between windows on the same screen.
    @Published var windowSwitching: Bool { didSet { defaults.set(windowSwitching, forKey: "windowSwitching") } }
    /// Use clicks as extra calibration samples.
    @Published var learnFromClicks: Bool { didSet { defaults.set(learnFromClicks, forKey: "learnFromClicks") } }
    /// Warp the pointer to the newly focused screen/window.
    @Published var movePointer: Bool { didSet { defaults.set(movePointer, forKey: "movePointer") } }
    /// Draw a small dot where the model thinks you are looking.
    @Published var showGazeDot: Bool { didSet { defaults.set(showGazeDot, forKey: "showGazeDot") } }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("FocusTracker: launch at login failed: \(error)")
            }
        }
    }

    private init() {
        defaults.register(defaults: [
            "dwellMs": 300.0,
            "edgeMargin": 0.05,
            "mouseQuietMs": 1500.0,
            "typingBeatMs": 600.0,
            "windowSwitching": true,
            "learnFromClicks": true,
            "movePointer": true,
            "showGazeDot": false,
        ])
        dwellMs = defaults.double(forKey: "dwellMs")
        edgeMargin = defaults.double(forKey: "edgeMargin")
        mouseQuietMs = defaults.double(forKey: "mouseQuietMs")
        typingBeatMs = defaults.double(forKey: "typingBeatMs")
        windowSwitching = defaults.bool(forKey: "windowSwitching")
        learnFromClicks = defaults.bool(forKey: "learnFromClicks")
        movePointer = defaults.bool(forKey: "movePointer")
        showGazeDot = defaults.bool(forKey: "showGazeDot")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
