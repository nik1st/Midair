import AppKit
import QuartzCore

/// Display ticks on a dedicated thread: between camera frames the cursor glides in step with the display, while the
/// main thread is busy with the UI and would throw the ticks off. When there's nothing to glide, ticks are paused:
/// otherwise a ProMotion display would stay at 120 Hz and waste battery.
final class DisplayTicker: NSObject, @unchecked Sendable {
    /// Called on every tick with the time of this display refresh, in `CACurrentMediaTime` clock.
    /// `false` pauses the ticks until `wake()`.
    private let onTick: @Sendable (Double) -> Bool
    private let lock = NSLock()
    private var link: CADisplayLink?
    private var runLoop: CFRunLoop?
    private var isPaused = true

    init(onTick: @escaping @Sendable (Double) -> Bool) {
        self.onTick = onTick
    }

    /// The tick thread is running and ready to wake up on `wake()`.
    var isRunning: Bool {
        lock.withLock { runLoop != nil }
    }

    /// Ticks of the display the cursor is currently on.
    @MainActor func start() {
        lock.lock()
        defer { lock.unlock() }
        guard link == nil else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.isPaused = true
        isPaused = true
        self.link = link
        let box = LinkBox(link)
        let thread = Thread { [weak self] in
            // The port keeps the run loop alive while ticks are paused.
            RunLoop.current.add(NSMachPort(), forMode: .common)
            box.link.add(to: .current, forMode: .common)
            guard let self, self.attach(CFRunLoopGetCurrent(), for: box.link) else { return }
            CFRunLoopRun()
        }
        thread.name = "dev.nikita.midair.display"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let link else { return }
        self.link = nil
        isPaused = true
        guard let runLoop else { return link.invalidate() }
        self.runLoop = nil
        let box = LinkBox(link)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            box.link.invalidate()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Resumes the ticks: the cursor now has somewhere to glide. Can be called from any thread.
    func wake() {
        lock.lock()
        defer { lock.unlock() }
        guard isPaused, let link, let runLoop else { return }
        isPaused = false
        let box = LinkBox(link)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { box.link.isPaused = false }
        CFRunLoopWakeUp(runLoop)
    }

    private func attach(_ runLoop: CFRunLoop, for link: CADisplayLink) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // `stop()` got there before the thread started.
        guard self.link === link else {
            link.invalidate()
            return false
        }
        self.runLoop = runLoop
        return true
    }

    @objc private func tick(_ link: CADisplayLink) {
        lock.lock()
        defer { lock.unlock() }
        guard self.link === link, !isPaused else { return }
        // The pause decision is made under the same lock as `wake()`: a move arriving during a tick won't be lost to the pause.
        if !onTick(link.timestamp) {
            isPaused = true
            link.isPaused = true
        }
    }
}

/// `CADisplayLink` isn't `Sendable`, yet it has to be touched from the tick thread.
private final class LinkBox: @unchecked Sendable {
    let link: CADisplayLink

    init(_ link: CADisplayLink) {
        self.link = link
    }
}
