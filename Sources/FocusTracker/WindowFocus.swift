import AppKit
import ApplicationServices

/// A window of another app, reachable through the Accessibility API.
struct TrackedWindow {
    let pid: pid_t
    let element: AXUIElement
    let frame: CGRect
    var windowID: CGWindowID?

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// Whether the window still exists and where it is now.
    var currentFrame: CGRect? { element.frame }
}

extension AXUIElement {
    var frame: CGRect? {
        guard let posValue = axValue(kAXPositionAttribute), let sizeValue = axValue(kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let value = copy(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        (copy(attribute) as? [AXUIElement]) ?? []
    }

    func bool(_ attribute: String) -> Bool? {
        copy(attribute) as? Bool
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }

    private func axValue(_ attribute: String) -> AXValue? {
        guard let value = copy(attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private func copy(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}

enum WindowFocus {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The focused window of the frontmost app (not ours).
    static func focusedWindow() -> TrackedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = axApp.element(kAXFocusedWindowAttribute), let frame = window.frame else { return nil }
        return TrackedWindow(pid: app.processIdentifier, element: window, frame: frame)
    }

    /// The front-most normal window whose bounds contain `rect` entirely.
    static func window(covering rect: CGRect) -> TrackedWindow? {
        for info in onScreenWindows() where info.bounds.contains(rect) {
            return axWindow(pid: info.pid, matching: info.bounds, windowID: info.id)
        }
        return nil
    }

    /// The front-most normal window whose centre lies on `display`.
    static func topWindow(on display: CGRect) -> TrackedWindow? {
        for info in onScreenWindows() where display.contains(CGPoint(x: info.bounds.midX, y: info.bounds.midY)) {
            if let w = axWindow(pid: info.pid, matching: info.bounds, windowID: info.id) { return w }
        }
        return nil
    }

    /// Brings `window` to the front and gives it keyboard focus, without clicking.
    @discardableResult
    static func focus(_ window: TrackedWindow) -> Bool {
        let axApp = AXUIElementCreateApplication(window.pid)
        window.element.set(kAXMainAttribute, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        axApp.set(kAXFrontmostAttribute, kCFBooleanTrue)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != window.pid {
            NSRunningApplication(processIdentifier: window.pid)?.activate()
        }
        window.element.set(kAXFocusedAttribute, kCFBooleanTrue)
        return raised == .success
    }

    static func movePointer(to p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: - Gaze → window

    struct WindowInfo {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
    }

    struct WindowShare {
        let window: WindowInfo
        /// Probability (0...1) that the gaze is on the visible part of this window.
        let share: Double
    }

    /// Spreads the gaze estimate as a Gaussian (`sigma` per axis, in points) over `display` and sums, per window,
    /// the probability that lands on its visible part. `windows` are front to back; occluded parts count for the
    /// window in front. Mass beyond the display edge belongs to whatever sits at that edge (you are facing this
    /// display), so it is pulled in past the menu bar or Dock.
    static func shares(center p: CGPoint, sigma: CGSize, display: CGRect, windows: [WindowInfo]) -> [WindowShare] {
        let onDisplay = windows.filter { $0.bounds.intersects(display) }
        let edge = display.insetBy(dx: min(80, display.width / 4), dy: min(80, display.height / 4))
        let steps = 7
        var weights: [CGWindowID: Double] = [:]
        var total = 0.0
        for i in -steps...steps {
            for j in -steps...steps {
                // Sample ±2.5 sigma.
                let zx = Double(i) / Double(steps) * 2.5, zy = Double(j) / Double(steps) * 2.5
                let weight = exp(-0.5 * (zx * zx + zy * zy))
                var q = CGPoint(x: p.x + CGFloat(zx) * sigma.width, y: p.y + CGFloat(zy) * sigma.height)
                if !display.contains(q) {
                    q.x = min(max(q.x, edge.minX), edge.maxX)
                    q.y = min(max(q.y, edge.minY), edge.maxY)
                }
                total += weight
                if let hit = onDisplay.first(where: { $0.bounds.contains(q) }) {
                    weights[hit.id, default: 0] += weight
                }
            }
        }
        guard total > 0 else { return [] }
        return onDisplay.compactMap { w in weights[w.id].map { WindowShare(window: w, share: $0 / total) } }
            .sorted { $0.share > $1.share }
    }

    /// The window you are most likely looking at, if the estimate is clear enough: at least `minShare`
    /// of the probability, and well ahead of the runner-up.
    static func likelyWindow(from shares: [WindowShare], minShare: Double = 0.6, minLead: Double = 0.25) -> WindowInfo? {
        guard let best = shares.first, best.share >= minShare,
              best.share - (shares.dropFirst().first?.share ?? 0) >= minLead else { return nil }
        return best.window
    }

    static func tracked(_ info: WindowInfo) -> TrackedWindow? {
        axWindow(pid: info.pid, matching: info.bounds, windowID: info.id)
    }

    // MARK: - Private

    /// Normal (layer 0) on-screen windows of other apps, front to back.
    static func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = getpid()
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  bounds.width > 120, bounds.height > 80 else { return nil }
            return WindowInfo(id: id, pid: pid, bounds: bounds)
        }
    }

    private static func axWindow(pid: pid_t, matching bounds: CGRect, windowID: CGWindowID) -> TrackedWindow? {
        let axApp = AXUIElementCreateApplication(pid)
        for window in axApp.elements(kAXWindowsAttribute) {
            guard let frame = window.frame else { continue }
            if abs(frame.minX - bounds.minX) < 4, abs(frame.minY - bounds.minY) < 4,
               abs(frame.width - bounds.width) < 4, abs(frame.height - bounds.height) < 4 {
                return TrackedWindow(pid: pid, element: window, frame: frame, windowID: windowID)
            }
        }
        return nil
    }
}

/// Remembers the last focused window on every display.
final class WindowHistory {
    private(set) var lastWindow: [CGDirectDisplayID: TrackedWindow] = [:]
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.poll() }
        }
        poll()
    }

    func poll() {
        guard WindowFocus.isTrusted, let window = WindowFocus.focusedWindow(),
              let display = Displays.display(containing: window.center) else { return }
        lastWindow[display.id] = window
    }

    /// The remembered window for `display`, if it still exists and is still there.
    func window(on display: DisplayInfo) -> TrackedWindow? {
        guard let w = lastWindow[display.id], let frame = w.currentFrame,
              display.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else {
            lastWindow[display.id] = nil
            return nil
        }
        return TrackedWindow(pid: w.pid, element: w.element, frame: frame, windowID: w.windowID)
    }
}
