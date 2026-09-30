import Foundation
import CoreGraphics

/// A labelled observation: while the user had `features`, they were looking at `point` on display `displayUUID`.
struct CalibrationSample: Codable {
    var features: GazeFeatures
    var displayUUID: String
    /// Position within the display, 0...1, top-left origin.
    var point: CGPoint
    var fromClick: Bool
}

/// Two ridge regressions from gaze features:
/// - one shared model over all displays in the display arrangement (global points), which decides which display
///   you face — it sees head tilt and turn across every screen, so stacked or side-by-side screens separate well;
/// - one model per display for the point on that display (used to pick windows).
/// A predicted point far outside every display means you look elsewhere (desk, phone, window).
final class GazeModel {
    private(set) var samples: [CalibrationSample] = []
    /// The loaded file came from an older version whose features are incompatible; recalibration is needed.
    private(set) var discardedOutdatedCalibration = false

    struct Estimate {
        let uuid: String
        /// Predicted point relative to the display (can lie outside 0...1).
        let point: CGPoint
        /// Where the shared model puts the gaze, relative to this display; decides `score`.
        let classifyPoint: CGPoint
        /// Negative: inside (depth to nearest edge). Positive: distance outside. In screen fractions.
        let score: Double
        /// Expected error of `classifyPoint` (screen fractions).
        let classifyError: Double
        /// Expected prediction error for this display, in screen fractions (combined and per axis).
        let error: Double
        let errorX: Double
        let errorY: Double
    }

    private struct Fit {
        let mean: [Double]
        let wx: [Double]
        let wy: [Double]
        let quadratic: Bool
    }

    private var fits: [String: Fit] = [:]
    private var globalFit: Fit?
    /// Display frames (global points) at calibration time: the coordinate system of the shared model.
    private(set) var frames: [String: CGRect] = [:]
    private var globalErrors: [String: (x: Double, y: Double)] = [:]
    /// Global points per target unit, keeps the shared regression well conditioned.
    private static let globalScale: CGFloat = 1000
    /// Combined expected error per display (screen fractions).
    var errors: [String: Double] { axisErrors.mapValues { hypot($0.x, $0.y) } }
    /// Expected error per display and axis (screen fractions).
    private(set) var axisErrors: [String: (x: Double, y: Double)] = [:]
    private static let fallbackError = (x: 0.12, y: 0.12)
    private var fileURL: URL

    private let maxClickSamplesPerDisplay = 80
    private static let fileVersion = 3

    /// Size of a meaningful change per feature (see `GazeFeatures.vector`). Fixed rather than learned, so a
    /// feature that barely varied during calibration can't blow up when you shift in your seat.
    private static let scales: [Double] = [0.1, 0.1, 0.05, 0.05, 0.02, 0.02, 0.02, 0.05, 0.05, 0.01]
    /// Ridge penalty per feature. Seat position (last three) is only trusted once clicks from
    /// different positions back it up.
    private static let penalties: [Double] = [1, 1, 1, 1, 1, 1, 1, 100, 100, 100]
    private static let minSamples = 12

    private struct File: Codable {
        var version: Int
        var samples: [CalibrationSample]
        var frames: [String: CGRect]?
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load(from: fileURL)
    }

    /// Switches to another calibration file (e.g. another profile).
    func load(from url: URL) {
        fileURL = url
        discardedOutdatedCalibration = false
        samples = []
        frames = [:]
        if let data = try? Data(contentsOf: url) {
            if let file = try? JSONDecoder().decode(File.self, from: data), file.version == Self.fileVersion {
                samples = file.samples
                frames = file.frames ?? [:]
            } else {
                discardedOutdatedCalibration = true
            }
        }
        rebuild()
    }

    var calibratedDisplays: Set<String> {
        Set(samples.lazy.filter { !$0.fromClick }.map(\.displayUUID)).intersection(fits.keys)
    }

    func isCalibrated(_ uuid: String) -> Bool { calibratedDisplays.contains(uuid) }

    // MARK: - Editing

    /// `frames`: current arrangement of the connected displays; it becomes the shared model's coordinate system.
    func replaceCalibration(for uuid: String, with new: [CalibrationSample], frames current: [String: CGRect]) {
        samples.removeAll { $0.displayUUID == uuid }
        samples.append(contentsOf: new)
        frames.merge(current) { _, new in new }
        rebuild()
        save()
    }

    /// Fills in frames for displays calibrated before frames were stored.
    func addMissingFrames(_ current: [String: CGRect]) {
        let missing = Set(samples.map(\.displayUUID)).subtracting(frames.keys)
        let found = current.filter { missing.contains($0.key) }
        guard !found.isEmpty else { return }
        frames.merge(found) { old, _ in old }
        rebuild()
        save()
    }

    func addClickSample(_ sample: CalibrationSample, frame: CGRect) {
        guard isCalibrated(sample.displayUUID) else { return }
        if frames[sample.displayUUID] == nil { frames[sample.displayUUID] = frame }
        samples.append(sample)
        let clicks = samples.indices.filter { samples[$0].fromClick && samples[$0].displayUUID == sample.displayUUID }
        if clicks.count > maxClickSamplesPerDisplay {
            let drop = Set(clicks.prefix(clicks.count - maxClickSamplesPerDisplay))
            samples = samples.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
        rebuild(onlyDisplay: sample.displayUUID)
        save()
    }

    func removeClickSamples() {
        samples.removeAll { $0.fromClick }
        rebuild()
        save()
    }

    func clear() {
        samples.removeAll()
        frames.removeAll()
        rebuild()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(File(version: Self.fileVersion, samples: samples, frames: frames)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Prediction

    /// Estimates for every calibrated display in `uuids`, best (most inside) first.
    func estimates(for f: GazeFeatures, among uuids: Set<String>) -> [Estimate] {
        let v = Self.vector(f)
        let global = globalFit.map { Self.apply($0, v, clamp: false) }
        return fits.compactMap { uuid, fit -> Estimate? in
            guard uuids.contains(uuid) else { return nil }
            let local = Self.apply(fit, v)
            let e = axisErrors[uuid] ?? Self.fallbackError
            var classify = local
            var classifyError = hypot(e.x, e.y)
            if let global, let frame = frames[uuid] {
                classify = Self.relative(global, in: frame)
                let ge = globalErrors[uuid] ?? e
                classifyError = hypot(ge.x, ge.y)
            }
            // The per-display model is finer on its own screen; off its edges trust the shared one.
            let point = Self.score(local) <= 0.1 ? local : classify
            return Estimate(uuid: uuid, point: point, classifyPoint: classify, score: Self.score(classify),
                            classifyError: classifyError, error: hypot(e.x, e.y), errorX: e.x, errorY: e.y)
        }.sorted { $0.score < $1.score }
    }

    /// Estimated point on `uuid` (0...1, may lie outside).
    func predictPoint(_ f: GazeFeatures, on uuid: String) -> CGPoint? {
        fits[uuid].map { Self.apply($0, Self.vector(f)) }
    }

    /// Negative inside the unit square (depth to the nearest edge), positive outside (distance to it).
    static func score(_ p: CGPoint) -> Double {
        let dx = max(0, -p.x, p.x - 1), dy = max(0, -p.y, p.y - 1)
        if dx == 0 && dy == 0 { return -Double(min(p.x, 1 - p.x, p.y, 1 - p.y)) }
        return Double(hypot(dx, dy))
    }

    // MARK: - Fitting

    private static func vector(_ f: GazeFeatures) -> [Double] {
        zip(f.vector, scales).map { $0 / $1 }
    }

    /// Regression input: bias, centred features and — for the shared model, which spans large angles —
    /// quadratic head-pose terms.
    private static func input(_ v: [Double], mean: [Double], quadratic: Bool) -> [Double] {
        let c = zip(v, mean).map { $0 - $1 }
        var x = [1.0] + c
        if quadratic {
            for (i, j) in quadraticPairs { x.append(c[i] * c[j] * 0.1) }
        }
        return x
    }

    /// yaw², pitch², yaw·pitch, noseX², noseY², noseX·noseY
    private static let quadraticPairs = [(0, 0), (1, 1), (0, 1), (2, 2), (3, 3), (2, 3)]

    private static func apply(_ fit: Fit, _ v: [Double], clamp: Bool = true) -> CGPoint {
        let x = input(v, mean: fit.mean, quadratic: fit.quadratic)
        let px = zip(x, fit.wx).map(*).reduce(0, +)
        let py = zip(x, fit.wy).map(*).reduce(0, +)
        guard clamp else { return CGPoint(x: px * globalScale, y: py * globalScale) }
        // Keep wild extrapolations bounded; anything this far out is "not this display" anyway.
        return CGPoint(x: min(max(px, -3), 4), y: min(max(py, -3), 4))
    }

    private static func relative(_ global: CGPoint, in frame: CGRect) -> CGPoint {
        let p = CGPoint(x: (global.x - frame.minX) / frame.width, y: (global.y - frame.minY) / frame.height)
        return CGPoint(x: min(max(p.x, -3), 4), y: min(max(p.y, -3), 4))
    }

    private func globalTarget(_ s: CalibrationSample) -> CGPoint? {
        frames[s.displayUUID].map {
            CGPoint(x: ($0.minX + s.point.x * $0.width) / Self.globalScale,
                    y: ($0.minY + s.point.y * $0.height) / Self.globalScale)
        }
    }

    private func rebuild(onlyDisplay: String? = nil) {
        rebuildGlobal(withErrors: onlyDisplay == nil)
        if onlyDisplay == nil { fits = [:]; axisErrors = [:] }
        let uuids = onlyDisplay.map { [$0] } ?? Array(Set(samples.map(\.displayUUID)))
        for uuid in uuids {
            let own = samples.filter { $0.displayUUID == uuid }
            guard own.contains(where: { !$0.fromClick }), let fit = Self.fit(own) else {
                fits[uuid] = nil
                axisErrors[uuid] = nil
                continue
            }
            fits[uuid] = fit
            axisErrors[uuid] = Self.crossValidatedError(own) ?? Self.fallbackError
        }
    }

    /// Shared model over every display with a known frame. Cross-validation (costly) only on full rebuilds.
    private func rebuildGlobal(withErrors: Bool) {
        let usable = samples.filter { frames[$0.displayUUID] != nil && fitsOrCalibrated($0.displayUUID) }
        let targets = usable.compactMap(globalTarget)
        guard Set(usable.map(\.displayUUID)).count >= 1,
              let fit = Self.fit(usable, targets: targets, quadratic: true) else {
            globalFit = nil
            globalErrors = [:]
            return
        }
        globalFit = fit
        if withErrors { globalErrors = crossValidatedGlobalErrors(usable) }
    }

    private func fitsOrCalibrated(_ uuid: String) -> Bool {
        samples.contains { $0.displayUUID == uuid && !$0.fromClick }
    }

    /// Leave-one-calibration-point-out error of the shared model, per display, in that display's fractions.
    private func crossValidatedGlobalErrors(_ usable: [CalibrationSample]) -> [String: (x: Double, y: Double)] {
        let calibration = usable.filter { !$0.fromClick }
        let clicks = usable.filter(\.fromClick)
        let groups = Dictionary(grouping: calibration.indices) { i -> String in
            let s = calibration[i]
            return "\(s.displayUUID)|\(Int((s.point.x * 1000).rounded())),\(Int((s.point.y * 1000).rounded()))"
        }
        guard groups.count >= 6 else { return [:] }
        var sums: [String: (x: Double, y: Double, n: Double)] = [:]
        for indices in groups.values {
            let excluded = Set(indices)
            let training = calibration.indices.filter { !excluded.contains($0) }.map { calibration[$0] } + clicks
            guard let fit = Self.fit(training, targets: training.compactMap(globalTarget), quadratic: true) else { continue }
            let sample = calibration[indices[0]]
            guard let frame = frames[sample.displayUUID] else { continue }
            let predictions = indices.map { Self.relative(Self.apply(fit, Self.vector(calibration[$0].features), clamp: false), in: frame) }
            let n = CGFloat(predictions.count)
            let px = predictions.map(\.x).reduce(0, +) / n, py = predictions.map(\.y).reduce(0, +) / n
            var sum = sums[sample.displayUUID] ?? (0, 0, 0)
            sum.x += Double((px - sample.point.x) * (px - sample.point.x))
            sum.y += Double((py - sample.point.y) * (py - sample.point.y))
            sum.n += 1
            sums[sample.displayUUID] = sum
        }
        return sums.mapValues { (sqrt($0.x / $0.n), sqrt($0.y / $0.n)) }
    }

    private static func fit(_ samples: [CalibrationSample]) -> Fit? {
        fit(samples, targets: samples.map(\.point), quadratic: false)
    }

    private static func fit(_ samples: [CalibrationSample], targets: [CGPoint], quadratic: Bool) -> Fit? {
        guard samples.count >= minSamples, targets.count == samples.count else { return nil }
        let xs = samples.map { vector($0.features) }
        let dims = xs[0].count
        let mean = (0..<dims).map { d in xs.map { $0[d] }.reduce(0, +) / Double(xs.count) }
        let inputs = xs.map { input($0, mean: mean, quadratic: quadratic) }
        // A click marks exactly where you looked; weigh it a bit more than one calibration frame.
        let weights = samples.map { $0.fromClick ? 3.0 : 1.0 }
        let lambdas = [0.0] + penalties + (quadratic ? Array(repeating: 3.0, count: quadraticPairs.count) : [])
        guard let wx = ridge(inputs, targets.map { Double($0.x) }, weights, lambdas),
              let wy = ridge(inputs, targets.map { Double($0.y) }, weights, lambdas) else { return nil }
        return Fit(mean: mean, wx: wx, wy: wy, quadratic: quadratic)
    }

    /// Leave-one-calibration-point-out RMS error in screen fractions: how well the fit generalises to
    /// places it has not been shown. Slightly pessimistic, since left-out corners must be extrapolated.
    private static func crossValidatedError(_ samples: [CalibrationSample]) -> (x: Double, y: Double)? {
        let calibration = samples.filter { !$0.fromClick }
        let clicks = samples.filter(\.fromClick)
        let groups = Dictionary(grouping: calibration.indices) { i -> String in
            let p = calibration[i].point
            return "\(Int((p.x * 1000).rounded())),\(Int((p.y * 1000).rounded()))"
        }
        guard groups.count >= 6 else { return nil }
        var squaredX = 0.0, squaredY = 0.0
        for indices in groups.values {
            let excluded = Set(indices)
            let training = calibration.indices.filter { !excluded.contains($0) }.map { calibration[$0] } + clicks
            guard let fit = fit(training) else { return nil }
            let predictions = indices.map { apply(fit, vector(calibration[$0].features)) }
            let n = CGFloat(predictions.count)
            let px = predictions.map(\.x).reduce(0, +) / n, py = predictions.map(\.y).reduce(0, +) / n
            let target = calibration[indices[0]].point
            squaredX += Double((px - target.x) * (px - target.x))
            squaredY += Double((py - target.y) * (py - target.y))
        }
        let n = Double(groups.count)
        return (sqrt(squaredX / n), sqrt(squaredY / n))
    }

    /// Weighted ridge: solves (XᵀWX + Λ) w = XᵀWy.
    private static func ridge(_ xs: [[Double]], _ ys: [Double], _ weights: [Double], _ lambdas: [Double]) -> [Double]? {
        guard let dims = xs.first?.count else { return nil }
        var a = Array(repeating: Array(repeating: 0.0, count: dims), count: dims)
        var b = Array(repeating: 0.0, count: dims)
        for ((x, y), w) in zip(zip(xs, ys), weights) {
            for i in 0..<dims {
                b[i] += w * x[i] * y
                for j in 0..<dims { a[i][j] += w * x[i] * x[j] }
            }
        }
        for i in 0..<dims { a[i][i] += lambdas[i] }
        return solve(a, b)
    }

    /// Gaussian elimination with partial pivoting.
    private static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        var a = matrix, b = vector
        let n = b.count
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }), abs(a[pivot][col]) > 1e-9 else { return nil }
            a.swapAt(col, pivot); b.swapAt(col, pivot)
            for row in (col + 1)..<n {
                let factor = a[row][col] / a[col][col]
                for k in col..<n { a[row][k] -= factor * a[col][k] }
                b[row] -= factor * b[col]
            }
        }
        var x = Array(repeating: 0.0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            let rest = ((row + 1)..<n).map { a[row][$0] * x[$0] }.reduce(0, +)
            x[row] = (b[row] - rest) / a[row][row]
        }
        return x
    }
}
