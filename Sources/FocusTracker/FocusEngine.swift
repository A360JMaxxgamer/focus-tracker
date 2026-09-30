import AppKit

/// Turns a stream of gaze samples into focus changes: settle (dwell), edge margin,
/// typing/mouse guards, ignore poses far from every screen, learn from clicks.
final class FocusEngine: ObservableObject {
    struct EstimateRow: Identifiable {
        let id: String
        let name: String
        let point: CGPoint
        let classifyPoint: CGPoint
        let score: Double
        let errorX: Double
        let errorY: Double
    }

    @Published private(set) var faceVisible = false
    @Published private(set) var features: GazeFeatures?
    @Published private(set) var facing: DisplayInfo?
    @Published private(set) var candidateName: String?
    @Published private(set) var estimateRows: [EstimateRow] = []
    /// Estimated gaze point in global CG coordinates.
    @Published private(set) var gazePoint: CGPoint? { didSet { if gazePoint == nil { gazeBox = nil } } }
    /// Area the gaze could be in, given this screen's measured accuracy (global CG coordinates).
    @Published private(set) var gazeBox: CGRect?
    /// Which window is under the gaze and whether it is certain enough to use.
    @Published private(set) var windowInfo = ""
    @Published private(set) var lastAction = ""
    /// Why focus is not moving right now (typing, mouse, settling, looking away…).
    @Published private(set) var blockedReason: String?
    /// Name of a display where clicks keep disagreeing with the model.
    @Published private(set) var accuracyWarning: String?

    /// False while paused, calibrating or without Accessibility access: samples are analysed but nothing is focused.
    var enabled = true
    var onStateChange: (() -> Void)?

    private let model: GazeModel
    private let history: WindowHistory
    private let activity: ActivityMonitor
    private let settings: Settings
    private let diagnostics = Diagnostics.shared

    private var recent: [GazeFeatures] = []
    private var smoothed: GazeFeatures?
    private var bestUUID: String?
    private var lastSampleTime: CFTimeInterval = 0
    private var displayCandidate: (uuid: String, since: CFTimeInterval)?
    private var windowCandidate: (id: CGWindowID, since: CFTimeInterval)?
    private var lastGazeWindowID: CGWindowID?
    private var clickHits: [String: [Bool]] = [:]
    private var lastLoggedWindows = ""

    /// A predicted point further than this outside every screen (in screen fractions) means "looking elsewhere".
    private let awayDistance = 0.35
    private let smoothing = 0.5

    init(model: GazeModel, history: WindowHistory, activity: ActivityMonitor, settings: Settings) {
        self.model = model
        self.history = history
        self.activity = activity
        self.settings = settings
    }

    func reset() {
        recent = []
        smoothed = nil
        bestUUID = nil
        displayCandidate = nil
        windowCandidate = nil
        faceVisible = false
        gazePoint = nil
        candidateName = nil
        blockedReason = nil
    }

    func calibrationChanged() {
        reset()
        facing = nil
        clickHits = [:]
        accuracyWarning = nil
        onStateChange?()
    }

    // MARK: - Samples

    func handle(_ raw: GazeFeatures?) {
        let now = CACurrentMediaTime()
        guard let raw else {
            if faceVisible { faceVisible = false; onStateChange?() }
            if now - lastSampleTime > 1 { smoothed = nil; recent = [] }
            bestUUID = nil
            displayCandidate = nil
            windowCandidate = nil
            gazePoint = nil
            blockedReason = "face not found"
            return
        }
        lastSampleTime = now
        if !faceVisible { faceVisible = true; onStateChange?() }

        // Median of the last 3 frames drops single-frame outliers, then light exponential smoothing.
        recent.append(raw)
        if recent.count > 3 { recent.removeFirst() }
        let filtered = GazeFeatures.median(recent)
        let sample = smoothed.map { $0.blended(with: filtered, alpha: smoothing) } ?? filtered
        smoothed = sample
        features = sample

        let displays = Displays.all()
        let estimates = model.estimates(for: sample, among: Set(displays.map(\.uuid)))
        estimateRows = estimates.map { e in
            EstimateRow(id: e.uuid, name: displays.first { $0.uuid == e.uuid }?.name ?? "?",
                        point: e.point, classifyPoint: e.classifyPoint, score: e.score, errorX: e.errorX, errorY: e.errorY)
        }
        bestUUID = estimates.first?.uuid
        if diagnostics.isRecording {
            diagnostics.log("sample", [
                "f": Diagnostics.features(sample),
                "est": estimates.map { e in ["name": displays.first { $0.uuid == e.uuid }?.name ?? e.uuid,
                                         "u": Double(e.point.x).rounded(toPlaces: 3), "v": Double(e.point.y).rounded(toPlaces: 3),
                                         "cu": Double(e.classifyPoint.x).rounded(toPlaces: 3), "cv": Double(e.classifyPoint.y).rounded(toPlaces: 3),
                                         "score": e.score.rounded(toPlaces: 3)] },
                "facing": facing?.name ?? "", "blocked": blockedReason ?? "",
            ])
        }

        guard let best = estimates.first else {
            gazePoint = nil
            blockedReason = "no calibrated screen connected"
            return
        }
        // How far outside counts as "elsewhere" scales with how precise this display's estimate is.
        guard best.score <= max(awayDistance, best.classifyError * 2) else {
            // Looking at the desk, a phone, the ceiling…
            blockedReason = "looking away from all screens"
            candidateName = nil
            displayCandidate = nil
            windowCandidate = nil
            gazePoint = nil
            return
        }

        // Stay on the current screen until the gaze is clearly past its edge.
        var target = best
        if let current = facing?.uuid, current != best.uuid,
           let currentEstimate = estimates.first(where: { $0.uuid == current }),
           currentEstimate.score < settings.edgeMargin {
            target = currentEstimate
        }
        guard let targetDisplay = displays.first(where: { $0.uuid == target.uuid }) else { return }
        let point = targetDisplay.globalPoint(relative: CGPoint(x: min(max(target.point.x, 0), 1),
                                                                y: min(max(target.point.y, 0), 1)))
        gazePoint = point
        let sigma = CGSize(width: targetDisplay.bounds.width * CGFloat(max(target.errorX, 0.03)),
                           height: targetDisplay.bounds.height * CGFloat(max(target.errorY, 0.03)))
        gazeBox = CGRect(x: point.x - sigma.width, y: point.y - sigma.height,
                         width: sigma.width * 2, height: sigma.height * 2).intersection(targetDisplay.bounds)
        let shares = WindowFocus.shares(center: point, sigma: sigma, display: targetDisplay.bounds,
                                        windows: WindowFocus.onScreenWindows())
        let gazeWindow = WindowFocus.likelyWindow(from: shares)
        describeWindows(shares: shares, likely: gazeWindow, on: targetDisplay, estimate: target)

        guard enabled else {
            blockedReason = "disabled"
            return
        }
        let dwell = settings.dwellMs / 1000

        if target.uuid != facing?.uuid {
            windowCandidate = nil
            if displayCandidate?.uuid != target.uuid { displayCandidate = (target.uuid, now) }
            candidateName = targetDisplay.name
            guard let since = displayCandidate?.since, now - since >= dwell else {
                blockedReason = "settling"
                return
            }
            guard activity.secondsSinceMouse(now) >= settings.mouseQuietMs / 1000 else {
                blockedReason = "mouse in use"
                return
            }
            guard activity.secondsSinceKey(now) >= settings.typingBeatMs / 1000 else {
                blockedReason = "typing"
                return
            }
            displayCandidate = nil
            candidateName = nil
            blockedReason = nil
            switchDisplay(to: targetDisplay, gazeWindow: gazeWindow)
        } else {
            displayCandidate = nil
            candidateName = nil
            blockedReason = nil
            if settings.windowSwitching { considerWindowSwitch(on: targetDisplay, gazeWindow: gazeWindow, now: now, dwell: dwell) }
        }
    }

    // MARK: - Focus changes

    private func switchDisplay(to display: DisplayInfo, gazeWindow: WindowFocus.WindowInfo?) {
        facing = display
        onStateChange?()
        lastGazeWindowID = gazeWindow?.id

        if let focused = WindowFocus.focusedWindow(), display.bounds.contains(focused.center) {
            lastAction = "Facing \(display.name) — focus already there"
            return
        }

        var target: TrackedWindow?
        var how = ""
        if settings.windowSwitching, let w = gazeWindow.flatMap(WindowFocus.tracked) {
            target = w; how = "window you look at"
        } else if let w = history.window(on: display) {
            target = w; how = "last used window"
        } else if let w = WindowFocus.topWindow(on: display.bounds) {
            target = w; how = "front window"
        }

        if let target {
            focus(target, on: display, how: how)
            lastGazeWindowID = target.windowID ?? lastGazeWindowID
            if settings.movePointer { WindowFocus.movePointer(to: target.center) }
        } else {
            if settings.movePointer { WindowFocus.movePointer(to: display.center) }
            lastAction = "→ \(display.name): no window, pointer moved"
        }
    }

    /// Same-screen switching is stricter: longer settle time, no typing at all, and only when one window
    /// clearly holds most of the gaze probability.
    private func considerWindowSwitch(on display: DisplayInfo, gazeWindow: WindowFocus.WindowInfo?, now: CFTimeInterval, dwell: Double) {
        guard let id = gazeWindow?.id, id != lastGazeWindowID else {
            windowCandidate = nil
            return
        }
        if windowCandidate?.id != id {
            windowCandidate = (id, now)
            return
        }
        guard let since = windowCandidate?.since, now - since >= dwell * 2 else {
            blockedReason = "settling on window"
            return
        }
        guard activity.secondsSinceKey(now) >= max(1.2, settings.typingBeatMs / 500) else {
            blockedReason = "typing"
            return
        }
        guard activity.secondsSinceMouse(now) >= settings.mouseQuietMs / 1000 else {
            blockedReason = "mouse in use"
            return
        }

        windowCandidate = nil
        lastGazeWindowID = id
        guard let window = gazeWindow.flatMap(WindowFocus.tracked) else { return }
        if let focused = WindowFocus.focusedWindow(), CFEqual(focused.element, window.element) { return }
        focus(window, on: display, how: "window you look at")
    }

    /// Focuses and checks shortly after; some apps ignore the first request.
    private func focus(_ window: TrackedWindow, on display: DisplayInfo, how: String) {
        WindowFocus.focus(window)
        let app = appName(window.pid)
        lastAction = "→ \(display.name): \(how) (\(app))"
        diagnostics.log("focus", ["display": display.name, "how": how, "app": app])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let focused = WindowFocus.focusedWindow(), !CFEqual(focused.element, window.element),
                  window.currentFrame != nil else { return }
            WindowFocus.focus(window)
            self.lastAction += " (retried)"
            self.diagnostics.log("focus-retry", ["display": display.name, "app": app])
        }
    }

    /// Explains (Monitor + diagnostics) how the gaze probability splits over windows and whether one is clear enough.
    private func describeWindows(shares: [WindowFocus.WindowShare], likely: WindowFocus.WindowInfo?,
                                 on display: DisplayInfo, estimate: GazeModel.Estimate) {
        func span(_ w: WindowFocus.WindowInfo) -> (CGPoint, CGPoint) {
            (display.relativePoint(global: w.bounds.origin),
             display.relativePoint(global: CGPoint(x: w.bounds.maxX, y: w.bounds.maxY)))
        }
        let top = shares.prefix(3).map { s -> String in
            let (a, b) = span(s.window)
            return String(format: "%@ [x %.2f–%.2f] %.0f %%", appName(s.window.pid), a.x, b.x, s.share * 100)
        }
        var info = top.isEmpty ? "No window under gaze" : top.joined(separator: " · ")
        info += String(format: "  (±%.0f %% × ±%.0f %%)", estimate.errorX * 100, estimate.errorY * 100)
        if let likely {
            info += " → \(appName(likely.pid))"
        } else if !shares.isEmpty {
            info += " → not clear enough, keeps last used"
        }
        windowInfo = info

        guard diagnostics.isRecording else { return }
        let key = "\(likely?.id ?? 0)|" + shares.prefix(3).map { "\($0.window.id):\(Int($0.share * 10))" }.joined(separator: ",")
        guard key != lastLoggedWindows else { return }
        lastLoggedWindows = key
        diagnostics.log("windows", [
            "display": display.name,
            "u": Double(estimate.point.x).rounded(toPlaces: 3), "v": Double(estimate.point.y).rounded(toPlaces: 3),
            "errX": estimate.errorX.rounded(toPlaces: 3), "errY": estimate.errorY.rounded(toPlaces: 3),
            "shares": shares.prefix(4).map { s -> [String: Any] in
                let (a, b) = span(s.window)
                return ["app": appName(s.window.pid), "share": s.share.rounded(toPlaces: 3),
                        "x0": Double(a.x).rounded(toPlaces: 3), "x1": Double(b.x).rounded(toPlaces: 3),
                        "y0": Double(a.y).rounded(toPlaces: 3), "y1": Double(b.y).rounded(toPlaces: 3)]
            },
            "chosen": likely.map { appName($0.pid) } ?? "",
            "focused": WindowFocus.focusedWindow().map { appName($0.pid) } ?? "",
        ])
    }

    private func appName(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }

    // MARK: - Learning from clicks

    /// You look where you click: every click is a free, labelled calibration sample.
    func handleClick(at p: CGPoint) {
        guard enabled, let sample = smoothed, CACurrentMediaTime() - lastSampleTime < 0.3,
              let display = Displays.display(containing: p), model.isCalibrated(display.uuid) else { return }

        let hit = bestUUID == display.uuid
        var hits = clickHits[display.uuid, default: []]
        hits.append(hit)
        if hits.count > 20 { hits.removeFirst() }
        clickHits[display.uuid] = hits
        let hitRate = Double(hits.filter { $0 }.count) / Double(hits.count)
        if hits.count >= 12, hitRate < 0.5, accuracyWarning == nil {
            accuracyWarning = display.name
            onStateChange?()
        }

        let relative = display.relativePoint(global: p)
        if diagnostics.isRecording {
            let predicted = model.predictPoint(sample, on: display.uuid)
            diagnostics.log("click", [
                "display": display.name, "hit": hit, "f": Diagnostics.features(sample),
                "u": Double(relative.x).rounded(toPlaces: 3), "v": Double(relative.y).rounded(toPlaces: 3),
                "pu": Double(predicted?.x ?? -9).rounded(toPlaces: 3), "pv": Double(predicted?.y ?? -9).rounded(toPlaces: 3),
            ])
        }
        if settings.learnFromClicks {
            model.addClickSample(CalibrationSample(features: sample, displayUUID: display.uuid, point: relative, fromClick: true),
                                 frame: display.bounds)
        }
    }
}
