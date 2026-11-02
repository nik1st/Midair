import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PreviewPanel()
                GestureLegend()
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(minWidth: 560, maxWidth: .infinity)

            Divider()

            SettingsPanel()
                .frame(width: 360)
        }
        .frame(minWidth: 940, minHeight: 660)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EnableToggle()
            }
        }
        .onAppear { model.isWindowVisible = true }
        .onDisappear { model.isWindowVisible = false }
    }
}

private struct EnableToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Toggle(model.isEnabled ? "Gestures on" : "Gestures off", isOn: $model.isEnabled)
            .toggleStyle(.switch)
            .help("⌃⌥⌘G turns gestures on and off from any app")
    }
}

private struct PreviewPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.cameraAuthorized {
                CameraPreview(session: model.pipeline.session, mirrored: model.config.invertX, generation: model.previewGeneration)
                LiveSkeleton(source: .main, mirrored: model.config.invertX)
                StatusBadge(status: model.status, isEnabled: model.isEnabled)
                    .padding(10)
                if model.status.isDual {
                    DeskPreview()
                }
            } else {
                ContentUnavailableView {
                    Label("No Camera Access", systemImage: "video.slash")
                } description: {
                    Text("Frames are processed only on this Mac and never leave it.")
                } actions: {
                    Button("Allow Access") {
                        Task { await model.requestCamera() }
                    }
                }
            }
        }
        .aspectRatio(model.status.frameAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Hand skeleton over the `source` camera image while that camera leads the hand. The hand changes with every snapshot,
/// and a separate view redraws only the skeleton with it, not the window.
private struct LiveSkeleton: View {
    @Environment(AppModel.self) private var model
    let source: CameraSource
    let mirrored: Bool

    var body: some View {
        let status = model.status
        let leads = status.isDual ? status.leader == source : source == .main
        SkeletonOverlay(hand: leads ? model.liveHand : nil, phase: status.phase, mirrored: mirrored)
    }
}

/// Desk View image in the preview corner in "Two cameras" mode. A green border means the desk drives the cursor now.
private struct DeskPreview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let leads = model.status.leader == .desk
        ZStack {
            CameraPreview(session: model.pipeline.deskSession, mirrored: false, generation: model.previewGeneration)
            // The desk hand is mapped to the main camera's axes: mirror it back for the Desk View image.
            LiveSkeleton(source: .desk, mirrored: true)
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .frame(width: 200)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(leads ? .green : .white.opacity(0.5), lineWidth: leads ? 3 : 1))
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

private struct StatusBadge: View {
    let status: TrackingStatus
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.phase.symbol)
                .foregroundStyle(status.phase.tint)
            Text(status.isSuspended ? "Paused: you're using the keyboard or mouse" : status.phase.title)
            Text("\(status.framesPerSecond) fps")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if let latency = status.latency {
                Text("\(latency) ms")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if status.isDual {
                Text(status.leader == .desk ? "desk leads" : "face camera leads")
                    .foregroundStyle(.secondary)
            }
            if status.isDark {
                Text("dark")
                    .foregroundStyle(.secondary)
            }
            if !isEnabled {
                Text("view only")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}

private struct GestureLegend: View {
    private struct Item: Identifiable {
        let symbol: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        var id: String { symbol }
    }

    private let items = [
        Item(symbol: "hand.raised", title: "Palm still for half a second", detail: "takes control: until then the cursor stays put and pinches are ignored"),
        Item(symbol: "cursorarrow", title: "Open palm", detail: "moves the cursor, like a finger on a trackpad"),
        Item(symbol: "pause.fill", title: "Fist", detail: "“lift the mouse”: the cursor stays put and you can reposition your hand"),
        Item(symbol: "hand.raised.slash", title: "Hand out of frame", detail: "also “mouse lifted”; a drag waits a second for the pinching hand, after 1.5 s you need to take control again"),
        Item(symbol: "cursorarrow.click", title: "Pinch and release", detail: "click; thumb with index or middle finger, either works; twice for a double-click"),
        Item(symbol: "arrow.up.and.down.and.arrow.left.and.right", title: "Pinch and move", detail: "drag; the button goes down once the hand moves a couple of centimeters, opening the fingers releases it"),
        Item(symbol: "contextualmenu.and.cursorarrow", title: "Thumb to pinky", detail: "right-click; you can also hold a regular pinch for a second and a half until the ring is full"),
        Item(symbol: "arrow.up.and.down.circle", title: "Fist with the other hand", detail: "scrolling: while that fist is held, the first hand scrolls: the palm moves the page, a fist repositions the hand. Open the other hand to get the cursor back"),
        Item(symbol: "arrow.up.and.down", title: "Two fingers", detail: "one-handed scrolling, if enabled below: index and middle fingers straight, the others bent, the page follows the hand. Bend those two fingers to reposition the hand, open your palm to finish"),
        Item(symbol: "keyboard", title: "Keyboard, mouse, trackpad", detail: "gestures pause on their own while you use them, then take control with your palm again"),
        Item(symbol: "command", title: "⌃⌥⌘G", detail: "turn gestures on or off from any app"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(items) { item in
                GridRow {
                    Image(systemName: item.symbol)
                        .frame(width: 22)
                        .foregroundStyle(.secondary)
                    Text(item.title)
                        .fontWeight(.medium)
                    Text(item.detail)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }
}

private struct SettingsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Permissions") {
                PermissionRow(title: "Camera", granted: model.cameraAuthorized) {
                    Task { await model.requestCamera() }
                }
                PermissionRow(title: "Accessibility", granted: model.accessibilityTrusted) {
                    model.requestAccessibility()
                    model.openAccessibilitySettings()
                }
            }

            Section("Camera") {
                Picker("Source", selection: $model.cameraSelection) {
                    ForEach(model.cameras) { camera in
                        Text(camera.title).tag(Optional(camera.id))
                    }
                }
                Toggle("Taller frame (4:3)", isOn: $model.prefersTallFrame)
                    .help("4:3 instead of 16:9: if the camera delivers it from the same sensor, the hand gets more room at the bottom")
                if let error = model.cameraError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            Section("Low Light") {
                LightRow()
                Picker("Screen light", selection: $model.screenLightMode) {
                    ForEach(ScreenLightMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .help("Bright strips along the screen edges light up your hand while gestures are on. “In the Dark”: they turn on when the frame gets dark and stay on until gestures are turned off")
                Slider(value: $model.screenLightStrength, in: 0...1) { Text("Light strength") }
                    .disabled(model.screenLightMode == .off)
                LabeledContent("Edge Light") {
                    HStack {
                        Text(model.isEdgeLightEnabled ? "Enabled" : "Disabled")
                        Button("Video Effects…") { model.showVideoEffects() }
                    }
                }
                .help("Screen lighting from macOS. It can only be turned on in the system Video Effects menu while the Midair camera is running")
                Toggle("Brighten dark frames for recognition", isOn: $model.brightensDarkFrames)
                BrighteningVerdict()
            }

            Section("Cursor") {
                Picker("Mode", selection: $model.config.mapping) {
                    Text("Like a trackpad").tag(GestureConfig.Mapping.relative)
                    Text("Frame area to the whole screen").tag(GestureConfig.Mapping.absolute)
                }
                Picker("Hand", selection: $model.config.preferredHand) {
                    Text("Any").tag(Chirality?.none)
                    Text("Right").tag(Chirality?.some(.right))
                    Text("Left").tag(Chirality?.some(.left))
                }
                Slider(value: $model.config.speed, in: 0.4...2.5) { Text("Speed") }
                Slider(value: $model.smoothing, in: 0...1) { Text("Smoothing") }
                Toggle("Smooth motion between camera frames", isOn: $model.smoothsCursor)
                    .help("The cursor moves in step with the display instead of jumping 30 times a second. The cost: with a 30 fps camera it lags behind the hand by about 20 ms more")
                Toggle("Flip horizontally", isOn: $model.config.invertX)
                Toggle("Flip vertically", isOn: $model.config.invertY)
                Toggle("Gesture badge next to the cursor", isOn: $model.showsCursorIndicator)
                Toggle("Mini window with hand position", isOn: $model.showsMiniView)
            }

            Section("Gestures") {
                Toggle("Take control with an open palm", isOn: $model.config.requiresEngagement)
                    .help("Hands that enter the frame by accident (a mug, a phone, a conversation) do nothing until the palm holds still for half a second")
                Slider(value: $model.pinchSensitivity, in: 0...1) { Text("Pinch sensitivity") }
                Slider(value: $model.config.scrollGain, in: 800...5000) { Text("Scroll speed") }
                Toggle("Natural scrolling", isOn: $model.config.naturalScroll)
                Toggle("Two-finger scrolling with one hand", isOn: $model.config.oneHandScroll)
                    .help("For when the other hand isn't in the frame. Off by default because a hand opening a pinch looks like this pose and starts scrolling by itself")
            }

            Section("Log") {
                Toggle("Record a log while gestures are on", isOn: $model.recordsGestures)
                Toggle("Shadow log while gestures are off", isOn: $model.recordsShadow)
                    .help("The camera watches and the engine recognizes gestures, but nothing gets pressed. Every gesture in this log is a false one: it's used to count false triggers per hour")
                Picker("What you're doing", selection: $model.activity) {
                    ForEach(GestureActivity.allCases, id: \.self) { activity in
                        Text(activity.title).tag(activity)
                    }
                }
                if let url = model.recordingURL {
                    LabeledContent("File") {
                        Button(url.lastPathComponent) { model.revealRecording() }
                            .buttonStyle(.link)
                    }
                    Text("Right after a false trigger press ⌃⌥⌘M, and if a gesture didn't work, ⌃⌥⌘N: a mark appears in the log and you hear a sound")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Reset Settings") { model.resetSettings() }
            }
        }
        .formStyle(.grouped)
    }
}

/// Light in the frame. A separate view and a rounded `lightStatus` instead of the snapshot: the snapshot changes 30 times a second,
/// and the settings form with all its sliders would redraw on every frame.
private struct LightRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LabeledContent("Light in frame") {
            Text(Self.description(model.lightStatus))
        }
        .help("Average frame brightness and illuminance as estimated by the camera itself")
    }

    private static func description(_ light: LightStatus) -> String {
        guard let brightness = light.brightness else { return String(localized: "no frames") }
        var parts = ["\(brightness)%"]
        if let lux = light.lux { parts.append(String(localized: "about \(lux) lx")) }
        if light.exposureLimited { parts.append(String(localized: "exposure at its limit")) }
        if light.isDark { parts.append(String(localized: "dark")) }
        return parts.joined(separator: ", ")
    }
}

/// Result of comparing brightening on the same dark frames, once there are enough frame pairs.
private struct BrighteningVerdict: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let comparison = model.lightStatus.comparison {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dark frames compared: \(comparison.frames). The hand was found in \(comparison.plainFound)% of them without brightening and in \(comparison.brightenedFound)% with it; joints visible: \(comparison.plainJoints) and \(comparison.brightenedJoints) of 21.")
                Text(Self.verdict(comparison, isOn: model.brightensDarkFrames))
                    .fontWeight(.medium)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private static func verdict(_ comparison: LightStatus.Comparison, isOn: Bool) -> LocalizedStringKey {
        let found = comparison.brightenedFound - comparison.plainFound
        let joints = comparison.brightenedJoints - comparison.plainJoints
        if found > 5 || joints > 1 { return isOn ? "Brightening helps" : "Brightening helps: worth turning it on" }
        if found < -5 || joints < -1 { return isOn ? "Brightening hurts: better turn it off" : "Brightening hurts" }
        return "Almost no difference"
    }
}

private struct PermissionRow: View {
    let title: LocalizedStringKey
    let granted: Bool
    let request: () -> Void

    var body: some View {
        LabeledContent(title) {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Allow", action: request)
            }
        }
    }
}

private extension CameraDevice {
    var title: String {
        switch kind {
        case .deskView: String(localized: "\(name) (desk view)")
        case .continuity: "\(name) (iPhone)"
        case .dual: String(localized: "Two cameras: \(name) and desk view")
        case .builtIn, .external: name
        }
    }
}
