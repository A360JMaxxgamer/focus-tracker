import AppKit
import AVFoundation
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let profiles = ProfileStore()
    private lazy var model = GazeModel(fileURL: profiles.calibrationURL(for: profiles.activeID))
    private let tracker = HeadTracker()
    private let activity = ActivityMonitor()
    private let history = WindowHistory()
    private let calibration = CalibrationController()
    private let gazeDot = GazeDot()
    private let cameraList = CameraList()
    private lazy var engine = FocusEngine(model: model, history: history, activity: activity, settings: settings)

    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var trustTimer: Timer?
    private var settingsWindow: NSWindow?
    private var debugWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private var paused = false
    private var asleep = false
    private var locked = false
    private var cameraError: String?
    private var pendingProfileCheck: DispatchWorkItem?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        tracker.onSample = { [weak self] features in self?.handleSample(features) }
        tracker.onError = { [weak self] message in
            self?.cameraError = message
            self?.updateIcon()
        }
        activity.onLeftClick = { [weak self] point in self?.engine.handleClick(at: point) }
        engine.onStateChange = { [weak self] in self?.updateIcon() }
        hotKey = HotKey { [weak self] in self?.togglePause() }
        // A plugged-in camera may belong to another profile, be the selected one, or be the one just removed.
        cameraList.onChange = { [weak self] in
            guard let self else { return }
            if !self.autoSelectProfile() { self.restartCamera() }
        }
        profiles.onActiveChange = { [weak self] _ in self?.applyActiveProfile() }
        profiles.onCameraChange = { [weak self] in self?.restartCamera() }
        model.addMissingFrames(Self.currentFrames())
        if profiles.active.screens.isEmpty && !model.calibratedDisplays.isEmpty { syncProfileScreens() }
        autoSelectProfile()
        settings.$showGazeDot.sink { [weak self] show in
            if !show { self?.gazeDot.hide() }
        }.store(in: &cancellables)

        observeSystem()
        updateIcon()
        setUpPermissions()
    }

    private func setUpPermissions() {
        if !WindowFocus.isTrusted { WindowFocus.promptForTrust() }
        waitForAccessibility()

        HeadTracker.requestCameraAccess { [weak self] granted in
            guard let self else { return }
            if granted {
                self.updateCamera()
                if self.model.calibratedDisplays.isEmpty {
                    self.offerCalibration(reason: self.model.discardedOutdatedCalibration
                        ? "This version uses a more precise face model, so the old calibration no longer fits. Please calibrate again — about 25 seconds per screen."
                        : nil)
                }
            } else {
                self.cameraError = "Camera access denied"
                self.updateIcon()
            }
        }
    }

    /// Global key/mouse monitors only work once we are trusted, so start them when that happens.
    private func waitForAccessibility() {
        if WindowFocus.isTrusted {
            activity.start()
            history.start()
            updateIcon()
            return
        }
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard WindowFocus.isTrusted else { return }
            timer.invalidate()
            self?.waitForAccessibility()
        }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.asleep = true
                self?.updateCamera()
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.asleep = false
                self?.updateCamera()
                self?.scheduleProfileCheck()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.scheduleProfileCheck()
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true
            self?.updateCamera()
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false
            self?.updateCamera()
        }
    }

    private static func currentFrames() -> [String: CGRect] {
        Dictionary(Displays.all().map { ($0.uuid, $0.bounds) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Profiles

    /// Screen changes arrive in bursts while displays reconnect; wait for them to settle.
    private func scheduleProfileCheck() {
        pendingProfileCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autoSelectProfile() }
        pendingProfileCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Activates the profile that best fits the connected screens and cameras. Returns true if it switched.
    @discardableResult
    private func autoSelectProfile() -> Bool {
        guard profiles.autoSwitch, !calibration.isRunning,
              let best = profiles.bestMatch(displays: Displays.all().map { ($0.uuid, $0.bounds) },
                                            cameras: Set(cameraList.cameras.map(\.id))),
              best.id != profiles.activeID else { return false }
        profiles.activate(best.id)
        return true
    }

    private func applyActiveProfile() {
        calibration.cancel()
        model.load(from: profiles.calibrationURL(for: profiles.activeID))
        model.addMissingFrames(Self.currentFrames())
        engine.calibrationChanged()
        restartCamera()
    }

    /// Records which screens (and their arrangement) the active profile is calibrated for.
    private func syncProfileScreens() {
        let connected = Displays.all()
        let previous = profiles.active.screens
        let screens = model.calibratedDisplays.sorted().compactMap { uuid -> Profile.Screen? in
            if let display = connected.first(where: { $0.uuid == uuid }) {
                return Profile.Screen(uuid: uuid, name: display.name, frame: display.bounds)
            }
            return previous.first { $0.uuid == uuid }
        }
        profiles.setScreens(screens)
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        profiles.activate(id)
    }

    @objc private func newProfile() {
        guard let name = askForName(title: "New Profile",
                                    text: "E.g. “Office” or “Home”. The new profile starts with the current camera and needs its own calibration.",
                                    initial: "") else { return }
        let profile = profiles.create(name: name, cameraID: profiles.active.cameraID)
        profiles.activate(profile.id)
        offerCalibration()
    }

    @objc private func renameProfile() {
        guard let name = askForName(title: "Rename Profile", text: "", initial: profiles.active.name) else { return }
        profiles.rename(profiles.activeID, to: name)
    }

    @objc private func deleteProfile() {
        guard profiles.profiles.count > 1 else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Delete profile “\(profiles.active.displayName)”?"
        alert.informativeText = "Its calibration and learned clicks will be deleted."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        profiles.delete(profiles.activeID)
    }

    @objc private func toggleAutoSwitch() {
        profiles.autoSwitch.toggle()
        if profiles.autoSwitch { autoSelectProfile() }
    }

    private func askForName(title: String, text: String, initial: String) -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "Profile name"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    // MARK: - Camera

    private var shouldTrack: Bool {
        !paused && !asleep && !locked && HeadTracker.cameraAuthorized
    }

    private func updateCamera() {
        if shouldTrack {
            tracker.start(deviceID: profiles.active.cameraID)
        } else {
            tracker.stop()
            engine.reset()
            gazeDot.hide()
        }
        updateIcon()
    }

    private func restartCamera() {
        cameraError = nil
        engine.reset()
        if shouldTrack {
            tracker.restart(deviceID: profiles.active.cameraID)
            updateIcon()
        } else {
            updateCamera()
        }
    }

    private func handleSample(_ features: GazeFeatures?) {
        guard shouldTrack else { return }
        if cameraError != nil { cameraError = nil; updateIcon() }
        if calibration.isRunning { calibration.feed(features) }
        engine.enabled = !calibration.isRunning && WindowFocus.isTrusted
        engine.handle(features)
        if settings.showGazeDot && !calibration.isRunning {
            gazeDot.show(at: engine.gazePoint, box: engine.gazeBox)
        } else {
            gazeDot.hide()
        }
    }

    // MARK: - Actions

    @objc private func togglePause() {
        paused.toggle()
        updateCamera()
    }

    @objc private func calibrateAll() {
        calibrate(Displays.all())
    }

    @objc private func calibrateOne(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String,
              let display = Displays.all().first(where: { $0.uuid == uuid }) else { return }
        calibrate([display])
    }

    @objc private func calibrateWarned() {
        let name = engine.accuracyWarning
        calibrate(Displays.all().filter { $0.name == name })
    }

    private func calibrate(_ displays: [DisplayInfo]) {
        guard !displays.isEmpty, !calibration.isRunning else { return }
        guard HeadTracker.cameraAuthorized else {
            alert("Camera access needed", "Allow FocusTracker to use the camera in System Settings → Privacy & Security → Camera.")
            return
        }
        if paused { paused = false; updateCamera() }
        gazeDot.hide()
        calibration.run(displays: displays) { [weak self] result in
            guard let self, let result else { return }
            var failed: [String] = []
            for display in displays {
                let samples = result[display.uuid] ?? []
                if samples.count >= 40 {
                    self.model.replaceCalibration(for: display.uuid, with: samples, frames: Self.currentFrames())
                } else {
                    failed.append(display.name)
                }
            }
            self.syncProfileScreens()
            self.engine.calibrationChanged()
            self.showCalibrationResult(displays: displays, failed: failed)
        }
    }

    /// Tells how precise the new calibration is, so a bad one (light, camera angle) gets redone right away.
    private func showCalibrationResult(displays: [DisplayInfo], failed: [String]) {
        var lines: [String] = []
        var poor = false
        for display in displays where !failed.contains(display.name) {
            guard let e = model.axisErrors[display.uuid] else { continue }
            let error = max(e.x, e.y)
            let quality = error < 0.1 ? "very good" : error < 0.16 ? "good" : error < 0.25 ? "fair" : "poor"
            if error >= 0.25 { poor = true }
            lines.append("\(display.name): ±\(Int((e.x * 100).rounded())) % horizontal, ±\(Int((e.y * 100).rounded())) % vertical (\(quality))")
        }
        if !failed.isEmpty {
            lines.append("Couldn't see your face well enough on: \(failed.joined(separator: ", ")).")
        }
        if poor || !failed.isEmpty {
            lines.append("\nTips: light your face from the front, put the camera centred above or below the screens, keep your usual seat, and actually turn your head towards each dot.")
        }
        lines.append("\nEach click you make keeps improving this.")
        alert(failed.isEmpty ? "Calibration done" : "Calibration incomplete", lines.joined(separator: "\n"))
    }

    private func offerCalibration(reason: String? = nil) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Calibrate your screens for “\(profiles.active.displayName)”"
        alert.informativeText = reason ?? "Follow a dot around each screen — about 25 seconds each. FocusTracker learns which way you face for every screen."
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { calibrateAll() }
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        profiles.setCamera(sender.representedObject as? String ?? "")
    }

    @objc private func toggleGazeDot() { settings.showGazeDot.toggle() }

    @objc private func toggleDiagnostics() {
        let diagnostics = Diagnostics.shared
        if diagnostics.isRecording {
            diagnostics.stopRecording()
            if let url = diagnostics.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } else {
            diagnostics.startRecording()
            let displays = Displays.all()
            diagnostics.log("model", [
                "profile": profiles.active.displayName,
                "errors": model.axisErrors.map { uuid, e in
                    ["display": displays.first { $0.uuid == uuid }?.name ?? uuid,
                     "x": e.x.rounded(toPlaces: 3), "y": e.y.rounded(toPlaces: 3)]
                },
                "clickSamples": model.samples.filter(\.fromClick).count,
            ])
        }
    }

    @objc private func forgetClicks() {
        model.removeClickSamples()
        engine.calibrationChanged()
    }

    @objc private func resetCalibration() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Reset calibration?"
        alert.informativeText = "All calibration and learned click data of profile “\(profiles.active.displayName)” will be deleted."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.clear()
        syncProfileScreens()
        engine.calibrationChanged()
    }

    @objc private func openAccessibilitySettings() {
        WindowFocus.promptForTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openCameraSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    @objc private func showSettings() {
        cameraList.refresh()
        settingsWindow = showWindow(settingsWindow, title: "FocusTracker Settings",
                                    view: SettingsView(settings: settings, profiles: profiles, cameraList: cameraList,
                                                       onNewProfile: { [weak self] in self?.newProfile() },
                                                       onDeleteProfile: { [weak self] in self?.deleteProfile() },
                                                       onCalibrate: { [weak self] in self?.calibrateAll() }))
    }

    @objc private func showDebug() {
        debugWindow = showWindow(debugWindow, title: "FocusTracker Monitor", view: DebugView(engine: engine))
    }

    private func showWindow<V: View>(_ existing: NSWindow?, title: String, view: V) -> NSWindow {
        let window = existing ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = title
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            return w
        }()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: - Menu

    private var statusText: String {
        if paused { return "Paused" }
        if asleep || locked { return "Paused while locked" }
        if let cameraError { return cameraError }
        if !WindowFocus.isTrusted { return "Needs Accessibility access" }
        if model.calibratedDisplays.isEmpty { return "Not calibrated" }
        if !engine.faceVisible { return "Looking for your face…" }
        return "Facing: \(engine.facing?.name ?? "—")"
    }

    private var headerText: String { "\(profiles.active.displayName) — \(statusText)" }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        if paused || asleep || locked {
            symbol = "eye.slash"
        } else if cameraError != nil || !WindowFocus.isTrusted || model.calibratedDisplays.isEmpty || engine.accuracyWarning != nil {
            symbol = "eye.trianglebadge.exclamationmark"
        } else {
            symbol = "eye"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "FocusTracker")
            ?? NSImage(systemSymbolName: "eye", accessibilityDescription: "FocusTracker")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "FocusTracker — \(headerText)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: headerText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let warned = engine.accuracyWarning {
            menu.addItem(item("⚠︎ Accuracy dropped on \(warned) — Recalibrate…", #selector(calibrateWarned)))
        }
        if !WindowFocus.isTrusted {
            menu.addItem(item("Grant Accessibility Access…", #selector(openAccessibilitySettings)))
        }
        if AVCameraStatus.denied {
            menu.addItem(item("Grant Camera Access…", #selector(openCameraSettings)))
        }
        menu.addItem(.separator())

        let pause = item(paused ? "Resume" : "Pause", #selector(togglePause), key: "g")
        pause.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(pause)

        let profileMenu = NSMenu()
        for profile in profiles.profiles {
            let entry = item(profile.displayName, #selector(selectProfile(_:)))
            entry.representedObject = profile.id
            entry.state = profile.id == profiles.activeID ? .on : .off
            profileMenu.addItem(entry)
        }
        profileMenu.addItem(.separator())
        profileMenu.addItem(item("New Profile…", #selector(newProfile)))
        profileMenu.addItem(item("Rename “\(profiles.active.displayName)”…", #selector(renameProfile)))
        if profiles.profiles.count > 1 {
            profileMenu.addItem(item("Delete “\(profiles.active.displayName)”…", #selector(deleteProfile)))
        }
        profileMenu.addItem(.separator())
        let auto = item("Switch Automatically", #selector(toggleAutoSwitch))
        auto.state = profiles.autoSwitch ? .on : .off
        profileMenu.addItem(auto)
        let profileItem = NSMenuItem(title: "Profile: \(profiles.active.displayName)", action: nil, keyEquivalent: "")
        profileItem.submenu = profileMenu
        menu.addItem(profileItem)

        menu.addItem(item("Calibrate All Screens…", #selector(calibrateAll)))
        let screens = NSMenu()
        for display in Displays.all() {
            let entry = item(display.name, #selector(calibrateOne(_:)))
            entry.representedObject = display.uuid
            entry.state = model.isCalibrated(display.uuid) ? .on : .off
            screens.addItem(entry)
        }
        let screensItem = NSMenuItem(title: "Calibrate Screen", action: nil, keyEquivalent: "")
        screensItem.submenu = screens
        menu.addItem(screensItem)

        let cameras = NSMenu()
        let systemDefault = item("System Default", #selector(selectCamera(_:)))
        systemDefault.representedObject = ""
        systemDefault.state = profiles.active.cameraID.isEmpty ? .on : .off
        cameras.addItem(systemDefault)
        for camera in cameraList.cameras {
            let entry = item(camera.name, #selector(selectCamera(_:)))
            entry.representedObject = camera.id
            entry.state = profiles.active.cameraID == camera.id ? .on : .off
            cameras.addItem(entry)
        }
        let camerasItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        camerasItem.submenu = cameras
        menu.addItem(camerasItem)

        menu.addItem(.separator())
        let dot = item("Show Gaze Dot", #selector(toggleGazeDot))
        dot.state = settings.showGazeDot ? .on : .off
        menu.addItem(dot)
        menu.addItem(item("Monitor…", #selector(showDebug)))
        let record = item(Diagnostics.shared.isRecording ? "Stop Recording Diagnostics" : "Record Diagnostics", #selector(toggleDiagnostics))
        record.state = Diagnostics.shared.isRecording ? .on : .off
        menu.addItem(record)
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))

        menu.addItem(.separator())
        menu.addItem(item("Forget Learned Clicks", #selector(forgetClicks)))
        menu.addItem(item("Reset Calibration…", #selector(resetCalibration)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit FocusTracker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}

private enum AVCameraStatus {
    static var denied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }
}
