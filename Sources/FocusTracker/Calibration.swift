import AppKit

/// Full-screen overlay that walks a dot around each screen and records gaze samples for each position.
final class CalibrationController {
    private(set) var isRunning = false
    private var task: Task<Void, Never>?
    private var window: CalibrationWindow?
    private var collected: [GazeFeatures] = []
    private var isCollecting = false

    func feed(_ features: GazeFeatures?) {
        if isCollecting, let features { collected.append(features) }
    }

    func cancel() {
        task?.cancel()
    }

    /// Calls `completion` with samples per display UUID, or `nil` if cancelled.
    func run(displays: [DisplayInfo], completion: @escaping ([String: [CalibrationSample]]?) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        let all = Displays.all()

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var result: [String: [CalibrationSample]] = [:]

            for (index, display) in displays.enumerated() {
                guard !Task.isCancelled, let screen = Displays.screen(for: display.id) else { continue }
                let window = CalibrationWindow(screen: screen)
                window.onCancel = { [weak self] in self?.cancel() }
                self.window = window
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)

                let view = window.calibrationView
                let intro = "Screen \(index + 1) of \(displays.count): \(display.name)\nLook at the dot and turn your head as you normally would while working. Sit as you usually sit. Esc cancels."
                view.message = intro
                view.moveDot(to: CGPoint(x: 0.5, y: 0.5), animated: false)
                await Self.sleep(2.2)

                for point in Self.points(for: display, among: all) {
                    if Task.isCancelled { break }
                    view.moveDot(to: point, animated: true)
                    // Give head and eyes time to arrive before sampling.
                    await Self.sleep(0.9)

                    self.collected = []
                    self.isCollecting = true
                    view.setCollecting(true)
                    await Self.sleep(1.2)
                    var waited = 0.0
                    while self.collected.count < 10, waited < 3, !Task.isCancelled {
                        view.message = "Can't see your face — look at the dot, facing the camera."
                        await Self.sleep(0.25)
                        waited += 0.25
                    }
                    view.message = intro
                    self.isCollecting = false
                    view.setCollecting(false)

                    // The first frames can still be on the way to the dot.
                    let settled = self.collected.dropFirst(2)
                    result[display.uuid, default: []] += settled.map {
                        CalibrationSample(features: $0, displayUUID: display.uuid, point: point, fromClick: false)
                    }
                }
                window.orderOut(nil)
                self.window = nil
            }

            self.isRunning = false
            self.isCollecting = false
            completion(Task.isCancelled ? nil : result)
        }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// 3×3 grid, plus extra spots along edges this screen shares with another one.
    private static func points(for display: DisplayInfo, among displays: [DisplayInfo]) -> [CGPoint] {
        var points: [CGPoint] = [
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.08, y: 0.08), CGPoint(x: 0.5, y: 0.08), CGPoint(x: 0.92, y: 0.08),
            CGPoint(x: 0.92, y: 0.5), CGPoint(x: 0.92, y: 0.92), CGPoint(x: 0.5, y: 0.92),
            CGPoint(x: 0.08, y: 0.92), CGPoint(x: 0.08, y: 0.5),
        ]
        let along: [CGFloat] = [0.25, 0.5, 0.75]
        for edge in Displays.sharedEdges(of: display, among: displays) {
            switch edge {
            case .left: points += along.map { CGPoint(x: 0.03, y: $0) }
            case .right: points += along.map { CGPoint(x: 0.97, y: $0) }
            case .top: points += along.map { CGPoint(x: $0, y: 0.03) }
            case .bottom: points += along.map { CGPoint(x: $0, y: 0.97) }
            }
        }
        return points
    }
}

final class CalibrationWindow: NSWindow {
    var onCancel: (() -> Void)?
    let calibrationView: CalibrationView

    init(screen: NSScreen) {
        calibrationView = CalibrationView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.88)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = calibrationView
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

final class CalibrationView: NSView {
    private let ring = CAShapeLayer()
    private let dot = CAShapeLayer()
    private let label = NSTextField(wrappingLabelWithString: "")

    var message: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        ring.path = CGPath(ellipseIn: CGRect(x: -22, y: -22, width: 44, height: 44), transform: nil)
        ring.fillColor = NSColor.white.withAlphaComponent(0.12).cgColor
        ring.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        ring.lineWidth = 2
        dot.path = CGPath(ellipseIn: CGRect(x: -7, y: -7, width: 14, height: 14), transform: nil)
        dot.fillColor = NSColor.systemGreen.cgColor
        layer?.addSublayer(ring)
        layer?.addSublayer(dot)

        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: frame.height * 0.3),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `p` is relative to the screen, 0...1 with top-left origin.
    func moveDot(to p: CGPoint, animated: Bool) {
        let position = CGPoint(x: p.x * bounds.width, y: (1 - p.y) * bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.5)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        ring.position = position
        dot.position = position
        CATransaction.commit()
    }

    func setCollecting(_ collecting: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(collecting ? 1.0 : 0.2)
        ring.transform = collecting ? CATransform3DMakeScale(0.45, 0.45, 1) : CATransform3DIdentity
        ring.strokeColor = (collecting ? NSColor.systemGreen : NSColor.white.withAlphaComponent(0.8)).cgColor
        CATransaction.commit()
    }
}
