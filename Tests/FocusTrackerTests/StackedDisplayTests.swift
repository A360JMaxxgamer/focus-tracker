import XCTest
@testable import FocusTracker

/// The reported setup: Odyssey G7 in front, LG 27GL850 to the left, MacBook directly below the LG.
/// Head tilt is small and noisy, so each screen alone barely learns "up/down"; the shared model must
/// still tell LG and MacBook apart and never call the MacBook "away".
final class StackedDisplayTests: XCTestCase {
    private var url: URL!

    private let frames: [String: CGRect] = [
        "odyssey": CGRect(x: 0, y: 0, width: 3360, height: 1890),
        "lg": CGRect(x: -2560, y: -289, width: 2560, height: 1440),
        "macbook": CGRect(x: -1512, y: 1151, width: 1512, height: 982),
    ]
    private let head = CGPoint(x: 1300, y: 700)
    private let distance: CGFloat = 3000

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-stack-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Looking at global point `g`: head does 60 % of the turn. Small tilts are done by the eyes alone; the head
    /// only follows beyond ±0.1 rad (as people do), and eye tilt is barely measurable. `posture` shifts head tilt,
    /// like sitting a little differently than during calibration.
    private func features(at g: CGPoint, noise: Double, posture: Double = 0) -> GazeFeatures {
        func n(_ scale: Double) -> Double { Double.random(in: -noise...noise) * scale }
        let yaw = -Double(atan((g.x - head.x) / distance))
        let pitch = -Double(atan((g.y - head.y) / distance))
        let headYaw = yaw * 0.6 + n(1)
        let headPitch = (pitch > 0 ? 1 : -1) * max(0, abs(pitch) - 0.1) * 0.8 + posture + n(1.5)
        return GazeFeatures(
            yaw: headYaw, pitch: headPitch,
            noseX: headYaw * 0.45 + n(0.5), noseY: -0.9 - headPitch * 0.35 + n(1),
            eyeX: (yaw - headYaw) * 0.1 + n(0.2), eyeY: (pitch - headPitch) * 0.05 + n(0.4), eyeOpen: 0.2 + (pitch - headPitch) * 0.05 + n(0.4),
            faceX: 0.5 + headYaw * 0.04 + n(0.1), faceY: 0.5 + n(0.1), faceSize: 0.063 + n(0.02))
    }

    private func global(_ uuid: String, _ p: CGPoint) -> CGPoint {
        let f = frames[uuid]!
        return CGPoint(x: f.minX + p.x * f.width, y: f.minY + p.y * f.height)
    }

    private func calibrated() -> GazeModel {
        let model = GazeModel(fileURL: url)
        let grid: [CGPoint] = [0.08, 0.5, 0.92].flatMap { x in [0.08, 0.5, 0.92].map { CGPoint(x: x, y: $0) } }
        for uuid in frames.keys {
            let samples = grid.flatMap { p in
                (0..<10).map { _ in
                    CalibrationSample(features: features(at: global(uuid, p), noise: 0.012), displayUUID: uuid, point: p, fromClick: false)
                }
            }
            model.replaceCalibration(for: uuid, with: samples, frames: frames)
        }
        return model
    }

    func testTellsStackedScreensApart() {
        let model = calibrated()
        for uuid in ["lg", "macbook", "odyssey"] {
            var correct = 0
            for _ in 0..<100 {
                let p = CGPoint(x: .random(in: 0.15...0.85), y: .random(in: 0.15...0.85))
                let best = model.estimates(for: features(at: global(uuid, p), noise: 0.015, posture: 0.02), among: Set(frames.keys)).first!
                if best.uuid == uuid, best.score <= max(0.35, best.classifyError * 2) { correct += 1 }
            }
            XCTAssertGreaterThan(correct, 85, "\(uuid): \(correct) % recognised")
        }
    }

    func testLookingAtTheDeskIsAway() {
        let model = calibrated()
        let desk = CGPoint(x: 1300, y: 4500)
        let best = model.estimates(for: features(at: desk, noise: 0), among: Set(frames.keys)).first!
        XCTAssertGreaterThan(best.score, max(0.35, best.classifyError * 2))
    }
}
