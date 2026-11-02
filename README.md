# Midair

A macOS prototype that moves the cursor, clicks and scrolls with hand gestures in front of the MacBook camera.
Everything runs locally with Apple Vision; camera frames never leave the Mac.

## What it does (v0.1)

| Gesture | Action |
|---|---|
| Palm held still for half a second | takes control: until then the cursor stays put and pinches are ignored. Hands that enter the frame by accident (a mug, a phone, talking) do nothing |
| Open palm | moves the cursor like a finger on a trackpad: slow is precise, fast goes far. The cursor is on a leash to the working area: the palm's place in it roughly matches the cursor's place on the screen, so the whole screen is reachable without taking the hand out of the frame. A palm at the edge of the frame means a cursor at the edge of the screen |
| Fist | "lift the mouse": the cursor stays put and you can reposition the hand |
| Hand out of frame | also "mouse lifted": the cursor stays put. If you lower your hand, the cursor goes back to where the hand started to drop; a returning hand picks the cursor up smoothly. After 1.5 s without a hand you need to take control again |
| Pinch and release | click on release; thumb with the index or middle finger, either works; twice for a double click |
| Pinch and move | drag: the button goes down once the pinching hand moves about 3% of the frame, and goes up when the fingers open |
| Dragging, hand left the frame | the button is held for up to a second: bring the hand back pinched and keep dragging, an open hand releases |
| Thumb to pinky | right click, as soon as the fingers touch; you can also hold a regular pinch still for 1.5 s until the orange ring at the cursor is full |
| Fist with one hand, the other open | two-handed scrolling: while the fist is closed, the open hand scrolls like fingers on a trackpad. Either hand can make the fist, including the one that moved the cursor. The open palm moves the page, a fist "lifts" the hand so you can reposition it. The scrolling hand may slip out of the frame: the mode holds while the fist is visible. Opening the fist gives the cursor back to the hand that had it before scrolling. Hands are told apart by their place in the frame: if Vision loses one for a frame, the other doesn't take over its role |
| Two fingers | one-handed scrolling, off by default (turn it on in Settings, "Gestures" section): a hand opening from a pinch looks like this pose, and in live testing it turned on by itself right after a pinch three times out of five. Like on a trackpad: index and middle fingers straight (together or apart), ring finger and pinky bent, and the page follows the hand. Bend those two fingers and they are lifted off the trackpad: you can reposition the hand, and after a fast stroke the page keeps coasting. An open palm ends scrolling |
| Keyboard, mouse, trackpad | gestures pause while you use them and for another second; then you take control with the palm again |
| Dark | the screen lights up the hand, gestures get more careful, the mini window says "dark" (more below) |
| ⌃⌥⌘G | turn gestures on or off from any app |

While gestures are on, a mini window sits in the corner of the screen: a diagram of the frame with the hand skeleton, a highlight on the edge the hand has approached, and a hint where it went if it disappeared. If the hand leaves in the middle of a drag, the mini window reminds you that the button is still held and the hand has to come back pinched. You don't have to watch it: when the hand is at the edge of the frame or a gesture waits for it to return, an orange arrow next to the gesture icon at the cursor shows where to bring the hand back.

The image source is picked in the window: the built-in camera, Desk View (a top-down view of the desk), an iPhone via Continuity Camera, or "Two cameras" at once (more below).

## How it differs from the typical demo

Most viral projects are built the same way: Python, MediaPipe, `pyautogui`, the cursor tied to the index fingertip. Hence the jitter, missed clicks and stuck buttons. Midair does it differently:

- **The cursor follows the knuckles, not the fingertip.** The anchor is the center of the wrist and knuckles: it barely moves during a pinch, so a click doesn't slide off its target.
- **No event reaches the system until the gesture is clear.** A pinch is decided by hand travel and timing, not by which finger touched the thumb: a 2D camera can't tell that reliably (the index and middle fingertips sit 0.22-0.24 palm sizes apart). Releasing produces the whole click at the point where the pinch started. The drag button goes down only after the pinching hand has traveled 0.45 palm sizes: a clicking hand moves ten times less, so a click no longer turns into a drag. A pinch started while the hand is moving is almost always false: if the hand travels more than 0.3 palm sizes in the first 0.45 s, the pinch is silently canceled.
- **Right click with a separate finger.** Thumb to pinky: in a regular pinch the pinky is never closer than 0.34 palm sizes to the thumb, so there is nothing to confuse it with. When the thumb reaches for the pinky, the hand folds and the index finger ends up close too (0.27-0.29 versus 0.12-0.15 for the pinky), so the pinch is tied to whichever finger is closer to the thumb. The click fires as soon as the touch is confirmed: the pressed pinky is hidden behind the thumb, Vision gives its tip a confidence of 0.15-0.3 (the threshold for it is lowered to 0.15) and then loses it, so waiting for the release would lose the click. A bent pinky doesn't count, so a fist and the scrolling pose don't produce right clicks. Fallback: a still pinch held for 1.5 s (slow clicks in live testing lasted up to 0.9 s).
- **Pinch with hysteresis and confirmation.** The press threshold is 0.32 palm sizes, release is 0.52 (in live testing a regular pinch held a gap of 0.26-0.31). A pinch must hold in three frames out of four (a 0.11 s window, counted in time rather than frames, so it's the same at 60 fps from an iPhone), release in two out of three. In the dark, and when camera exposure is at its limit, the window is one frame longer. The palm size is the average of its length and 1.4 times its width, a median over five frames: this halves its jitter.
- **A gate on pinch start.** A pinch doesn't start on a fast hand (over 4 palm sizes per second, 3 when exposure is at its limit: motion blur merges the fingertips) or on a finger pointing at the camera or curled into a fist (shorter than 0.4 palm sizes in projection). After any gesture, a fist, or the hand entering the frame, a new pinch waits until the fingers separate. A "palm edge-on to the camera" check was dropped after live testing: in a regular pinch the palm's length-to-width ratio reaches 2.8, and the check rejected 40% of pinches.
- **The button doesn't stick.** Before a drag the button simply isn't pressed. If the fingertips aren't visible for 0.3 s, the pinch is silently canceled, and during a drag the button is released after 0.5 s.
- **A fist without bouncing.** The fist is decided by a frame vote over the fingers that are visible: entering takes four frames out of five, leaving three out of four. On a recorded session the old layout switched between cursor and fist 13 times during a 0.9 s fist, and the cursor drifted 102 pt; the new one switches once, and the cursor stays put.
- **The palm takes control.** A hand that enters the frame in motion doesn't touch the cursor: it takes an open palm held still for half a second, with a ring at the cursor. After a pause for the keyboard, or no hand for more than 1.5 s, you take control again. This can be turned off in Settings.
- **Scrolling with a dedicated pose.** By default scrolling is turned on by a fist of the second hand; the one-handed pose is enabled in Settings. "Two fingers" turn scrolling on after 0.2 s on a slow hand, so scrolling no longer gets confused with clicks and drags. The pose works like a trackpad, and like the cursor with the fist: straight index and middle fingers "touch", and the page follows the palm with acceleration; bent, they are "lifted", the hand can be brought back, and after a fast stroke the page coasts. The pose is entered by a strict check and holds while the ring finger and pinky stay bent: once either straightens, the palm is opening and scrolling ends right away. Three earlier schemes failed in live testing. Scrolling that followed the palm without "lifting" didn't scroll, because people moved their fingers instead. A joystick driven by the fingertips couldn't scroll up: in the pose the fingers are already extended and can't go above the reference point. A page that followed the fingertips slid back with every finger return and every palm opening, and flicks didn't fix that: people flick down and up equally fast.
- **The 1€ filter instead of a moving average.** Jitter is damped on slow movements, and on fast ones the lag barely grows.
- **Trackpad mode with acceleration.** Small wrist movements cover the whole screen; there's no need to sweep the hand across the whole frame.
- **A working area instead of a drifting hand.** With a pure trackpad the hand drifts toward the edge of the frame over time: fast strokes carry the cursor further than slow ones bring it back. In live testing the hand left the frame sideways, up and down. Now the cursor is on a leash: it follows the hand with the same acceleration but never strays more than a quarter of the screen from where the working area puts the hand. The area is placed where the cursor started following the hand again (control taken, hand returned, a fist or scroll ended), sized to the hand travel for the full screen, and entirely within the part of the frame where the whole hand is visible. The leash ignores the jitter of a still hand, so the cursor doesn't creep on its own.
- **Leaving and returning without jerks.** A hand out of frame works like a lifted mouse. The downward motion of lowering the hand is rolled back (the last 0.2 s, trackpad mode only). After the hand returns, the cursor stays put while the hand is still moving into the frame (faster than 3 S/s, where S is the palm size), for at least 0.12 s and at most 0.8 s, and then picks up speed smoothly over 0.15 s. Before, the cursor stopped for exactly 0.12 s, while according to the logs an entering hand keeps moving at 8-29 S/s for another 0.15-0.8 s, and the cursor followed it backward. A pinch in the first 0.15 s doesn't count: an entering hand isn't fully visible. In two-handed scrolling a returning scrolling hand is likewise "lifted" first: the page coasts and doesn't scroll back, and the hand's anchor is rebuilt from its joints, like the cursor's, without jumping to the center of the hand. A scrolling hand that shows only a few points without the base of the palm (at the edge of the frame) counts as gone: otherwise the flickering points reset the departure timer, and a hand entering from above scrolled the page back. It counts as settled only after being slower than 3 S/s for at least 0.06 s in a row: an entering hand slows down for a frame and keeps going. An anchor jump of more than 0.15 frame heights in one frame counts as a different hand or a Vision glitch: the cursor doesn't repeat it and picks the hand up again. A hand dropout shorter than 0.1 s on motion blur triggers none of this.
- **Scrolling like a trackpad.** Pixel events with phases and momentum, the second axis locked. The axis is decided over the first 0.01 frame heights of travel: vertical unless the travel is clearly sideways. A touch that starts within a second after the scrolling hand returns takes the axis of the previous stroke: entering the frame, the hand often moves sideways. A touch that went sideways switches to vertical when, over the last 0.3 s, the hand has moved at least 0.03 frame heights vertically and twice as much as sideways: jitter at the start used to lock the axis sideways for the whole touch (in one session, 6 s sideways while the hand went up and down). There's no switch back: vertical scrolling is needed more often.
- **Center Stage is turned off while Midair runs.** Otherwise auto-framing shifts the picture and the cursor "floats" by itself.
- **It yields to real input.** While you type or touch the trackpad, gestures are paused: hands over the keyboard don't turn into random clicks.
- **Feedback.** The hand skeleton in the window and a gesture icon at the cursor with a ring: blue while the palm is taking control, orange while a held pinch builds up to a right click.
- **Native and lean.** Swift 6, Vision, one serial queue per frame; the camera is on only while the window is open or gestures are on.
- **The gesture logic is covered by tests.** `Core/` doesn't depend on AppKit, AVFoundation or Vision.

## Requirements

- macOS 26 or later.
- Xcode with the macOS 26 SDK (the project is set up with Xcode 27.1).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.44.1 or later: the Xcode project is generated from `project.yml` and isn't stored in the repository.

## Building

After cloning:

```bash
brew install xcodegen
xcodegen generate
open Midair.xcodeproj
```

Then Run in Xcode. On first launch macOS asks for camera access. Turning gestures on also needs Accessibility: System Settings > Privacy & Security > Accessibility > Midair. Without it, mouse events silently never reach the system.

### Signing

A fresh clone builds with ad-hoc signing ("Sign to Run Locally"), no Apple developer account needed. The catch: with ad-hoc signing macOS resets the Accessibility permission after every rebuild. To keep it, sign with your Apple Development certificate:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Then set your `DEVELOPMENT_TEAM` in `Config/Local.xcconfig`. The file is ignored by git.

### Tests

Gesture logic tests:

```bash
xcodebuild -project Midair.xcodeproj -scheme Midair -destination 'platform=macOS,arch=arm64' test
```

One test replays a real gesture log from `MidairTests/Fixtures/`. The log records a real hand and isn't in the repository, so in a fresh clone that test is skipped.

## Privacy

- Camera frames stay on the Mac: they're processed with Apple Vision and aren't saved or sent anywhere. The app has no network code.
- Gesture logs are off by default. Once you turn one on (menu bar or window, "Log" section), Midair writes hand joint coordinates and the engine's decisions to `~/Library/Logs/Midair`, no camera frames (see [Gesture log](#gesture-log)).

## Cameras (measured on a MacBook Pro M4, October 31, 2026)

| Device | AVFoundation type | Formats | Max fps |
|---|---|---|---|
| MacBook Pro Camera | `builtInWideAngleCamera`, with Center Stage | 640x480, 1280x720, 1920x1080; 4:3 1760x1328; square 1552x1552; portrait 1328x1760 and 1080x1920 | 30 |
| MacBook Pro Desk View Camera | `deskViewCamera` | 1920x1440 | 30 |
| iPhone 11 / iPhone 17 | `continuityCamera` | 640x480 ... 1920x1440 | 60 |
| iPhone 11 / iPhone 17 Desk View | `deskViewCamera` | 1920x1440 | 30 |

The built-in camera is limited to 30 fps, so waiting for a frame alone adds up to 33 ms of latency. An iPhone via Continuity Camera gives 60 fps.

The "Taller frame (4:3)" setting takes 1760x1328 instead of 1280x720. This is a hypothesis: if 4:3 is shot from the same sensor, the frame is taller and the hand has more room at the bottom. It can only be checked by eye in the preview: macOS doesn't expose a format's field of view (`videoFieldOfView` is unavailable), and the camera can't be zoomed out programmatically (`videoZoomFactor` is unavailable too).

The format is selected again after `startRunning()`: on macOS the session sets the format from its preset (1080p) on start, and `AVCaptureSessionPresetInputPriority` isn't available here. Without this, 4:3 didn't apply. Without a size in `videoSettings` the output delivered 1920x1080 frames per the preset even though `activeFormat` was already 1280x720, upscaling 720p for nothing. Now the output asks for BGRA up to 1280 wide in the format's proportions (checked in the debugger: 1280x720, `BGRA`). Measured on an M4 Pro: Vision on such a frame costs 2.7 ms of CPU and 6.6 ms to the result (median, including the conversion to BGRA), versus 4.3 ms and 11 ms on 1080p in native 420v.

## Two cameras: the hand on the desk (experimental)

The MacBook Pro M4 has one ultra-wide sensor, and macOS exposes it as two cameras: the main one (face and a raised hand) and Desk View (the desk from above, where a lowered hand ends up). With the "Two cameras" source Midair captures both at once and hands the hand over between them: lower your hand to the desk, and the cursor keeps going without a jerk and without releasing the button. No calibration between the cameras is needed, since the cursor is relative.

- **Whether it works at all** was checked by the `DualCameraProbe` probe: two separate `AVCaptureSession`s (macOS has no `AVCaptureMultiCamSession`) deliver 30.0 fps each at the same time, with no dropped frames, interruptions or errors, and the main camera doesn't slow down. To repeat it: `open Midair.app --args -dualCameraProbe /tmp/probe.txt`, and add `-prefersTallFrame YES` for the 4:3 frame. The gesture camera doesn't start in this mode; after about 20 s the report is written to the given file, and the app quits by itself.
- **The camera that sees the hand more confidently, and not at the edge, leads**: the other camera has to see the hand noticeably better for three frames in a row (`CameraLeader`), otherwise the lead would jump back and forth while both see the hand.
- **Handover**: the engine continues from the hand's new position (`GestureEngine.handOver`), the cursor stays put for 0.12 s and picks up speed smoothly, a drag isn't released, and the lowering motion from `hover` is rolled back.
- **The desk axes come from the Desk View geometry**: the picture shows the desk as the person sees it, hands enter from the bottom. Moving the hand right goes right and away from you means up, so desk hand coordinates are mirrored in x and mapped to the main camera's axes. This needs live verification.
- **You can see who leads**: the desk preview sits in the corner of the main preview, and a green frame means the desk leads; the mini window shows "face" or "desk".

## Low light

Camera exposure can't be controlled on macOS: none of the cameras tested (built-in, Desk View, both iPhones) support exposure modes or a metering point, and ISO, shutter speed, exposure compensation and Low Light Boost aren't available on macOS. So Midair doesn't tune the camera: it notices the dark and adapts. All of this is visible and adjustable in the window, "Low Light" section.

- **How it knows it's dark.** From the average frame brightness (the Y channel on a sparse grid, microseconds) and from the illuminance the camera puts into every frame: the `MetadataDictionary` attachment has `AdaptiveLuxValue` (an estimate in lux), `ExposureTime` and `AELimitsReached`. These keys are undocumented, so without them only the frame brightness is used. It's dark if brightness stays below 0.20 or light below 25 lux for a second; back at 0.28 and 40 lux. These are first-pass thresholds and should be tuned from live measurements.
- **Screen light.** Bright strips along the left, bottom and right edges of the built-in display; clicks pass through them. The color is in extended range (EDR: `CALayer.preferredDynamicRange = .high` and a color with brightness headroom), so on an XDR display the strips are brighter than regular white even when screen brightness is turned down; this drains the battery more noticeably. The "In the Dark" mode turns them on when the frame gets dark and keeps them on until gestures are turned off: the light itself brightens the frame, and the darkness detector would switch it off and on in a loop.
- **Edge Light** from macOS 26.2 can't be turned on by the app: it can only find out whether it's on (`AVCaptureDevice.isEdgeLightEnabled`) and open the system Video Effects menu where it's turned on.
- **Gestures are more careful in the dark.** Twice the smoothing, a hand dropout of up to 0.25 s counts as a blink (no rollback and no soft landing), mid-gesture the hand is waited for 0.4 s instead of 0.25, and a pinch needs a third frame in a row.
- **Brightening the frame before Vision** (an `x^gamma` curve via `CIGammaAdjust` that raises the average brightness to 0.4) is enabled with a switch. Whether it helps Vision isn't known in advance, so in the dark every third frame is recognized twice, with and without brightening, and the settings show where the hand is found more often and more completely.

Measured on the evening of October 31, 2026 with room lighting: frame brightness 0.45, the camera estimates 59 lux, exposure 0.03 s (the maximum at 30 fps) and `AELimitsReached=1`, meaning auto exposure is already at its limit. The frame rate still holds at 30 fps.

## Gesture log

To analyze false triggers from data rather than impressions, Midair can keep a gesture log. It's off by default: turn it on in the menu bar or in the window, "Log" section. From then on Midair writes it by itself while gestures are on: one file per activation in `~/Library/Logs/Midair/gestures-<date_time>.jsonl`, and the last thirty are kept. One JSON object per line: every hand pose (21 joints with Vision confidences, no camera frames, plus the second hand when there's one in the frame), the gesture phase, mouse actions, the engine's decisions in words (why a pinch started, was canceled or rejected), darkness, light and exposure at its limit. Right after a false trigger press ⌃⌥⌘M, and if a gesture didn't fire, ⌃⌥⌘N: a mark goes into the log and a sound plays (a muffled one if there's nowhere to write).

**The shadow log** (also off by default, in the same "Log" section) is written while gestures are off: the camera watches and the engine recognizes gestures, but nothing reaches the system, and pauses for the keyboard and mouse are marked just as in normal operation. There's no reason to gesture in this mode, so every event in a shadow log is false: a few hours of regular work show how many false clicks and drags per hour a layout would produce. The "What you're doing" menu sets an activity label (typing, a call, a mug and so on): false triggers usually cluster in a few activities. Logs you need for longer should be moved out of `~/Library/Logs/Midair` into a separate folder, otherwise rotation will eat them.

A log can be replayed through the same engine with any thresholds from `GestureConfig`, or through the old layout (before November 1, 2026, `Tools/LegacyGestureEngine.swift`):

```bash
swiftc -parse-as-library -O Midair/Core/*.swift Tools/LegacyGestureEngine.swift Tools/GestureReplay.swift -o /tmp/gesture-replay
/tmp/gesture-replay ~/Library/Logs/Midair/gestures-<time>.jsonl preset=old --b
/tmp/gesture-replay ~/Library/Logs/Midair/ pinchEnter=0.3 --b pinchEnter=0.34
```

The report lists events of all kinds (click, double click, drag with duration and path, right click, scroll, cursor rollback) with their rate per hour of time with a hand in the frame, and for zero, an upper bound by the rule of three. It also has time shares by phase, the engine's decisions, and a window around every ⌃⌥⌘M and ⌃⌥⌘N mark: what happened nearby and the last event of each kind before it (`window=3,0.5` sets the seconds before and after). After `--b` comes a second variant, and the events of both are matched on the same frames: what disappeared, appeared or changed kind. `preset=old` runs the old layout, `preset=defaults` takes the current thresholds instead of those recorded in the log, `around=<second>` prints the frames around that point with what the engine was looking at, `--csv` prints events as a table, `--frames` a per-frame table of engine features and cursor position. The replay cursor moves across the screen of a 16-inch MacBook Pro, and the engine uses it to keep the hand in the working area; the report shows the cursor path and hits against the screen edge (`leash=0` gives a pure trackpad for comparison). A whole folder can be replayed, with a summary by log and activity. A typo in a threshold name stops the run. Without thresholds the run is checked against the log by action kind: this shows the log is complete (the old layout matches a log from October 31 in 243 frames out of 243).

Settings are stored with a threshold version number. On update, saved settings from an older version get the new gesture thresholds, while personal settings (speed, smoothing, scrolling, mirroring) stay.

## Architecture

```
Midair/
  App/        AppModel: state, permissions, camera lifecycle; MidairApp: window and menu bar
  Capture/    CameraCatalog: cameras, format selection, Center Stage; DualCameraProbe: two-camera measurement
  Tracking/   TrackingPipeline: frame -> Vision -> gestures -> events; HandPoseDetector: Vision; FrameLight: frame brightness and the camera's light data; GestureRecorder: gesture log
  Core/       HandPose, OneEuroFilter2D, GestureConfig, GestureEngine, CameraLeader, LowLight, CursorGlide: pure logic, covered by tests
  Output/     InputInjector: CGEvent events; DisplayTicker: display ticks on their own thread; HotKey: global shortcut via Carbon
  UI/         window with preview and hand skeleton, settings, gesture icon at the cursor, screen light
MidairTests/     gesture engine and filter tests (Swift Testing)
Tools/           GestureReplay: replays a gesture log through the engine with other thresholds and compares layouts;
                 LegacyGestureEngine: the layout before November 1, 2026, for comparison
Config/          signing settings (xcconfig)
```

Data flow: camera (30 or 60 fps) > `VNDetectHumanHandPoseRequest` > hand selection > `GestureEngine` (1€ filter, state machine) > `[PointerAction]` > `InputInjector` (CGEvent). A state snapshot goes to the UI 30 times a second.

### Performance (measured November 1, 2026, M4 Pro)

- **The cursor glides between frames.** The camera gives 30 frames a second and the display runs at 120 Hz: the per-frame shift (`CursorGlide`) is stretched until the next frame arrives and delivered on display ticks (`DisplayTicker`, `CADisplayLink` on its own thread, idle while paused). The cost: at 30 fps the cursor lags by about 20 ms more, so Settings has a "Smooth motion between camera frames" switch. Before a button press the remainder is delivered at once, so the click lands where the engine led. If you grab the mouse mid-glide, the glide stops and gestures pause.
- **The gesture icon at the cursor** catches up with the cursor on every display tick rather than 30 times a second with the snapshot; when the cursor is still, its ticks are paused.
- **The UI doesn't redraw on every frame.** Views read a rounded `TrackingStatus` that changes only when something visible changes, and only the skeletons read the hand every frame. Before: the main thread was busy 57% of the time with the window open; after: 12%.
- **Vision runs only when needed.** While the preview window is closed: during a keyboard and mouse pause frames aren't recognized at all (the log gets a frame line without a hand, `fed=0`, and the replay skips such frames anyway), and with no hand for more than 2 s every other frame is recognized. The second pass that compares brightening runs only while the window is open.
- Overall, with the window open and gestures off (the same state, Debug): 32% CPU and energy impact 21.5 in `top` before these changes, 20.7% and 10.3 after. Release would save about 1% more: the rest is spent by system frameworks.

## Background research

Conclusions from the research behind this prototype:

- It can be done entirely with public APIs: hand pose in Vision costs about 5.6 ms per frame on an M4 Pro.
- A hand in the air can't fully replace a mouse: it gives about 2.7 bits/s versus 4.2 for a mouse, and three times as many misses. The realistic niche is hands away from the keyboard, accessibility, RSI, presentations.
- The keyboard is replaced by voice, not by fingers in the air (7-17 words per minute). Russian needs `DictationTranscriber` or Parakeet v3: `SpeechTranscriber` doesn't support Russian.
- The similar apps we looked at don't publish latency or accuracy figures. The way to stand out is click engineering, explicit modes and open measurements.

## Prototype limitations

- Typing with gestures isn't supported yet.
- The app isn't sandboxed: mouse events via CGEvent require Accessibility.
- The Desk View image orientation should be checked live: if the cursor goes the wrong way, the "Flip horizontally" and "Flip vertically" switches help. In "Two cameras" mode they apply to both cameras at once; if only the desk is mirrored, its axes are fixed in `TrackingPipeline` (mirroring the desk hand).
- While Midair runs, Center Stage is off in other apps too; when the camera stops, control goes back to the user.

## Security

See [SECURITY.md](SECURITY.md).

## License

The source code is released under the [MIT License](LICENSE). The license covers the code only: the Midair name and app icon aren't covered by it.

## Credits

- The 1€ filter: Géry Casiez, Nicolas Roussel, Daniel Vogel. "1€ Filter: A Simple Speed-based Low-pass Filter for Noisy Input in Interactive Systems", CHI 2012.
