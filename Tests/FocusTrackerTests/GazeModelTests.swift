import XCTest
@testable import FocusTracker

final class GazeModelTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Simulated user looking at relative point `p` on a screen centred at `yawCenter` radians:
    /// the head does ~70 % of the turn, the eyes the rest. `seat` shifts the face in the camera frame.
    private func features(yawCenter: Double, pitchCenter: Double = 0, p: CGPoint, noise: Double,
                          seat: (x: Double, size: Double) = (0, 0)) -> GazeFeatures {
        func n(_ scale: Double = 1) -> Double { Double.random(in: -noise...noise) * scale }
        let gazeYaw = yawCenter + (Double(p.x) - 0.5) * 0.45
        let gazePitch = pitchCenter - (Double(p.y) - 0.5) * 0.25
        let yaw = gazeYaw * 0.7 + n()
        let pitch = gazePitch * 0.7 + n()
        return GazeFeatures(
            yaw: yaw, pitch: pitch,
            noseX: yaw * 0.5 + n(0.4), noseY: 0.9 - pitch * 0.4 + n(0.4),
            eyeX: gazeYaw * 0.3 * 0.12 + n(0.15), eyeY: gazePitch * 0.3 * 0.12 + n(0.15),
            faceX: 0.5 + yaw * 0.05 + seat.x + n(0.1), faceY: 0.45 + n(0.1), faceSize: 0.1 + seat.size + n(0.02))
    }

    private let grid: [CGPoint] = [0.08, 0.5, 0.92].flatMap { x in [0.08, 0.5, 0.92].map { CGPoint(x: x, y: $0) } }

    private let frames: [String: CGRect] = [
        "left": CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        "right": CGRect(x: 0, y: 0, width: 1920, height: 1080),
    ]

    private func calibrated() -> GazeModel {
        let model = GazeModel(fileURL: url)
        for (uuid, center) in [("left", -0.4), ("right", 0.4)] {
            let samples = grid.flatMap { p in
                (0..<12).map { _ in
                    CalibrationSample(features: features(yawCenter: center, p: p, noise: 0.01), displayUUID: uuid, point: p, fromClick: false)
                }
            }
            model.replaceCalibration(for: uuid, with: samples, frames: frames)
        }
        return model
    }

    private func accuracy(_ model: GazeModel, seat: (x: Double, size: Double) = (0, 0)) -> Double {
        var correct = 0
        for _ in 0..<200 {
            let p = CGPoint(x: .random(in: 0.05...0.95), y: .random(in: 0.05...0.95))
            let isLeft = Bool.random()
            let f = features(yawCenter: isLeft ? -0.4 : 0.4, p: p, noise: 0.015, seat: seat)
            let best = model.estimates(for: f, among: ["left", "right"]).first
            if best?.uuid == (isLeft ? "left" : "right"), best!.score <= 0.35 { correct += 1 }
        }
        return Double(correct) / 200
    }

    func testClassifiesScreens() {
        XCTAssertGreaterThan(accuracy(calibrated()), 0.97)
    }

    /// Sitting a bit to the side / closer than during calibration must not read as "looking away".
    func testToleratesDifferentSeatPosition() {
        XCTAssertGreaterThan(accuracy(calibrated(), seat: (x: 0.08, size: 0.02)), 0.9)
    }

    func testPredictsPointWithReportedError() {
        let model = calibrated()
        var squared = 0.0
        for _ in 0..<100 {
            let p = CGPoint(x: .random(in: 0.1...0.9), y: .random(in: 0.1...0.9))
            let predicted = model.predictPoint(features(yawCenter: 0.4, p: p, noise: 0.005), on: "right")!
            squared += Double(pow(predicted.x - p.x, 2) + pow(predicted.y - p.y, 2))
        }
        XCTAssertLessThan(sqrt(squared / 100), 0.1)
        let reported = model.errors["right"]!
        XCTAssertGreaterThan(reported, 0)
        XCTAssertLessThan(reported, 0.2)
    }

    func testLookingDownIsAway() {
        let model = calibrated()
        let f = features(yawCenter: 0, pitchCenter: -0.8, p: CGPoint(x: 0.5, y: 0.5), noise: 0)
        XCTAssertGreaterThan(model.estimates(for: f, among: ["left", "right"]).first!.score, 0.35)
    }

    func testDiscardsOutdatedCalibrationFile() throws {
        try Data("[]".utf8).write(to: url)
        let model = GazeModel(fileURL: url)
        XCTAssertTrue(model.discardedOutdatedCalibration)
        XCTAssertTrue(model.calibratedDisplays.isEmpty)
    }

    func testPersistsAndCapsClickSamples() {
        let model = calibrated()
        for _ in 0..<100 {
            model.addClickSample(CalibrationSample(
                features: features(yawCenter: 0.4, p: CGPoint(x: 0.5, y: 0.5), noise: 0.01),
                displayUUID: "right", point: CGPoint(x: 0.5, y: 0.5), fromClick: true), frame: frames["right"]!)
        }
        let reloaded = GazeModel(fileURL: url)
        XCTAssertFalse(reloaded.discardedOutdatedCalibration)
        XCTAssertEqual(reloaded.samples.filter(\.fromClick).count, 80)
        XCTAssertEqual(reloaded.calibratedDisplays, ["left", "right"])
        XCTAssertEqual(reloaded.frames, frames)
    }
}
