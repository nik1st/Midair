import CoreGraphics
import Foundation
import Testing

/// A synthetic hand with the palm facing the camera, in frame heights. The palm size S for the thresholds is about
/// 0.092 (the mean of the palm length 0.1 and 1.4 times the palm width 0.06).
private enum TestHand {
    static let palm = open(at: .zero).blendedScale!

    static func open(at origin: CGPoint, missing: Set<HandJoint> = []) -> HandPose {
        make(at: origin, missing: missing)
    }

    /// The thumb touches the tip of `fingertip`, or stands `gap` palm sizes away from it.
    static func pinch(_ fingertip: HandJoint = .indexTip, at origin: CGPoint, gap: Double = 0.05,
                      missing: Set<HandJoint> = []) -> HandPose {
        let target = make(at: origin)[fingertip]!
        return make(at: origin, thumbTip: CGPoint(x: target.x - gap * palm, y: target.y), missing: missing)
    }

    static func fist(at origin: CGPoint, missing: Set<HandJoint> = []) -> HandPose {
        make(at: origin, curled: [.index, .middle, .ring, .little], missing: missing)
    }

    /// The "two fingers" pose: index and middle fingers extended, ring finger and pinky bent, held by the thumb.
    static func twoFingers(at origin: CGPoint) -> HandPose {
        make(at: origin, thumbTip: CGPoint(x: origin.x, y: origin.y + 0.08), curled: [.ring, .little])
    }

    /// The thumb touches the tip of the extended pinky.
    static func pinkyPinch(at origin: CGPoint, missing: Set<HandJoint> = []) -> HandPose {
        let target = make(at: origin)[.littleTip]!
        return make(at: origin, thumbTip: CGPoint(x: target.x - 0.05 * palm, y: target.y), missing: missing)
    }

    /// The thumb reaches for the pinky and the hand folds: the pinky is 0.12 palm from the thumb, while the index
    /// and middle fingers are close too, at 0.27-0.31, as in live testing.
    static func foldedPinkyPinch(at origin: CGPoint) -> HandPose {
        var points = make(at: origin).pointsByJoint
        let thumb = CGPoint(x: points[.littleTip]!.x - 0.12 * palm, y: points[.littleTip]!.y)
        points[.thumbTip] = thumb
        points[.indexTip] = CGPoint(x: thumb.x - 0.27 * palm, y: thumb.y)
        return HandPose(points: points)
    }

    /// The "two fingers" held together, the way they are held in live testing.
    static func twoFingersTogether(at origin: CGPoint) -> HandPose {
        var points = twoFingers(at: origin).pointsByJoint
        points[.indexTip] = CGPoint(x: origin.x - 0.02, y: origin.y + 0.185)
        points[.middleTip] = CGPoint(x: origin.x - 0.02, y: origin.y + 0.185)
        return HandPose(points: points)
    }

    /// "Two fingers" tilted toward the camera: shorter in projection, so the strict pose check no longer finds them.
    static func tiltedTwoFingers(at origin: CGPoint) -> HandPose {
        var points = twoFingers(at: origin).pointsByJoint
        for (x, pip, dip, tip) in [(-0.03, HandJoint.indexPIP, HandJoint.indexDIP, HandJoint.indexTip),
                                   (-0.01, .middlePIP, .middleDIP, .middleTip)] {
            points[pip] = CGPoint(x: origin.x + x, y: origin.y + 0.125)
            points[dip] = CGPoint(x: origin.x + x, y: origin.y + 0.135)
            points[tip] = CGPoint(x: origin.x + x, y: origin.y + 0.14)
        }
        return HandPose(points: points)
    }

    /// A pinch with the index finger pointing at the camera: in projection the finger is short, as in a fist.
    static func pointingPinch(at origin: CGPoint) -> HandPose {
        var points = make(at: origin).pointsByJoint
        points[.indexPIP] = CGPoint(x: origin.x - 0.03, y: origin.y + 0.125)
        points[.indexDIP] = CGPoint(x: origin.x - 0.03, y: origin.y + 0.115)
        points[.indexTip] = CGPoint(x: origin.x - 0.03, y: origin.y + 0.11)
        points[.thumbTip] = CGPoint(x: origin.x - 0.034, y: origin.y + 0.11)
        return HandPose(points: points)
    }

    private static func make(at origin: CGPoint, thumbTip: CGPoint? = nil, curled: Set<Finger> = [],
                             missing: Set<HandJoint> = []) -> HandPose {
        func at(_ dx: Double, _ dy: Double) -> CGPoint { CGPoint(x: origin.x + dx, y: origin.y + dy) }
        var points: [HandJoint: CGPoint] = [.wrist: at(0, 0)]
        let fingers: [(finger: Finger, x: Double)] = [(.index, -0.03), (.middle, -0.01), (.ring, 0.01), (.little, 0.03)]
        for (finger, x) in fingers {
            let joints = [finger.mcp, finger.pip, HandJoint(rawValue: finger.pip.rawValue + 1)!, finger.tip]
            let isCurled = curled.contains(finger)
            points[joints[0]] = at(x, 0.10)
            points[joints[1]] = at(x, 0.14)
            // A bent finger tucks its tip toward the palm center, closer to the wrist than the middle joint.
            points[joints[2]] = isCurled ? at(x, 0.09) : at(x, 0.165)
            points[joints[3]] = isCurled ? at(x * 0.5, 0.06) : at(x, 0.185)
        }
        points[.thumbCMC] = at(-0.03, 0.03)
        points[.thumbMP] = at(-0.05, 0.05)
        points[.thumbIP] = at(-0.065, 0.07)
        // In a fist the thumb lies next to the index finger: this must not count as a pinch.
        let isFist = curled.count == 4
        points[.thumbTip] = thumbTip ?? (isFist ? at(-0.035, 0.08) : at(-0.075, 0.09))
        for joint in missing {
            points[joint] = nil
        }
        return HandPose(points: points)
    }
}

private extension HandPose {
    var pointsByJoint: [HandJoint: CGPoint] {
        Dictionary(uniqueKeysWithValues: HandJoint.allCases.compactMap { joint in self[joint].map { (joint, $0) } })
    }
}

/// Feeds frames through the engine at 60 fps and collects all actions and decisions.
private struct Session {
    var engine: GestureEngine
    var time = 0.0
    var log: [PointerAction] = []
    var notes: [String] = []
    var phases: [GesturePhase] = []

    /// The screen for the work area: if set, the engine knows where the cursor is, and moves stop at the screen edges.
    var screen: CGSize?
    var cursor = CGPoint.zero

    init(config: GestureConfig = GestureConfig()) {
        engine = GestureEngine(config: config)
    }

    mutating func feed(frames: Int, _ hand: (Int) -> HandPose?) {
        for frame in 0..<frames {
            process(hand(frame), other: nil)
        }
    }

    /// Frames with two hands: `other` is the second hand in the frame.
    mutating func feed(frames: Int, _ hand: (Int) -> HandPose?, other: (Int) -> HandPose?) {
        for frame in 0..<frames {
            process(hand(frame), other: other(frame))
        }
    }

    private mutating func process(_ hand: HandPose?, other: HandPose?) {
        if let screen {
            engine.cursor = CursorContext(position: CGPoint(x: cursor.x / (screen.width - 1), y: cursor.y / (screen.height - 1)),
                                          size: screen)
        }
        let actions = engine.process(hand: hand, other: other, time: time)
        log += actions
        notes += engine.notes
        phases.append(engine.phase)
        time += 1.0 / 60
        guard let screen else { return }
        for case let .move(dx, dy) in actions {
            cursor = CGPoint(x: min(max(cursor.x + dx, 0), screen.width - 1), y: min(max(cursor.y + dy, 0), screen.height - 1))
        }
    }

    /// The hand entered the frame, held a palm and took control; the soft landing is over too.
    mutating func settle(at point: CGPoint) {
        feed(frames: 45) { _ in TestHand.open(at: point) }
    }

    /// A pinch in place, then the hand moves left, i.e. the cursor moves right: by the end the cursor is dragging.
    mutating func drag(from point: CGPoint) {
        feed(frames: 8) { _ in TestHand.pinch(at: point) }
        feed(frames: 40) { TestHand.pinch(at: CGPoint(x: point.x - Double($0) * 0.004, y: point.y)) }
    }

    /// The hand moved into the other camera's frame.
    mutating func handOver() {
        log += engine.handOver(at: time)
    }

    var moves: [CGVector] {
        log.compactMap(\.moveDelta)
    }

    func count(_ action: PointerAction) -> Int {
        log.filter { $0 == action }.count
    }

    /// Whole clicks: a press and a release in a row.
    var clicks: Int {
        zip(log, log.dropFirst()).filter { $0 == .leftDown && $1 == .leftUp }.count
    }

    var buttonEvents: [PointerAction] {
        log.filter { $0 == .leftDown || $0 == .leftUp || $0 == .rightClick }
    }
}

private extension PointerAction {
    var moveDelta: CGVector? {
        guard case let .move(dx, dy) = self else { return nil }
        return CGVector(dx: dx, dy: dy)
    }

    var scrollEvent: (dx: Double, dy: Double, phase: ScrollPhase)? {
        guard case let .scroll(dx, dy, phase) = self else { return nil }
        return (dx, dy, phase)
    }

    var rewindTime: Double? {
        guard case let .rewind(since) = self else { return nil }
        return since
    }
}

private let spot = CGPoint(x: 0.9, y: 0.3)

/// One-hand scrolling with the "two fingers" pose is off by default: the pose's own tests turn it on.
private func poseScrollSession() -> Session {
    var config = GestureConfig()
    config.oneHandScroll = true
    return Session(config: config)
}

// MARK: - Cursor and control

@Test func openHandMovesCursorLikeAMirror() {
    var session = Session()
    session.settle(at: spot)
    // In the unmirrored frame of a front camera, a hand moving right shifts left.
    session.feed(frames: 30) { TestHand.open(at: CGPoint(x: 0.9 - Double($0) * 0.01, y: 0.3)) }

    #expect(!session.moves.isEmpty)
    #expect(session.moves.allSatisfy { $0.dx > 0 && $0.dy == 0 })
    #expect(session.engine.phase == .hover)
}

@Test func fasterHandMovesCursorFartherForSameDistance() {
    var slow = Session()
    slow.settle(at: spot)
    slow.feed(frames: 60) { TestHand.open(at: CGPoint(x: 0.9 - Double($0) * 0.002, y: 0.3)) }
    var fast = Session()
    fast.settle(at: spot)
    fast.feed(frames: 12) { TestHand.open(at: CGPoint(x: 0.9 - Double($0) * 0.01, y: 0.3)) }
    fast.feed(frames: 30) { _ in TestHand.open(at: CGPoint(x: 0.9 - 11 * 0.01, y: 0.3)) }

    let slowDistance = slow.moves.reduce(0) { $0 + $1.dx }
    let fastDistance = fast.moves.reduce(0) { $0 + $1.dx }
    #expect(fastDistance > slowDistance * 1.5)
}

@Test func handPassingThroughFrameDoesNotMoveCursor() {
    var session = Session()
    // The hand entered the frame on the move (reaching for a mug): control is not taken, the cursor stays put.
    session.feed(frames: 40) { TestHand.open(at: CGPoint(x: 0.5 + Double($0) * 0.01, y: 0.3)) }
    #expect(session.moves.isEmpty)
    #expect(session.engine.phase == .standby)

    // The palm held for half a second: the cursor followed the hand.
    session.feed(frames: 40) { _ in TestHand.open(at: CGPoint(x: 0.9, y: 0.3)) }
    #expect(session.engine.phase == .hover)
    session.feed(frames: 20) { TestHand.open(at: CGPoint(x: 0.9 - Double($0) * 0.01, y: 0.3)) }
    #expect(!session.moves.isEmpty)
}

@Test func standbyRingFillsWhilePalmHolds() {
    var session = Session()
    session.feed(frames: 15) { _ in TestHand.open(at: spot) }
    guard case let .engaging(progress) = session.engine.cue else {
        Issue.record("expected the palm ring, got \(session.engine.cue)")
        return
    }
    #expect(progress > 0.3 && progress < 0.7)
}

@Test func pinchBeforeTakingControlDoesNothing() {
    var session = Session()
    session.feed(frames: 30) { _ in TestHand.pinch(at: spot) }
    session.feed(frames: 6) { _ in TestHand.open(at: spot) }
    #expect(session.buttonEvents.isEmpty)
}

@Test func resetTakesControlAway() {
    var session = Session()
    session.settle(at: spot)
    // The person reached for the keyboard: the pipeline reset the engine. After typing, control is retaken with a palm.
    session.engine.reset()
    session.feed(frames: 30) { TestHand.open(at: CGPoint(x: 0.9 - Double($0) * 0.01, y: 0.3)) }
    #expect(session.moves.isEmpty)
    #expect(session.engine.phase == .standby)
}

@Test func longAbsenceTakesControlAwayButShortOneDoesNot() {
    func moves(afterAbsence frames: Int) -> Int {
        var session = Session()
        session.settle(at: spot)
        session.feed(frames: frames) { _ in nil }
        session.log = []
        session.feed(frames: 40) { TestHand.open(at: CGPoint(x: 0.9 - Double($0) * 0.002, y: 0.3)) }
        return session.moves.count
    }
    #expect(moves(afterAbsence: 60) > 0)
    #expect(moves(afterAbsence: 120) == 0)
}

@Test func engagementCanBeTurnedOff() {
    var config = GestureConfig()
    config.requiresEngagement = false
    var session = Session(config: config)
    session.feed(frames: 30) { TestHand.open(at: CGPoint(x: 0.9 - Double($0) * 0.002, y: 0.3)) }
    #expect(!session.moves.isEmpty)
}

// MARK: - Click, drag, right-click

@Test func quickPinchClicksOnRelease() throws {
    var session = Session()
    session.settle(at: spot)
    // The hand drifts a little during the pinch, but the cursor stays put and the button is not pressed until release.
    session.feed(frames: 12) { TestHand.pinch(at: CGPoint(x: spot.x - Double($0) * 0.0005, y: spot.y)) }
    #expect(session.engine.phase == .pinched)
    #expect(session.buttonEvents.isEmpty)
    let movesBefore = session.moves.count
    session.feed(frames: 6) { _ in TestHand.open(at: CGPoint(x: spot.x - 0.006, y: spot.y)) }

    #expect(session.clicks == 1)
    #expect(session.buttonEvents == [.leftDown, .leftUp])
    #expect(session.moves.count == movesBefore)
}

@Test func middleFingerPinchIsTheSameClick() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 12) { _ in TestHand.pinch(.middleTip, at: spot) }
    session.feed(frames: 6) { _ in TestHand.open(at: spot) }
    #expect(session.clicks == 1)
    #expect(session.count(.rightClick) == 0)
}

@Test func shortPinchIsIgnored() {
    var session = Session()
    session.settle(at: spot)
    // Five frames at 60 fps are shorter than the confirmation window: a thumb brushing past on its way elsewhere.
    session.feed(frames: 5) { _ in TestHand.pinch(at: spot) }
    session.feed(frames: 6) { _ in TestHand.open(at: spot) }
    #expect(session.buttonEvents.isEmpty)
}

@Test func pinchStartedOnTheMoveIsCancelledSilently() {
    var session = Session()
    session.settle(at: spot)
    // A pinch while the hand is moving: this is what almost any false pinch looks like. Travel in the first fraction of
    // a second cancels it without events.
    session.feed(frames: 40) { TestHand.pinch(at: CGPoint(x: spot.x - Double($0) * 0.004, y: spot.y)) }
    #expect(session.notes.contains("cancel: travel"))
    #expect(session.engine.phase == .hover)
    session.feed(frames: 6) { _ in TestHand.open(at: CGPoint(x: spot.x - 0.16, y: spot.y)) }

    #expect(session.buttonEvents.isEmpty)
    // While the fingers stay together after the cancel, the cursor follows the hand instead of standing still.
    #expect(!session.moves.isEmpty)
}

@Test func pinchThenMovementDragsWithoutWaiting() throws {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 8) { _ in TestHand.pinch(at: spot) }
    #expect(session.engine.phase == .pinched)
    #expect(session.buttonEvents.isEmpty)
    session.feed(frames: 40) { TestHand.pinch(at: CGPoint(x: spot.x - Double($0) * 0.004, y: spot.y)) }
    #expect(session.engine.phase == .dragging)
    session.feed(frames: 6) { _ in TestHand.open(at: CGPoint(x: spot.x - 0.16, y: spot.y)) }

    let down = try #require(session.log.firstIndex(of: .leftDown))
    let up = try #require(session.log.firstIndex(of: .leftUp))
    let dragged = session.log[down..<up].compactMap(\.moveDelta)
    #expect(dragged.map(\.dx).reduce(0, +) > 50)
    // No jump for the travel already covered: the first move with the button is small.
    #expect((dragged.first?.dx ?? 0) < 20)
    #expect(session.buttonEvents == [.leftDown, .leftUp])
}

@Test func slowClickIsStillAClick() {
    var session = Session()
    session.settle(at: spot)
    // In live testing slow clicks lasted up to 0.9 s: that is not a right-click yet.
    session.feed(frames: 56) { _ in TestHand.pinch(at: spot) }
    session.feed(frames: 6) { _ in TestHand.open(at: spot) }
    #expect(session.clicks == 1)
    #expect(session.count(.rightClick) == 0)
}

@Test func longStillPinchIsRightClick() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 70) { _ in TestHand.pinch(at: spot) }
    guard case .holding = session.engine.cue else {
        Issue.record("expected the hold ring, got \(session.engine.cue)")
        return
    }
    session.feed(frames: 30) { _ in TestHand.pinch(at: spot) }
    #expect(session.engine.cue == .rightClick)
    session.feed(frames: 6) { _ in TestHand.open(at: spot) }

    #expect(session.buttonEvents == [.rightClick])
}

@Test func thumbToPinkyIsRightClickRightAway() {
    var session = Session()
    session.settle(at: spot)
    // The right-click goes out as soon as the touch is confirmed, without waiting for the release: a pressed pinky
    // is covered by the thumb, and Vision often loses its tip.
    session.feed(frames: 8) { _ in TestHand.pinkyPinch(at: spot) }
    #expect(session.buttonEvents == [.rightClick])
    session.feed(frames: 20) { _ in TestHand.pinkyPinch(at: spot, missing: [.littleTip]) }
    session.feed(frames: 6) { _ in TestHand.open(at: spot) }
    #expect(session.buttonEvents == [.rightClick])
}

@Test func foldedHandReachingPinkyIsRightClickNotClick() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 12) { _ in TestHand.foldedPinkyPinch(at: spot) }
    session.feed(frames: 6) { _ in TestHand.open(at: spot) }
    #expect(session.buttonEvents == [.rightClick])
}

@Test func twoQuickPinchesAreTwoClicks() {
    var session = Session()
    session.settle(at: spot)
    for _ in 0..<2 {
        session.feed(frames: 8) { _ in TestHand.pinch(at: spot) }
        session.feed(frames: 6) { _ in TestHand.open(at: spot) }
    }
    #expect(session.clicks == 2)
    // Both pairs fit within the usual double-click interval.
    #expect(session.time < 0.75 + 0.5)
}

@Test func relaxedFingersAfterPinchFinishTheClick() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 8) { _ in TestHand.pinch(at: spot) }
    // The fingers did not open fully (0.38, between the thresholds 0.32 and 0.52): after 0.2 s that is a release.
    session.feed(frames: 15) { _ in TestHand.pinch(at: spot, gap: 0.38) }
    #expect(session.clicks == 1)
}

@Test func betweenThresholdsDuringDragKeepsButton() {
    var session = Session()
    session.settle(at: spot)
    session.drag(from: spot)
    // During a drag only a fully opened pinch releases.
    session.feed(frames: 30) { _ in TestHand.pinch(at: CGPoint(x: spot.x - 0.16, y: spot.y), gap: 0.38) }
    #expect(session.count(.leftUp) == 0)
    session.feed(frames: 6) { _ in TestHand.open(at: CGPoint(x: spot.x - 0.16, y: spot.y)) }
    #expect(session.count(.leftUp) == 1)
}

@Test func newPinchNeedsFingersToOpenFirst() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 8) { _ in TestHand.pinch(at: spot) }
    session.feed(frames: 15) { _ in TestHand.pinch(at: spot, gap: 0.38) }
    #expect(session.clicks == 1)
    // The fingers came together again without ever opening: no second click.
    session.feed(frames: 20) { _ in TestHand.pinch(at: spot) }
    session.feed(frames: 15) { _ in TestHand.pinch(at: spot, gap: 0.38) }
    #expect(session.clicks == 1)
    #expect(session.notes.contains("pinch blocked: rearm"))

    session.feed(frames: 6) { _ in TestHand.open(at: spot) }
    session.feed(frames: 8) { _ in TestHand.pinch(at: spot) }
    session.feed(frames: 6) { _ in TestHand.open(at: spot) }
    #expect(session.clicks == 2)
}

@Test func pinchDuringFastMovementIsIgnored() {
    var session = Session()
    session.settle(at: spot)
    // The hand sweeps across the frame (1.2 frame heights/s, about 13 S/s), and on motion blur the fingers "merge".
    session.feed(frames: 10) { TestHand.open(at: CGPoint(x: spot.x - Double($0) * 0.02, y: spot.y)) }
    session.feed(frames: 10) { TestHand.pinch(at: CGPoint(x: spot.x - 0.2 - Double($0) * 0.02, y: spot.y)) }
    #expect(session.engine.phase == .hover)
    #expect(session.notes.contains("pinch blocked: speed"))

    // The hand stopped: the same pinch now counts, and the release gives a click.
    session.feed(frames: 20) { _ in TestHand.pinch(at: CGPoint(x: spot.x - 0.4, y: spot.y)) }
    #expect(session.engine.phase == .pinched)
    session.feed(frames: 6) { _ in TestHand.open(at: CGPoint(x: spot.x - 0.4, y: spot.y)) }
    #expect(session.clicks == 1)
}

@Test func withExposureAtLimitPinchStartsOnlyOnSlowerHand() {
    func run(limited: Bool) -> Session {
        var session = Session()
        session.engine.isExposureLimited = limited
        session.settle(at: spot)
        // About 3.5 S per second: normally a pinch still starts, but with a long exposure it no longer does.
        let step = 3.5 * TestHand.palm / 60
        session.feed(frames: 10) { TestHand.open(at: CGPoint(x: spot.x - Double($0) * step, y: spot.y)) }
        session.feed(frames: 10) { TestHand.pinch(at: CGPoint(x: spot.x - Double(10 + $0) * step, y: spot.y)) }
        return session
    }
    #expect(run(limited: false).notes.contains("pinch"))
    let limited = run(limited: true)
    #expect(!limited.notes.contains("pinch"))
    #expect(limited.notes.contains("pinch blocked: speed"))
}

@Test func fingerPointingAtCameraDoesNotPinch() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 20) { _ in TestHand.pointingPinch(at: spot) }
    #expect(session.engine.phase != .pinched)
    #expect(session.notes.contains("pinch blocked: finger"))
}

// MARK: - Hand and fingertip dropouts

@Test func losingHandMidPinchCancelsSilently() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 8) { _ in TestHand.pinch(at: spot) }
    // Longer than the 250 ms tolerance: the button isn't pressed, so there is nothing to cancel.
    session.feed(frames: 20) { _ in nil }

    #expect(session.buttonEvents.isEmpty)
    #expect(session.engine.phase == .noHand)
}

@Test func briefTrackingLossKeepsPinch() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 8) { _ in TestHand.pinch(at: spot) }
    session.feed(frames: 5) { _ in nil }
    session.feed(frames: 5) { _ in TestHand.pinch(at: spot) }

    #expect(session.buttonEvents.isEmpty)
    #expect(session.engine.phase == .pinched)
}

@Test func losingHandMidDragReleasesButton() {
    var session = Session()
    session.settle(at: spot)
    session.drag(from: spot)
    session.feed(frames: 70) { _ in nil }
    #expect(session.buttonEvents == [.leftDown, .leftUp])
    #expect(session.engine.phase == .noHand)
}

@Test func hiddenFingertipsCancelPinchSilently() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 8) { _ in TestHand.pinch(at: spot) }
    let hidden: Set<HandJoint> = [.indexTip, .middleTip]
    // The tips vanished for 0.2 s, for example on motion blur: the pinch holds.
    session.feed(frames: 12) { _ in TestHand.pinch(at: spot, missing: hidden) }
    #expect(session.engine.phase == .pinched)
    session.feed(frames: 2) { _ in TestHand.pinch(at: spot) }

    // The tips are not visible for more than 0.3 s: the pinch is cancelled, and the release gives no click.
    session.feed(frames: 24) { _ in TestHand.pinch(at: spot, missing: hidden) }
    session.feed(frames: 6) { _ in TestHand.open(at: spot) }
    #expect(session.buttonEvents.isEmpty)
}

@Test func hiddenFingertipsEndDragAfterHalfSecond() {
    var session = Session()
    session.settle(at: spot)
    session.drag(from: spot)
    let point = CGPoint(x: spot.x - 0.16, y: spot.y)
    let hidden: Set<HandJoint> = [.indexTip, .middleTip]
    session.feed(frames: 12) { _ in TestHand.pinch(at: point, missing: hidden) }
    #expect(session.count(.leftUp) == 0)
    // Tips not visible for over half a second: release the button instead of holding it while the hand is in frame.
    session.feed(frames: 40) { _ in TestHand.pinch(at: point, missing: hidden) }
    #expect(session.count(.leftUp) == 1)
}

@Test func missingWristAtFrameEdgeDoesNotDropDrag() {
    var session = Session()
    session.settle(at: spot)
    session.drag(from: spot)
    let movesBefore = session.moves.count
    // The wrist went past the bottom edge: the anchor is restored from the knuckles, the drag continues.
    session.feed(frames: 30) {
        TestHand.pinch(at: CGPoint(x: spot.x - 0.16 - Double($0) * 0.004, y: spot.y), missing: [.wrist])
    }

    #expect(session.count(.leftUp) == 0)
    #expect(session.engine.phase == .dragging)
    #expect(session.moves.count > movesBefore)
    #expect(session.moves.allSatisfy { abs($0.dy) < 1 })
}

// MARK: - Fist

@Test func fistHoldsCursorWhileHandRepositions() {
    var session = Session()
    session.settle(at: spot)
    let movesBefore = session.moves.count
    session.feed(frames: 20) { TestHand.fist(at: CGPoint(x: spot.x + Double($0) * 0.01, y: spot.y)) }

    #expect(session.engine.phase == .clutch)
    #expect(session.moves.count == movesBefore)
    #expect(session.buttonEvents.isEmpty)
}

@Test func fistWithHiddenFingertipIsStillAFist() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 20) { _ in TestHand.fist(at: spot, missing: [.littleTip]) }
    #expect(session.engine.phase == .clutch)
}

@Test func flickeringFistDoesNotMoveCursor() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 12) { _ in TestHand.fist(at: spot) }
    let movesBefore = session.moves.count
    // Every fourth frame Vision reads the fingers as extended, while the hand is being repositioned.
    session.feed(frames: 40) { frame in
        let point = CGPoint(x: spot.x + Double(frame) * 0.005, y: spot.y)
        return frame % 4 == 3 ? TestHand.open(at: point) : TestHand.fist(at: point)
    }
    #expect(session.moves.count == movesBefore)
    #expect(session.phases.suffix(40).allSatisfy { $0 == .clutch })
}

@Test func openingFistPastThumbDoesNotClick() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 20) { _ in TestHand.fist(at: spot) }
    // The hand opens and the index finger passes by the thumb: a few frames look like a pinch.
    session.feed(frames: 10) { _ in TestHand.pinch(at: spot) }
    session.feed(frames: 10) { _ in TestHand.open(at: spot) }
    #expect(session.buttonEvents.isEmpty)
}

/// A recording of a real hand: it isn't published with the code, so the test runs only where the file is present.
private let fistAndPalmJournal = URL(filePath: #filePath).deletingLastPathComponent()
    .appending(path: "Fixtures/fist-and-palm-2026-10-31.jsonl")

@Test(.enabled(if: FileManager.default.fileExists(atPath: fistAndPalmJournal.path(percentEncoded: false)),
               "The recording of a real hand isn't in the repository"))
func realJournalFistHoldsWithoutFlicker() throws {
    // Journal of 31 October 2026: 1.4 s of hand, a fist and a palm. The legacy layout switched 13 times on these frames
    // between cursor and fist, and the cursor traveled 102 pt while in the fist.
    let text = try String(contentsOf: fistAndPalmJournal, encoding: .utf8)
    var config = GestureConfig()
    config.requiresEngagement = false
    var engine = GestureEngine(config: config)
    var phases: [GesturePhase] = []
    var actions: [PointerAction] = []
    var travelInFist = 0.0
    for line in text.split(separator: "\n") {
        guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              record["k"] as? String == "frame", let time = record["t"] as? Double else { continue }
        let hand = journalHand(record)?.filtered(minConfidence: config.minConfidence)
        let step = engine.process(hand: hand, time: time)
        if phases.contains(.clutch) {
            travelInFist += step.compactMap(\.moveDelta).map { hypot($0.dx, $0.dy) }.reduce(0, +)
        }
        actions += step
        phases.append(engine.phase)
    }
    let switches = zip(phases, phases.dropFirst()).filter { ($0 == .clutch) != ($1 == .clutch) }.count
    #expect(switches <= 2)
    #expect(travelInFist < 5)
    #expect(!actions.contains { $0 == .leftDown || $0 == .rightClick || $0.scrollEvent != nil })
}

private func journalHand(_ record: [String: Any]) -> HandPose? {
    guard let values = record["hand"] as? [Any], let aspect = record["aspect"] as? Double else { return nil }
    var points: [HandJoint: CGPoint] = [:]
    for joint in HandJoint.allCases {
        let index = joint.rawValue * 2
        guard let x = values[index] as? Double, let y = values[index + 1] as? Double else { continue }
        points[joint] = CGPoint(x: x, y: y)
    }
    return HandPose(points: points, aspect: aspect)
}

// MARK: - Scrolling with a pose

@Test func straightTwoFingersDragThePageWithTheHand() {
    var session = poseScrollSession()
    session.settle(at: spot)
    session.feed(frames: 15) { _ in TestHand.twoFingers(at: spot) }
    #expect(session.engine.phase == .scrolling)
    // The hand is still: the page stays put.
    session.feed(frames: 10) { _ in TestHand.twoFingers(at: spot) }
    #expect(!session.log.contains { $0.scrollEvent != nil })

    // The hand moves down (in Vision's frame y decreases): with natural scrolling the content follows it,
    // i.e. the wheel scrolls up.
    session.feed(frames: 20) { TestHand.twoFingers(at: CGPoint(x: spot.x, y: spot.y - Double($0) * 0.004)) }
    let down = session.log.compactMap(\.scrollEvent)
    #expect(down.first?.phase == .began)
    #expect(down.filter { abs($0.dy) > 0.5 }.allSatisfy { $0.dy > 0 && $0.dx == 0 })
    #expect(down.map(\.dy).reduce(0, +) > 50)

    // The hand goes back up with straight fingers: the page moves back, as on a trackpad.
    session.log = []
    session.feed(frames: 20) { TestHand.twoFingers(at: CGPoint(x: spot.x, y: spot.y - 0.076 + Double($0) * 0.004)) }
    #expect(session.log.compactMap(\.scrollEvent).map(\.dy).reduce(0, +) < -50)
    #expect(session.buttonEvents.isEmpty)
}

@Test func bentFingersLiftSoTheHandCanReturn() {
    var session = poseScrollSession()
    session.settle(at: spot)
    session.feed(frames: 15) { _ in TestHand.twoFingers(at: spot) }
    // A fast stroke down with straight fingers, then bent fingers: the gesture is closed, the page coasts to a stop.
    session.feed(frames: 10) { TestHand.twoFingers(at: CGPoint(x: spot.x, y: spot.y - Double($0) * 0.01)) }
    session.feed(frames: 5) { _ in TestHand.fist(at: CGPoint(x: spot.x, y: spot.y - 0.09)) }
    let lifted = session.log.compactMap(\.scrollEvent).map(\.phase)
    #expect(lifted.contains(.ended))
    #expect(lifted.contains(.momentumBegan))

    // The hand is brought back up with bent fingers: the page doesn't go back, and the pose holds.
    session.log = []
    session.feed(frames: 30) { TestHand.fist(at: CGPoint(x: spot.x, y: spot.y - 0.09 + Double($0) * 0.003)) }
    #expect(session.phases.suffix(30).allSatisfy { $0 == .scrolling })
    let returning = session.log.compactMap(\.scrollEvent)
    #expect(returning.allSatisfy { $0.phase == .momentum || $0.phase == .momentumEnded })
    #expect(returning.allSatisfy { $0.dy >= 0 })
}

@Test func openingPalmDoesNotScrollBack() {
    var session = poseScrollSession()
    session.settle(at: spot)
    session.feed(frames: 15) { _ in TestHand.twoFingers(at: spot) }
    session.feed(frames: 20) { TestHand.twoFingers(at: CGPoint(x: spot.x, y: spot.y - Double($0) * 0.002)) }
    session.log = []
    // The palm opens in place: the fingertips rise, and the page doesn't scroll back.
    session.feed(frames: 20) { _ in TestHand.open(at: CGPoint(x: spot.x, y: spot.y - 0.038)) }
    let after = session.log.compactMap(\.scrollEvent)
    #expect(after.allSatisfy { $0.dy >= 0 })
    #expect(session.engine.phase == .hover)
}

@Test func pinchRightAfterScrollingIsNotBlocked() {
    var session = poseScrollSession()
    session.settle(at: spot)
    session.feed(frames: 15) { _ in TestHand.twoFingers(at: spot) }
    session.feed(frames: 10) { TestHand.twoFingers(at: CGPoint(x: spot.x, y: spot.y - Double($0) * 0.004)) }
    // Straight from the scroll pose into a pinch, with no open palm in between: the click goes through.
    let point = CGPoint(x: spot.x, y: spot.y - 0.036)
    session.feed(frames: 20) { _ in TestHand.pinch(at: point) }
    session.feed(frames: 6) { _ in TestHand.open(at: point) }
    #expect(session.clicks == 1)
}

@Test func briefHandLossKeepsScrollSession() {
    var session = poseScrollSession()
    session.settle(at: spot)
    session.feed(frames: 15) { _ in TestHand.twoFingers(at: spot) }
    // The hand is repositioned with bent fingers and Vision loses it for a third of a second: the scroll session holds.
    session.feed(frames: 20) { _ in nil }
    session.feed(frames: 5) { _ in TestHand.fist(at: spot) }
    #expect(session.engine.phase == .scrolling)
}

@Test func bendingFingersIntoFistKeepsScrolling() {
    var session = poseScrollSession()
    session.settle(at: spot)
    session.feed(frames: 15) { _ in TestHand.twoFingers(at: spot) }
    // Bent fingers look like a fist, yet the scroll session doesn't break: this is "fingers lifted".
    session.feed(frames: 30) { _ in TestHand.fist(at: spot) }
    #expect(session.phases.suffix(30).allSatisfy { $0 == .scrolling })
    session.feed(frames: 30) { _ in TestHand.tiltedTwoFingers(at: spot) }
    #expect(session.phases.suffix(30).allSatisfy { $0 == .scrolling })
}

@Test func fastStrokeScrollsFartherThanSlowOne() {
    func scrolled(frames: Int) -> Double {
        var session = poseScrollSession()
        session.settle(at: spot)
        session.feed(frames: 15) { _ in TestHand.twoFingers(at: spot) }
        let step = 0.06 / Double(frames)
        session.feed(frames: frames) { TestHand.twoFingers(at: CGPoint(x: spot.x, y: spot.y - Double($0 + 1) * step)) }
        session.feed(frames: 20) { _ in TestHand.twoFingers(at: CGPoint(x: spot.x, y: spot.y - 0.06)) }
        return session.log.compactMap(\.scrollEvent).filter { $0.phase == .began || $0.phase == .changed }.map(\.dy).reduce(0, +)
    }
    // The same hand stroke in 0.1 s and in 0.7 s: the fast one scrolls farther, like cursor acceleration.
    #expect(scrolled(frames: 6) > scrolled(frames: 40) * 1.3)
}

// MARK: - Two-hand scrolling

private let holderSpot = CGPoint(x: 0.4, y: 0.3)

@Test func fistOfSecondHandTurnsFirstHandIntoScroller() throws {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 20, { _ in TestHand.open(at: spot) }, other: { _ in TestHand.fist(at: holderSpot) })
    #expect(session.engine.phase == .scrolling)
    #expect(session.notes.contains("two hands"))

    // The first hand's palm moves down: the page follows it.
    session.feed(frames: 20, { TestHand.open(at: CGPoint(x: spot.x, y: spot.y - Double($0) * 0.004)) },
                 other: { _ in TestHand.fist(at: holderSpot) })
    let down = session.log.compactMap(\.scrollEvent)
    #expect(down.first?.phase == .began)
    #expect(down.map(\.dy).reduce(0, +) > 50)
    #expect(session.moves.isEmpty)

    // The first hand made a fist and went back up: the fingers are "lifted", the page doesn't scroll back.
    session.log = []
    session.feed(frames: 30, { TestHand.fist(at: CGPoint(x: spot.x, y: spot.y - 0.076 + Double($0) * 0.0025)) },
                 other: { _ in TestHand.fist(at: holderSpot) })
    #expect(session.log.compactMap(\.scrollEvent).allSatisfy { $0.phase != .began && $0.phase != .changed })

    // The second hand's fist is released: the cursor is back, without a jump.
    session.feed(frames: 15, { _ in TestHand.open(at: spot) }, other: { _ in TestHand.open(at: holderSpot) })
    #expect(session.engine.phase == .hover)
    session.log = []
    session.feed(frames: 20, { TestHand.open(at: CGPoint(x: spot.x - Double($0) * 0.004, y: spot.y)) },
                 other: { _ in TestHand.open(at: holderSpot) })
    let moves = session.moves
    #expect(!moves.isEmpty)
    #expect(moves.allSatisfy { abs($0.dx) < 20 })
}

@Test func openSecondHandDoesNotScroll() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 30, { TestHand.open(at: CGPoint(x: spot.x - Double($0) * 0.004, y: spot.y)) },
                 other: { _ in TestHand.open(at: holderSpot) })
    #expect(session.engine.phase == .hover)
    #expect(!session.moves.isEmpty)
    #expect(!session.log.contains { $0.scrollEvent != nil })
}

@Test func scrollerLeavingFrameKeepsTwoHandScroll() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 20, { _ in TestHand.open(at: spot) }, other: { _ in TestHand.fist(at: holderSpot) })
    // The scrolling hand jumped out of the frame: the pipeline gives the lead the only hand left, the fist.
    session.feed(frames: 30, { _ in TestHand.fist(at: holderSpot) }, other: { _ in nil })
    #expect(session.phases.suffix(30).allSatisfy { $0 == .scrolling })
    // The hand returned and keeps scrolling from wherever it is now.
    session.log = []
    session.feed(frames: 20, { TestHand.open(at: CGPoint(x: 0.7, y: 0.5 - Double($0) * 0.004)) },
                 other: { _ in TestHand.fist(at: holderSpot) })
    let scrolls = session.log.compactMap(\.scrollEvent).filter { $0.phase == .began || $0.phase == .changed }
    #expect(!scrolls.isEmpty)
    #expect(scrolls.allSatisfy { abs($0.dy) < 60 })
}

@Test func returningScrollerDoesNotScrollWhileMovingIn() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 20, { _ in TestHand.open(at: spot) }, other: { _ in TestHand.fist(at: holderSpot) })
    // A stroke down, then the scrolling hand left the frame: the page rolls on by momentum.
    session.feed(frames: 10, { TestHand.open(at: CGPoint(x: spot.x, y: spot.y - Double($0 + 1) * 0.01)) },
                 other: { _ in TestHand.fist(at: holderSpot) })
    session.feed(frames: 15, { _ in TestHand.fist(at: holderSpot) }, other: { _ in nil })
    // The hand returns and moves quickly up into the frame: this is not a touch yet, the page doesn't scroll back.
    session.log = []
    session.feed(frames: 15, { TestHand.open(at: CGPoint(x: spot.x, y: 0.05 + Double($0) * 0.01)) },
                 other: { _ in TestHand.fist(at: holderSpot) })
    let touches = { (log: [PointerAction]) in
        log.compactMap(\.scrollEvent).filter { $0.phase == .began || $0.phase == .changed }
    }
    #expect(touches(session.log).isEmpty)
    // The hand slowed down: the touch scrolls again.
    session.feed(frames: 30, { TestHand.open(at: CGPoint(x: spot.x, y: 0.2 - Double($0) * 0.002)) },
                 other: { _ in TestHand.fist(at: holderSpot) })
    #expect(!touches(session.log).isEmpty)
}

@Test func scrollerFlickeringAtEdgeStillWaitsToSettle() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 20, { _ in TestHand.open(at: spot) }, other: { _ in TestHand.fist(at: holderSpot) })
    session.feed(frames: 10, { TestHand.open(at: CGPoint(x: spot.x, y: spot.y - Double($0 + 1) * 0.01)) },
                 other: { _ in TestHand.fist(at: holderSpot) })
    // At the frame edge the scrolling hand alternately vanishes and shows up as a few joints without the palm base
    // (journal 21:46, 68.2 s): this still counts as leaving the frame.
    let base: Set<HandJoint> = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
    session.feed(frames: 15, { $0 % 3 == 2 ? nil : TestHand.open(at: CGPoint(x: spot.x, y: 0.05), missing: base) },
                 other: { _ in TestHand.fist(at: holderSpot) })
    session.log = []
    session.feed(frames: 15, { TestHand.open(at: CGPoint(x: spot.x, y: 0.05 + Double($0) * 0.01)) },
                 other: { _ in TestHand.fist(at: holderSpot) })
    let touches = { (log: [PointerAction]) in
        log.compactMap(\.scrollEvent).filter { $0.phase == .began || $0.phase == .changed }
    }
    #expect(touches(session.log).isEmpty)
    session.feed(frames: 30, { TestHand.open(at: CGPoint(x: spot.x, y: 0.2 - Double($0) * 0.002)) },
                 other: { _ in TestHand.fist(at: holderSpot) })
    #expect(!touches(session.log).isEmpty)
}

@Test func scrollerPausingForAFrameWhileMovingInStaysLifted() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 20, { _ in TestHand.open(at: spot) }, other: { _ in TestHand.fist(at: holderSpot) })
    session.feed(frames: 10, { TestHand.open(at: CGPoint(x: spot.x, y: spot.y - Double($0 + 1) * 0.01)) },
                 other: { _ in TestHand.fist(at: holderSpot) })
    session.feed(frames: 15, { _ in TestHand.fist(at: holderSpot) }, other: { _ in nil })
    // The hand returns and moves quickly up, pauses for 50 ms and goes on (journal 21:46, 68.3 s):
    // a couple of slow frames is not a stop yet.
    session.log = []
    session.feed(frames: 30, { TestHand.open(at: CGPoint(x: spot.x, y: 0.05 + Double($0 < 10 ? $0 : $0 < 13 ? 9 : $0 - 3) * 0.01)) },
                 other: { _ in TestHand.fist(at: holderSpot) })
    #expect(!session.log.contains { $0.scrollEvent.map { $0.phase == .began || $0.phase == .changed } ?? false })
}

@Test func returningScrollerKeepsAxisOfLastStroke() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 20, { _ in TestHand.open(at: spot) }, other: { _ in TestHand.fist(at: holderSpot) })
    session.feed(frames: 10, { TestHand.open(at: CGPoint(x: spot.x, y: spot.y - Double($0 + 1) * 0.01)) },
                 other: { _ in TestHand.fist(at: holderSpot) })
    session.feed(frames: 15, { _ in TestHand.fist(at: holderSpot) }, other: { _ in nil })
    // The hand returned, stopped and moved slowly sideways to its place (journal 21:46, 33.8 s):
    // the page does not slide sideways.
    session.log = []
    let back = CGPoint(x: spot.x, y: 0.15)
    session.feed(frames: 20, { _ in TestHand.open(at: back) }, other: { _ in TestHand.fist(at: holderSpot) })
    session.feed(frames: 20, { TestHand.open(at: CGPoint(x: back.x - Double($0 + 1) * 0.003, y: back.y + Double($0 + 1) * 0.0005)) },
                 other: { _ in TestHand.fist(at: holderSpot) })
    let touches = session.log.compactMap(\.scrollEvent).filter { $0.phase == .began || $0.phase == .changed }
    #expect(!touches.isEmpty)
    #expect(touches.allSatisfy { $0.dx == 0 })
}

@Test func sidewaysTouchTurnsVerticalWhenHandGoesUp() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 20, { _ in TestHand.open(at: spot) }, other: { _ in TestHand.fist(at: holderSpot) })
    // The touch began with a sideways jitter, so the axis was decided as horizontal, and then the hand goes up
    // (journal 22:10, 102.8 s).
    session.log = []
    session.feed(frames: 6, { TestHand.open(at: CGPoint(x: spot.x - Double($0 + 1) * 0.003, y: spot.y)) },
                 other: { _ in TestHand.fist(at: holderSpot) })
    session.feed(frames: 30, { TestHand.open(at: CGPoint(x: spot.x - 0.018, y: spot.y + Double($0 + 1) * 0.004)) },
                 other: { _ in TestHand.fist(at: holderSpot) })
    let touches = session.log.compactMap(\.scrollEvent).filter { $0.phase == .began || $0.phase == .changed }
    #expect(touches.contains { $0.dx != 0 })
    #expect(touches.suffix(10).allSatisfy { $0.dx == 0 && $0.dy != 0 })
}

@Test func fistOfCursorHandLetsTheOpenSecondHandScroll() {
    // The clenched hand holds the fist and the open one scrolls, even if the cursor hand is the one that clenched
    // (journal of 1 November 21:46, 66 s). It used to be a clutch, so scrolling did not engage.
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 20, { _ in TestHand.fist(at: spot) }, other: { _ in TestHand.open(at: holderSpot) })
    #expect(session.engine.phase == .scrolling)
    #expect(session.moves.isEmpty)

    // The open second hand moves down: the page follows it, the cursor stays put.
    session.feed(frames: 20, { _ in TestHand.fist(at: spot) },
                 other: { TestHand.open(at: CGPoint(x: holderSpot.x, y: holderSpot.y - Double($0) * 0.004)) })
    #expect(session.log.compactMap(\.scrollEvent).map(\.dy).reduce(0, +) > 50)
    #expect(session.moves.isEmpty)

    // The fist is released: the cursor is driven again by the hand that drove it before the scroll.
    session.feed(frames: 15, { _ in TestHand.open(at: spot) }, other: { _ in TestHand.open(at: holderSpot) })
    #expect(session.engine.phase == .hover)
    session.log = []
    session.feed(frames: 20, { TestHand.open(at: CGPoint(x: spot.x - Double($0) * 0.004, y: spot.y)) },
                 other: { _ in TestHand.open(at: holderSpot) })
    #expect(!session.moves.isEmpty)
    #expect(!session.log.contains { $0.scrollEvent != nil })
}

@Test func briefTwoFingerShapeDoesNotScroll() {
    var session = poseScrollSession()
    session.settle(at: spot)
    session.feed(frames: 20) { _ in TestHand.fist(at: spot) }
    // When a fist opens, the hand briefly looks like "two fingers": that is shorter than entering the pose takes.
    session.feed(frames: 6) { TestHand.twoFingers(at: CGPoint(x: spot.x, y: spot.y - Double($0) * 0.004)) }
    session.feed(frames: 20) { _ in TestHand.open(at: CGPoint(x: spot.x, y: spot.y - 0.024)) }
    #expect(!session.phases.contains(.scrolling))
    #expect(!session.log.contains { $0.scrollEvent != nil })
}

@Test func handPoseReadsFistAndTwoFingers() {
    #expect(TestHand.fist(at: spot).fistVote == true)
    #expect(TestHand.open(at: spot).fistVote == false)
    #expect(TestHand.twoFingers(at: spot).twoFingerVote(extended: 1.4, bent: 1.3) == true)
    #expect(TestHand.twoFingersTogether(at: spot).twoFingerVote(extended: 1.4, bent: 1.3) == true)
    #expect(TestHand.open(at: spot).twoFingerVote(extended: 1.4, bent: 1.3) == false)
    #expect(TestHand.fist(at: spot).twoFingerVote(extended: 1.4, bent: 1.3) == false)
    // Tilted fingers don't pass the pose entry check, but they hold an already started scroll.
    #expect(TestHand.tiltedTwoFingers(at: spot).twoFingerVote(extended: 1.4, bent: 1.3) == false)
    #expect(TestHand.tiltedTwoFingers(at: spot).twoFingerHoldVote(extended: 1.4) == true)
    #expect(TestHand.fist(at: spot).twoFingerHoldVote(extended: 1.4) == true)
    #expect(TestHand.open(at: spot).twoFingerHoldVote(extended: 1.4) == false)
}

@Test(arguments: [false, true])
func thumbOnCurledPinkyInScrollPoseIsNotRightClick(oneHandScroll: Bool) {
    var config = GestureConfig()
    config.oneHandScroll = oneHandScroll
    var session = Session(config: config)
    session.settle(at: spot)
    // In the "two fingers" pose the thumb holds the bent ring finger and pinky: this is not a pinky pinch,
    // neither in a scroll nor when the one-hand pose is off and the hand just drives the cursor.
    session.feed(frames: 40) { _ in TestHand.twoFingers(at: spot) }
    session.feed(frames: 10) { _ in TestHand.open(at: spot) }
    #expect(session.buttonEvents.isEmpty)
}

@Test func thumbSlidingOffPinkyAfterTwoFingersIsNotRightClick() {
    var session = Session()
    session.settle(at: spot)
    // The hand opens out of the "two fingers" pose: the pinky straightens while the thumb briefly stays at its tip.
    session.feed(frames: 20) { _ in TestHand.twoFingers(at: spot) }
    session.feed(frames: 12) { _ in TestHand.pinkyPinch(at: spot) }
    session.feed(frames: 25) { _ in TestHand.open(at: spot) }
    #expect(session.buttonEvents.isEmpty)
    // A pinky touch from an open hand is still a right-click.
    session.feed(frames: 15) { _ in TestHand.pinkyPinch(at: spot) }
    #expect(session.buttonEvents == [.rightClick])
}

@Test func twoFingersDoNotScrollByDefault() {
    // One-hand scrolling is off: a hand releasing a pinch looks like "two fingers" (journal 11:47).
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 30) { _ in TestHand.twoFingers(at: spot) }
    session.feed(frames: 20) { TestHand.twoFingers(at: CGPoint(x: spot.x, y: spot.y - Double($0 + 1) * 0.003)) }
    #expect(!session.phases.contains(.scrolling))
    #expect(!session.log.contains { $0.scrollEvent != nil })
    // Such a hand drives the cursor like an open palm.
    #expect(!session.moves.isEmpty)
}

@Test func filteringDropsUnsureJoints() {
    let hand = HandPose(points: [.wrist: .zero, .thumbTip: CGPoint(x: 0.1, y: 0.1)],
                        confidences: [.wrist: 0.9, .thumbTip: 0.2])
    let filtered = hand.filtered(minConfidence: 0.3)
    #expect(filtered[.wrist] != nil)
    #expect(filtered[.thumbTip] == nil)
    #expect(filtered.visibleJointCount == 1)
}

// MARK: - Settings

@Test func savedConfigOfOldVersionKeepsPersonalSettingsAndGetsNewThresholds() throws {
    let stored = #"{"mapping":"relative","speed":1.805,"slowGain":500,"fastGain":3600,"slowSpeed":0.05,"fastSpeed":1.2,"minCutoff":1,"beta":8,"pinchEnter":0.3,"pinchExit":0.45,"pinchConfirmFrames":2,"clickFreeze":0.18,"dragThreshold":10,"releaseHold":0.08,"rightClickMaxDuration":0.4,"scrollThreshold":0.02,"scrollGain":3100,"naturalScroll":false,"momentumDecay":0.12,"momentumMinSpeed":250,"invertX":true,"invertY":false,"activeRegion":[[0.2,0.2],[0.6,0.6]]}"#
    let config = try JSONDecoder().decode(GestureConfig.self, from: Data(stored.utf8))
    #expect(config.speed == 1.805)
    #expect(config.scrollGain == 3100)
    #expect(config.naturalScroll == false)
    #expect(config.pinchEnter == GestureConfig().pinchEnter)
    #expect(config.pinchExit == GestureConfig().pinchExit)
    #expect(config.version == GestureConfig.currentVersion)
}

@Test func savedConfigOfPreviousVersionGetsCurrentThresholds() throws {
    let stored = #"{"version":2,"speed":1.805,"pinchEnter":0.25,"pinchExit":0.42,"rightClickHold":0.9}"#
    let config = try JSONDecoder().decode(GestureConfig.self, from: Data(stored.utf8))
    #expect(config.speed == 1.805)
    #expect(config.pinchEnter == GestureConfig().pinchEnter)
    #expect(config.rightClickHold == GestureConfig().rightClickHold)
}

@Test func configWithMissingFieldsTakesDefaults() throws {
    let stored = #"{"version":3,"speed":1.5,"armDelay":0.5}"#
    let config = try JSONDecoder().decode(GestureConfig.self, from: Data(stored.utf8))
    var expected = GestureConfig()
    expected.speed = 1.5
    expected.armDelay = 0.5
    #expect(config == expected)
}

@Test func configRoundTrips() throws {
    var config = GestureConfig()
    config.speed = 1.805
    config.preferredHand = .left
    config.rightClickHold = 1.1
    let decoded = try JSONDecoder().decode(GestureConfig.self, from: JSONEncoder().encode(config))
    #expect(decoded == config)
}

// MARK: - Hand leaving and returning

@Test func handDroppedOutOfFrameRewindsCursor() {
    var session = Session()
    session.settle(at: spot)
    let dropStart = session.time
    // The hand is lowered (in Vision's frame y decreases), the cursor moves down, then Vision loses the hand.
    session.feed(frames: 10) { TestHand.open(at: CGPoint(x: spot.x, y: spot.y - Double($0 + 1) * 0.02)) }
    #expect(session.moves.reduce(0) { $0 + $1.dy } > 50)
    session.feed(frames: 12) { _ in nil }

    // One rewind to the start of the first move down: the cursor is where the hand began to lower.
    #expect(session.log.compactMap(\.rewindTime) == [dropStart])
    #expect(session.log.last?.rewindTime == dropStart)
    #expect(session.engine.phase == .noHand)
}

@Test func handLeavingSidewaysKeepsCursorWhereItStopped() {
    var session = Session()
    session.settle(at: spot)
    // The hand leaves past the side edge while the cursor is being moved on purpose: that motion is not rewound.
    session.feed(frames: 10) { TestHand.open(at: CGPoint(x: spot.x + Double($0 + 1) * 0.02, y: spot.y)) }
    session.feed(frames: 12) { _ in nil }

    #expect(!session.moves.isEmpty)
    #expect(session.log.allSatisfy { $0.rewindTime == nil })
    #expect(session.engine.phase == .noHand)
}

@Test func briefDropoutWhileMovingNeitherRewindsNorFreezes() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 10) { TestHand.open(at: CGPoint(x: spot.x, y: spot.y - Double($0 + 1) * 0.01)) }
    // Vision loses the hand for a couple of frames on motion blur, although nobody lowered it.
    session.feed(frames: 3) { _ in nil }
    let movesBefore = session.moves.count
    session.feed(frames: 4) { TestHand.open(at: CGPoint(x: spot.x, y: spot.y - 0.14 - Double($0) * 0.01)) }

    #expect(session.log.allSatisfy { $0.rewindTime == nil })
    // The cursor started moving on the second frame after the dropout, without the soft landing pause.
    #expect(session.moves.count > movesBefore)
    #expect(session.engine.phase == .hover)
}

@Test func returningHandHoldsCursorBeforeEasingIn() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 12) { _ in nil }
    #expect(session.engine.phase == .noHand)

    // The hand enters the frame from below and moves quickly up into place: until it slows down, the cursor stays put.
    session.feed(frames: 20) { TestHand.open(at: CGPoint(x: spot.x, y: 0.1 + Double($0) * 0.01)) }
    #expect(session.moves.isEmpty)
    // The hand slowed down: the cursor picks it up, and the gain ramps up smoothly to full.
    session.feed(frames: 20) { TestHand.open(at: CGPoint(x: spot.x, y: 0.3 + Double($0) * 0.002)) }
    #expect(session.moves.count > 5)
    #expect(session.moves.allSatisfy { $0.dy < 0 })
}

@Test func fastReturningHandIsPickedUpAfterMaxHold() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 12) { _ in nil }
    // The hand still moves fast after returning: the cursor waits for it no longer than 0.8 s.
    session.feed(frames: 45) { TestHand.open(at: CGPoint(x: spot.x - Double($0) * 0.012, y: spot.y)) }
    #expect(session.moves.isEmpty)
    session.feed(frames: 15) { TestHand.open(at: CGPoint(x: spot.x - 0.54 - Double($0) * 0.012, y: spot.y)) }
    #expect(!session.moves.isEmpty)
}

@Test func anchorJumpDoesNotFlingCursor() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 10) { TestHand.open(at: CGPoint(x: spot.x - Double($0 + 1) * 0.002, y: spot.y)) }
    // For one frame Vision gave the hand half a frame away, then this one again:
    // a real hand doesn't travel that far in one frame.
    session.log = []
    session.feed(frames: 1) { _ in TestHand.open(at: CGPoint(x: spot.x - 0.5, y: spot.y)) }
    session.feed(frames: 20) { TestHand.open(at: CGPoint(x: spot.x - 0.02 - Double($0) * 0.002, y: spot.y)) }
    #expect(session.moves.allSatisfy { hypot($0.dx, $0.dy) < 20 })
}

@Test func pinchRightAfterHandReturnsIsIgnored() {
    var session = Session()
    session.settle(at: spot)
    session.feed(frames: 12) { _ in nil }
    // A hand entering the frame isn't fully visible, and in the first frames the fingers merge into a "pinch".
    session.feed(frames: 12) { _ in TestHand.pinch(at: spot) }
    session.feed(frames: 10) { _ in TestHand.open(at: spot) }
    #expect(session.buttonEvents.isEmpty)

    // The hand has "settled", the fingers opened: the pinch works again.
    session.feed(frames: 8) { _ in TestHand.pinch(at: spot) }
    session.feed(frames: 6) { _ in TestHand.open(at: spot) }
    #expect(session.clicks == 1)
}

@Test func dragSurvivesHandLeavingFrameAndContinuesOnPinchedReturn() {
    var session = Session()
    session.settle(at: spot)
    session.drag(from: spot)
    #expect(session.engine.phase == .dragging)

    // The hand left the frame for 0.8 s, like repositioning a mouse, and came back pinching
    // in a different place in the frame.
    session.feed(frames: 48) { _ in nil }
    #expect(session.engine.phase == .dragging)
    let movesBefore = session.moves.count
    session.drag(from: CGPoint(x: 0.5, y: spot.y))

    #expect(session.count(.leftUp) == 0)
    #expect(session.engine.phase == .dragging)
    let resumed = session.moves[movesBefore...]
    #expect(!resumed.isEmpty)
    // No jump: the cursor continues from its place in small steps, not leaping by the difference in hand positions.
    #expect(resumed.allSatisfy { $0.dx > 0 && $0.dx < 20 })
}

@Test func dragIsReleasedWhenHandStaysAwayLongerThanASecond() {
    var session = Session()
    session.settle(at: spot)
    session.drag(from: spot)
    session.feed(frames: 54) { _ in nil }
    #expect(session.count(.leftUp) == 0)

    // 1.2 s without the hand in total: release the button so it doesn't stick.
    session.feed(frames: 18) { _ in nil }
    #expect(session.count(.leftUp) == 1)
    #expect(session.engine.phase == .noHand)
}

@Test func dragEndsWhenHandReturnsOpen() {
    var session = Session()
    session.settle(at: spot)
    session.drag(from: spot)
    session.feed(frames: 30) { _ in nil }
    // The first frames of a returned hand are noisy: open fingers are not counted right away.
    session.feed(frames: 5) { _ in TestHand.open(at: spot) }
    #expect(session.count(.leftUp) == 0)

    session.feed(frames: 10) { _ in TestHand.open(at: spot) }
    #expect(session.count(.leftUp) == 1)
    #expect(session.engine.phase == .hover)
}

// MARK: - Two cameras

@Test func handOverToOtherCameraKeepsDragWithoutJump() {
    var session = Session()
    session.settle(at: spot)
    session.drag(from: spot)
    let movesBefore = session.moves.count
    session.handOver()
    // In the other camera's frame the hand is elsewhere entirely, and the drag continues from the cursor's place.
    session.drag(from: CGPoint(x: 0.6, y: 0.7))

    #expect(session.count(.leftUp) == 0)
    #expect(session.engine.phase == .dragging)
    let resumed = session.moves[movesBefore...]
    #expect(!resumed.isEmpty)
    #expect(resumed.allSatisfy { $0.dx > 0 && $0.dx < 20 })
}

@Test func handOverFromHoverRewindsDescentAndLandsSoftly() {
    var session = Session()
    session.settle(at: spot)
    let dropStart = session.time
    // The hand lowers toward the desk and Desk View picks it up.
    session.feed(frames: 6) { TestHand.open(at: CGPoint(x: spot.x, y: spot.y - Double($0 + 1) * 0.02)) }
    session.handOver()
    #expect(session.log.compactMap(\.rewindTime) == [dropStart])

    let movesBefore = session.moves.count
    session.feed(frames: 6) { TestHand.open(at: CGPoint(x: 0.6, y: 0.5 + Double($0) * 0.01)) }
    #expect(session.moves.count == movesBefore)
    #expect(session.engine.phase == .hover)
}

@Test func leaderStaysWhileBothCamerasSeeHandAndSwitchesWhenMainLosesIt() {
    var leader = CameraLeader()
    let hand = TestHand.open(at: spot)
    var time = 0.0
    var switched = false
    for _ in 0..<10 {
        switched = leader.update(source: .main, hand: hand, time: time) || switched
        switched = leader.update(source: .desk, hand: hand, time: time + 0.01) || switched
        time += 1.0 / 30
    }
    #expect(!switched)
    #expect(leader.current == .main)

    // The main camera lost the hand and Desk View sees it: Desk View becomes the leading camera
    // on the third frame, not the first.
    var switches: [Bool] = []
    for _ in 0..<3 {
        _ = leader.update(source: .main, hand: nil, time: time)
        switches.append(leader.update(source: .desk, hand: hand, time: time + 0.01))
        time += 1.0 / 30
    }
    #expect(switches == [false, false, true])
    #expect(leader.current == .desk)
}

@Test func leaderPrefersCameraWhereHandIsNotAtEdge() {
    var leader = CameraLeader()
    // In the main camera the hand is at the bottom edge, in Desk View it is fully visible.
    let atEdge = TestHand.open(at: CGPoint(x: 0.9, y: 0.02))
    let onDesk = TestHand.open(at: CGPoint(x: 0.7, y: 0.4))
    var time = 0.0
    for _ in 0..<3 {
        _ = leader.update(source: .main, hand: atEdge, time: time)
        _ = leader.update(source: .desk, hand: onDesk, time: time + 0.01)
        time += 1.0 / 30
    }
    #expect(leader.current == .desk)
}

@Test func flippedHandMirrorsAcrossFrameWidth() throws {
    let hand = TestHand.open(at: CGPoint(x: 0.5, y: 0.3))
    let flipped = hand.flippedHorizontally()
    let wrist = try #require(flipped[.wrist])
    #expect(abs(wrist.x - (hand.aspect - 0.5)) < 1e-9)
    #expect(wrist.y == 0.3)
    #expect(flipped.chirality == hand.chirality)
}

@Test func handNearBottomEdgeIsReported() {
    #expect(TestHand.open(at: CGPoint(x: 0.9, y: 0.02)).nearestEdge(within: 0.1) == .bottom)
    #expect(TestHand.open(at: CGPoint(x: 0.9, y: 0.4)).nearestEdge(within: 0.1) == nil)
}

@Test func selectorKeepsFollowingTheSameHand() {
    let left = TestHand.open(at: CGPoint(x: 0.5, y: 0.3))
    let right = TestHand.open(at: CGPoint(x: 1.2, y: 0.3))
    var tracker = HandTracker()
    _ = tracker.assign([right], preferred: nil, phase: .hover, time: 0)
    #expect(tracker.assign([left, right], preferred: nil, phase: .hover, time: 0.033).hand == right)
}

@Test func selectorIgnoresChiralityFlipWhileTracking() {
    var tracked = TestHand.open(at: CGPoint(x: 0.5, y: 0.3))
    tracked.chirality = .left  // Vision changed the label mid-tracking
    var other = TestHand.open(at: CGPoint(x: 1.3, y: 0.3))
    other.chirality = .right

    var tracker = HandTracker()
    _ = tracker.assign([tracked], preferred: nil, phase: .hover, time: 0)
    #expect(tracker.assign([tracked, other], preferred: .right, phase: .hover, time: 0.033).hand == tracked)
    var fresh = HandTracker()
    #expect(fresh.assign([tracked, other], preferred: .right, phase: .hover, time: 0).hand == other)
}

// MARK: - Darkness

@Test func inTheDarkLongerDropoutIsStillAFlicker() {
    func run(lowLight: Bool) -> Session {
        var session = Session()
        session.engine.isLowLight = lowLight
        session.settle(at: spot)
        session.feed(frames: 10) { TestHand.open(at: CGPoint(x: spot.x, y: spot.y - Double($0 + 1) * 0.01)) }
        // Vision loses the hand for 0.2 s: in normal light that already counts as the hand leaving,
        // in the dark it is still a flicker.
        session.feed(frames: 12) { _ in nil }
        session.log = []
        session.feed(frames: 4) { TestHand.open(at: CGPoint(x: spot.x, y: spot.y - 0.14 - Double($0) * 0.01)) }
        return session
    }

    let dark = run(lowLight: true)
    #expect(dark.log.allSatisfy { $0.rewindTime == nil })
    #expect(!dark.moves.isEmpty)
    #expect(dark.engine.phase == .hover)
    // In normal light after such a dropout the cursor first stays put: the soft landing is in progress.
    #expect(run(lowLight: false).moves.isEmpty)
}

@Test func inTheDarkPinchNeedsOneMoreFrame() {
    func phase(afterPinchFrames frames: Int, lowLight: Bool) -> GesturePhase {
        var session = Session()
        session.engine.isLowLight = lowLight
        session.settle(at: spot)
        session.feed(frames: frames) { _ in TestHand.pinch(at: spot) }
        return session.engine.phase
    }
    #expect(phase(afterPinchFrames: 6, lowLight: false) == .pinched)
    #expect(phase(afterPinchFrames: 6, lowLight: true) == .hover)
    #expect(phase(afterPinchFrames: 7, lowLight: true) == .pinched)
}

// MARK: - Work area

private let screen = CGSize(width: 1728, height: 1117)

/// The engine knows the cursor, and it sits in the middle of a 16-inch MacBook Pro screen.
private func leashedSession(leash: Double = GestureConfig().leash) -> Session {
    var config = GestureConfig()
    config.leash = leash
    var session = Session(config: config)
    session.screen = screen
    session.cursor = CGPoint(x: screen.width / 2, y: screen.height / 2)
    return session
}

@Test func fastOutSlowBackKeepsCursorNearHand() {
    // Fast to the right and slowly back: with a pure trackpad the cursor drifts right with every loop and hits
    // the edge although the hand returns to its place, and from there it can be driven only by taking the hand
    // past the frame edge.
    func cursorX(leash: Double) -> Double {
        var session = leashedSession(leash: leash)
        session.settle(at: spot)
        for _ in 0..<6 {
            session.feed(frames: 10) { TestHand.open(at: CGPoint(x: 0.9 - Double($0 + 1) * 0.015, y: 0.3)) }
            session.feed(frames: 75) { TestHand.open(at: CGPoint(x: 0.75 + Double($0 + 1) * 0.002, y: 0.3)) }
        }
        return session.cursor.x
    }
    // Without the leash the cursor ends up at the right edge: the last slow stroke moves it off the stop only slightly.
    #expect(cursorX(leash: 0) > 0.9 * screen.width)
    #expect(abs(cursorX(leash: 0.25) - screen.width / 2) < 0.3 * screen.width)
}

@Test func slowSweepReachesScreenEdgeWithHandInFrame() {
    // A slow stroke: a pure trackpad would bring the hand to the frame edge long before the screen edge.
    var session = leashedSession()
    session.settle(at: spot)
    var handX = spot.x
    while session.cursor.x < screen.width - 1, handX > 0 {
        handX -= 0.002
        session.feed(frames: 1) { _ in TestHand.open(at: CGPoint(x: handX, y: spot.y)) }
    }
    #expect(session.cursor.x >= screen.width - 1)
    #expect(handX > 0.2)
}

@Test func stillHandBelowWorkAreaDoesNotDragCursor() {
    // A hand at the bottom of the frame, below the safe zone: the area shifts up and the hand points below the screen.
    // While the hand just trembles in place, the cursor doesn't creep; a stroke down pulls it along without a jump.
    var session = leashedSession()
    let low = CGPoint(x: spot.x, y: -0.06)
    session.settle(at: low)
    let start = session.cursor
    session.feed(frames: 120) { TestHand.open(at: CGPoint(x: low.x, y: low.y + ($0 % 2 == 0 ? 0.0003 : -0.0003))) }
    #expect(abs(session.cursor.y - start.y) < 2)
    session.log = []
    session.feed(frames: 20) { TestHand.open(at: CGPoint(x: low.x, y: low.y - Double($0 + 1) * 0.002)) }
    #expect(session.cursor.y > start.y + 20)
    #expect(session.moves.allSatisfy { $0.dy < 30 })
}

@Test func cursorNeverMovesAgainstHandOnLeash() {
    // The same stroke with and without the leash: a leashed step may be shorter, longer or zero, but never reversed.
    var free = leashedSession(leash: 0)
    var leashed = leashedSession()
    free.settle(at: spot)
    leashed.settle(at: spot)
    let path = (1...8).map { 0.9 - Double($0) * 0.03 } + (1...60).map { 0.66 + Double($0) * 0.001 }
    for x in path {
        free.log = []
        leashed.log = []
        free.feed(frames: 1) { _ in TestHand.open(at: CGPoint(x: x, y: 0.3)) }
        leashed.feed(frames: 1) { _ in TestHand.open(at: CGPoint(x: x, y: 0.3)) }
        let step = free.moves.first ?? .zero
        let held = leashed.moves.first ?? .zero
        #expect(step.dx * held.dx >= 0 && step.dy * held.dy >= 0)
    }
}
