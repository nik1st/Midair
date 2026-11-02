import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import Observation
import Synchronization

@MainActor
@Observable
final class AppModel {
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled, !accessibilityTrusted { requestAccessibility() }
            pipeline.setOutputEnabled(isEnabled)
            if !isEnabled { cursorHUD.hide() }
            refreshCamera()
            updateRecording()
        }
    }

    var config: GestureConfig {
        didSet {
            guard config != oldValue else { return }
            pipeline.update(config: config)
            Self.save(config)
        }
    }

    var selectedCameraID: String? {
        didSet {
            guard selectedCameraID != oldValue else { return }
            UserDefaults.standard.set(selectedCameraID, forKey: Keys.camera)
            if let camera = cameras.first(where: { $0.id == selectedCameraID }) {
                config.invertX = camera.looksAtUser
                config.invertY = false
            }
            restartCamera()
        }
    }

    var showsCursorIndicator = true {
        didSet { if !showsCursorIndicator { cursorHUD.hide() } }
    }

    var showsMiniView = UserDefaults.standard.object(forKey: Keys.miniView) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showsMiniView, forKey: Keys.miniView)
            updateMiniView()
        }
    }

    /// A 4:3 frame instead of 16:9: being taller, it lets the hand slip past the bottom edge less often. A hypothesis, checked on the preview.
    var prefersTallFrame = UserDefaults.standard.bool(forKey: Keys.tallFrame) {
        didSet {
            guard prefersTallFrame != oldValue else { return }
            UserDefaults.standard.set(prefersTallFrame, forKey: Keys.tallFrame)
            restartCamera()
        }
    }

    /// Lighting the hand with the screen: off, on its own in the dark, or always while gestures are on.
    var screenLightMode = ScreenLightMode(rawValue: UserDefaults.standard.string(forKey: Keys.screenLight) ?? "") ?? .dark {
        didSet {
            UserDefaults.standard.set(screenLightMode.rawValue, forKey: Keys.screenLight)
            updateScreenLight()
        }
    }

    /// Light strength: 0 means regular white, 1 means the brightest white the screen can show beyond regular.
    var screenLightStrength = UserDefaults.standard.object(forKey: Keys.screenLightStrength) as? Double ?? 0.4 {
        didSet {
            UserDefaults.standard.set(screenLightStrength, forKey: Keys.screenLightStrength)
            updateScreenLight()
        }
    }

    /// Brighten dark frames before Vision. Whether it helps shows in the comparison in settings: in the dark it always runs.
    var brightensDarkFrames = UserDefaults.standard.bool(forKey: Keys.brightening) {
        didSet {
            UserDefaults.standard.set(brightensDarkFrames, forKey: Keys.brightening)
            pipeline.setBrightensDarkFrames(brightensDarkFrames)
        }
    }

    /// The cursor glides between camera frames in step with the display instead of jumping 30 times a second. The cost of smoothness:
    /// with a 30 fps camera the cursor lags behind the hand by about 20 ms more.
    var smoothsCursor = UserDefaults.standard.object(forKey: Keys.smoothCursor) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(smoothsCursor, forKey: Keys.smoothCursor)
            pipeline.setSmoothsCursor(smoothsCursor)
        }
    }

    /// Gesture log in ~/Library/Logs/Midair: hand poses, engine decisions and ⌃⌥⌘M false trigger marks.
    /// Off by default because it records the user's hand. Once turned on, it records by itself while gestures are on,
    /// one file per activation.
    var recordsGestures = UserDefaults.standard.bool(forKey: Keys.recording) {
        didSet {
            UserDefaults.standard.set(recordsGestures, forKey: Keys.recording)
            updateRecording()
        }
    }

    /// Shadow log: while gestures are off, the camera watches and the engine recognizes, but nothing reaches the system.
    /// Every event in such a log is false, so there's no need to gesture: it's used to count false triggers per hour.
    var recordsShadow = UserDefaults.standard.bool(forKey: Keys.shadow) {
        didSet {
            UserDefaults.standard.set(recordsShadow, forKey: Keys.shadow)
            refreshCamera()
            updateRecording()
        }
    }

    /// What the person is doing right now: the label goes into the log, and the replay counts false triggers per activity.
    var activity = GestureActivity(rawValue: UserDefaults.standard.string(forKey: Keys.activity) ?? "") ?? .unspecified {
        didSet {
            UserDefaults.standard.set(activity.rawValue, forKey: Keys.activity)
            pipeline.setActivity(activity.rawValue)
        }
    }

    /// The log file being written right now.
    private(set) var recordingURL: URL?

    /// Edge Light is turned on in Control Center: the app can only find out whether it's on.
    private(set) var isEdgeLightEnabled = AppModel.edgeLightEnabled()

    /// The last hand seen: the mini window uses it to show where the hand went.
    private(set) var lastSeenHand: HandPose?

    var isWindowVisible = false {
        didSet {
            pipeline.setPreviewVisible(isWindowVisible)
            refreshCamera()
        }
    }

    private(set) var cameras: [CameraDevice] = []
    private(set) var activeCamera: CameraDevice?
    private(set) var cameraError: String?
    /// Window and mini window captions: they change only when what's visible changes.
    private(set) var status = TrackingStatus()
    /// The hand in the leading camera's frame. Only the skeletons read it: they're what redraws with every snapshot.
    private(set) var liveHand: HandPose?
    /// The pipeline's latest snapshot. Views don't read it: the snapshot changes 30 times a second, and any view
    /// that looked into it would redraw entirely on every frame.
    @ObservationIgnored private var snapshot = TrackingSnapshot.idle
    @ObservationIgnored private var statsTime = ContinuousClock.now
    /// Light in the frame for settings: unlike the snapshot, it changes rarely.
    private(set) var lightStatus = LightStatus()
    private(set) var cameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    private(set) var accessibilityTrusted = AppModel.canPostEvents()
    /// Grows on every camera start so that the preview sets mirroring again.
    private(set) var previewGeneration = 0

    @ObservationIgnored let pipeline = TrackingPipeline()
    @ObservationIgnored private let cursorHUD = CursorHUD()
    @ObservationIgnored private var miniView: MiniViewPanel?
    @ObservationIgnored private let screenLight = ScreenLight()
    /// In "In the Dark" mode the light, once on, stays on until gestures are turned off: it brightens the frame itself,
    /// and the darkness detector would keep switching it off and on.
    @ObservationIgnored private var screenLightLatched = false
    @ObservationIgnored private var edgeLightCheck = ContinuousClock.now
    @ObservationIgnored private var terminationSource: DispatchSourceSignal?
    @ObservationIgnored private var hotKey: HotKey?
    @ObservationIgnored private var markHotKey: HotKey?
    @ObservationIgnored private var missHotKey: HotKey?
    @ObservationIgnored private var isRecording = false
    @ObservationIgnored private var isCameraRunning = false
    @ObservationIgnored private var permissionPolling: Task<Void, Never>?
    @ObservationIgnored private var probe: DualCameraProbe?

    init() {
        config = Self.loadConfig()
        selectedCameraID = UserDefaults.standard.string(forKey: Keys.camera)

        pipeline.update(config: config)
        pipeline.setDoubleClickInterval(NSEvent.doubleClickInterval)
        pipeline.setBrightensDarkFrames(brightensDarkFrames)
        pipeline.setSmoothsCursor(smoothsCursor)
        pipeline.setActivity(activity.rawValue)
        let mailbox = SnapshotMailbox()
        pipeline.setSnapshotHandler { [weak self] snapshot in
            // The main thread may not keep up with 30 snapshots a second: old ones don't pile up in a queue, take the latest.
            guard mailbox.post(snapshot) else { return }
            Task { @MainActor [weak self] in
                guard let snapshot = mailbox.take() else { return }
                self?.apply(snapshot)
            }
        }

        hotKey = HotKey(keyCode: kVK_ANSI_G, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.isEnabled.toggle()
        }
        markHotKey = HotKey(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.markFalseTrigger()
        }
        missHotKey = HotKey(keyCode: kVK_ANSI_N, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.markMissedGesture()
        }

        let pipeline = pipeline
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            pipeline.shutdown()
        }
        // pkill and logging out send SIGTERM: terminate gracefully to release buttons and restore Center Stage.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        termination.resume()
        terminationSource = termination

        reloadCameras()
        if !accessibilityTrusted { startPermissionPolling() }
        if let reportPath = UserDefaults.standard.string(forKey: "dualCameraProbe") {
            runDualCameraProbe(reportPath: reportPath)
        }
    }

    /// A "false trigger here" mark in the log, with a sound so you can hear it was placed.
    /// Without recording there's nowhere to put the mark: then the sound is different.
    func markFalseTrigger() {
        guard isRecording else {
            NSSound(named: "Basso")?.play()
            return
        }
        pipeline.mark("mark")
        NSSound(named: "Tink")?.play()
    }

    /// A "gesture didn't work" mark: the replay uses it to count misses in series of intentional gestures.
    func markMissedGesture() {
        guard isRecording else {
            NSSound(named: "Basso")?.play()
            return
        }
        pipeline.mark("miss")
        NSSound(named: "Pop")?.play()
    }

    /// The log is written while gestures are on, and with the shadow log also while they're off. Switching modes keeps
    /// the file: frames in the log are marked with whether actions went to the system.
    private func updateRecording() {
        let active = isEnabled ? recordsGestures : recordsShadow && isCameraRunning
        guard active != isRecording else { return }
        isRecording = active
        pipeline.setRecording(active) { [weak self] url in
            Task { @MainActor [weak self] in self?.recordingURL = url }
        }
    }

    func revealRecording() {
        guard let recordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([recordingURL])
    }

    /// A dual-camera spike instead of normal operation: the gesture camera doesn't start, and the app quits after the measurement.
    private func runDualCameraProbe(reportPath: String) {
        let probe = DualCameraProbe()
        self.probe = probe
        Task {
            let report = await probe.run()
            try? report.write(toFile: reportPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    // MARK: - Permissions

    func requestCamera() async {
        cameraAuthorized = await AVCaptureDevice.requestAccess(for: .video)
        reloadCameras()
        refreshCamera()
    }

    /// Synthetic mouse events only need PostEvent access: it grants fewer rights than full
    /// Accessibility access, even though System Settings shows it in the same list.
    func requestAccessibility() {
        accessibilityTrusted = CGRequestPostEventAccess() || AXIsProcessTrusted()
        startPermissionPolling()
    }

    private static func canPostEvents() -> Bool {
        CGPreflightPostEventAccess() || AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The system Video Effects menu: Edge Light is turned on there while the Midair camera is running.
    func showVideoEffects() {
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }

    func resetSettings() {
        let invertX = config.invertX
        config = GestureConfig()
        config.invertX = invertX
    }

    /// Accessibility permission is granted in System Settings, and there's no notification about it.
    private func startPermissionPolling() {
        permissionPolling?.cancel()
        permissionPolling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let trusted = Self.canPostEvents()
                if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
                if trusted { return }
            }
        }
    }

    // MARK: - Camera

    func reloadCameras() {
        guard cameraAuthorized else { return }
        cameras = CameraCatalog.available()
    }

    /// The camera runs only while the window is open, gestures are on or the shadow log is recording:
    /// the green indicator doesn't light up for nothing.
    private func refreshCamera() {
        // The spike opens the cameras itself: the regular gesture camera would get in its way.
        guard probe == nil else { return }
        defer { updateRecording() }
        let shouldRun = cameraAuthorized && (isEnabled || isWindowVisible || recordsShadow)
        if shouldRun, !isCameraRunning {
            startCamera()
        } else if !shouldRun, isCameraRunning {
            isCameraRunning = false
            pipeline.stop()
            snapshot = .idle
            status = TrackingStatus()
            liveHand = nil
            lightStatus = LightStatus()
            lastSeenHand = nil
            cursorHUD.hide()
        }
        updateMiniView()
        updateScreenLight()
    }

    /// The mini window is needed while gestures are on: the main window is usually hidden then.
    private func updateMiniView() {
        let visible = showsMiniView && isEnabled && isCameraRunning
        if visible, miniView == nil {
            miniView = MiniViewPanel(model: self)
        }
        miniView?.setVisible(visible)
    }

    /// The hand needs the light only while gestures are on and the camera sees it.
    private func updateScreenLight() {
        let active = isEnabled && isCameraRunning
        if !active {
            screenLightLatched = false
        } else if snapshot.isDark {
            screenLightLatched = true
        }
        let visible: Bool = switch screenLightMode {
        case .off: false
        case .dark: active && screenLightLatched
        case .always: active
        }
        screenLight.update(visible: visible, strength: screenLightStrength)
    }

    private func restartCamera() {
        if isCameraRunning {
            startCamera()
        } else {
            refreshCamera()
        }
    }

    private func startCamera() {
        isCameraRunning = true
        pipeline.start(cameraID: selectedCameraID, tallFrame: prefersTallFrame) { [weak self] result in
            Task { @MainActor [weak self] in self?.cameraDidStart(result) }
        }
    }

    private func cameraDidStart(_ result: Result<CameraDevice, CameraError>) {
        switch result {
        case let .success(camera):
            activeCamera = camera
            cameraError = nil
            previewGeneration += 1
            // The hand position from the previous frame doesn't apply to a new camera or format.
            lastSeenHand = nil
        case let .failure(error):
            isCameraRunning = false
            activeCamera = nil
            updateMiniView()
            updateScreenLight()
            cameraError = switch error {
            case .noDevice: String(localized: "Camera not found")
            case let .configurationFailed(message): message
            }
        }
    }

    private func apply(_ snapshot: TrackingSnapshot) {
        guard isCameraRunning else { return }
        self.snapshot = snapshot
        let light = LightStatus(snapshot)
        if light != lightStatus { lightStatus = light }
        if snapshot.hand != liveHand { liveHand = snapshot.hand }
        if let hand = snapshot.hand { lastSeenHand = hand }
        updateStatus(with: snapshot)
        if isEnabled, showsCursorIndicator, !snapshot.isSuspended {
            let edge = HandHint.edge(for: snapshot, lastSeen: lastSeenHand)
            cursorHUD.show(phase: snapshot.phase, cue: snapshot.cue, edge: edge?.displayed(mirrored: config.invertX))
        } else {
            cursorHUD.hide()
        }
        updateScreenLight()
        // There are no notifications about Edge Light in Control Center: check once a second while frames are coming.
        let now = ContinuousClock.now
        if now - edgeLightCheck > .seconds(1) {
            edgeLightCheck = now
            let enabled = Self.edgeLightEnabled()
            if enabled != isEdgeLightEnabled { isEdgeLightEnabled = enabled }
        }
    }

    /// Frame rate and latency in captions update twice a second: they jitter from frame to frame,
    /// and a caption changing 30 times a second would drag window redraws along with it.
    private func updateStatus(with snapshot: TrackingSnapshot) {
        var status = status
        status.phase = snapshot.phase
        status.isSuspended = snapshot.isSuspended
        status.isDual = snapshot.isDual
        status.leader = snapshot.leader
        status.isDark = snapshot.isDark
        status.frameAspect = snapshot.frameAspect
        status.handAspect = (snapshot.hand ?? lastSeenHand)?.aspect ?? snapshot.frameAspect
        status.hint = HandHint.text(for: snapshot, lastSeen: lastSeenHand, mirrored: config.invertX)
        let now = ContinuousClock.now
        if now - statsTime >= .milliseconds(500) || status.framesPerSecond == 0 {
            statsTime = now
            status.framesPerSecond = Int(snapshot.framesPerSecond.rounded())
            status.latency = snapshot.latency.map { Int(($0 * 1000).rounded()) }
        }
        if status != self.status { self.status = status }
    }

    /// Edge Light appeared in macOS 26.2, while the app also runs on 26.0.
    private static func edgeLightEnabled() -> Bool {
        guard #available(macOS 26.2, *) else { return false }
        return AVCaptureDevice.isEdgeLightEnabled
    }

    // MARK: - Saving settings

    private enum Keys {
        static let config = "gestureConfig"
        static let camera = "cameraID"
        static let miniView = "showsMiniView"
        static let tallFrame = "prefersTallFrame"
        static let screenLight = "screenLightMode"
        static let screenLightStrength = "screenLightStrength"
        static let brightening = "brightensDarkFrames"
        static let smoothCursor = "smoothsCursor"
        static let recording = "recordsGestures"
        static let shadow = "recordsShadow"
        static let activity = "gestureActivity"
    }

    private static func loadConfig() -> GestureConfig {
        guard let data = UserDefaults.standard.data(forKey: Keys.config),
              let config = try? JSONDecoder().decode(GestureConfig.self, from: data) else { return GestureConfig() }
        return config
    }

    private static func save(_ config: GestureConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Keys.config)
    }
}

// MARK: - Convenient bindings for settings

extension AppModel {
    var cameraSelection: String? {
        get { selectedCameraID ?? activeCamera?.id }
        set { selectedCameraID = newValue }
    }

    /// 0 means light smoothing (3 Hz cutoff), 1 means strong smoothing (0.3 Hz).
    var smoothing: Double {
        get { log10(3 / config.minCutoff) }
        set { config.minCutoff = 3 * pow(0.1, newValue) }
    }

    /// The higher the sensitivity, the wider the gap between the fingers at which a pinch already counts.
    /// The release threshold stays 1.63 times above the press threshold: a ratio under 1.6 causes chatter.
    var pinchSensitivity: Double {
        get { (config.pinchEnter - 0.2) / 0.2 }
        set {
            config.pinchEnter = 0.2 + 0.2 * newValue
            config.pinchExit = config.pinchEnter * 1.63
        }
    }
}

/// What the window and mini window captions show. Unlike the snapshot, it changes rarely: numbers are rounded,
/// the hint is already assembled into a string.
struct TrackingStatus: Equatable {
    var phase = GesturePhase.noHand
    var isSuspended = false
    var isDual = false
    var leader = CameraSource.main
    var isDark = false
    /// Frame proportions of the main camera and of the camera currently leading the hand.
    var frameAspect = 16.0 / 9.0
    var handAspect = 16.0 / 9.0
    var framesPerSecond = 0
    /// From frame capture to ready events, in milliseconds.
    var latency: Int?
    var hint = ""
}

/// Light in the frame for settings, rounded. Changes rarely: the settings form doesn't redraw on every frame.
struct LightStatus: Equatable {
    struct Comparison: Equatable {
        var frames: Int
        /// Share of frames with a hand found, in percent, and how many joints are visible, without brightening and with it.
        var plainFound: Int
        var brightenedFound: Int
        var plainJoints: Int
        var brightenedJoints: Int
    }

    var brightness: Int?
    var lux: Int?
    var exposureLimited = false
    var isDark = false
    var comparison: Comparison?

    init() {}

    init(_ snapshot: TrackingSnapshot) {
        brightness = snapshot.brightness.map { Int(($0 * 100).rounded()) }
        // The illuminance estimate is noisy by a few lux: round to five so the line doesn't jitter.
        lux = snapshot.lux.map { Int(($0 / 5).rounded()) * 5 }
        exposureLimited = snapshot.exposureLimited ?? false
        isDark = snapshot.isDark
        comparison = snapshot.brightening.map { summary in
            Comparison(frames: summary.frames / 10 * 10,
                       plainFound: Int((summary.plainFound * 100).rounded()),
                       brightenedFound: Int((summary.brightenedFound * 100).rounded()),
                       plainJoints: Int(summary.plainJoints.rounded()),
                       brightenedJoints: Int(summary.brightenedJoints.rounded()))
        }
    }
}

/// A one-snapshot mailbox between the pipeline queue and the main thread.
private final class SnapshotMailbox: Sendable {
    private let slot = Mutex<TrackingSnapshot?>(nil)

    /// Puts the snapshot in place of the previous one. `true` if the mailbox was empty, meaning nobody is going to take a snapshot yet.
    func post(_ snapshot: TrackingSnapshot) -> Bool {
        slot.withLock { slot in
            defer { slot = snapshot }
            return slot == nil
        }
    }

    func take() -> TrackingSnapshot? {
        slot.withLock { slot in
            defer { slot = nil }
            return slot
        }
    }
}

/// What the person is doing while the log is recording. False triggers concentrate in a few activities,
/// so look for the guilty activity rather than moving the global threshold.
enum GestureActivity: String, CaseIterable, Sendable {
    case unspecified, gestures, typing, mouse, reading, call, phone, mug, writing, stretching, provocations

    var title: LocalizedStringResource {
        switch self {
        case .unspecified: "Not specified"
        case .gestures: "Intentional gestures"
        case .typing: "Typing"
        case .mouse: "Mouse or trackpad"
        case .reading: "Reading"
        case .call: "Call with gesturing"
        case .phone: "Phone in hand"
        case .mug: "Mug"
        case .writing: "Writing with a pen"
        case .stretching: "Stretching"
        case .provocations: "Provocations: waving, tapping, making a fist"
        }
    }
}
