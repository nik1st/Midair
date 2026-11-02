import AVFoundation

struct CameraDevice: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        /// `dual` is a camera together with its Desk View: the main camera follows a raised hand,
        /// Desk View a hand lowered onto the desk.
        case builtIn, deskView, continuity, external, dual
    }

    let id: String
    let name: String
    let kind: Kind

    /// Desk View looks down at the desk, so its frame doesn't need mirroring. Other cameras look at the person.
    var looksAtUser: Bool { kind != .deskView }
}

enum CameraError: Error, Sendable {
    case noDevice
    case configurationFailed(String)
}

enum CameraCatalog {
    /// Identifier prefix of the "Two cameras" mode, placed before the main camera's identifier.
    private static let dualPrefix = "dual:"

    static func available() -> [CameraDevice] {
        let devices = discovery.devices
        return devices.map(describe) + devices.filter { $0.companionDeskViewCamera != nil }.map(describeDual)
    }

    /// The main camera and, in "Two cameras" mode, its Desk View: both look through the same ultra-wide sensor.
    static func devices(id: String?) -> (main: AVCaptureDevice, desk: AVCaptureDevice?)? {
        guard let id, id.hasPrefix(dualPrefix) else { return device(id: id).map { ($0, nil) } }
        guard let main = device(id: String(id.dropFirst(dualPrefix.count))),
              let desk = main.companionDeskViewCamera else { return nil }
        return (main, desk)
    }

    static func describeDual(_ main: AVCaptureDevice) -> CameraDevice {
        CameraDevice(id: dualPrefix + main.uniqueID, name: main.localizedName, kind: .dual)
    }

    static func device(id: String?) -> AVCaptureDevice? {
        if let id, let device = AVCaptureDevice(uniqueID: id) {
            return device
        }
        return discovery.devices.first { $0.deviceType == .builtInWideAngleCamera } ?? discovery.devices.first
    }

    static func describe(_ device: AVCaptureDevice) -> CameraDevice {
        let kind: CameraDevice.Kind = switch device.deviceType {
        case .deskViewCamera: .deskView
        case .continuityCamera: .continuity
        case .external: .external
        default: .builtIn
        }
        return CameraDevice(id: device.uniqueID, name: device.localizedName, kind: kind)
    }

    /// Center Stage crops the image on the fly, and hand coordinates "drift" along with the frame.
    /// While Midair is running, we take over and turn it off.
    static func disableCenterStage() {
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
    }

    static func restoreCenterStage() {
        AVCaptureDevice.centerStageControlMode = .user
    }

    /// A format around 720p with the highest frame rate: that resolution is enough for Vision,
    /// and extra frames per second directly reduce cursor latency.
    ///
    /// With `tall`, a 4:3 frame is taken (1760x1328 on the built-in camera): if it's the same sensor, the frame
    /// is taller than 16:9 and the hand gets more room at the bottom. macOS doesn't expose a format's field of view,
    /// so it has to be checked by eye. If the camera can't do 4:3, the usual choice applies.
    ///
    /// Call it after `startRunning()` too: on macOS the session overrides the format with its preset on start.
    /// Returns the size of the selected format.
    @discardableResult
    static func selectFastFormat(for device: AVCaptureDevice, tall: Bool) throws -> CMVideoDimensions? {
        func dimensions(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        }
        func width(_ format: AVCaptureDevice.Format) -> Int32 {
            dimensions(format).width
        }
        func isFourByThree(_ format: AVCaptureDevice.Format) -> Bool {
            let size = dimensions(format)
            return abs(Double(size.width) / Double(max(size.height, 1)) - 4.0 / 3.0) < 0.05
        }
        func bestRange(_ format: AVCaptureDevice.Format) -> AVFrameRateRange? {
            format.videoSupportedFrameRateRanges.max { $0.maxFrameRate < $1.maxFrameRate }
        }

        var candidates = device.formats.filter { (640...1920).contains(width($0)) }
        if tall, candidates.contains(where: isFourByThree) {
            candidates = candidates.filter(isFourByThree)
        }
        guard let format = candidates.max(by: { lhs, rhs in
            let lhsRate = bestRange(lhs)?.maxFrameRate ?? 0
            let rhsRate = bestRange(rhs)?.maxFrameRate ?? 0
            if abs(lhsRate - rhsRate) > 1 { return lhsRate < rhsRate }
            return abs(width(lhs) - 1280) > abs(width(rhs) - 1280)
        }), let range = bestRange(format) else { return nil }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        lockFrameRate(of: device, to: range)
        return dimensions(format)
    }

    /// The format's maximum frame rate, and the camera doesn't lower it in the dark: a steady 30 fps
    /// matters more for the cursor than a brighter image.
    private static func lockFrameRate(of device: AVCaptureDevice, to range: AVFrameRateRange) {
        device.activeVideoMinFrameDuration = range.minFrameDuration
        device.activeVideoMaxFrameDuration = range.minFrameDuration
    }

    private static var discovery: AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .deskViewCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
    }
}
