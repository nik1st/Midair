import CoreGraphics
import Foundation

/// Turns a stream of hand poses into mouse actions. Pure logic with no side effects.
///
/// An open palm held still for half a second takes control. The palm drives the cursor, a fist is a clutch
/// (it "lifts the mouse"). A pinch of the thumb with the index or middle finger (this is one gesture: the camera
/// can hardly tell which finger touched the thumb) presses nothing until release or hand travel: release gives a
/// whole click, hand travel with a held pinch gives a drag, a still hold longer than `rightClickHold` gives a
/// right-click. A pinch started while the hand is moving is almost always a false trigger, and travel in the first
/// fraction of a second silently cancels it. Thumb to pinky gives a right-click as soon as the touch is confirmed.
/// A fist of the other hand turns on scrolling: while it is clenched, the first hand scrolls, like fingers on a
/// trackpad. The "two fingers" pose of one hand (`oneHandScroll`, off by default) works the same way: straight
/// fingers touch and the page follows the hand, bent fingers are lifted and the hand can be repositioned. A hand
/// outside the frame is also a clutch: the motion with which it was lowered is rolled back, and the returning
/// hand picks up the cursor smoothly. The cursor is driven like a trackpad but on a leash from the frame's work
/// area: the whole screen is reachable without taking the hand past the edge.
struct GestureEngine {
    var config: GestureConfig {
        didSet { applyFilterSettings() }
    }

    /// The frame is dark (the pipeline decides from brightness): Vision more often loses the hand for a frame
    /// or two, and the joints jitter.
    var isLowLight = false {
        didSet { applyFilterSettings() }
    }

    /// Auto-exposure is at its limit: the exposure is long and a moving hand blurs. Pinch start is stricter.
    var isExposureLimited = false

    /// Where the cursor is now, if the pipeline knows it. Without it the cursor is driven as a pure trackpad,
    /// without a work area.
    var cursor: CursorContext?

    private(set) var phase: GesturePhase = .noHand
    /// The ring at the cursor: how much longer to hold the palm or the pinch.
    private(set) var cue = GestureCue.none
    /// What the engine saw in the last frame.
    private(set) var features = GestureFeatures()
    /// The last frame's decisions in words, for the log: why a pinch started, was cancelled or was not accepted.
    private(set) var notes: [String] = []

    private var filter: OneEuroFilter2D
    private var lastPoint: CGPoint?
    private var lastTime: Double?
    private var scales: [Double] = []
    private var isEngaged = false
    private var engageStart: (time: Double, point: CGPoint)?
    private var lastHandTime: Double?
    private var fistVotes = Votes()
    private var isFist = false
    private var lastFistKnown: Double?
    private var pinchVotes = Votes()
    private var openVotes = Votes()
    private var pinkyVotes = Votes()
    /// A new pinch waits for the fingers to open: after a release, a cancel, a fist, and the hand entering the frame.
    private var needsRearm = false
    private var rearmOpenSince: Double?
    /// Why the pinch was not accepted in the previous frame: only a change of reason is written to the log.
    private var lastBlock: String?
    private var poseSince: Double?
    private var lastPoseTime: Double?
    /// Since which frame the started scroll has seen an open palm.
    private var poseBrokenSince: Double?
    private var gestureStart: Double = 0
    /// Where the hand's anchor was at the start of the pinch: travel is measured from it.
    private var gestureOrigin: CGPoint?
    /// The hand's speed at the moment the pinch was counted.
    private var startSpeed: Double = 0
    /// Scroll fingers "on the trackpad": straight index and middle scroll with the hand's travel, bent ones are lifted.
    private var isTouching = false
    /// Hand travel since the touch began, until the scroll axis is decided.
    private var scrollTravel = CGVector.zero
    private var scrollAxis: ScrollAxis?
    /// The axis of the last stroke: a touch started right after the scrolling hand returns follows it.
    private var strokeAxis: ScrollAxis?
    /// Hand travel over the last fraction of a second while the touch runs sideways: it releases the axis to vertical.
    private var axisProbe = CGVector.zero
    /// Scroll speed in pixels per second: the page coasts on it after the fingers are lifted.
    private var scrollVelocity = CGVector.zero
    private var twoHands = TwoHands()
    private var momentum: CGVector?
    private var momentumStarted = false
    private var momentumTime: Double = 0
    private var holdUntil: Double = 0
    private var lostSince: Double?
    private var anchorOffsets: [HandJoint: CGVector] = [:]
    /// Cursor movements in `hover` over the last fraction of a second: rolled back if the hand left the frame.
    private var recentMoves: [(time: Double, step: CGVector)] = []
    /// When the hand returned to the frame: the soft landing is counted from this moment.
    private var landingStart: Double?
    /// When the returned hand slowed down: the gain grows from this moment.
    private var landingSettled: Double?
    /// The previous frame's anchor before the filter: it reveals a jump to another hand.
    private var lastAnchor: CGPoint?
    /// The hand's work area in the frame: the hand's place in it corresponds to the cursor's place on the screen.
    /// Re-established when the cursor starts following the hand again.
    private var workArea: CGRect?
    /// Since when the fingertips of the held pinch have not been visible.
    private var tipsMissingSince: Double?
    /// Since when the fingers of the held pinch have been apart beyond the press threshold.
    private var looseSince: Double?

    /// How long to remember cursor movements, and how many seconds before the hand leaves to roll them back.
    private static let rollbackMemory = 0.3
    private static let rollbackWindow = 0.2
    /// Soft landing: after the hand returns, the cursor stays put while the hand moves into the frame (faster than
    /// `landingSettleSpeed`, S/s), but for no less than `landingFreeze` and no longer than `landingMaxHold`; then the
    /// gain ramps up to full over `landingRamp`. In the logs of November 1 an entering hand moves at 8-29 S/s and
    /// slows below 3 S/s after 0.15-0.8 s, while the cursor is driven slower than 3 S/s in 95% of frames.
    private static let landingFreeze = 0.12
    private static let landingSettleSpeed = 3.0
    private static let landingMaxHold = 0.8
    private static let landingRamp = 0.15
    /// A scrolling hand has settled only if it stays slower than `landingSettleSpeed` for this many seconds in a row:
    /// a hand entering over the edge slows down for a frame and then moves inward again (log 21:46, 68.3 s),
    /// and the page scrolled backward.
    private static let scrollerCalm = 0.06
    /// For how many seconds after the scrolling hand returns the touch takes the axis of the previous stroke: when
    /// entering the frame the hand often moves sideways, and the axis used to be decided by that travel
    /// (log 21:46, 33.8 and 52.3 s).
    private static let axisCarry = 1.0
    /// A touch that went sideways switches to vertical when, over the last `axisProbeWindow` seconds, the hand has
    /// moved vertically by more than this (in frame heights) and twice as far as sideways. The axis is decided by
    /// the first 0.01 of travel, and jitter used to lock it sideways for the whole touch (log 22:10, 102.8 s:
    /// 6 s sideways while the hand moved up and down).
    private static let axisUnlock = 0.03
    private static let axisProbeWindow = 0.3
    /// An anchor jump per frame farther than this (in frame heights) is another hand or a Vision glitch, not movement:
    /// per the logs a real hand covers at most 0.12 per frame, while the jumps were 0.24-1.5.
    private static let jumpGate = 0.15
    /// For how long after the "two fingers" pose a pinky touch doesn't count as a right-click.
    private static let poseRelease = 0.3
    /// Hand speeds (S/s) between which the leash turns on: a still hand jitters at 0.05-0.15 S/s.
    private static let leashStill = 0.15
    private static let leashMoving = 0.4
    /// Frame votes are kept with a margin for the longest window.
    private static let voteMemory = 0.4
    /// How many seconds before a right-click the ring at the cursor grows as the pinch is held.
    private static let ringLead = 0.6
    private static let anchorJoints: [HandJoint] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]

    init(config: GestureConfig = GestureConfig()) {
        self.config = config
        filter = OneEuroFilter2D(minCutoff: config.minCutoff, beta: config.beta)
    }

    /// Resets the state without emitting any actions, including the taken control. The caller must release the
    /// buttons (for example, on a pause for the keyboard: after typing, control is taken again with the palm).
    mutating func reset() {
        phase = .noHand
        cue = .none
        notes = []
        filter.reset()
        lastPoint = nil
        lastTime = nil
        scales = []
        isEngaged = false
        engageStart = nil
        lastHandTime = nil
        fistVotes.clear()
        isFist = false
        lastFistKnown = nil
        pinchVotes.clear()
        openVotes.clear()
        pinkyVotes.clear()
        needsRearm = false
        rearmOpenSince = nil
        lastBlock = nil
        poseSince = nil
        lastPoseTime = nil
        poseBrokenSince = nil
        gestureOrigin = nil
        isTouching = false
        twoHands = TwoHands()
        momentum = nil
        momentumStarted = false
        lostSince = nil
        anchorOffsets = [:]
        recentMoves = []
        landingStart = nil
        landingSettled = nil
        lastAnchor = nil
        workArea = nil
        tipsMissingSince = nil
        looseSince = nil
    }

    /// `other` is the second hand in the frame, if there is one: its fist holds a two-hand scroll.
    mutating func process(hand: HandPose?, other: HandPose? = nil, time: Double) -> [PointerAction] {
        notes = []
        var actions = coast(until: time)
        if let scrolled = twoHandScroll(hand: hand, other: other, time: time) {
            workArea = nil
            // We don't compare the anchor before the scroll with the one after it: it is not a per-frame jump.
            lastAnchor = nil
            updateCue(at: time)
            return actions + scrolled
        }

        guard let hand, let size = hand.blendedScale, let point = Self.stableAnchor(of: hand, offsets: &anchorOffsets) else {
            features = GestureFeatures()
            actions += handMissing(at: time)
            updateCue(at: time)
            return actions
        }
        lastHandTime = time
        if let since = lostSince {
            // After a miss we continue from the hand's new position, without a cursor jump.
            lostSince = nil
            filter.reset()
            lastPoint = nil
            lastTime = nil
            // The hand left the frame rather than flickering on blur: bring it back gently.
            if time - since >= dropoutTolerance { land(at: time) }
        } else if phase == .noHand {
            // The hand entered the frame: for the first frames it is not fully visible, and it is still moving.
            land(at: time)
        } else if let last = lastAnchor, hypot(point.x - last.x, point.y - last.y) > Self.jumpGate {
            // A hand doesn't travel that far in one frame: it is another hand or a Vision glitch.
            // Continue from the new position softly.
            filter.reset()
            lastPoint = nil
            lastTime = nil
            land(at: time)
            notes.append("jump")
        }
        lastAnchor = point

        let smoothed = filter.filter(point, time: time)
        let delta = lastPoint.map { CGVector(dx: smoothed.x - $0.x, dy: smoothed.y - $0.y) } ?? .zero
        let dt = lastTime.map { max(time - $0, 1.0 / 240) } ?? 1.0 / 30
        let wasTracking = lastPoint != nil
        lastPoint = smoothed
        lastTime = time

        let scale = medianScale(adding: size)
        let reading = read(hand, scale: scale, speed: hypot(delta.dx, delta.dy) / dt / scale, at: time)
        if wasTracking { updateLanding(speed: reading.speed, at: time) }

        switch phase {
        case .noHand, .standby, .hover, .clutch:
            actions += idle(reading, delta: delta, dt: dt, at: smoothed, scale: scale, aspect: hand.aspect,
                            wasTracking: wasTracking, time: time)
        case .pinched:
            actions += pinched(reading, at: smoothed, scale: scale, time: time)
        case .dragging:
            actions += dragging(reading, delta: delta, dt: dt, at: smoothed, scale: scale, aspect: hand.aspect, time: time)
        case .scrolling:
            actions += scrolling(reading, delta: delta, dt: dt, time: time)
        }
        updateCue(at: time)
        return actions
    }

    /// The hand moved into the frame of the other camera ("Two cameras" mode). Coordinates there are different, so
    /// we continue from the hand's new position with a soft landing, as after a return. The gesture phase doesn't
    /// change: a drag is not dropped, and from `hover` we roll back the motion with which the hand moved to the
    /// other camera.
    mutating func handOver(at time: Double) -> [PointerAction] {
        let actions = phase == .hover ? rollback() : []
        filter.reset()
        lastPoint = nil
        lastTime = nil
        lostSince = nil
        anchorOffsets = [:]
        lastAnchor = nil
        recentMoves = []
        scales = []
        engageStart = nil
        // From here on, pinch travel is measured from the hand's position in the new frame.
        gestureOrigin = nil
        workArea = nil
        if phase != .noHand {
            landingStart = time
            landingSettled = nil
        }
        return actions
    }

    // MARK: - Frame without a hand

    private mutating func handMissing(at time: Double) -> [PointerAction] {
        // The hand has been gone for long: control must be taken again. A held button is not dropped,
        // `dragGrace` will release it.
        if isEngaged, config.requiresEngagement, !phase.isActive, let lastHandTime,
           time - lastHandTime >= config.disengageAfter {
            isEngaged = false
            notes.append("disengage")
        }
        // Vision loses the hand for a frame or two at the frame edge and on blur: we don't drop the state right away.
        let since = lostSince ?? time
        lostSince = since
        if time - since < lossTolerance { return [] }
        let actions = finishGesture(at: time)
        phase = .noHand
        filter.reset()
        lastPoint = nil
        lastTime = nil
        scales = []
        lostSince = nil
        lastAnchor = nil
        recentMoves = []
        tipsMissingSince = nil
        looseSince = nil
        gestureOrigin = nil
        engageStart = nil
        return actions
    }

    /// The hand vanished mid-gesture. The button is not pressed before a drag, so the pinch is cancelled silently;
    /// during a drag we release the button so that it doesn't stick. From `hover` we roll back the motion with which
    /// the hand was leaving.
    private mutating func finishGesture(at time: Double) -> [PointerAction] {
        switch phase {
        case .pinched:
            notes.append("cancel: hand lost")
            return []
        case .dragging:
            notes.append("release: hand lost")
            return [.leftUp]
        case .scrolling:
            return lift(at: time)
        case .hover:
            return rollback()
        case .noHand, .standby, .clutch:
            return []
        }
    }

    private mutating func land(at time: Double) {
        landingStart = time
        landingSettled = nil
        workArea = nil
        needsRearm = true
        rearmOpenSince = nil
    }

    // MARK: - Frame features

    private enum Pinch {
        /// The gap is below the press threshold, between the thresholds, above the release threshold,
        /// or the fingertips are not visible.
        case closed, between, open, unknown
    }

    private struct Reading {
        var pinch: Pinch
        /// The pinch and pinky gaps in S. A curled pinky doesn't count: in a fist and in the "two fingers" pose
        /// the thumb rests on it.
        var gap: Double?
        var pinkyGap: Double?
        /// The pinky is curled (`true`), extended (`false`) or its tip is not visible (`nil`).
        var pinkyCurled: Bool?
        /// The thumb touches the pinky, and the pinky is noticeably closer to it than the index and middle fingers.
        /// `nil` if the pinky is not visible.
        var pinkyPinch: Bool?
        var fist: Bool?
        var twoFingers: Bool?
        var twoFingersHold: Bool?
        /// The index and middle fingers are straight (`true`) or at least one is curled (`false`):
        /// the scroll "touch" and "lift".
        var fingersStraight: Bool?
        var speed: Double
        var fingerLength: Double?
    }

    private mutating func read(_ hand: HandPose, scale: Double, speed: Double, at time: Double) -> Reading {
        // For a pinch the index and middle fingers count as one finger: we take the one the thumb is closer to.
        let gaps: [(HandJoint, Double)] = [HandJoint.indexTip, .middleTip].compactMap { tip in
            hand.distance(.thumbTip, tip).map { (tip, $0 / scale) }
        }
        let nearest = gaps.min { $0.1 < $1.1 }
        let finger: Finger? = switch nearest?.0 {
        case .indexTip?: .index
        case .middleTip?: .middle
        default: nil
        }
        let pinkyCurled = hand.isCurled(tip: .littleTip, pip: .littlePIP)
        let pinkyGap = pinkyCurled == false ? hand.distance(.thumbTip, .littleTip).map { $0 / scale } : nil
        let fist = hand.fistVote
        let twoFingers = hand.twoFingerVote(extended: config.extendedRatio, bent: config.bentRatio)
        let twoFingersHold = hand.twoFingerHoldVote(extended: config.extendedRatio)
        // In an ordinary pinch the pinky is no closer than 0.34 palm sizes to the thumb (log of November 1),
        // so there is nothing to mistake it for.
        let pinkyPinch = pinkyGap.map { gap in
            gap < config.pinchEnter && gap < (nearest?.1 ?? .infinity) - config.pinkyMargin
        }
        let fingersStraight: Bool? = switch (hand.isCurled(tip: .indexTip, pip: .indexPIP), hand.isCurled(tip: .middleTip, pip: .middlePIP)) {
        case (false?, false?): true
        case (true?, _), (_, true?): false
        default: nil
        }
        let reading = Reading(
            pinch: state(nearest?.1),
            gap: nearest?.1,
            pinkyGap: pinkyGap,
            pinkyCurled: pinkyCurled,
            pinkyPinch: pinkyPinch,
            fist: fist,
            twoFingers: twoFingers,
            twoFingersHold: twoFingersHold,
            fingersStraight: fingersStraight,
            speed: speed,
            fingerLength: finger.flatMap { hand.distance($0.tip, $0.mcp) }.map { $0 / scale }
        )
        features = GestureFeatures(scale: scale, gap: nearest?.1, finger: nearest?.0, speed: speed, travel: nil,
                                   fingerLength: reading.fingerLength, edgeRatio: hand.edgeRatio,
                                   fist: fist, twoFingers: twoFingers, pinkyGap: pinkyGap, twoFingersHold: twoFingersHold)

        fistVotes.add(fist, at: time, keeping: Self.voteMemory)
        pinchVotes.add(reading.pinch == .unknown ? nil : reading.pinch == .closed, at: time, keeping: Self.voteMemory)
        openVotes.add(reading.pinch == .unknown ? nil : reading.pinch == .open, at: time, keeping: Self.voteMemory)
        pinkyVotes.add(pinkyPinch, at: time, keeping: Self.voteMemory)
        updateRearm(reading, at: time)
        updateFist(fist, at: time)
        if twoFingers == true {
            poseSince = poseSince ?? time
        } else if twoFingers == false {
            poseSince = nil
        }
        // A started scroll is kept by the soft pose check, while only the strict check can start it.
        if twoFingers == true || (phase == .scrolling && twoFingersHold == true) { lastPoseTime = time }
        if phase == .scrolling, twoFingersHold == false {
            poseBrokenSince = poseBrokenSince ?? time
        } else if twoFingersHold == true {
            poseBrokenSince = nil
        }
        return reading
    }

    private func state(_ gap: Double?) -> Pinch {
        switch gap {
        case nil: .unknown
        case let gap? where gap < config.pinchEnter: .closed
        case let gap? where gap > config.pinchExit: .open
        default: .between
        }
    }

    /// A new pinch is accepted only after the fingers have been open: otherwise fingers that haven't moved apart after
    /// a release or cancel would press again immediately. Fingers count as open when farther than the midpoint between
    /// the thresholds: after a click the hand is relaxed, and the fingers don't always spread to the release threshold.
    /// A missing pinky tip does not advance the count: pressed against the thumb it is often invisible, and otherwise
    /// one right-click would produce two.
    private mutating func updateRearm(_ reading: Reading, at time: Double) {
        let apart = (config.pinchEnter + config.pinchExit) / 2
        let fingersApart = reading.gap.map { $0 > apart }
        let pinkyApart: Bool? = switch reading.pinkyCurled {
        case true?: true
        case false?: reading.pinkyGap.map { $0 > apart }
        case nil: nil
        }
        if fingersApart == false || pinkyApart == false {
            rearmOpenSince = nil
        } else if fingersApart == true, pinkyApart == true {
            let since = rearmOpenSince ?? time
            rearmOpenSince = since
            if needsRearm, time - since >= config.rearmOpen { needsRearm = false }
        }
    }

    /// A fist is decided by frame voting: a single frame with a straight finger read or a missing joint
    /// doesn't take us out of the fist (in the log the phase flipped 13 times in 0.9 s and the cursor traveled 102 pt).
    private mutating func updateFist(_ vote: Bool?, at time: Double) {
        if vote != nil { lastFistKnown = time }
        if isFist {
            let unknownTooLong = lastFistKnown.map { time - $0 >= config.fistUnknownHold } ?? true
            if unknownTooLong || (fistVotes.share(within: config.fistExit, at: time) ?? 1) <= 0.25 {
                isFist = false
                // Opening a fist, the fingers pass by the thumb: a pinch counts only after the fingers have been open.
                needsRearm = true
                rearmOpenSince = nil
            }
        } else if vote == true, (fistVotes.share(within: config.fistEnter, at: time) ?? 0) >= 0.8 {
            isFist = true
        }
    }

    /// Why a pinch can't start right now, or `nil`. These checks are for starting only: a drag that has begun
    /// moves and is released at any speed.
    private func startBlock(_ reading: Reading, pinky: Bool, at time: Double) -> String? {
        if isSettling(at: time) { return "landing" }
        if needsRearm { return "rearm" }
        let limited = isExposureLimited || isLowLight
        if reading.speed > (limited ? config.limitedPinchStartSpeed : config.pinchStartSpeed) { return "speed" }
        if !pinky, let length = reading.fingerLength, length < config.minFingerLength { return "finger" }
        // In the "two fingers" pose the thumb holds the curled ring finger and pinky and, when the hand opens,
        // slides off the pinky: in the 11:47 log this produced a right-click while the one-hand pose was off.
        if pinky, let pose = lastPoseTime, time - pose < Self.poseRelease { return "after two fingers" }
        return nil
    }

    /// A pinch must hold for three quarters of the frames in the confirmation window: otherwise the thumb, on its way
    /// somewhere else, manages to "click". In the dark and with long exposure the window is one frame longer.
    private func confirmed(_ votes: Votes, at time: Double) -> Bool {
        let extra = isLowLight || isExposureLimited ? config.lowLightConfirmExtra : 0
        return (votes.share(within: config.pinchConfirm + extra, at: time) ?? 0) >= 0.75
    }

    // MARK: - Phases

    private mutating func idle(_ reading: Reading, delta: CGVector, dt: Double, at point: CGPoint, scale: Double,
                               aspect: Double, wasTracking: Bool, time: Double) -> [PointerAction] {
        defer { if phase != .hover { recentMoves = [] } }

        if !isEngaged, config.requiresEngagement {
            phase = .standby
            workArea = nil
            guard engage(reading, at: point, scale: scale, time: time) else { return [] }
            notes.append("engage")
            // A pose shown before control is taken does not start scrolling.
            poseSince = nil
        }
        isEngaged = true

        if isFist {
            // A fist repositions the hand without touching the cursor: the work area will be set where the hand opens.
            phase = .clutch
            workArea = nil
            return []
        }
        let wasHover = phase == .hover
        phase = .hover
        // The frame looks like a fist, but the fist is not confirmed yet: the cursor stays put,
        // and a pinch doesn't start from a closing hand.
        if reading.fist == true { return [] }

        if config.oneHandScroll, let since = poseSince, time - since >= config.scrollPoseEnter,
           reading.speed < config.scrollPoseSpeed {
            var actions: [PointerAction] = []
            stopCoasting(&actions)
            phase = .scrolling
            gestureStart = time
            isTouching = false
            poseBrokenSince = nil
            workArea = nil
            notes.append("scroll pose")
            return actions
        }

        // The pinky is checked first: a thumb reaching for it passes close to the index and middle fingers.
        let isPinky = reading.pinkyPinch == true
        if isPinky || reading.pinch == .closed {
            let block = startBlock(reading, pinky: isPinky, at: time)
            if let block, block != lastBlock { notes.append("pinch blocked: \(block)") }
            lastBlock = block
            if block == nil {
                // A pinch candidate: the cursor stays put so the click doesn't drift off the target.
                guard confirmed(isPinky ? pinkyVotes : pinchVotes, at: time) else { return [] }
                var actions: [PointerAction] = []
                stopCoasting(&actions)
                if isPinky { return actions + pinkyRightClick(at: time) }
                phase = .pinched
                gestureStart = time
                gestureOrigin = point
                startSpeed = reading.speed
                tipsMissingSince = nil
                looseSince = nil
                notes.append("pinch")
                return actions
            }
        } else {
            lastBlock = nil
        }

        // The first frame after a fist or taking control doesn't move the cursor:
        // it still contains the shift from the pose change.
        guard wasHover, wasTracking, time >= holdUntil else { return [] }
        let moves = pointerMove(delta, dt: dt, at: point, scale: scale, aspect: aspect, time: time)
        remember(moves, at: time)
        return moves
    }

    /// Control is taken by an open palm held still for `engageHold`. Missing fingertips don't reset the count:
    /// Vision loses them in every third or fourth frame.
    private mutating func engage(_ reading: Reading, at point: CGPoint, scale: Double, time: Double) -> Bool {
        let palm = !isFist && reading.pinch != .closed && reading.pinch != .between
        guard palm else {
            engageStart = nil
            return false
        }
        if let start = engageStart, hypot(point.x - start.point.x, point.y - start.point.y) <= config.engageDrift * scale {
            return time - start.time >= config.engageHold
        }
        engageStart = (time, point)
        return false
    }

    /// A thumb-to-pinky right-click goes out as soon as the touch is confirmed: a pinky pressed against the thumb is
    /// covered by it, Vision often loses its tip, and waiting for the release would mean losing the click.
    private mutating func pinkyRightClick(at time: Double) -> [PointerAction] {
        notes.append("pinky right click")
        endGesture(at: time)
        return [.rightClick]
    }

    private mutating func pinched(_ reading: Reading, at point: CGPoint, scale: Double, time: Double) -> [PointerAction] {
        let elapsed = time - gestureStart
        let origin = gestureOrigin ?? point
        gestureOrigin = origin
        let travel = hypot(point.x - origin.x, point.y - origin.y) / scale
        features.travel = travel

        // The thumb was heading to the pinky and brushed the index finger on the way: the pinch has pressed
        // nothing yet, so this is a right-click.
        if reading.pinkyPinch == true, confirmed(pinkyVotes, at: time) { return pinkyRightClick(at: time) }

        // Fingertips are not visible: the pinch holds briefly, then is cancelled silently.
        // The button is not pressed, so there is nothing to release.
        guard reading.pinch != .unknown else {
            let since = tipsMissingSince ?? time
            tipsMissingSince = since
            if time - since >= config.pinchTipGrace { cancel("cancel: tips hidden", at: time) }
            return []
        }
        tipsMissingSince = nil

        // A returned hand is not fully visible in the first frames: fingers that look open in them
        // are not yet a reason to decide.
        if !isSettling(at: time), released(reading.pinch, votes: openVotes, at: time, acceptsLoose: true) {
            endGesture(at: time)
            if elapsed >= config.rightClickHold {
                notes.append("right click")
                return [.rightClick]
            }
            notes.append("click")
            // The whole click at the moment of release: the cursor stayed where the pinch began all this time.
            return [.leftDown, .leftUp]
        }
        // A pinch started while the hand is moving is almost always a false trigger:
        // if the hand keeps going, it is cancelled without events.
        if startSpeed > config.stillSpeed, elapsed < config.armDelay, travel > config.cancelTravel {
            cancel("cancel: travel", at: time)
            return []
        }
        guard travel > config.dragTravel else { return [] }
        // The drag starts from where the cursor froze, without a jump over the travel already covered.
        phase = .dragging
        notes.append("drag")
        return [.leftDown]
    }

    private mutating func dragging(_ reading: Reading, delta: CGVector, dt: Double, at point: CGPoint, scale: Double,
                                   aspect: Double, time: Double) -> [PointerAction] {
        if reading.pinch == .unknown {
            // Fingertips are not visible (blur, hand rotation): keep dragging, but not for long,
            // otherwise the button stays down for as long as the hand is in the frame.
            let since = tipsMissingSince ?? time
            tipsMissingSince = since
            if time - since >= config.dragTipGrace {
                notes.append("release: tips hidden")
                endGesture(at: time)
                return [.leftUp]
            }
        } else {
            tipsMissingSince = nil
            // During a drag only a fully open pinch releases: half-open fingers keep dragging.
            if !isSettling(at: time), released(reading.pinch, votes: openVotes, at: time, acceptsLoose: false) {
                notes.append("release")
                endGesture(at: time)
                return [.leftUp]
            }
        }
        return pointerMove(delta, dt: dt, at: point, scale: scale, aspect: aspect, time: time)
    }

    /// The "two fingers" pose works like a trackpad and like the cursor with a fist: straight index and middle
    /// fingers "touch" and the page follows the hand (the palm, not the fingertips), bent fingers are "lifted" and
    /// the hand can be moved back, and after a fast movement the page coasts on momentum. An open palm ends the scroll.
    /// In live testing, a page that followed the fingertips slid back every time the fingers came back
    /// and every time the palm opened: the fingers rise while the palm barely moves.
    private mutating func scrolling(_ reading: Reading, delta: CGVector, dt: Double, time: Double) -> [PointerAction] {
        let opened = poseBrokenSince.map { time - $0 >= config.scrollPoseExit } ?? false
        let lost = lastPoseTime.map { time - $0 >= config.scrollGrace } ?? true
        if opened || lost {
            notes.append("scroll end")
            let actions = lift(at: time)
            // After a scroll a pinch doesn't wait for the fingers to open: the scroll wasn't a pinch, and a click
            // right after it was blocked in live testing.
            endGesture(at: time, rearm: false)
            return actions
        }
        // The palm is opening: this frame no longer scrolls.
        guard reading.twoFingersHold != false else { return lift(at: time) }
        switch reading.fingersStraight {
        case false?: return lift(at: time)
        case nil where !isTouching: return []
        default: break
        }

        return touchScroll(delta, dt: dt, time: time)
    }

    /// Hand travel while the fingers are "on the trackpad": starts the touch, decides the axis from the first
    /// noticeable travel, and scrolls.
    private mutating func touchScroll(_ delta: CGVector, dt: Double, time: Double,
                                      carriedAxis: ScrollAxis? = nil) -> [PointerAction] {
        var actions: [PointerAction] = []
        if !isTouching {
            // The fingers are "on the trackpad" again: the momentum of the previous stroke stops,
            // as it does on a real trackpad touch.
            stopCoasting(&actions)
            isTouching = true
            scrollTravel = .zero
            scrollAxis = nil
            scrollVelocity = .zero
            axisProbe = .zero
            notes.append("scroll touch")
        }
        guard let axis = scrollAxis else {
            // The axis is decided by the first noticeable travel: vertical unless the travel is clearly sideways.
            // `carriedAxis` is the axis of the previous stroke when the touch began right after the hand returned.
            scrollTravel.dx += delta.dx
            scrollTravel.dy += delta.dy
            guard hypot(scrollTravel.dx, scrollTravel.dy) >= 0.01 else { return actions }
            let axis: ScrollAxis = carriedAxis ?? (abs(scrollTravel.dx) > abs(scrollTravel.dy) * 2 ? .horizontal : .vertical)
            scrollAxis = axis
            strokeAxis = axis
            return actions + [scroll(scrollTravel, dt: max(time - gestureStart, dt), axis: axis, phase: .began)]
        }
        if axis == .horizontal {
            let keep = exp(-dt / Self.axisProbeWindow)
            axisProbe = CGVector(dx: axisProbe.dx * keep + delta.dx, dy: axisProbe.dy * keep + delta.dy)
            if abs(axisProbe.dy) >= Self.axisUnlock, abs(axisProbe.dy) > abs(axisProbe.dx) * 2 {
                // The hand has clearly gone vertical: the sideways axis was accidental.
                scrollAxis = .vertical
                strokeAxis = .vertical
                notes.append("axis vertical")
                return actions + [scroll(delta, dt: dt, axis: .vertical, phase: .changed)]
            }
        }
        return actions + [scroll(delta, dt: dt, axis: axis, phase: .changed)]
    }

    // MARK: - Two-hand scrolling

    /// A fist of one hand holds the scroll, like a held key, while the other hand scrolls, like fingers on a trackpad:
    /// an open palm "touches" and the page follows it, a fist "lifts" it so it can be repositioned.
    /// The scrolling hand may jump out of the frame: the mode holds while the other hand's fist is in the frame.
    /// An opened fist gives the cursor back. `nil` if the mode is not on: then the frame is handled by the normal
    /// gesture layout.
    private mutating func twoHandScroll(hand: HandPose?, other: HandPose?, time: Double) -> [PointerAction]? {
        guard twoHands.isActive else {
            guard startTwoHandScroll(hand: hand, other: other, time: time) else { return nil }
            var actions: [PointerAction] = []
            stopCoasting(&actions)
            return actions
        }
        if hand != nil || other != nil { lastHandTime = time }
        // Hand roles are kept by position: the pipeline's leading-hand choice can swap them.
        func distance(_ point: CGPoint?, _ center: CGPoint) -> Double {
            point.map { hypot($0.x - center.x, $0.y - center.y) } ?? .infinity
        }
        var holder: HandPose?
        var scroller: HandPose?
        for pose in [hand, other].compactMap({ $0 }) {
            guard let center = pose.center else { continue }
            if holder == nil, distance(twoHands.holderCenter, center) <= distance(twoHands.scrollerCenter, center) {
                holder = pose
                twoHands.holderCenter = center
            } else if scroller == nil {
                scroller = pose
                twoHands.scrollerCenter = center
            }
        }

        if let holder {
            twoHands.holderSeen = time
            switch holder.fistVote {
            case true?: twoHands.holderOpenSince = nil
            case false?: twoHands.holderOpenSince = twoHands.holderOpenSince ?? time
            case nil: break
            }
        }
        let opened = twoHands.holderOpenSince.map { time - $0 >= config.scrollPoseExit } ?? false
        if opened || time - twoHands.holderSeen >= config.scrollGrace {
            notes.append("two hands end")
            let actions = lift(at: time)
            twoHands = TwoHands()
            phase = .hover
            // The cursor continues from the hand's new position, without a jump.
            filter.reset()
            lastPoint = nil
            lastTime = nil
            landingStart = time
            landingSettled = nil
            return actions
        }

        // A scrolling hand without the palm base (only a few points are visible at the frame edge) counts as gone,
        // the same as a missing one: otherwise points flickering at the edge reset the count, and the hand that came
        // in scrolled without a landing (log 21:46, 68.2 s).
        let anchor = scroller.flatMap { Self.stableAnchor(of: $0, offsets: &twoHands.anchorOffsets) }
        if anchor == nil {
            twoHands.outSince = twoHands.outSince ?? time
        } else if let since = twoHands.outSince {
            twoHands.outSince = nil
            if time - since >= dropoutTolerance {
                // The scrolling hand is back in the frame and still moving inward: until it settles the fingers
                // are "lifted" and momentum carries on. Otherwise the hand entering scrolled the page backward
                // and cut the momentum short.
                twoHands.landingStart = time
                twoHands.landingSettled = nil
                twoHands.slowSince = nil
                twoHands.filter.reset()
                twoHands.lastPoint = nil
            }
        }
        // The scrolling hand left the frame or clenched into a fist: the fingers are "lifted".
        guard let scroller, scroller.fistVote != true else {
            twoHands.lastPoint = nil
            return lift(at: time)
        }
        guard let anchor else {
            // We ride out a short miss of the base without breaking the touch: the center of all points sits
            // 0.3-0.7 S above the base, and switching to it made the page jerk by up to 600 px per frame.
            // A long miss means the hand has left.
            guard let since = twoHands.outSince, time - since >= dropoutTolerance else { return [] }
            twoHands.lastPoint = nil
            return lift(at: time)
        }
        let point = twoHands.filter.filter(anchor, time: time)
        defer { twoHands.lastPoint = (point, time) }
        guard let previous = twoHands.lastPoint else { return [] }
        let delta = CGVector(dx: point.x - previous.point.x, dy: point.y - previous.point.y)
        let dt = max(time - previous.time, 1.0 / 240)
        if let start = twoHands.landingStart, twoHands.landingSettled == nil {
            let speed = hypot(delta.dx, delta.dy) / dt / (scroller.blendedScale ?? 0.14)
            twoHands.slowSince = speed < Self.landingSettleSpeed ? twoHands.slowSince ?? time : nil
            let calm = twoHands.slowSince.map { time - $0 >= Self.scrollerCalm } ?? false
            guard Self.hasSettled(calm: calm, after: time - start) else { return [] }
            twoHands.landingSettled = time
        }
        let justReturned = twoHands.landingStart.map { time - $0 < Self.axisCarry } ?? false
        return touchScroll(delta, dt: dt, time: time, carriedAxis: justReturned ? strokeAxis : nil)
    }

    /// The mode turns on when control is taken, no gesture has started, one hand is clenched into a fist and holds it
    /// for `scrollPoseEnter`, and the other hand is not a fist. The clenched hand holds the fist and the open one
    /// scrolls, and which of them was driving the cursor does not matter: in live testing the fist was clenched
    /// sometimes with one hand and sometimes with the other (log of November 1 21:46, 66 s), whereas before, a fist
    /// on the leading hand with the other hand open was a clutch and scrolling did not turn on.
    /// The cursor does not move meanwhile: while votes accumulate, the leading hand still drives it, and when the fist
    /// is released the cursor goes back to the same hand.
    private mutating func startTwoHandScroll(hand: HandPose?, other: HandPose?, time: Double) -> Bool {
        let swapped = hand?.fistVote == true && other?.fistVote == false
        let (scroller, holder) = swapped ? (other, hand) : (hand, other)
        guard let scroller, let holder, let center = holder.center, isEngaged || !config.requiresEngagement,
              phase == .hover || phase == .clutch, scroller.fistVote != true else {
            twoHands.holdVotes.clear()
            twoHands.holderCenter = nil
            return false
        }
        // Votes accumulate for one and the same hand: if the fist hand changed, start counting over.
        if let last = twoHands.holderCenter, hypot(center.x - last.x, center.y - last.y) > 0.15 { twoHands.holdVotes.clear() }
        twoHands.holderCenter = center
        twoHands.holdVotes.add(holder.fistVote, at: time, keeping: Self.voteMemory)
        guard holder.fistVote == true, (twoHands.holdVotes.share(within: config.scrollPoseEnter, at: time) ?? 0) >= 0.8 else {
            return false
        }
        twoHands.isActive = true
        twoHands.holderSeen = time
        // Joint offsets are known only for the hand that was driving the cursor;
        // for the other hand they will be collected anew.
        twoHands.anchorOffsets = swapped ? [:] : anchorOffsets
        twoHands.scrollerCenter = scroller.center
        twoHands.filter.reset()
        twoHands.lastPoint = nil
        phase = .scrolling
        gestureStart = time
        isTouching = false
        notes.append("two hands")
        return true
    }

    /// The fingers are "lifted": the scroll gesture is closed, and the speed of the last stroke goes into momentum.
    private mutating func lift(at time: Double) -> [PointerAction] {
        guard isTouching else { return [] }
        isTouching = false
        guard scrollAxis != nil else { return [] }
        startCoasting(at: time)
        return [.scroll(dx: 0, dy: 0, phase: .ended)]
    }

    /// Turns hand travel into wheel scrolling, with acceleration like the cursor's. With natural scrolling the content
    /// follows the hand: the y axis in the frame points up, and a positive wheel `dy` scrolls up, which moves the
    /// content down.
    private mutating func scroll(_ delta: CGVector, dt: Double, axis: ScrollAxis, phase: ScrollPhase) -> PointerAction {
        let speed = hypot(delta.dx, delta.dy) / dt
        let gain = config.scrollGain * (1 + Self.smoothstep(config.slowSpeed, config.fastSpeed, speed))
        let sign: Double = config.naturalScroll ? 1 : -1
        var dx = (config.invertX ? -delta.dx : delta.dx) * gain * sign
        var dy = (config.invertY ? delta.dy : -delta.dy) * gain * sign
        switch axis {
        case .vertical: dx = 0
        case .horizontal: dy = 0
        }
        scrollVelocity = CGVector(dx: (scrollVelocity.dx + dx / dt) / 2, dy: (scrollVelocity.dy + dy / dt) / 2)
        return .scroll(dx: dx, dy: dy, phase: phase)
    }

    private mutating func startCoasting(at time: Double) {
        guard hypot(scrollVelocity.dx, scrollVelocity.dy) >= config.momentumMinSpeed else { return }
        momentum = scrollVelocity
        momentumStarted = false
        momentumTime = time
    }

    private mutating func coast(until time: Double) -> [PointerAction] {
        guard var velocity = momentum else { return [] }
        let dt = max(time - momentumTime, 0)
        momentumTime = time
        let keep = pow(config.momentumDecay, dt)
        velocity = CGVector(dx: velocity.dx * keep, dy: velocity.dy * keep)
        guard hypot(velocity.dx, velocity.dy) >= 30 else {
            momentum = nil
            return momentumStarted ? [.scroll(dx: 0, dy: 0, phase: .momentumEnded)] : []
        }
        momentum = velocity
        defer { momentumStarted = true }
        return [.scroll(dx: velocity.dx * dt, dy: velocity.dy * dt, phase: momentumStarted ? .momentum : .momentumBegan)]
    }

    private mutating func stopCoasting(_ actions: inout [PointerAction]) {
        guard momentum != nil else { return }
        momentum = nil
        if momentumStarted { actions.append(.scroll(dx: 0, dy: 0, phase: .momentumEnded)) }
    }

    /// Whether the fingers of a held pinch are open: two thirds of the frames in the release window are above the
    /// release threshold. Before a drag, fingers stuck between the thresholds also count as a release: after a click
    /// the hand relaxes, and they often don't spread all the way.
    private mutating func released(_ state: Pinch, votes: Votes, at time: Double, acceptsLoose: Bool) -> Bool {
        if state == .open, (votes.share(within: config.releaseConfirm, at: time) ?? 0) >= 0.66 { return true }
        guard acceptsLoose, state != .closed else {
            looseSince = nil
            return false
        }
        let since = looseSince ?? time
        looseSince = since
        return time - since >= config.looseRelease
    }

    private mutating func cancel(_ reason: String, at time: Double) {
        notes.append(reason)
        endGesture(at: time)
    }

    /// The open frames that released the pinch already count toward re-arming: otherwise the quick
    /// second pinch of a double-click wouldn't have time to arm.
    private mutating func endGesture(at time: Double, rearm: Bool = true) {
        phase = .hover
        holdUntil = time + config.releaseHold
        if rearm { needsRearm = true }
        gestureOrigin = nil
        tipsMissingSince = nil
        looseSince = nil
        poseSince = nil
        poseBrokenSince = nil
        isTouching = false
    }

    private mutating func updateCue(at time: Double) {
        switch phase {
        case .standby:
            let held = engageStart.map { time - $0.time } ?? 0
            cue = .engaging(Self.clamp(held / config.engageHold))
        case .pinched:
            // The ring doesn't flash on clicks: it grows over the last `ringLead` seconds before a right-click.
            let elapsed = time - gestureStart
            let ringStart = config.rightClickHold - Self.ringLead
            if elapsed >= config.rightClickHold {
                cue = .rightClick
            } else if elapsed >= ringStart {
                cue = .holding(Self.clamp((elapsed - ringStart) / Self.ringLead))
            } else {
                cue = .none
            }
        case .noHand, .hover, .clutch, .dragging, .scrolling:
            cue = .none
        }
    }

    // MARK: - Anchor and scale

    /// The hand's anchor, which doesn't jump when one or two palm points are missing (usually at the frame edge):
    /// the missing ones are restored from their offset from the center on this hand's last complete frame.
    private static func stableAnchor(of hand: HandPose, offsets anchorOffsets: inout [HandJoint: CGVector]) -> CGPoint? {
        if let anchor = hand.anchor {
            for joint in anchorJoints {
                guard let point = hand[joint] else { continue }
                anchorOffsets[joint] = CGVector(dx: point.x - anchor.x, dy: point.y - anchor.y)
            }
            return anchor
        }
        let estimates = anchorJoints.compactMap { joint -> CGPoint? in
            guard let point = hand[joint], let offset = anchorOffsets[joint] else { return nil }
            return CGPoint(x: point.x - offset.dx, y: point.y - offset.dy)
        }
        guard estimates.count >= 3 else { return nil }
        let sum = estimates.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / Double(estimates.count), y: sum.y / Double(estimates.count))
    }

    /// Palm size jitters from frame to frame: thresholds are computed from the median over five frames.
    private mutating func medianScale(adding size: Double) -> Double {
        scales.append(size)
        if scales.count > 5 { scales.removeFirst(scales.count - 5) }
        return scales.sorted()[scales.count / 2]
    }

    // MARK: - Hand leaving and returning

    /// How long to wait for a missing hand before deciding it has left the frame.
    private var lossTolerance: Double {
        switch phase {
        case .noHand: 0
        case .standby, .hover, .clutch: dropoutTolerance
        case .pinched: isLowLight ? config.lowLightLossGrace : config.lossGrace
        case .scrolling: config.scrollGrace
        case .dragging: config.dragGrace
        }
    }

    /// A hand miss shorter than this counts as a Vision flicker: no rewind and no soft landing.
    private var dropoutTolerance: Double {
        isLowLight ? config.lowLightDropoutGrace : config.dropoutGrace
    }

    private mutating func applyFilterSettings() {
        filter.minCutoff = config.minCutoff * (isLowLight ? config.lowLightCutoffScale : 1)
        filter.beta = config.beta
    }

    /// Remembers cursor movements in `hover` so they can be rolled back if the hand leaves the frame next.
    private mutating func remember(_ moves: [PointerAction], at time: Double) {
        recentMoves.removeAll { $0.time < time - Self.rollbackMemory }
        for case let .move(dx, dy) in moves {
            recentMoves.append((time, CGVector(dx: dx, dy: dy)))
        }
    }

    /// The hand left the frame straight from `hover`. Most often it was simply lowered, and for the last fractions
    /// of a second the cursor was drifting down against the user's intent: we return it to where the hand started
    /// to go down.
    private func rollback() -> [PointerAction] {
        guard config.mapping == .relative, let lastTime else { return [] }
        let window = recentMoves.filter { $0.time >= lastTime - Self.rollbackWindow }
        guard let first = window.first else { return [] }
        let travel = window.reduce(CGVector.zero) { CGVector(dx: $0.dx + $1.step.dx, dy: $0.dy + $1.step.dy) }
        // A hand usually leaves sideways or upward when the cursor is being driven deliberately:
        // we don't touch such movement.
        guard travel.dy > abs(travel.dx) else { return [] }
        return [.rewind(since: first.time)]
    }

    /// Gain multiplier after the hand returns: the cursor stays put until the hand settles, then over `landingRamp`
    /// the gain grows smoothly to full. An entering hand is still moving into the frame, and its first frames
    /// are noisy.
    private func landingGain(at time: Double) -> Double {
        guard landingStart != nil else { return 1 }
        guard let landingSettled else { return 0 }
        return Self.smoothstep(0, Self.landingRamp, time - landingSettled)
    }

    private mutating func updateLanding(speed: Double, at time: Double) {
        guard let landingStart, landingSettled == nil,
              Self.hasSettled(calm: speed < Self.landingSettleSpeed, after: time - landingStart) else { return }
        landingSettled = time
    }

    /// The returned hand has settled: it slowed down or time ran out. In live testing a hand being brought back
    /// into the frame kept moving inward for another 0.3-0.6 s, and the cursor and the page drifted back with it.
    private static func hasSettled(calm: Bool, after elapsed: Double) -> Bool {
        elapsed >= landingFreeze && (calm || elapsed >= landingMaxHold)
    }

    /// The hand has just returned to the frame and is not fully visible: we don't read the finger pose from it.
    private func isSettling(at time: Double) -> Bool {
        guard let landingStart else { return false }
        return time - landingStart < config.landingPinchBlock
    }

    // MARK: - Cursor

    private mutating func pointerMove(_ delta: CGVector, dt: Double, at point: CGPoint, scale: Double, aspect: Double,
                                      time: Double) -> [PointerAction] {
        switch config.mapping {
        case .relative:
            let step = leashed(screenDelta(delta, dt: dt, at: time), delta: delta, dt: dt, at: point, scale: scale,
                               aspect: aspect, time: time)
            return step == .zero ? [] : [.move(dx: step.dx, dy: step.dy)]
        case .absolute:
            // The cursor is placed by the hand position: there is nothing to accelerate, we just wait
            // for the returned hand to "settle".
            return landingGain(at: time) > 0 ? [absoluteMove(point, aspect: aspect)] : []
        }
    }

    /// Converts hand movement into a cursor shift with acceleration: slow means precise, fast means far.
    private func screenDelta(_ delta: CGVector, dt: Double, at time: Double) -> CGVector {
        let speed = hypot(delta.dx, delta.dy) / dt
        let t = Self.smoothstep(config.slowSpeed, config.fastSpeed, speed)
        let gain = (config.slowGain + (config.fastGain - config.slowGain) * t) * config.speed * landingGain(at: time)
        return CGVector(dx: (config.invertX ? -delta.dx : delta.dx) * gain,
                        dy: (config.invertY ? delta.dy : -delta.dy) * gain)
    }

    private func absoluteMove(_ point: CGPoint, aspect: Double) -> PointerAction {
        let region = config.activeRegion
        let u = Self.clamp((point.x / aspect - region.minX) / region.width)
        let v = Self.clamp((point.y - region.minY) / region.height)
        return .moveTo(x: config.invertX ? 1 - u : u, y: config.invertY ? v : 1 - v)
    }

    // MARK: - Work area

    /// The trackpad leash: the cursor follows the hand with acceleration but never strays farther than `leash` of the
    /// screen from the spot where the work area places the hand. That way the whole screen is reachable without
    /// taking the hand out of the frame, and a fast swing doesn't carry the cursor beyond the hand. Without hand
    /// travel the cursor doesn't move and never goes against the hand. In live testing (log 11:20) with a pure
    /// trackpad the hand drifted toward the frame edge and left it sideways, upward and downward.
    private mutating func leashed(_ step: CGVector, delta: CGVector, dt: Double, at point: CGPoint, scale: Double,
                                  aspect: Double, time: Double) -> CGVector {
        guard let cursor, config.leash > 0, let safe = Self.safeArea(aspect: aspect, scale: scale) else {
            workArea = nil
            return step
        }
        let size = workAreaSize(screen: cursor.size, fitting: safe)
        // The cursor has only just started following the hand (control taken, hand returned, fist or scroll over)
        // or the hand is still settling after a return: the area is placed so the hand points to where the cursor is.
        guard let current = workArea, landingGain(at: time) >= 1 else {
            workArea = placed(size, at: point, pointingAt: cursor.position, in: safe)
            return step
        }
        // The hand moved toward or away from the camera: the area resizes around its center and stays within the zone.
        let area = Self.fit(CGRect(x: current.midX - size.width / 2, y: current.midY - size.height / 2,
                                   width: size.width, height: size.height), into: safe)
        workArea = area
        // The leash doesn't touch the jitter of a still hand: it would shorten steps back and forth differently,
        // and the cursor would creep by itself while the hand stands still.
        let weight = Self.smoothstep(Self.leashStill, Self.leashMoving, hypot(delta.dx, delta.dy) / dt / scale)
        guard weight > 0 else { return step }
        let target = screenPosition(of: point, in: area)
        let follow = CGVector(dx: (config.invertX ? -delta.dx : delta.dx) * cursor.size.width / area.width,
                              dy: (config.invertY ? delta.dy : -delta.dy) * cursor.size.height / area.height)
        let offset = CGVector(dx: (cursor.position.x - target.x) * cursor.size.width,
                              dy: (cursor.position.y - target.y) * cursor.size.height)
        let dx = Self.leash(step.dx, follow: follow.dx, offset: offset.dx, limit: config.leash * cursor.size.width)
        let dy = Self.leash(step.dy, follow: follow.dy, offset: offset.dy, limit: config.leash * cursor.size.height)
        return CGVector(dx: step.dx + (dx - step.dx) * weight, dy: step.dy + (dy - step.dy) * weight)
    }

    /// One axis of the leash. `follow` is the step with which the cursor would track the hand exactly across the
    /// work area, `offset` is how far the cursor has already strayed from the hand's spot. A trackpad step that
    /// takes the cursor farther away tapers down to `follow` as it nears `limit`, and beyond that turns into a
    /// catching-up one. A step that returns the cursor to the hand is not changed.
    private static func leash(_ step: Double, follow: Double, offset: Double, limit: Double) -> Double {
        let push = step - follow
        guard push * offset > 0 else { return step }
        // The cube keeps slow movements precise almost to the very end of the leash.
        let slack = max(1 - pow(abs(offset) / limit, 3), -0.5)
        let leashed = follow + push * slack
        // While catching up, the cursor may stop but won't move against the hand's motion.
        return leashed * follow < 0 ? 0 : leashed
    }

    /// Where the hand's anchor can be so that the whole hand stays in the frame: in the logs the fingertips rise
    /// above the anchor by 0.9-1.1 S, the wrist drops below it by 0.7 S, and the hand extends sideways by 0.65-0.75 S.
    private static func safeArea(aspect: Double, scale: Double) -> CGRect? {
        let area = CGRect(x: 0.8 * scale, y: 0.75 * scale, width: aspect - 1.6 * scale, height: 1 - 1.9 * scale)
        return area.width > 0.1 && area.height > 0.1 ? area : nil
    }

    /// Hand travel across the whole screen: the screen divided by `workAreaGain` and the speed, but no more than
    /// the safe zone. The sides follow the screen's proportions so the cursor moves the same along both axes.
    private func workAreaSize(screen: CGSize, fitting safe: CGRect) -> CGSize {
        let width = screen.width / (config.workAreaGain * config.speed)
        let height = width * screen.height / screen.width
        let fit = min(1, safe.width / width, safe.height / height)
        return CGSize(width: width * fit, height: height * fit)
    }

    /// The area in which a hand at `point` points at the screen's `position`, if it fits within the safe zone.
    private func placed(_ size: CGSize, at point: CGPoint, pointingAt position: CGPoint, in safe: CGRect) -> CGRect {
        let u = config.invertX ? 1 - position.x : position.x
        let v = config.invertY ? position.y : 1 - position.y
        return Self.fit(CGRect(x: point.x - u * size.width, y: point.y - v * size.height,
                               width: size.width, height: size.height), into: safe)
    }

    /// Where on the screen (as fractions, y down) the work area places the hand. Beyond the edge of the area
    /// the fractions fall outside 0...1.
    private func screenPosition(of point: CGPoint, in area: CGRect) -> CGPoint {
        let u = (point.x - area.minX) / area.width
        let v = (point.y - area.minY) / area.height
        return CGPoint(x: config.invertX ? 1 - u : u, y: config.invertY ? v : 1 - v)
    }

    private static func fit(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        CGRect(x: min(max(rect.minX, bounds.minX), bounds.maxX - rect.width),
               y: min(max(rect.minY, bounds.minY), bounds.maxY - rect.height),
               width: rect.width, height: rect.height)
    }

    /// The axis of a stroke: vertical unless the stroke is clearly sideways. The other axis is locked
    /// for the duration of the stroke.
    private enum ScrollAxis {
        case vertical, horizontal
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = clamp((x - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    private static func clamp(_ x: Double) -> Double {
        min(max(x, 0), 1)
    }
}

/// Votes of the latest frames: "yes", "no" or "unknown". Windows are set by time rather than by frame count,
/// so the thresholds don't change with the camera frame rate (iPhone: 60 fps, built-in: 30).
private struct Votes {
    private var samples: [(time: Double, value: Bool?)] = []

    mutating func add(_ value: Bool?, at time: Double, keeping memory: Double) {
        samples.append((time, value))
        samples.removeAll { $0.time <= time - memory }
    }

    /// The share of "yes" among the known votes over the last `window` seconds. `nil` if fewer than two are known
    /// or fewer than 60% of the window's frames: such a window can't support a decision.
    func share(within window: Double, at time: Double) -> Double? {
        let recent = samples.filter { $0.time > time - window }
        let known = recent.compactMap(\.value)
        guard known.count >= 2, Double(known.count) >= Double(recent.count) * 0.6 else { return nil }
        return Double(known.count(where: { $0 })) / Double(known.count)
    }

    mutating func clear() {
        samples = []
    }
}

/// Two-hand scroll state: which hand holds the fist, which one scrolls, and where travel is measured from.
private struct TwoHands {
    var isActive = false
    var holdVotes = Votes()
    var holderCenter: CGPoint?
    var scrollerCenter: CGPoint?
    var holderSeen: Double = 0
    var holderOpenSince: Double?
    var filter = OneEuroFilter2D(minCutoff: 1, beta: 8)
    var lastPoint: (point: CGPoint, time: Double)?
    /// Offsets of the scrolling hand's base joints: they complete the anchor when points go missing.
    var anchorOffsets: [HandJoint: CGVector] = [:]
    /// Since when the scrolling hand has been out of the frame, when it returned, since when it has been slow,
    /// and when it settled.
    var outSince: Double?
    var landingStart: Double?
    var slowSince: Double?
    var landingSettled: Double?
}
