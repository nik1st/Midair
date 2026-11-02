import AVFoundation
import ImageIO
import Synchronization

/// "Center Stage for the hand" spike: does macOS give the app the main camera and its Desk View at the same time.
/// There's no `AVCaptureMultiCamSession` on macOS, so there are two sessions, one per camera.
///
/// Launch: `open Midair.app --args -dualCameraProbe <report file>`. The gesture camera doesn't start then;
/// after the measurement (about 20 s) the report is written to the file and the app quits.
final class DualCameraProbe: @unchecked Sendable {
    private let events = Mutex<[String]>([])
    private let startTime = DualCameraProbe.now()

    func run() async -> String {
        var lines = ["Midair: two cameras at once, \(Date().formatted(date: .numeric, time: .standard))"]
        guard let mainDevice = CameraCatalog.device(id: nil) else { return "Main camera not found" }
        let companion = mainDevice.companionDeskViewCamera
        let deskDevice = companion ?? AVCaptureDevice.DiscoverySession(
            deviceTypes: [.deskViewCamera], mediaType: .video, position: .unspecified
        ).devices.first
        lines.append("Main: \(Self.describe(mainDevice))")
        guard let deskDevice else {
            lines.append("Desk View not found")
            return lines.joined(separator: "\n")
        }
        lines.append("Desk View: \(Self.describe(deskDevice)), found \(companion != nil ? "via companionDeskViewCamera" : "by device type search")")

        // As in normal operation: Center Stage is off, the format and frame rate are the same as in TrackingPipeline.
        CameraCatalog.disableCenterStage()
        lines.append("Center Stage: enabled \(AVCaptureDevice.isCenterStageEnabled), control mode \(AVCaptureDevice.centerStageControlMode.rawValue)")
        // The same key as the "Taller frame (4:3)" setting: it can be overridden with a launch argument.
        let tall = UserDefaults.standard.bool(forKey: "prefersTallFrame")
        lines.append("Taller frame (4:3): \(tall ? "yes" : "no")")
        let main = ProbeStream(name: "main", device: mainDevice, tall: tall)
        let desk = ProbeStream(name: "Desk View", device: deskDevice, tall: false)
        let observers = [main, desk].flatMap(observe)

        do {
            try main.configure()
            await main.startRunning()
            lines.append("Main format after start: \(Self.format(of: mainDevice))")
            let mainStart = Self.now()
            try? await Task.sleep(for: .seconds(4.5))
            lines.append("1. Main only, 4 s: \(main.stats(from: mainStart + 0.5, to: Self.now()))")
            lines.append("   main frame: \(main.frameMetadata)")

            try desk.configure()
            await desk.startRunning()
            lines.append("Formats after Desk View start: main \(Self.format(of: mainDevice)), Desk View \(Self.format(of: deskDevice))")
            let bothStart = Self.now()
            try? await Task.sleep(for: .seconds(11))
            let bothEnd = Self.now()
            lines.append("2. Both cameras, 10 s:")
            lines.append("   main: \(main.stats(from: bothStart + 1, to: bothEnd))")
            lines.append("   Desk View: \(desk.stats(from: bothStart + 1, to: bothEnd))")
            lines.append("   Desk View frame: \(desk.frameMetadata)")

            await desk.stopRunning()
            let soloStart = Self.now()
            try? await Task.sleep(for: .seconds(3.5))
            lines.append("3. Main only again, 3 s: \(main.stats(from: soloStart + 0.5, to: Self.now()))")
        } catch {
            lines.append("Configuration error: \(error)")
        }
        await desk.stopRunning()
        await main.stopRunning()
        observers.forEach(NotificationCenter.default.removeObserver)
        CameraCatalog.restoreCenterStage()

        lines.append("Dropped frames (didDrop): main \(main.droppedFrames), Desk View \(desk.droppedFrames)")
        let log = events.withLock { $0 }
        lines.append(log.isEmpty ? "No session events" : "Session events:\n" + log.joined(separator: "\n"))
        return lines.joined(separator: "\n")
    }

    /// Errors, interruptions, start and stop of each session, plus camera disconnection.
    private func observe(_ stream: ProbeStream) -> [NSObjectProtocol] {
        let sessionEvents: [Notification.Name] = [
            AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification,
            AVCaptureSession.interruptionEndedNotification, AVCaptureSession.didStartRunningNotification,
            AVCaptureSession.didStopRunningNotification,
        ]
        var tokens = sessionEvents.map { name in
            NotificationCenter.default.addObserver(forName: name, object: stream.session, queue: nil) { [weak self] note in
                let details = note.userInfo.map { " \($0)" } ?? ""
                self?.record("\(stream.name): \(name.rawValue)\(details)")
            }
        }
        tokens.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                                                             object: stream.device, queue: nil) { [weak self] _ in
            self?.record("\(stream.name): camera disconnected")
        })
        return tokens
    }

    private func record(_ message: String) {
        let line = String(format: "  %6.2f s  ", Self.now() - startTime) + message
        events.withLock { $0.append(line) }
    }

    private static func describe(_ device: AVCaptureDevice) -> String {
        let formats = device.formats.map { format -> String in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let rate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return "\(size.width)x\(size.height)@\(Int(rate))"
        }
        return "\(device.localizedName) (\(device.deviceType.rawValue)), formats \(formats.joined(separator: " "))"
    }

    private static func format(of device: AVCaptureDevice) -> String {
        let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let rate = 1 / device.activeVideoMinFrameDuration.seconds
        return "\(size.width)x\(size.height) up to \(Int(rate.rounded())) fps"
    }

    fileprivate static func now() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }
}

/// A camera session that only counts frames: no Vision, so the measurement is about the camera, not the load.
private final class ProbeStream: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Frame {
        let time: Double
        let width: Int
        let height: Int
    }

    let name: String
    let device: AVCaptureDevice
    let session = AVCaptureSession()
    private let tall: Bool
    private let output = AVCaptureVideoDataOutput()
    private let queue: DispatchQueue
    private let frames = Mutex<[Frame]>([])
    private let dropped = Mutex(0)
    private let metadata = Mutex<String?>(nil)

    var droppedFrames: Int { dropped.withLock { $0 } }
    /// What the camera puts into a frame besides the image: from the frame 2 s after start, once exposure has settled.
    var frameMetadata: String { metadata.withLock { $0 } ?? "no frames" }

    init(name: String, device: AVCaptureDevice, tall: Bool) {
        self.name = name
        self.device = device
        self.tall = tall
        queue = DispatchQueue(label: "dev.nikita.midair.probe.\(device.deviceType.rawValue)", qos: .userInteractive)
        super.init()
    }

    func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.configurationFailed("\(name): can't add input") }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraError.configurationFailed("\(name): can't add output") }
        session.addOutput(output)
        try CameraCatalog.selectFastFormat(for: device, tall: tall)
    }

    func startRunning() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.session.startRunning()
                // As in TrackingPipeline: pick the format again after start.
                _ = try? CameraCatalog.selectFastFormat(for: self.device, tall: self.tall)
                continuation.resume()
            }
        }
    }

    func stopRunning() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if self.session.isRunning { self.session.stopRunning() }
                continuation.resume()
            }
        }
    }

    /// Fps, frame count, longest gap between frames and frame sizes over a time window.
    func stats(from start: Double, to end: Double) -> String {
        let window = frames.withLock { $0.filter { $0.time >= start && $0.time <= end } }
        guard let first = window.first, let last = window.last, window.count > 1 else {
            return "no frames (\(window.count))"
        }
        let fps = Double(window.count - 1) / (last.time - first.time)
        let longestGap = zip(window, window.dropFirst()).map { $1.time - $0.time }.max() ?? 0
        let sizes = Set(window.map { "\($0.width)x\($0.height)" }).sorted().joined(separator: ", ")
        return String(format: "%.1f fps, %d frames, longest gap %.0f ms, frames ", fps, window.count, longestGap * 1000) + sizes
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frame = Frame(time: DualCameraProbe.now(), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let count = frames.withLock { frames -> Int in
            frames.append(frame)
            return frames.count
        }
        if count == 60 {
            let info = Self.describeMetadata(of: sampleBuffer, pixelBuffer: buffer)
            metadata.withLock { $0 = info }
        }
    }

    /// Whether the frame carries exposure time, ISO and scene brightness: they would reveal darkness
    /// more precisely than the frame itself.
    private static func describeMetadata(of sampleBuffer: CMSampleBuffer, pixelBuffer: CVPixelBuffer) -> String {
        let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: sampleBuffer,
                                                        attachmentMode: kCMAttachmentMode_ShouldPropagate) as? [String: Any] ?? [:]
        let exif = attachments[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let fields = ["ExposureTime", "ISOSpeedRatings", "BrightnessValue", "ExposureBiasValue"]
        let exifText = exif.map { exif in
            fields.map { field in
                let value = exif[field].map { String(describing: $0).split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                return "\(field) \(value ?? "none")"
            }.joined(separator: ", ")
        } ?? "none"
        // The keys of these attachments are undocumented: this is the only way to see what's in them.
        let isp = (attachments["MetadataDictionary"] as? [String: Any]).map { dict in
            dict.keys.sorted().compactMap { key in (dict[key] as? NSNumber).map { "\(key)=\($0)" } }.joined(separator: " ")
        } ?? "none"
        let night = attachments["NightModeEnabled"].map { "\($0)" } ?? "none"
        return String(format: "brightness %.2f; EXIF: ", FrameLight.brightness(of: pixelBuffer)) + exifText
            + "; NightModeEnabled: \(night); MetadataDictionary: \(isp)"
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dropped.withLock { $0 += 1 }
    }
}
