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
    /// Pupil offset from the eye centre, same frame and units as the nose.
    var eyeX: Double
    var eyeY: Double
    /// Eye midpoint in the camera frame (0...1) and eye distance relative to frame width.
    /// They describe where you sit, not where you look.
    var faceX: Double
    var faceY: Double
    var faceSize: Double

    var vector: [Double] { [yaw, pitch, noseX, noseY, eyeX, eyeY, faceX, faceY, faceSize] }

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
        self.init(yaw: v[0], pitch: v[1], noseX: v[2], noseY: v[3], eyeX: v[4], eyeY: v[5],
                  faceX: v[6], faceY: v[7], faceSize: v[8])
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
        return Self.features(landmarks, imageSize: size, yaw: yaw, pitch: pitch)
    }

    /// Landmark geometry in pixel coordinates (aspect-correct), rotated so the eye line is horizontal.
    private static func features(_ landmarks: VNFaceLandmarks2D, imageSize size: CGSize, yaw: Double, pitch: Double) -> GazeFeatures? {
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

        var pupilOffsets: [(Double, Double)] = []
        for (eye, pupil) in [(leftEye, landmarks.leftPupil), (rightEye, landmarks.rightPupil)] {
            guard let pupil, pupil.pointCount > 0 else { continue }
            let eyeCenter = centroid(eye)
            let p = pupil.pointsInImage(imageSize: size)[0]
            pupilOffsets.append(inFace(p.x - eyeCenter.x, p.y - eyeCenter.y))
        }
        let n = Double(max(pupilOffsets.count, 1))

        return GazeFeatures(
            yaw: yaw, pitch: pitch,
            noseX: noseOffset.0, noseY: noseOffset.1,
            eyeX: pupilOffsets.map(\.0).reduce(0, +) / n, eyeY: pupilOffsets.map(\.1).reduce(0, +) / n,
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
