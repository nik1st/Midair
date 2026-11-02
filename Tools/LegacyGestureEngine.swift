// The gesture layout from before 1 November 2026, kept for comparison in Tools/GestureReplay.swift (preset=old):
// a copy of Midair/Core/GestureEngine.swift as of that day with the types renamed. Not part of the app or the tests.

import CoreGraphics
import Foundation

struct LegacyGestureConfig: Codable, Equatable, Sendable {
    enum Mapping: String, Codable, CaseIterable, Sendable {
        /// Like a trackpad: the cursor moves by the hand's displacement, with acceleration.
        case relative
        /// The frame zone is stretched over the whole screen.
        case absolute
    }

    var mapping: Mapping = .relative
    var preferredHand: Chirality?
    /// Overall cursor speed multiplier.
    var speed: Double = 1
    /// Gain in screen points per frame height: for slow and for fast movements.
    var slowGain: Double = 500
    var fastGain: Double = 3600
    /// Hand speeds (frame heights per second) between which the gain ramps up smoothly.
    var slowSpeed: Double = 0.05
    var fastSpeed: Double = 1.2
    var minCutoff: Double = 1
    var beta: Double = 8
    /// Pinch threshold and release threshold in palm sizes. The gap between them suppresses chatter.
    var pinchEnter: Double = 0.3
    var pinchExit: Double = 0.45
    /// How many consecutive frames a pinch must hold to count.
    var pinchConfirmFrames = 2
    /// How long the cursor stays put after a pinch starts, so the click doesn't slide off the target.
    var clickFreeze: Double = 0.18
    /// How many points to travel with the pinch held before a drag begins.
    var dragThreshold: Double = 10
    /// Pause after a pinch is released, while the fingers open.
    var releaseHold: Double = 0.08
    var rightClickMaxDuration: Double = 0.4
    /// Hand travel (in frame heights) after which a middle-finger pinch becomes a scroll.
    var scrollThreshold: Double = 0.02
    /// Scroll pixels per frame height.
    var scrollGain: Double = 2200
    var naturalScroll = true
    /// The fraction of the momentum speed that remains after one second.
    var momentumDecay: Double = 0.12
    var momentumMinSpeed: Double = 250
    /// Front cameras deliver an unmirrored frame: the hand moves right, but in the frame it moves left.
    var invertX = true
    var invertY = false
    /// The frame zone for absolute mode, in normalized coordinates (origin at the bottom left).
    var activeRegion = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
}

enum LegacyPointerAction: Equatable, Sendable {
    /// Relative move in screen points, the y axis points down.
    case move(dx: Double, dy: Double)
    /// Absolute position as a fraction of the main screen, the y axis points down.
    case moveTo(x: Double, y: Double)
    case leftDown
    case leftUp
    case rightClick
    /// Scroll in pixels using the mouse-wheel convention: a positive `dy` scrolls up.
    case scroll(dx: Double, dy: Double, phase: LegacyScrollPhase)
    /// Return the cursor to where it was before the move at time `since`: a rewind of the motion the hand
    /// left the frame with. A reverse move can't express it: near the screen edge, clamping ate some of the moves.
    case rewind(since: Double)
}

enum LegacyScrollPhase: Equatable, Sendable {
    case began, changed, ended
    case momentumBegan, momentum, momentumEnded
}

enum LegacyGesturePhase: String, Equatable, Sendable {
    case noHand, hover, clutch, pressing, dragging, secondary, scrolling

    /// A gesture that must not be abandoned midway: a button is held or a scroll is in progress.
    var isActive: Bool {
        switch self {
        case .pressing, .dragging, .secondary, .scrolling: true
        case .noHand, .hover, .clutch: false
        }
    }
}

/// Turns a stream of hand poses into mouse actions. Pure logic without side effects.
///
/// An open palm drives the cursor, a fist clutches (lifts the mouse), a pinch of thumb and index finger
/// works as the left button, a pinch of thumb and middle finger gives a right-click or a scroll.
/// A hand outside the frame is a clutch too: the motion it was lowered with is rewound,
/// and a returning hand picks up the cursor smoothly.
struct LegacyGestureEngine {
    var config: LegacyGestureConfig {
        didSet { applyFilterSettings() }
    }

    /// The frame is dark (the pipeline decides by brightness): Vision loses the hand for a frame or two more often,
    /// and the joints jitter. Then smoothing is stronger, a longer hand dropout still doesn't count as leaving, and
    /// a pinch needs one more frame to be confirmed.
    var isLowLight = false {
        didSet { applyFilterSettings() }
    }

    private(set) var phase: LegacyGesturePhase = .noHand

    private var filter: OneEuroFilter2D
    private var lastPoint: CGPoint?
    private var lastTime: Double?
    private var candidate = Pose.open
    private var candidateFrames = 0
    private var gestureStart: Double = 0
    private var pendingDrag = CGVector.zero
    private var secondaryTravel = CGVector.zero
    private var scrollAxis = ScrollAxis.free
    private var scrollVelocity = CGVector.zero
    private var holdUntil: Double = 0
    private var momentum: CGVector?
    private var momentumStarted = false
    private var momentumTime: Double = 0
    private var lostSince: Double?
    private var anchorOffsets: [HandJoint: CGVector] = [:]
    /// Cursor moves in `hover` over the last fractions of a second: they are rewound if the hand left the frame.
    private var recentMoves: [(time: Double, step: CGVector)] = []
    /// When the hand returned to the frame: the soft landing is counted from this moment.
    private var landingStart: Double?
    /// Since when the fingertips that hold the gesture have not been visible.
    private var tipsMissingSince: Double?
    /// Since when the fingers of a held gesture have been past the press threshold but short of the release threshold.
    private var looseSince: Double?

    /// How long the hand can go unseen mid-gesture before the button is released.
    private static let lossGrace = 0.25
    /// A drag waits for the hand longer: it can leave the frame and return pinching, like repositioning a mouse.
    private static let dragGrace = 1.0
    /// A dropout shorter than this is a Vision glitch on motion blur, not the hand leaving: no rewind, no soft landing.
    private static let dropoutGrace = 0.1
    /// How long to remember cursor moves, and how many seconds before the hand leaves they are rewound.
    private static let rollbackMemory = 0.3
    private static let rollbackWindow = 0.2
    /// Soft landing: after the hand returns the cursor stays put, then the gain ramps up smoothly to full.
    private static let landingFreeze = 0.12
    private static let landingRamp = 0.3
    /// How long after the hand returns to distrust a pinch: a hand entering the frame is not fully visible.
    private static let landingPinchBlock = 0.15
    /// How long to hold a gesture while its fingertips are not visible (motion blur, hand rotation).
    private static let tipGrace = 0.5
    /// How long the fingers can stay "half open" before the button is released.
    private static let looseRelease = 0.3
    /// Above this hand speed (frame heights per second) a pinch doesn't count: the hand is being swept across,
    /// not aimed, and on motion blur the fingertips merge.
    private static let pinchSpeedLimit = 0.6
    /// In the dark: the filter cutoff is halved, a hand flicker of up to 0.25 s is not yet leaving,
    /// and mid-gesture the hand is awaited for 0.4 s.
    private static let lowLightCutoffScale = 0.5
    private static let lowLightDropoutGrace = 0.25
    private static let lowLightLossGrace = 0.4
    private static let anchorJoints: [HandJoint] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]

    init(config: LegacyGestureConfig = LegacyGestureConfig()) {
        self.config = config
        filter = OneEuroFilter2D(minCutoff: config.minCutoff, beta: config.beta)
    }

    /// Resets the state without emitting actions. The caller must release the buttons (for example, on pause).
    mutating func reset() {
        phase = .noHand
        filter.reset()
        lastPoint = nil
        lastTime = nil
        candidate = .open
        candidateFrames = 0
        momentum = nil
        momentumStarted = false
        lostSince = nil
        anchorOffsets = [:]
        recentMoves = []
        landingStart = nil
        tipsMissingSince = nil
        looseSince = nil
    }

    mutating func process(hand: HandPose?, time: Double) -> [LegacyPointerAction] {
        var actions = coast(until: time)

        guard let hand, hand.scale != nil, let point = stableAnchor(of: hand) else {
            // Vision loses the hand for a frame or two at the frame edge and on blur: don't drop the state right away.
            let since = lostSince ?? time
            lostSince = since
            if time - since < lossTolerance { return actions }
            actions += finishGesture(at: time)
            phase = .noHand
            filter.reset()
            lastPoint = nil
            lastTime = nil
            candidateFrames = 0
            lostSince = nil
            recentMoves = []
            tipsMissingSince = nil
            looseSince = nil
            return actions
        }
        if let since = lostSince {
            // After a dropout, continue from the hand's new position, without a cursor jump.
            lostSince = nil
            filter.reset()
            lastPoint = nil
            lastTime = nil
            // The hand left the frame rather than flickering on motion blur: bring it back softly.
            if time - since >= dropoutTolerance { landingStart = time }
        } else if phase == .noHand {
            // The hand entered the frame: its first frames show it only partly, and it is still moving.
            landingStart = time
        }

        let smoothed = filter.filter(point, time: time)
        let delta = lastPoint.map { CGVector(dx: smoothed.x - $0.x, dy: smoothed.y - $0.y) } ?? .zero
        let dt = lastTime.map { max(time - $0, 1.0 / 240) } ?? 1.0 / 30
        let wasTracking = lastPoint != nil
        lastPoint = smoothed
        lastTime = time

        switch phase {
        case .noHand, .hover, .clutch:
            switch confirmedPose(for: hand, speed: hypot(delta.dx, delta.dy) / dt, at: time) {
            case .primaryPinch?:
                stopCoasting(&actions)
                phase = .pressing
                gestureStart = time
                pendingDrag = .zero
                actions.append(.leftDown)
            case .secondaryPinch?:
                stopCoasting(&actions)
                phase = .secondary
                gestureStart = time
                secondaryTravel = .zero
            case .fist?:
                phase = .clutch
            case .open?:
                let canMove = phase == .hover && wasTracking && time >= holdUntil
                phase = .hover
                if canMove {
                    let moves = pointerMove(delta, dt: dt, at: smoothed, aspect: hand.aspect, time: time)
                    remember(moves, at: time)
                    actions += moves
                }
            case nil:
                // The pinch isn't confirmed yet: keep the cursor in place.
                if phase == .noHand { phase = .hover }
            }
            // Only the motion the hand left with straight from `hover` can be rewound.
            if phase != .hover { recentMoves = [] }

        case .pressing, .dragging:
            let ratio = hand.pinchRatio(.indexTip)
            // A returned hand is only partly visible at first: fingers that look open then are no reason to release.
            if !isSettling(at: time), fingersOpened(.indexTip, in: hand, at: time) || pinchLoosened(ratio, at: time) {
                actions.append(.leftUp)
                endGesture(at: time)
            } else if phase == .dragging {
                actions += pointerMove(delta, dt: dt, at: smoothed, aspect: hand.aspect, time: time)
            } else if time - gestureStart >= config.clickFreeze, let ratio, ratio < config.pinchEnter {
                // A drag begins only with a tight pinch. While the fingers open after a click,
                // the hand moves, and that move must not turn the click into a drag of a tab or window.
                let step = screenDelta(delta, dt: dt, at: time)
                pendingDrag.dx += step.dx
                pendingDrag.dy += step.dy
                if hypot(pendingDrag.dx, pendingDrag.dy) >= config.dragThreshold {
                    phase = .dragging
                    actions += config.mapping == .relative
                        ? [.move(dx: pendingDrag.dx, dy: pendingDrag.dy)]
                        : [absoluteMove(smoothed, aspect: hand.aspect)]
                }
            }

        case .secondary, .scrolling:
            if fingersOpened(.middleTip, in: hand, at: time) {
                if phase == .scrolling {
                    actions.append(.scroll(dx: 0, dy: 0, phase: .ended))
                    startCoasting(at: time)
                } else if time - gestureStart <= config.rightClickMaxDuration {
                    actions.append(.rightClick)
                }
                endGesture(at: time)
            } else if phase == .scrolling {
                actions.append(scroll(delta, dt: dt, phase: .changed))
            } else {
                secondaryTravel.dx += delta.dx
                secondaryTravel.dy += delta.dy
                if hypot(secondaryTravel.dx, secondaryTravel.dy) >= config.scrollThreshold {
                    phase = .scrolling
                    scrollVelocity = .zero
                    scrollAxis = ScrollAxis(secondaryTravel)
                    actions.append(scroll(secondaryTravel, dt: max(time - gestureStart, dt), phase: .began))
                }
            }
        }
        return actions
    }

    /// The hand moved into the other camera's frame ("Two cameras" mode). Its coordinates are its own, so we continue
    /// from the hand's new position with a soft landing, as after a return. The gesture phase doesn't change: a drag
    /// is not dropped, and from `hover` the motion the hand left with toward the other camera is rewound.
    mutating func handOver(at time: Double) -> [LegacyPointerAction] {
        let actions = phase == .hover ? rollback() : []
        filter.reset()
        lastPoint = nil
        lastTime = nil
        lostSince = nil
        anchorOffsets = [:]
        recentMoves = []
        if phase != .noHand { landingStart = time }
        return actions
    }

    /// A cursor anchor that doesn't jump when one or two palm joints vanish (usually at the frame edge):
    /// the missing ones are restored from their offset from the center in the last complete frame.
    private mutating func stableAnchor(of hand: HandPose) -> CGPoint? {
        if let anchor = hand.anchor {
            for joint in Self.anchorJoints {
                guard let point = hand[joint] else { continue }
                anchorOffsets[joint] = CGVector(dx: point.x - anchor.x, dy: point.y - anchor.y)
            }
            return anchor
        }
        let estimates = Self.anchorJoints.compactMap { joint -> CGPoint? in
            guard let point = hand[joint], let offset = anchorOffsets[joint] else { return nil }
            return CGPoint(x: point.x - offset.dx, y: point.y - offset.dy)
        }
        guard estimates.count >= 3 else { return nil }
        let sum = estimates.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / Double(estimates.count), y: sum.y / Double(estimates.count))
    }

    // MARK: - Poses

    private enum Pose: Equatable {
        case open, fist, primaryPinch, secondaryPinch
    }

    private func classify(_ hand: HandPose) -> Pose {
        if hand.isFist { return .fist }
        let index = hand.pinchRatio(.indexTip) ?? .infinity
        let middle = hand.pinchRatio(.middleTip) ?? .infinity
        if index < config.pinchEnter, index <= middle { return .primaryPinch }
        if middle < config.pinchEnter { return .secondaryPinch }
        return .open
    }

    /// A pinch counts only if it holds for several frames in a row: otherwise the thumb, on its way
    /// to the middle finger, has time to "click" with the index finger. `nil` means the pose isn't confirmed yet.
    /// `speed` is the speed of the hand's anchor in frame heights per second.
    private mutating func confirmedPose(for hand: HandPose, speed: Double, at time: Double) -> Pose? {
        let pose = classify(hand)
        if pose == candidate {
            candidateFrames += 1
        } else {
            candidate = pose
            candidateFrames = 1
        }
        switch pose {
        case .primaryPinch, .secondaryPinch:
            // On a hand entering the frame, fingers easily merge into a "pinch" in the first frames: those don't count.
            // Same for fast motion: blur merges the tips, and a pinch during a hand jerk is almost always false.
            if isSettling(at: time) || speed > Self.pinchSpeedLimit {
                candidateFrames = 0
                return nil
            }
            // In the dark the fingertips jitter and merge more often: a pinch needs one more frame.
            return candidateFrames >= config.pinchConfirmFrames + (isLowLight ? 1 : 0) ? pose : nil
        case .open, .fist:
            return pose
        }
    }

    private mutating func endGesture(at time: Double) {
        phase = .hover
        holdUntil = time + config.releaseHold
        candidate = .open
        candidateFrames = 0
        tipsMissingSince = nil
        looseSince = nil
    }

    /// Whether the fingers of a held gesture have opened. If the tips are not visible, the gesture holds for `tipGrace`
    /// and is then released as well: otherwise the button hangs for as long as the hand is in the frame, and any hand
    /// motion drags a window or tab.
    private mutating func fingersOpened(_ fingertip: HandJoint, in hand: HandPose, at time: Double) -> Bool {
        guard let ratio = hand.pinchRatio(fingertip) else {
            let since = tipsMissingSince ?? time
            tipsMissingSince = since
            return time - since >= Self.tipGrace
        }
        tipsMissingSince = nil
        return ratio > config.pinchExit
    }

    /// After a click the hand relaxes, and the fingers often get stuck between the press and release thresholds:
    /// the button would hang until they open wider. A pinch like that longer than `looseRelease` counts as released.
    private mutating func pinchLoosened(_ ratio: Double?, at time: Double) -> Bool {
        // The tips aren't visible: `fingersOpened` handles that, so we leave the timer alone here.
        guard let ratio else { return false }
        guard ratio >= config.pinchEnter else {
            looseSince = nil
            return false
        }
        let since = looseSince ?? time
        looseSince = since
        return time - since >= Self.looseRelease
    }

    /// The hand vanished mid-gesture: release the button so it doesn't stick. From `hover`, rewind the motion
    /// the hand left with.
    private mutating func finishGesture(at time: Double) -> [LegacyPointerAction] {
        switch phase {
        case .pressing, .dragging:
            return [.leftUp]
        case .scrolling:
            startCoasting(at: time)
            return [.scroll(dx: 0, dy: 0, phase: .ended)]
        case .hover:
            return rollback()
        case .noHand, .clutch, .secondary:
            return []
        }
    }

    // MARK: - Hand leaving and returning

    /// How long to wait for a vanished hand before deciding that it left the frame.
    private var lossTolerance: Double {
        switch phase {
        case .noHand: 0
        case .hover, .clutch: dropoutTolerance
        case .pressing, .secondary, .scrolling: isLowLight ? Self.lowLightLossGrace : Self.lossGrace
        case .dragging: Self.dragGrace
        }
    }

    /// A hand dropout shorter than this counts as Vision flicker: no rewind or soft landing.
    private var dropoutTolerance: Double {
        isLowLight ? Self.lowLightDropoutGrace : Self.dropoutGrace
    }

    private mutating func applyFilterSettings() {
        filter.minCutoff = config.minCutoff * (isLowLight ? Self.lowLightCutoffScale : 1)
        filter.beta = config.beta
    }

    /// Remembers cursor moves in `hover`: if the hand leaves the frame now, they can be rewound.
    private mutating func remember(_ moves: [LegacyPointerAction], at time: Double) {
        recentMoves.removeAll { $0.time < time - Self.rollbackMemory }
        for case let .move(dx, dy) in moves {
            recentMoves.append((time, CGVector(dx: dx, dy: dy)))
        }
    }

    /// The hand left the frame straight from `hover`. Most often it was simply lowered, and for the last fractions of a
    /// second the cursor drifted down against the person's will: return it to where the hand began to lower.
    private func rollback() -> [LegacyPointerAction] {
        guard config.mapping == .relative, let lastTime else { return [] }
        let window = recentMoves.filter { $0.time >= lastTime - Self.rollbackWindow }
        guard let first = window.first else { return [] }
        let travel = window.reduce(CGVector.zero) { CGVector(dx: $0.dx + $1.step.dx, dy: $0.dy + $1.step.dy) }
        // The hand usually leaves sideways or up while the cursor is moved on purpose: don't touch that motion.
        guard travel.dy > abs(travel.dx) else { return [] }
        return [.rewind(since: first.time)]
    }

    /// Gain multiplier after the hand returns: the cursor stays put for `landingFreeze`, then by `landingRamp`
    /// the gain ramps up smoothly to full. An entering hand is still moving, and its first frames are noisy.
    private func landingGain(at time: Double) -> Double {
        guard let landingStart else { return 1 }
        return Self.smoothstep(Self.landingFreeze, Self.landingRamp, time - landingStart)
    }

    /// The hand just returned to the frame and is only partly visible: don't read the finger pose from it.
    private func isSettling(at time: Double) -> Bool {
        guard let landingStart else { return false }
        return time - landingStart < Self.landingPinchBlock
    }

    // MARK: - Cursor

    private func pointerMove(_ delta: CGVector, dt: Double, at point: CGPoint, aspect: Double, time: Double) -> [LegacyPointerAction] {
        switch config.mapping {
        case .relative:
            let step = screenDelta(delta, dt: dt, at: time)
            return step == .zero ? [] : [.move(dx: step.dx, dy: step.dy)]
        case .absolute:
            // The cursor follows the hand position: nothing to accelerate, just wait for the returned hand to "settle".
            return landingGain(at: time) > 0 ? [absoluteMove(point, aspect: aspect)] : []
        }
    }

    /// Converts hand displacement into a cursor move with acceleration: slow means precise, fast means far.
    private func screenDelta(_ delta: CGVector, dt: Double, at time: Double) -> CGVector {
        let speed = hypot(delta.dx, delta.dy) / dt
        let t = Self.smoothstep(config.slowSpeed, config.fastSpeed, speed)
        let gain = (config.slowGain + (config.fastGain - config.slowGain) * t) * config.speed * landingGain(at: time)
        return CGVector(dx: (config.invertX ? -delta.dx : delta.dx) * gain,
                        dy: (config.invertY ? delta.dy : -delta.dy) * gain)
    }

    private func absoluteMove(_ point: CGPoint, aspect: Double) -> LegacyPointerAction {
        let region = config.activeRegion
        let u = Self.clamp((point.x / aspect - region.minX) / region.width)
        let v = Self.clamp((point.y - region.minY) / region.height)
        return .moveTo(x: config.invertX ? 1 - u : u, y: config.invertY ? v : 1 - v)
    }

    // MARK: - Scrolling

    private enum ScrollAxis {
        case free, vertical, horizontal

        /// As on a trackpad: if the start is clearly vertical or horizontal, the other axis is locked.
        init(_ travel: CGVector) {
            if abs(travel.dy) > abs(travel.dx) * 1.5 {
                self = .vertical
            } else if abs(travel.dx) > abs(travel.dy) * 1.5 {
                self = .horizontal
            } else {
                self = .free
            }
        }
    }

    private mutating func scroll(_ delta: CGVector, dt: Double, phase: LegacyScrollPhase) -> LegacyPointerAction {
        // With natural scrolling the content follows the hand.
        let direction: Double = config.naturalScroll ? 1 : -1
        var step = CGVector(dx: (config.invertX ? -delta.dx : delta.dx) * config.scrollGain * direction,
                            dy: (config.invertY ? delta.dy : -delta.dy) * config.scrollGain * direction)
        switch scrollAxis {
        case .vertical: step.dx = 0
        case .horizontal: step.dy = 0
        case .free: break
        }
        scrollVelocity = CGVector(dx: (scrollVelocity.dx + step.dx / dt) / 2,
                                  dy: (scrollVelocity.dy + step.dy / dt) / 2)
        return .scroll(dx: step.dx, dy: step.dy, phase: phase)
    }

    private mutating func startCoasting(at time: Double) {
        guard hypot(scrollVelocity.dx, scrollVelocity.dy) >= config.momentumMinSpeed else { return }
        momentum = scrollVelocity
        momentumStarted = false
        momentumTime = time
    }

    private mutating func coast(until time: Double) -> [LegacyPointerAction] {
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

    private mutating func stopCoasting(_ actions: inout [LegacyPointerAction]) {
        guard momentum != nil else { return }
        momentum = nil
        if momentumStarted {
            actions.append(.scroll(dx: 0, dy: 0, phase: .momentumEnded))
        }
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = clamp((x - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    private static func clamp(_ x: Double) -> Double {
        min(max(x, 0), 1)
    }
}

extension LegacyGestureConfig {
    /// Fields missing from the record (journals of the new layout hold other thresholds) get legacy layout defaults.
    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) throws {
            if let decoded = try container.decodeIfPresent(T.self, forKey: key) { value = decoded }
        }
        try read(.mapping, &mapping)
        if let hand = try container.decodeIfPresent(Chirality.self, forKey: .preferredHand) { preferredHand = hand }
        try read(.speed, &speed)
        try read(.slowGain, &slowGain)
        try read(.fastGain, &fastGain)
        try read(.slowSpeed, &slowSpeed)
        try read(.fastSpeed, &fastSpeed)
        try read(.minCutoff, &minCutoff)
        try read(.beta, &beta)
        try read(.pinchEnter, &pinchEnter)
        try read(.pinchExit, &pinchExit)
        try read(.pinchConfirmFrames, &pinchConfirmFrames)
        try read(.clickFreeze, &clickFreeze)
        try read(.dragThreshold, &dragThreshold)
        try read(.releaseHold, &releaseHold)
        try read(.rightClickMaxDuration, &rightClickMaxDuration)
        try read(.scrollThreshold, &scrollThreshold)
        try read(.scrollGain, &scrollGain)
        try read(.naturalScroll, &naturalScroll)
        try read(.momentumDecay, &momentumDecay)
        try read(.momentumMinSpeed, &momentumMinSpeed)
        try read(.invertX, &invertX)
        try read(.invertY, &invertY)
        try read(.activeRegion, &activeRegion)
    }

    /// Fields the legacy layout understands: the replay doesn't apply other keys to it.
    static var keys: Set<String> {
        let data = (try? JSONEncoder().encode(LegacyGestureConfig())) ?? Data()
        return Set(((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]).keys).union(["preferredHand"])
    }
}

extension LegacyPointerAction {
    var current: PointerAction {
        switch self {
        case let .move(dx, dy): .move(dx: dx, dy: dy)
        case let .moveTo(x, y): .moveTo(x: x, y: y)
        case .leftDown: .leftDown
        case .leftUp: .leftUp
        case .rightClick: .rightClick
        case let .scroll(dx, dy, phase): .scroll(dx: dx, dy: dy, phase: phase.current)
        case let .rewind(since): .rewind(since: since)
        }
    }
}

extension LegacyScrollPhase {
    var current: ScrollPhase {
        switch self {
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        case .momentumBegan: .momentumBegan
        case .momentum: .momentum
        case .momentumEnded: .momentumEnded
        }
    }
}
