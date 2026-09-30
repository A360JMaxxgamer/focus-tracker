import AppKit

/// Watches global keyboard and mouse activity so focus never moves mid-sentence or while the mouse is in use.
final class ActivityMonitor {
    private(set) var lastKeyTime: CFTimeInterval = 0
    private(set) var lastMouseTime: CFTimeInterval = 0
    /// Left clicks in global CG coordinates.
    var onLeftClick: ((CGPoint) -> Void)?

    private var monitors: [Any] = []

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] _ in
            self?.lastKeyTime = CACurrentMediaTime()
        }) { monitors.append(keys) }

        let mouseEvents: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]
        if let mouse = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents, handler: { [weak self] event in
            guard let self else { return }
            self.lastMouseTime = CACurrentMediaTime()
            if event.type == .leftMouseDown {
                self.onLeftClick?(Displays.toCG(NSEvent.mouseLocation))
            }
        }) { monitors.append(mouse) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    func secondsSinceKey(_ now: CFTimeInterval = CACurrentMediaTime()) -> Double { now - lastKeyTime }
    func secondsSinceMouse(_ now: CFTimeInterval = CACurrentMediaTime()) -> Double { now - lastMouseTime }
}
