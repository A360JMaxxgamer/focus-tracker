import AppKit
import SwiftUI

/// Small click-through dot that shows where the model thinks you are looking.
final class GazeDot {
    private let size: CGFloat = 22
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        view.layer?.cornerRadius = size / 2
        view.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.55).cgColor
        view.layer?.borderColor = NSColor.white.cgColor
        view.layer?.borderWidth = 2
        panel.contentView = view
        return panel
    }()

    /// Outline of the uncertainty box around the dot.
    private lazy var boxPanel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.7).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 6
        view.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.06).cgColor
        panel.contentView = view
        return panel
    }()

    /// `p` and `box` in global CG coordinates; `nil` hides the dot.
    func show(at p: CGPoint?, box: CGRect? = nil) {
        guard let p else { hide(); return }
        if let box {
            let origin = Displays.toAppKit(CGPoint(x: box.minX, y: box.maxY))
            boxPanel.setFrame(NSRect(origin: origin, size: box.size), display: true)
            if !boxPanel.isVisible { boxPanel.orderFrontRegardless() }
        } else if boxPanel.isVisible {
            boxPanel.orderOut(nil)
        }
        let ns = Displays.toAppKit(p)
        panel.setFrameOrigin(NSPoint(x: ns.x - size / 2, y: ns.y - size / 2))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
        if boxPanel.isVisible { boxPanel.orderOut(nil) }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var profiles: ProfileStore
    @ObservedObject var cameraList: CameraList
    let onNewProfile: () -> Void
    let onDeleteProfile: () -> Void
    let onCalibrate: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Active profile", selection: Binding(get: { profiles.activeID }, set: { profiles.activate($0) })) {
                    ForEach(profiles.profiles) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
                TextField("Name", text: Binding(get: { profiles.active.name },
                                                set: { profiles.rename(profiles.activeID, to: $0) }))
                Picker("Camera", selection: Binding(get: { profiles.active.cameraID }, set: { profiles.setCamera($0) })) {
                    Text("System default").tag("")
                    ForEach(cameraList.cameras) { camera in
                        Text(camera.name).tag(camera.id)
                    }
                    let selected = profiles.active.cameraID
                    if !selected.isEmpty && !cameraList.cameras.contains(where: { $0.id == selected }) {
                        Text("Selected camera (not connected)").tag(selected)
                    }
                }
                LabeledContent("Calibrated screens") {
                    Text(profiles.active.screens.isEmpty ? "none" : profiles.active.screens.map(\.name).joined(separator: ", "))
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Switch profile automatically", isOn: $profiles.autoSwitch)
                HStack {
                    Button("New Profile…", action: onNewProfile)
                    Button("Delete Profile…", action: onDeleteProfile).disabled(profiles.profiles.count < 2)
                    Spacer()
                    Button("Calibrate…", action: onCalibrate)
                }
            } header: {
                Text("Profile")
            } footer: {
                Text("Each profile keeps its own camera and calibration — e.g. Home and Office. With automatic switching, the profile whose calibrated screens (and camera) are connected is picked when you plug in or wake.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Timing") {
                slider("Settle time", value: $settings.dwellMs, in: 100...1200, step: 50, unit: "ms",
                       help: "Keep facing another screen this long before focus moves. Quick glances are ignored.")
                slider("Wait after typing", value: $settings.typingBeatMs, in: 200...2000, step: 100, unit: "ms",
                       help: "Focus never moves while you type; it follows after this pause.")
                slider("Wait after mouse", value: $settings.mouseQuietMs, in: 500...4000, step: 100, unit: "ms",
                       help: "While you use the mouse or trackpad, and this long after, nothing moves.")
                VStack(alignment: .leading) {
                    Slider(value: $settings.edgeMargin, in: 0...0.2, step: 0.01) {
                        Text("Edge margin: \(Int((settings.edgeMargin * 100).rounded())) % of screen")
                    }
                    Text("How far past the edge you must look before leaving the current screen. Higher = no ping-pong at the bezel, lower = faster switching.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Behaviour") {
                Toggle("Switch windows on the same screen", isOn: $settings.windowSwitching)
                Toggle("Bring the pointer along", isOn: $settings.movePointer)
                Toggle("Learn from clicks", isOn: $settings.learnFromClicks)
                Toggle("Show gaze dot (debug)", isOn: $settings.showGazeDot)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                LabeledContent("Pause / resume", value: "⇧⌘G")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, unit: String, help: String) -> some View {
        VStack(alignment: .leading) {
            Slider(value: value, in: range, step: step) {
                Text("\(title): \(Int(value.wrappedValue)) \(unit)")
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DebugView: View {
    @ObservedObject var engine: FocusEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                row("Face", engine.faceVisible ? "visible" : "not found")
                if let f = engine.features {
                    row("Head", String(format: "yaw %+.1f° · pitch %+.1f°", f.yaw * 180 / .pi, f.pitch * 180 / .pi))
                    row("Nose", String(format: "x %+.3f · y %+.3f", f.noseX, f.noseY))
                    row("Eyes", String(format: "x %+.3f · y %+.3f · open %.3f", f.eyeX, f.eyeY, f.eyeOpen))
                    row("Seat", String(format: "x %.2f · y %.2f · size %.3f", f.faceX, f.faceY, f.faceSize))
                }
                row("Facing", engine.facing?.name ?? "—")
                row("Switching to", engine.candidateName ?? "—")
                row("Waiting for", engine.blockedReason ?? "—")
                row("Gaze point", engine.gazePoint.map { String(format: "%.0f, %.0f", $0.x, $0.y) } ?? "—")
                row("Window", engine.windowInfo.isEmpty ? "—" : engine.windowInfo)
                row("Last action", engine.lastAction.isEmpty ? "—" : engine.lastAction)
            }
            Divider()
            Text("Per screen: shared model (u, v; 0…1 = on screen, decides the screen) · own model · accuracy")
                .font(.caption).foregroundStyle(.secondary)
            if engine.estimateRows.isEmpty {
                Text("Not calibrated").foregroundStyle(.secondary)
            }
            ForEach(engine.estimateRows) { e in
                HStack {
                    Text(e.name).fontWeight(e.score <= 0 ? .bold : .regular)
                    Spacer()
                    Text(String(format: "%.2f, %.2f · %.2f, %.2f · ±%.0f×%.0f %%", e.classifyPoint.x, e.classifyPoint.y,
                                e.point.x, e.point.y, e.errorX * 100, e.errorY * 100))
                }
            }
        }
        .font(.system(.body, design: .monospaced))
        .padding(16)
        .frame(width: 520, alignment: .topLeading)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
    }
}
