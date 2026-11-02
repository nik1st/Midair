import CoreGraphics
import Foundation
import QuartzCore

/// Turns `PointerAction` into system mouse events via CGEvent.
/// Requires the Accessibility permission. Actions come from the pipeline queue, while the cursor glide
/// between frames runs on the display tick thread (`tick`), so all state lives under the `lock`.
final class InputInjector: @unchecked Sendable {
    /// A tag in `eventSourceUserData` that tells our events apart from real ones.
    static let eventMarker: Int64 = 0x4D44_4152

    /// Pipeline queue only; ticks don't read it.
    var doubleClickInterval: TimeInterval = 0.5
    /// How long to spread a frame's move over display ticks; zero means the move is applied at once, in one event.
    /// Pipeline queue only.
    var glideDuration: TimeInterval = 0

    /// Pause between pressing and releasing a button when both events fall in one frame (a whole click on pinch
    /// release, a right-click). Without it the system loses some mouseUp events (PawVis measured up to 20%,
    /// and zero with a pause of 4 ms or more), and a lost mouseUp leaves the app with a "stuck" button.
    private static let buttonGap: TimeInterval = 0.007
    /// For this long after our last move the cursor counts as ours: someone else moving it during this time means
    /// the person reached for the mouse or trackpad.
    private static let ownership: TimeInterval = 0.3

    private enum ScrollState {
        case idle, gesture, momentum
    }

    private let lock = NSLock()
    /// `CGEventSource.h` recommends the session state for user programs and `hidSystemState` for drivers.
    private let source = CGEventSource(stateID: .combinedSessionState)
    private var isLeftDown = false
    private var scrollState = ScrollState.idle
    private var clickState: Int64 = 0
    private var lastClickTime = -Double.infinity
    private var lastClickLocation = CGPoint.zero
    private var lastButtonDown: TimeInterval = 0
    private var scrollCarry = CGVector.zero
    private var glide = CursorGlide()
    /// When the glide last got a tick or started: without ticks the remainder would pile up while the cursor stood still.
    private var lastGlideTick = 0.0
    /// Fractional remainders of `mouseEventDelta`: at 120 Hz a fraction of a frame's move is under a point, and without
    /// remainders, apps that read the delta rather than the cursor position would come up short on travel.
    private var deltaCarry = CGVector.zero
    private var lastPost: (location: CGPoint, time: Double)?
    /// Our last cursor positions. The system reports the cursor position with a delay, and when gliding at 120 Hz
    /// it can be a tick behind: somewhere along this path the cursor is still ours.
    private var recentPosts: [CGPoint] = []
    /// The person moved the cursor while it was gliding: the glide is interrupted, the pipeline finds out on the next frame.
    private var movedExternally = false
    /// Where our cursor moves started over the last second: `.rewind` uses them to move the cursor back.
    private var moveOrigins: [(time: Double, location: CGPoint)] = []
    private var displays: [CGRect] = []
    private var displaysTime = -Double.infinity

    /// The cursor still has somewhere to glide: display ticks are needed.
    var isGliding: Bool {
        lock.withLock { !glide.isIdle }
    }

    func perform(_ action: PointerAction, time: Double) {
        lock.lock()
        defer { lock.unlock() }
        if case let .move(dx, dy) = action {
            return move(by: CGVector(dx: dx, dy: dy), time: time)
        }
        // In "frame area to the whole screen" mode the cursor position arrives every frame: glide to it the same way.
        if case let .moveTo(x, y) = action, glideDuration > 0 {
            let target = Self.mainScreenPoint(x: x, y: y)
            let from = expectedLocation()
            return move(by: CGVector(dx: target.x - from.x, dy: target.y - from.y), time: time)
        }
        switch action {
        case .rewind, .moveTo:
            // The cursor is set to the point, so the unglided remainder is no longer needed there.
            glide.cancel()
        default:
            // The button is pressed where the engine brought the cursor, not halfway there.
            flushGlide()
        }
        switch action {
        case .move:
            break
        case let .rewind(since):
            // Put the cursor at the start of the first move being rewound: that way the rewind is exact even at the screen edge.
            guard let target = moveOrigins.first(where: { $0.time >= since })?.location else { return }
            moveOrigins = []
            let origin = location()
            moveCursor(to: target, delta: CGVector(dx: target.x - origin.x, dy: target.y - origin.y))
        case let .moveTo(x, y):
            let target = Self.mainScreenPoint(x: x, y: y)
            let origin = location()
            moveCursor(to: target, delta: CGVector(dx: target.x - origin.x, dy: target.y - origin.y))
        case .leftDown:
            let location = location()
            let isRepeat = time - lastClickTime <= doubleClickInterval
                && hypot(location.x - lastClickLocation.x, location.y - lastClickLocation.y) < 6
            clickState = isRepeat ? min(clickState + 1, 3) : 1
            lastClickTime = time
            lastClickLocation = location
            postMouse(.leftMouseDown, at: location, button: .left, clickState: clickState)
            lastButtonDown = ProcessInfo.processInfo.systemUptime
            isLeftDown = true
        case .leftUp:
            guard isLeftDown else { return }
            waitAfterButtonDown()
            postMouse(.leftMouseUp, at: location(), button: .left, clickState: clickState)
            isLeftDown = false
        case .rightClick:
            let location = location()
            postMouse(.rightMouseDown, at: location, button: .right, clickState: 1)
            lastButtonDown = ProcessInfo.processInfo.systemUptime
            waitAfterButtonDown()
            postMouse(.rightMouseUp, at: location, button: .right, clickState: 1)
        case let .scroll(dx, dy, phase):
            postScroll(dx: dx, dy: dy, phase: phase)
        }
    }

    /// A display tick at `now`: the cursor covers its next share of the move. `false` when there's nothing left to glide.
    func tick(now: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !glide.isIdle else { return false }
        let actual = currentLocation()
        if recentPosts.isEmpty {
            recentPosts = [actual]
        } else if Self.distance(from: actual, toPath: recentPosts) > 3 {
            // The cursor left our path: the person reached for the mouse. Don't pull the cursor back.
            glide.cancel()
            movedExternally = true
            return false
        }
        lastGlideTick = CACurrentMediaTime()
        let step = glide.step(now: now)
        if step != .zero {
            let origin = location()
            moveCursor(to: clamp(CGPoint(x: origin.x + step.dx, y: origin.y + step.dy), from: origin), delta: step)
        }
        return !glide.isIdle
    }

    /// Releases everything held down: before a pause, turning off and quitting.
    func releaseAll() {
        lock.lock()
        defer { lock.unlock() }
        glide.cancel()
        if isLeftDown {
            postMouse(.leftMouseUp, at: location(), button: .left, clickState: clickState)
            isLeftDown = false
        }
        switch scrollState {
        case .gesture: postScroll(dx: 0, dy: 0, phase: .ended)
        case .momentum: postScroll(dx: 0, dy: 0, phase: .momentumEnded)
        case .idle: break
        }
        lastPost = nil
        recentPosts = []
        movedExternally = false
        moveOrigins = []
    }

    /// Where the cursor is on its screen, counting the unglided remainder: the engine uses it
    /// to keep the hand within the working area of the frame.
    func cursorContext() -> CursorContext? {
        lock.lock()
        defer { lock.unlock() }
        let location = expectedLocation()
        guard let screen = activeDisplays().first(where: { $0.contains(location) }),
              screen.width > 1, screen.height > 1 else { return nil }
        return CursorContext(position: CGPoint(x: (location.x - screen.minX) / (screen.width - 1),
                                               y: (location.y - screen.minY) / (screen.height - 1)),
                             size: screen.size)
    }

    /// The cursor was moved by someone else, so the person reached for the mouse or trackpad.
    func pointerMovedExternally() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if movedExternally {
            movedExternally = false
            return true
        }
        guard let lastPost else { return false }
        guard CACurrentMediaTime() - lastPost.time < Self.ownership else {
            self.lastPost = nil
            recentPosts = []
            return false
        }
        return Self.distance(from: currentLocation(), toPath: recentPosts) > 3
    }

    // MARK: - Events

    private func move(by delta: CGVector, time: Double) {
        let origin = expectedLocation()
        moveOrigins.removeAll { $0.time < time - 1 }
        moveOrigins.append((time, origin))
        let now = CACurrentMediaTime()
        // No ticks for a while, yet there's something to glide: the display slept or disappeared.
        // Move the cursor at once, as without spreading.
        let stalled = !glide.isIdle && now - lastGlideTick > 0.1
        guard glideDuration > 0, !stalled else {
            flushGlide()
            let from = location()
            return moveCursor(to: clamp(CGPoint(x: from.x + delta.dx, y: from.y + delta.dy), from: from), delta: delta)
        }
        if glide.isIdle {
            lastGlideTick = now
            // The previous glide ended long ago, and the person may have moved the cursor since: the path starts over.
            if let lastPost, now - lastPost.time >= Self.ownership {
                self.lastPost = nil
                recentPosts = []
            }
        }
        glide.add(delta, now: now, duration: glideDuration)
    }

    /// Emits the unglided remainder as one event.
    private func flushGlide() {
        let rest = glide.flush()
        guard rest != .zero else { return }
        let origin = location()
        moveCursor(to: clamp(CGPoint(x: origin.x + rest.dx, y: origin.y + rest.dy), from: origin), delta: rest)
    }

    private func moveCursor(to target: CGPoint, delta: CGVector) {
        let type: CGEventType = isLeftDown ? .leftMouseDragged : .mouseMoved
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: .left) else { return }
        deltaCarry.dx += delta.dx
        deltaCarry.dy += delta.dy
        let whole = CGVector(dx: deltaCarry.dx.rounded(), dy: deltaCarry.dy.rounded())
        deltaCarry.dx -= whole.dx
        deltaCarry.dy -= whole.dy
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(whole.dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(whole.dy))
        post(event)
        lastPost = (target, CACurrentMediaTime())
        recentPosts.append(target)
        if recentPosts.count > 4 { recentPosts.removeFirst(recentPosts.count - 4) }
    }

    /// The pipeline queue stalls for these milliseconds, but only in a click frame.
    private func waitAfterButtonDown() {
        let elapsed = ProcessInfo.processInfo.systemUptime - lastButtonDown
        if elapsed < Self.buttonGap { Thread.sleep(forTimeInterval: Self.buttonGap - elapsed) }
    }

    private func postMouse(_ type: CGEventType, at location: CGPoint, button: CGMouseButton, clickState: Int64) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        post(event)
    }

    /// Pixel scrolling with phases, like a trackpad: apps animate it smoothly and understand momentum.
    private func postScroll(dx: Double, dy: Double, phase: ScrollPhase) {
        switch phase {
        case .began:
            scrollState = .gesture
        case .momentumBegan:
            scrollState = .momentum
        case .changed, .ended:
            guard scrollState == .gesture else { return }
        case .momentum, .momentumEnded:
            guard scrollState == .momentum else { return }
        }

        scrollCarry.dx += dx
        scrollCarry.dy += dy
        let wheelX = scrollCarry.dx.rounded(.towardZero)
        let wheelY = scrollCarry.dy.rounded(.towardZero)
        scrollCarry.dx -= wheelX
        scrollCarry.dy -= wheelY

        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(clamping: Int(wheelY)), wheel2: Int32(clamping: Int(wheelX)), wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Values from CGEventTypes.h: kCGScrollPhase* and kCGMomentumScrollPhase*.
        let (scrollPhase, momentumPhase): (Int64, Int64) = switch phase {
        case .began: (1, 0)
        case .changed: (2, 0)
        case .ended: (4, 0)
        case .momentumBegan: (0, 1)
        case .momentum: (0, 2)
        case .momentumEnded: (0, 3)
        }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        post(event)

        if phase == .ended || phase == .momentumEnded {
            scrollState = .idle
            scrollCarry = .zero
        }
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Screen

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Where the cursor is now. Right after our event the system may report the previous position, so while
    /// the cursor is ours, we trust our last event.
    private func location() -> CGPoint {
        if let lastPost, CACurrentMediaTime() - lastPost.time < Self.ownership { return lastPost.location }
        return currentLocation()
    }

    /// Where the cursor will end up once it finishes gliding.
    private func expectedLocation() -> CGPoint {
        let origin = location()
        guard !glide.isIdle else { return origin }
        return clamp(CGPoint(x: origin.x + glide.pending.dx, y: origin.y + glide.pending.dy), from: origin)
    }

    /// A point on the main screen given as fractions of its width and height.
    private static func mainScreenPoint(x: Double, y: Double) -> CGPoint {
        let screen = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: screen.minX + x * (screen.width - 1), y: screen.minY + y * (screen.height - 1))
    }

    /// Distance from a point to the polyline through `path`.
    private static func distance(from point: CGPoint, toPath path: [CGPoint]) -> Double {
        guard var previous = path.first else { return .infinity }
        var best = hypot(point.x - previous.x, point.y - previous.y)
        for next in path.dropFirst() {
            let segment = CGVector(dx: next.x - previous.x, dy: next.y - previous.y)
            let length = segment.dx * segment.dx + segment.dy * segment.dy
            let t = length > 0 ? min(max(((point.x - previous.x) * segment.dx + (point.y - previous.y) * segment.dy) / length, 0), 1) : 0
            best = min(best, hypot(point.x - (previous.x + t * segment.dx), point.y - (previous.y + t * segment.dy)))
            previous = next
        }
        return best
    }

    /// Keeps the cursor within the screens: where monitors of different sizes meet there are "gaps".
    private func clamp(_ point: CGPoint, from origin: CGPoint) -> CGPoint {
        let screens = activeDisplays()
        if screens.contains(where: { $0.contains(point) }) { return point }
        let home = screens.first { $0.contains(origin) } ?? CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: min(max(point.x, home.minX), home.maxX - 1),
                       y: min(max(point.y, home.minY), home.maxY - 1))
    }

    private func activeDisplays() -> [CGRect] {
        let now = CACurrentMediaTime()
        guard now - displaysTime > 1 || displays.isEmpty else { return displays }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return displays }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return displays }
        displays = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        displaysTime = now
        return displays
    }
}
