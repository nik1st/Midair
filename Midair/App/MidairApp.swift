import SwiftUI

@main
struct MidairApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Midair", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1060, height: 720)

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(systemName: model.isEnabled ? "hand.raised.fill" : "hand.raised")
        }
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Toggle("Gesture control (⌃⌥⌘G)", isOn: $model.isEnabled)
        Toggle("Mini window with hand position", isOn: $model.showsMiniView)
        Picker("Screen light", selection: $model.screenLightMode) {
            ForEach(ScreenLightMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        Toggle("Gesture log (⌃⌥⌘M false trigger, ⌃⌥⌘N miss)", isOn: $model.recordsGestures)
        Toggle("Shadow log while gestures are off", isOn: $model.recordsShadow)
        Picker("What you're doing", selection: $model.activity) {
            ForEach(GestureActivity.allCases, id: \.self) { activity in
                Text(activity.title).tag(activity)
            }
        }
        Button("Open Midair") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
