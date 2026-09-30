import AVFoundation
import Vision

/// One observation of where the user is facing.
struct GazeFeatures: Codable, Equatable {
    /// Head turn and tilt (radians, from Vision).
    var yaw: Double
    var pitch: Double
    /// Nose relative to the midpoint between the eyes, in the face's own frame (roll removed),
    /// in units of eye distance. A continuous, landmark-based head pose that complements Vision's angles.
    var noseX: Double
    var noseY: Double
    /// Iris offset from the midpoint of the eye corners, same frame and units as the nose. The corners are
    /// fixed to the skull, so unlike the eye outline they don't move when the lids follow a downward glance.
    var eyeX: Double
    var eyeY: Double
    /// Lid opening (outline height) in units of eye distance; the upper lid drops when you look down.
    var eyeOpen: Double
    /// Eye midpoint in the camera frame (0...1) and eye distance relative to frame width.
    /// They describe where you sit, not where you look.
    var faceX: Double
    var faceY: Double
    var faceSize: Double

    var vector: [Double] { [yaw, pitch, noseX, noseY, eyeX, eyeY, eyeOpen, faceX, faceY, faceSize] }

    func blended(with other: GazeFeatures, alpha: Double) -> GazeFeatures {
        GazeFeatures(vector: zip(vector, other.vector).map { $0 + ($1 - $0) * alpha })
    }

    /// Per-feature median; removes single-frame outliers from Vision.
    static func median(_ list: [GazeFeatures]) -> GazeFeatures {
        let vectors = list.map(\.vector)
        return GazeFeatures(vector: (0..<vectors[0].count).map { d in
            let sorted = vectors.map { $0[d] }.sorted()
            return sorted[sorted.count / 2]
        })
    }
}

extension GazeFeatures {
    init(vector v: [Double]) {
        self.init(yaw: v[0], pitch: v[1], noseX: v[2], noseY: v[3], eyeX: v[4], eyeY: v[5], eyeOpen: v[6],
                  faceX: v[7], faceY: v[8], faceSize: v[9])
    }
}

/// Captures camera frames (720p, max 15 fps) and turns them into `GazeFeatures` with Apple Vision.
/// Frames only ever live in memory.
final class HeadTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Called on the main queue for every analysed frame; `nil` when no face was found.
    var onSample: ((GazeFeatures?) -> Void)?
    var onError: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "focustracker.camera")
    private var configuredDeviceID: String?
    private var lastFrameTime: CFTimeInterval = 0
    private let maxFPS: Double = 15
    /// Typical lid opening (slow average) and the last eye values measured with open eyes; bridges blinks.
    private var openBaseline: Double?
    private var lastOpenEyes: (x: Double, y: Double, open: Double)?

    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3
        return r
    }()

    private let landmarksRequest: VNDetectFaceLandmarksRequest = {
        let r = VNDetectFaceLandmarksRequest()
        r.revision = VNDetectFaceLandmarksRequestRevision3
        r.constellation = .constellation76Points
        return r
    }()

    static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    static var cameraAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static func requestCameraAccess(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func start(deviceID: String) {
        queue.async { [weak self] in self?.startOnQueue(deviceID: deviceID) }
    }

    /// Rebuilds the capture input even if the same camera ID is selected (e.g. after it was unplugged and replugged).
    func restart(deviceID: String) {
        queue.async { [weak self] in
            self?.configuredDeviceID = nil
            self?.startOnQueue(deviceID: deviceID)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func startOnQueue(deviceID: String) {
        if configuredDeviceID != deviceID || session.inputs.isEmpty {
            guard configure(deviceID: deviceID) else { return }
        }
        if !session.isRunning { session.startRunning() }
    }

    private func configure(deviceID: String) -> Bool {
        let wasRunning = session.isRunning
        if wasRunning { session.stopRunning() }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach { session.removeInput($0) }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }

        let device = (deviceID.isEmpty ? nil : AVCaptureDevice(uniqueID: deviceID)) ?? AVCaptureDevice.default(for: .video)
        guard let device else {
            report("No camera found")
            return false
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                report("Camera \(device.localizedName) cannot be used")
                return false
            }
            session.addInput(input)
        } catch {
            report("Camera error: \(error.localizedDescription)")
            return false
        }

        if session.outputs.isEmpty {
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }

        configuredDeviceID = deviceID
        return true
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }

    // MARK: - Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= 1.0 / maxFPS else { return }
        lastFrameTime = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let features = analyze(pixelBuffer)
        DispatchQueue.main.async { [weak self] in self?.onSample?(features) }
    }

    private func analyze(_ pixelBuffer: CVPixelBuffer) -> GazeFeatures? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do { try handler.perform([faceRequest]) } catch { return nil }

        guard let face = faceRequest.results?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else { return nil }

        landmarksRequest.inputFaceObservations = [face]
        try? handler.perform([landmarksRequest])
        guard let detailed = landmarksRequest.results?.first, let landmarks = detailed.landmarks,
              let yaw = (face.yaw ?? detailed.yaw)?.doubleValue else { return nil }
        let pitch = (face.pitch ?? detailed.pitch)?.doubleValue ?? 0

        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard var f = Self.features(landmarks, imageSize: size, luma: Luma(pixelBuffer), yaw: yaw, pitch: pitch) else { return nil }
        bridgeBlink(&f)
        return f
    }

    /// While the lids are nearly shut the iris can't be seen: keep the last open-eye values instead.
    private func bridgeBlink(_ f: inout GazeFeatures) {
        let baseline = openBaseline ?? f.eyeOpen
        if f.eyeOpen < baseline * 0.45, let last = lastOpenEyes {
            (f.eyeX, f.eyeY, f.eyeOpen) = last
            return
        }
        openBaseline = baseline + (f.eyeOpen - baseline) * 0.02
        lastOpenEyes = (f.eyeX, f.eyeY, f.eyeOpen)
    }

    /// Luminance plane of the camera frame (full-range 4:2:0, plane 0), top-left origin. Valid while the buffer is locked.
    private struct Luma {
        let base: UnsafePointer<UInt8>
        let width: Int, height: Int, bytesPerRow: Int

        init?(_ buffer: CVPixelBuffer) {
            guard CVPixelBufferGetPlaneCount(buffer) > 0,
                  let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
            self.base = UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
            width = CVPixelBufferGetWidthOfPlane(buffer, 0)
            height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        }

        subscript(x: Int, y: Int) -> Double { Double(base[y * bytesPerRow + x]) }
    }

    /// Centre of the dark iris inside the eye outline (Vision image coordinates, bottom-left origin):
    /// darkness-weighted centroid of the darkest pixels. Much steadier than Vision's pupil landmark,
    /// which barely moves when only the eyes move.
    private static func irisCenter(_ outline: [CGPoint], luma: Luma) -> CGPoint? {
        let poly = outline.map { CGPoint(x: $0.x, y: CGFloat(luma.height) - $0.y) }
        let xs = poly.map(\.x), ys = poly.map(\.y)
        let minX = max(0, Int(xs.min()!)), maxX = min(luma.width - 1, Int(xs.max()!.rounded(.up)))
        let minY = max(0, Int(ys.min()!)), maxY = min(luma.height - 1, Int(ys.max()!.rounded(.up)))
        guard maxX - minX >= 6, maxY - minY >= 2 else { return nil }

        var pixels: [(x: Double, y: Double, v: Double)] = []
        for y in minY...maxY {
            for x in minX...maxX where contains(poly, CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                pixels.append((Double(x) + 0.5, Double(y) + 0.5, luma[x, y]))
            }
        }
        guard pixels.count >= 12 else { return nil }
        // The iris covers roughly a third of the visible eye; sclera and skin are brighter.
        let threshold = pixels.map(\.v).sorted()[pixels.count * 3 / 10]
        var sx = 0.0, sy = 0.0, sw = 0.0
        for p in pixels where p.v <= threshold {
            let w = threshold - p.v + 1
            sx += p.x * w; sy += p.y * w; sw += w
        }
        guard sw > 0 else { return nil }
        return CGPoint(x: sx / sw, y: Double(luma.height) - sy / sw)
    }

    /// Even-odd point-in-polygon test.
    private static func contains(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Landmark geometry in pixel coordinates (aspect-correct), rotated so the eye line is horizontal.
    private static func features(_ landmarks: VNFaceLandmarks2D, imageSize size: CGSize, luma: Luma?,
                                 yaw: Double, pitch: Double) -> GazeFeatures? {
        guard let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye, let nose = landmarks.nose,
              leftEye.pointCount > 2, rightEye.pointCount > 2, nose.pointCount > 2 else { return nil }

        func centroid(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
            let points = region.pointsInImage(imageSize: size)
            let n = CGFloat(points.count)
            return CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
        }

        let left = centroid(leftEye), right = centroid(rightEye)
        let mid = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        let eyeDistance = hypot(right.x - left.x, right.y - left.y)
        guard eyeDistance > 8 else { return nil }
        let angle = atan2(right.y - left.y, right.x - left.x)
        let c = cos(angle), s = sin(angle)

        /// Vector in the face frame, in units of eye distance.
        func inFace(_ dx: CGFloat, _ dy: CGFloat) -> (Double, Double) {
            (Double((dx * c + dy * s) / eyeDistance), Double((-dx * s + dy * c) / eyeDistance))
        }

        let noseCenter = centroid(nose)
        let noseOffset = inFace(noseCenter.x - mid.x, noseCenter.y - mid.y)

        var eyeOffsets: [(Double, Double)] = []
        var openings: [Double] = []
        for (eye, pupil) in [(leftEye, landmarks.leftPupil), (rightEye, landmarks.rightPupil)] {
            let outline = eye.pointsInImage(imageSize: size)
            let local = outline.map { inFace($0.x - mid.x, $0.y - mid.y) }
            guard let inner = local.indices.min(by: { local[$0].0 < local[$1].0 }),
                  let outer = local.indices.max(by: { local[$0].0 < local[$1].0 }) else { continue }
            openings.append(local.map(\.1).max()! - local.map(\.1).min()!)
            let corners = CGPoint(x: (outline[inner].x + outline[outer].x) / 2, y: (outline[inner].y + outline[outer].y) / 2)
            let iris = luma.flatMap { irisCenter(outline, luma: $0) }
                ?? pupil.flatMap { $0.pointCount > 0 ? $0.pointsInImage(imageSize: size)[0] : nil }
            guard let iris else { continue }
            eyeOffsets.append(inFace(iris.x - corners.x, iris.y - corners.y))
        }
        let n = Double(max(eyeOffsets.count, 1))

        return GazeFeatures(
            yaw: yaw, pitch: pitch,
            noseX: noseOffset.0, noseY: noseOffset.1,
            eyeX: eyeOffsets.map(\.0).reduce(0, +) / n, eyeY: eyeOffsets.map(\.1).reduce(0, +) / n,
            eyeOpen: openings.reduce(0, +) / Double(max(openings.count, 1)),
            faceX: Double(mid.x / size.width), faceY: Double(mid.y / size.height),
            faceSize: Double(eyeDistance / size.width))
    }
}

/// Live list of connected cameras; updates when a camera is plugged in or removed.
final class CameraList: ObservableObject {
    struct Camera: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @Published private(set) var cameras: [Camera] = []
    /// Called on the main queue after a camera was connected or disconnected.
    var onChange: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard (note.object as? AVCaptureDevice)?.hasMediaType(.video) ?? true else { return }
                self?.refresh()
                self?.onChange?()
            })
        }
    }

    func refresh() {
        cameras = HeadTracker.availableCameras().map { Camera(id: $0.uniqueID, name: $0.localizedName) }
    }
}
