import AVFoundation
import CoreGraphics
import CoreMedia

struct TrackingSnapshot: Sendable {
    /// The hand in the leading camera's frame. A Desk View hand is already mapped to the main camera's axes.
    var hand: HandPose?
    var phase: GesturePhase = .noHand
    /// The ring at the cursor while the palm or the pinch builds up time.
    var cue = GestureCue.none
    /// The main camera's frame width divided by its height: 16:9 or 4:3 depending on the format.
    var frameAspect = 16.0 / 9.0
    /// "Two cameras" mode and which of the two drives the cursor right now.
    var isDual = false
    var leader = CameraSource.main
    var framesPerSecond: Double = 0
    /// From the moment the frame is captured to ready events, in seconds.
    var latency: Double?
    var isSuspended = false
    /// Smoothed brightness of the main camera's frame from 0 to 1, illuminance as estimated by the camera
    /// and whether it's dark now.
    var brightness: Double?
    var lux: Double?
    /// Auto exposure is at its limit: exposure time and gain are at maximum.
    var exposureLimited: Bool?
    var isDark = false
    /// How Vision finds the hand on dark frames with and without brightening, once there are enough frame pairs.
    var brightening: BrighteningComparison.Summary?

    static let idle = TrackingSnapshot()
}

/// Camera, hand recognition, gestures and event injection. All mutable state lives
/// on the serial queue `queue`; camera sessions are configured on `sessionQueue`.
final class TrackingPipeline: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    /// A second session for Desk View in "Two cameras" mode: there's no `AVCaptureMultiCamSession` on macOS,
    /// and two separate sessions on one sensor deliver 30 fps each (measured by `DualCameraProbe`).
    let deskSession = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "dev.nikita.midair.session")
    private let queue = DispatchQueue(label: "dev.nikita.midair.tracking", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private let deskOutput = AVCaptureVideoDataOutput()
    private let detector = HandPoseDetector()
    private let injector = InputInjector()
    /// Display ticks on which the cursor glides between camera frames.
    private let ticker: DisplayTicker
    private var engine = GestureEngine()
    private var isOutputEnabled = false
    private var suspendedUntil: Double = 0
    private var idleCursor: CGPoint?
    private var isDual = false
    private var leader = CameraLeader()
    /// Where the leading and the second hand are in each camera's frame.
    private var trackers: [CameraSource: HandTracker] = [:]
    private var mainAspect = 16.0 / 9.0
    private var lowLight = LowLightDetector()
    private var exposureLimited: Bool?
    private var comparison = BrighteningComparison()
    private var brightensDarkFrames = false
    private var darkFrames = 0
    private var recorder: GestureRecorder?
    /// Activity label for the log: typing, a call, a mug and so on.
    private var activity = "unspecified"
    /// Smoothed interval between the leading camera's frames: the cursor spreads a frame's move over this long.
    private var frameInterval: Double?
    private var lastFrameTime: Double?
    private var lastPublishTime: Double = 0
    /// The cursor glides between frames on display ticks instead of jumping once per frame.
    private var smoothsCursor = true
    /// The preview window is open: the person watches the hand skeleton and the brightening comparison,
    /// so Vision is needed on every frame.
    private var isPreviewVisible = false
    /// When Vision last saw a hand in any of the cameras.
    private var lastHandTime = -Double.infinity
    /// Whether the previous camera frame was skipped while the hand is gone for long: recognize every other frame.
    private var skippedLast: [CameraSource: Bool] = [:]
    private var onSnapshot: (@Sendable (TrackingSnapshot) -> Void)?

    override init() {
        ticker = DisplayTicker { [injector] now in injector.tick(now: now) }
        super.init()
        for output in [output, deskOutput] {
            output.videoSettings = Self.videoSettings(for: nil)
            output.alwaysDiscardsLateVideoFrames = true
            // Frames from both cameras go to one queue: the engine and the choice of the leading camera live there too.
            output.setSampleBufferDelegate(self, queue: queue)
        }
    }

    func setSnapshotHandler(_ handler: @escaping @Sendable (TrackingSnapshot) -> Void) {
        queue.async { self.onSnapshot = handler }
    }

    func start(cameraID: String?, tallFrame: Bool, completion: @escaping @Sendable (Result<CameraDevice, CameraError>) -> Void) {
        // A new camera or format has different hand coordinates: the old gesture state would make the cursor jump.
        queue.async {
            self.releaseEverything()
            self.leader = CameraLeader()
            self.trackers = [:]
            // Brightness and the brightening comparison belong to the previous camera.
            self.lowLight = LowLightDetector()
            self.comparison = BrighteningComparison()
            // Another camera may have a different frame rate: 30 for the built-in one, 60 for an iPhone.
            self.frameInterval = nil
            self.lastFrameTime = nil
        }
        sessionQueue.async {
            do {
                let (device, desk) = try self.configureSessions(cameraID: cameraID, tallFrame: tallFrame)
                self.queue.async { self.isDual = desk != nil }
                if !self.session.isRunning { self.session.startRunning() }
                if desk != nil, !self.deskSession.isRunning { self.deskSession.startRunning() }
                if desk == nil, self.deskSession.isRunning { self.deskSession.stopRunning() }
                // On macOS the session sets the format from its preset (1080p) on start and on commitConfiguration,
                // and there's no "as the client chose" preset here: pick the format and frame rate again after start.
                _ = try? CameraCatalog.selectFastFormat(for: device, tall: tallFrame)
                if let desk { _ = try? CameraCatalog.selectFastFormat(for: desk, tall: false) }
                completion(.success(desk != nil ? CameraCatalog.describeDual(device) : CameraCatalog.describe(device)))
            } catch let error as CameraError {
                completion(.failure(error))
            } catch {
                completion(.failure(.configurationFailed(error.localizedDescription)))
            }
        }
    }

    func stop() {
        sessionQueue.async {
            self.session.stopRunning()
            self.deskSession.stopRunning()
            CameraCatalog.restoreCenterStage()
        }
    }

    @MainActor func setOutputEnabled(_ enabled: Bool) {
        // Display ticks are needed only while gestures move the cursor.
        if enabled { ticker.start() } else { ticker.stop() }
        queue.async {
            self.isOutputEnabled = enabled
            self.releaseEverything()
        }
    }

    func setSmoothsCursor(_ enabled: Bool) {
        queue.async { self.smoothsCursor = enabled }
    }

    func setPreviewVisible(_ visible: Bool) {
        queue.async { self.isPreviewVisible = visible }
    }

    func update(config: GestureConfig) {
        queue.async {
            self.engine.config = config
            self.recorder?.config(config, time: Self.hostTime())
        }
    }

    /// Starts or stops the gesture log; `completion` gets the log file or `nil`.
    func setRecording(_ enabled: Bool, completion: @escaping @Sendable (URL?) -> Void) {
        queue.async {
            self.recorder?.close()
            self.recorder = nil
            if enabled, let recorder = try? GestureRecorder() {
                let time = Self.hostTime()
                recorder.config(self.engine.config, time: time)
                recorder.event("activity", time: time, label: self.activity)
                self.recorder = recorder
            }
            completion(self.recorder?.url)
        }
    }

    /// The person's mark in the log: `mark` means "a false trigger happened here", `miss` means "a gesture didn't work".
    func mark(_ kind: String) {
        queue.async { self.recorder?.event(kind, time: Self.hostTime()) }
    }

    /// What the person is doing right now: the replay uses these labels to count false triggers per activity.
    func setActivity(_ label: String) {
        queue.async {
            self.activity = label
            self.recorder?.event("activity", time: Self.hostTime(), label: label)
        }
    }

    func setDoubleClickInterval(_ interval: TimeInterval) {
        queue.async { self.injector.doubleClickInterval = interval }
    }

    func setBrightensDarkFrames(_ enabled: Bool) {
        queue.async { self.brightensDarkFrames = enabled }
    }

    /// Synchronously releases buttons and shuts down the cameras: called when the app quits.
    func shutdown() {
        queue.sync {
            isOutputEnabled = false
            releaseEverything()
            recorder?.close()
            recorder = nil
        }
        sessionQueue.sync {
            session.stopRunning()
            deskSession.stopRunning()
            CameraCatalog.restoreCenterStage()
        }
        ticker.stop()
    }

    private func configureSessions(cameraID: String?, tallFrame: Bool) throws -> (main: AVCaptureDevice, desk: AVCaptureDevice?) {
        guard let devices = CameraCatalog.devices(id: cameraID) else { throw CameraError.noDevice }
        CameraCatalog.disableCenterStage()
        try configure(session, output: output, device: devices.main, tallFrame: tallFrame)
        if let desk = devices.desk {
            try configure(deskSession, output: deskOutput, device: desk, tallFrame: false)
        }
        return devices
    }

    private func configure(_ session: AVCaptureSession, output: AVCaptureVideoDataOutput, device: AVCaptureDevice, tallFrame: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs {
            session.removeInput(input)
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.configurationFailed(String(localized: "Camera is busy or unavailable")) }
        session.addInput(input)
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { throw CameraError.configurationFailed(String(localized: "Couldn't get frames from the camera")) }
            session.addOutput(output)
        }
        let format = try CameraCatalog.selectFastFormat(for: device, tall: tallFrame)
        output.videoSettings = Self.videoSettings(for: format)
    }

    /// Frame for Vision: BGRA up to 1280 points wide in the camera format's proportions. Without a size the output
    /// delivers frames per the session preset, 1920x1080, i.e. it upscales the 720p format for nothing. Measured on M4 Pro:
    /// BGRA 720p costs Vision 2.7 ms of CPU per frame and 6.6 ms to the result (median), including converting the frame
    /// to BGRA, while 1080p in native 420v takes 4.3 ms and 11 ms.
    private static func videoSettings(for format: CMVideoDimensions?) -> [String: Any] {
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        guard let format, format.width > 0, format.height > 0 else { return settings }
        let width = min(Int(format.width), 1280)
        settings[kCVPixelBufferWidthKey as String] = width
        settings[kCVPixelBufferHeightKey as String] = Int((Double(width) * Double(format.height) / Double(format.width) / 2).rounded()) * 2
        return settings
    }

    private func releaseEverything() {
        engine.reset()
        injector.releaseAll()
        recorder?.event("reset", time: Self.hostTime())
    }

    private static func hostTime() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }
}

extension TrackingPipeline: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let source: CameraSource = output === deskOutput ? .desk : .main
        // Late desk frames after leaving "Two cameras" mode aren't needed.
        guard source == .main || isDual else { return }

        // The main camera decides on darkness: it looks at the person, and the palm faces it.
        let brightness = FrameLight.brightness(of: pixelBuffer)
        if source == .main {
            let report = FrameLight.cameraReport(of: sampleBuffer)
            exposureLimited = report.exposureLimited
            lowLight.update(brightness: brightness, lux: report.lux, time: time)
        }
        if source == leader.current { updateFrameInterval(time) }
        if skipsDetection(source: source, time: time) { return }
        let gamma = lowLight.isDark ? Brightening.gamma(forBrightness: brightness) : 1
        let detected = (try? detector.detect(in: pixelBuffer, gamma: brightensDarkFrames ? gamma : 1)) ?? []
        // Desk View shows the desk as the person sees it: mirror the hand so the axes match the front camera.
        let raw = source == .desk ? detected.map { $0.flippedHorizontally() } : detected
        // Low-confidence points are cut off here for the whole pipeline, while the log gets all of them, with confidences.
        let hands = raw.map(engine.config.visible)
        // A second hand in the frame: its fist turns on two-handed scrolling. When the leading hand vanishes for a frame
        // or two, the second one doesn't take its place until the engine decides the leading hand is gone.
        let (hand, other) = trackers[source, default: HandTracker()].assign(
            hands, preferred: engine.config.preferredHand, phase: engine.phase, time: time)
        if hand != nil || other != nil { lastHandTime = time }
        let rawHand = hand.flatMap { hands.firstIndex(of: $0) }.map { raw[$0] }
        let rawOther = other.flatMap { hands.firstIndex(of: $0) }.map { raw[$0] }
        if source == .main {
            mainAspect = Double(CVPixelBufferGetWidth(pixelBuffer)) / Double(max(CVPixelBufferGetHeight(pixelBuffer), 1))
        }

        // The leading camera changed: the engine continues from the hand in the new frame,
        // without a jump and without releasing the button.
        var actions: [PointerAction] = []
        if isDual, leader.update(source: source, hand: hand, time: time) {
            actions = engine.handOver(at: time)
            recorder?.event("handover", time: time, actions: actions)
        }
        // One camera drives the cursor; the other camera's frames only hint when to pass the hand over to it.
        guard source == leader.current else { return }
        // A second Vision pass for the brightening comparison is needed only while the comparison is visible in the window.
        if gamma < 1, isPreviewVisible { compareBrightening(pixelBuffer, gamma: gamma, used: detected) }
        if engine.isLowLight != lowLight.isDark { engine.isLowLight = lowLight.isDark }
        engine.isExposureLimited = exposureLimited ?? false

        // The pause for real input applies even without event output: the window shows what it would in operation,
        // and the shadow log marks the frames that would have been paused in operation.
        if userTouchedRealInput(now: time) {
            if time >= suspendedUntil { releaseEverything() }
            suspendedUntil = time + 1
        }
        let isSuspended = time < suspendedUntil
        var processed: [PointerAction]?
        if !isSuspended {
            // Without output the cursor isn't ours, and the working area isn't set from it.
            engine.cursor = isOutputEnabled ? injector.cursorContext() : nil
            let result = engine.process(hand: hand, other: other, time: time)
            processed = result
            if isOutputEnabled {
                actions += result
                // A frame's move is spread until the next frame, with a 4 ms margin for uneven frame arrival.
                // Without display ticks there's nothing to spread it over: the cursor moves at once, as before.
                injector.glideDuration = smoothsCursor && ticker.isRunning ? (frameInterval ?? 1.0 / 30) + 0.004 : 0
                for action in actions {
                    injector.perform(action, time: time)
                }
                if injector.isGliding { ticker.wake() }
            }
        }
        recorder?.frame(time: time, source: source, hand: rawHand, other: rawOther, dark: lowLight.isDark, brightness: lowLight.brightness,
                        lux: lowLight.lux, exposureLimited: exposureLimited, fed: processed != nil, out: isOutputEnabled,
                        suspended: isSuspended, phase: engine.phase, actions: processed ?? [],
                        notes: processed != nil ? engine.notes : [])

        publish(hand: hand, time: time, isSuspended: isSuspended)
    }

    /// The person reached for the keyboard, mouse or trackpad: gestures yield while they're in use, plus one more second.
    /// Hands above the keyboard often get into the frame; without this pause typing turns into random clicks.
    private func userTouchedRealInput(now: Double) -> Bool {
        let typing = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < 0.5
        let location = CGEvent(source: nil)?.location
        defer { idleCursor = location }
        if now < suspendedUntil, let location, let idleCursor {
            // During the pause we don't move the cursor, so any movement of it was made by the person.
            return typing || hypot(location.x - idleCursor.x, location.y - idleCursor.y) > 1
        }
        // Without output only the person moves the cursor: check the time of the last mouse event directly.
        guard isOutputEnabled else {
            return typing || CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved) < 0.5
        }
        return typing || injector.pointerMovedExternally()
    }

    /// While the preview window is closed, Vision isn't run where its answer decides nothing. During a keyboard
    /// and mouse pause gestures aren't accepted anyway, and typing takes up most of the day: a paused frame goes
    /// to the log without a hand, the engine doesn't get it anyway, and the replay skips such frames. When the hand
    /// has been gone for over two seconds, control is taken again with a half-second palm anyway, and recognizing
    /// every other frame is enough to find the hand; skipped frames don't go to the log,
    /// so the replay sees what the engine saw.
    private func skipsDetection(source: CameraSource, time: Double) -> Bool {
        guard !isPreviewVisible else { return false }
        if time < suspendedUntil {
            // Where the hands were before the pause doesn't apply to the hands after it.
            trackers[source] = nil
            guard source == leader.current else { return true }
            // The pause is extended while the person types or moves the mouse.
            if userTouchedRealInput(now: time) { suspendedUntil = time + 1 }
            recorder?.frame(time: time, source: source, hand: nil, other: nil, dark: lowLight.isDark, brightness: lowLight.brightness,
                            lux: lowLight.lux, exposureLimited: exposureLimited, fed: false, out: isOutputEnabled,
                            suspended: true, phase: engine.phase, actions: [], notes: [])
            publish(hand: nil, time: time, isSuspended: true)
            return true
        }
        guard engine.phase == .noHand, time - lastHandTime > 2 else {
            skippedLast[source] = false
            return false
        }
        let skip = !(skippedLast[source] ?? false)
        skippedLast[source] = skip
        return skip
    }

    /// Every third dark frame of the leading camera is recognized twice, the second time with the other variant:
    /// brightening is thus compared on the same frames, and the extra Vision pass costs about 2 ms per frame on average.
    private func compareBrightening(_ pixelBuffer: CVPixelBuffer, gamma: Double, used: [HandPose]) {
        darkFrames += 1
        guard darkFrames.isMultiple(of: 3) else { return }
        let other = (try? detector.detect(in: pixelBuffer, gamma: brightensDarkFrames ? 1 : gamma)) ?? []
        let (plain, brightened) = brightensDarkFrames ? (other, used) : (used, other)
        let config = engine.config
        comparison.record(plainJoints: plain.map { config.visible($0).visibleJointCount }.max() ?? 0,
                          brightenedJoints: brightened.map { config.visible($0).visibleJointCount }.max() ?? 0)
    }

    private func publish(hand: HandPose?, time: Double, isSuspended: Bool) {
        // No more than 30 times a second, but with tolerance: 30 fps frame timestamps jitter,
        // and a strict "not before 1/30 s" skipped some frames, so the UI updated in jerks at 15-20 fps.
        guard let onSnapshot, time - lastPublishTime >= 1.0 / 40 else { return }
        lastPublishTime = time
        let latency = CMClockGetTime(CMClockGetHostTimeClock()).seconds - time
        onSnapshot(TrackingSnapshot(
            hand: hand,
            phase: engine.phase,
            cue: engine.cue,
            frameAspect: mainAspect,
            isDual: isDual,
            leader: leader.current,
            framesPerSecond: frameInterval.map { 1 / $0 } ?? 0,
            latency: (0...1).contains(latency) ? latency : nil,
            isSuspended: isSuspended,
            brightness: lowLight.brightness,
            lux: lowLight.lux,
            exposureLimited: exposureLimited,
            isDark: lowLight.isDark,
            brightening: comparison.summary
        ))
    }

    /// Over all frames of the leading camera, including those Vision skipped.
    private func updateFrameInterval(_ time: Double) {
        defer { lastFrameTime = time }
        guard let lastFrameTime, time > lastFrameTime, time - lastFrameTime < 0.5 else { return }
        let interval = time - lastFrameTime
        frameInterval = frameInterval.map { $0 * 0.9 + interval * 0.1 } ?? interval
    }
}
