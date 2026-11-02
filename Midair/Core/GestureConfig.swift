import CoreGraphics
import Foundation

/// Gesture engine settings. Lengths are in palm sizes S (`HandPose.blendedScale`) unless stated otherwise,
/// time is in seconds.
///
/// Stored in UserDefaults as a whole and written to the log, so decoding is lenient: missing fields take their
/// defaults. Settings from an earlier threshold version get the current thresholds, while personal settings are kept.
struct GestureConfig: Codable, Equatable, Sendable {
    enum Mapping: String, Codable, CaseIterable, Sendable {
        /// Like a trackpad: the cursor moves by the hand's displacement, with acceleration.
        case relative
        /// A zone of the frame stretched over the whole screen.
        case absolute
    }

    /// Version 2 came with the gesture layout where a pinch is decided by time and hand travel; version 3 came after
    /// the first live test (November 1, 2026): a loose pinch counts again, and dragging starts without waiting.
    static let currentVersion = 3
    var version = GestureConfig.currentVersion

    // MARK: Cursor

    var mapping: Mapping = .relative
    var preferredHand: Chirality?
    /// Overall cursor speed multiplier.
    var speed: Double = 1
    /// Gain in screen points per frame height: for slow and for fast movements.
    var slowGain: Double = 500
    var fastGain: Double = 3600
    /// Hand speeds (frame heights per second) between which the gain grows smoothly.
    var slowSpeed: Double = 0.05
    var fastSpeed: Double = 1.2
    var minCutoff: Double = 1
    var beta: Double = 8
    /// Front cameras deliver an unmirrored frame: the hand moves right but goes left in the frame.
    var invertX = true
    var invertY = false
    /// Frame zone for absolute mode in normalized coordinates (origin at the bottom left).
    var activeRegion = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
    /// Hand work area in "like a trackpad" mode: the hand travel that covers the whole screen equals the screen divided
    /// by `workAreaGain * speed`, but no more than the part of the frame where the hand is fully visible. The cursor
    /// moves away from the spot where the area places the hand by no more than `leash` of the screen, so the whole
    /// screen is reachable without taking the hand out of the frame. Zero in `leash` leaves a pure trackpad.
    var workAreaGain: Double = 2000
    var leash: Double = 0.25

    // MARK: Scrolling

    /// Scroll pixels per frame height the hand covers; up to twice as many for fast strokes, like cursor acceleration.
    var scrollGain: Double = 2200
    var naturalScroll = true
    /// Fraction of momentum speed left after one second, and the speed (pixels per second) at which momentum begins.
    var momentumDecay: Double = 0.12
    var momentumMinSpeed: Double = 250
    /// One-hand scrolling with the "two fingers" pose. Off by default: a hand releasing a pinch looks like this pose,
    /// and in live testing (log of 11:47 on November 1) the pose turned on by itself right after a pinch three times
    /// out of five. Without it, scrolling is started by a fist of the other hand.
    var oneHandScroll = false

    // MARK: Taking control

    /// The cursor and gestures come alive only when an open palm stays for `engageHold`, moving no more than
    /// `engageDrift`: hands that get into the frame unintentionally (a mug, a phone, a conversation) do nothing.
    var requiresEngagement = true
    var engageHold = 0.5
    var engageDrift = 0.4
    /// If the hand is absent for longer than this, control must be taken again.
    var disengageAfter = 1.5

    // MARK: Pinch

    /// Joints that Vision is less sure about than this are treated as invisible. The pinky tip has a lower
    /// threshold: pressed against the thumb it is hidden by the thumb, and Vision gives it 0.15-0.3 even though
    /// it guesses the position correctly.
    var minConfidence = 0.3
    var pinkyMinConfidence = 0.15
    /// The pinch threshold and the release threshold: the gap from the thumb tip to the nearer of the index
    /// and middle fingertips. The distance between the thresholds suppresses chatter.
    /// For the person we tested on, an ordinary pinch keeps a gap of 0.26-0.31: a threshold of 0.25 didn't count it.
    var pinchEnter = 0.32
    var pinchExit = 0.52
    /// Pinch confirmation window: three quarters of the frames in it must show a pinch (three of four at 30 fps).
    var pinchConfirm = 0.11
    /// Release window: two thirds of the frames in it must show open fingers (two of three at 30 fps).
    var releaseConfirm = 0.08
    /// A pinch doesn't start faster than this (S per second): in motion blur the fingertips merge into a "pinch".
    /// When the exposure is at its limit or it is dark, the blur is stronger and the threshold is lower.
    var pinchStartSpeed: Double = 4
    var limitedPinchStartSpeed: Double = 3
    /// A pinching finger shorter than this in projection points at the camera or is curled into a fist:
    /// such a pinch doesn't start.
    var minFingerLength = 0.4
    /// After a release, a cancel or a fist, a new pinch is accepted only once the fingers have stayed open this long.
    var rearmOpen = 0.03
    /// Fingers stuck between the press and release thresholds: before a drag this counts as a release too.
    var looseRelease = 0.2
    /// How long to wait for the fingertips of a held pinch: before a drag (then the pinch is cancelled silently)
    /// and during a drag.
    var pinchTipGrace = 0.3
    var dragTipGrace = 0.5

    // MARK: Click, drag, right-click

    /// Hand travel with a held pinch after which a drag starts (about 3% of the frame for a hand a meter
    /// from the camera): a hand that clicked in place travels ten times less.
    var dragTravel = 0.45
    /// A pinch started while the hand is moving (faster than `stillSpeed`, S per second) is almost always a false
    /// trigger: if the hand goes farther than `cancelTravel` within the first `armDelay`, it is cancelled silently.
    /// A pinch from a standstill drags immediately.
    var stillSpeed: Double = 1
    var armDelay = 0.45
    var cancelTravel = 0.3
    /// A still pinch held longer than this gives a right-click on release. The quick right-click: thumb to pinky.
    /// In live testing slow clicks lasted up to 0.9 s, so the hold is noticeably longer.
    var rightClickHold = 1.5
    /// The pinky decides if it is closer to the thumb than the index and middle fingers by at least this much: when
    /// the thumb reaches for the pinky, the hand folds and the index finger ends up close too (0.27-0.29 vs 0.12-0.15).
    var pinkyMargin = 0.08
    /// Pause after a pinch release while the fingers open up.
    var releaseHold = 0.08

    // MARK: Fist

    /// Windows for entering and leaving a fist: four frames of five and three of four at 30 fps.
    var fistEnter = 0.16
    var fistExit = 0.13
    /// How long to keep the fist state while the fingers can't tell whether it is a fist or not.
    var fistUnknownHold = 0.3

    // MARK: "Two fingers" pose for scrolling

    /// How long the pose must hold before scrolling starts, and how long frames with an open palm must last to end it.
    /// Scrolling waits longer through frames where the pose can't be made out and through a missing hand: a hand
    /// with bent fingers is repositioned quickly, and Vision loses it in motion blur.
    var scrollPoseEnter = 0.2
    var scrollPoseExit = 0.13
    var scrollGrace = 0.6
    /// The pose does not turn on when the hand is faster than this (S per second).
    var scrollPoseSpeed = 2.5
    /// A finger is extended if its tip is farther from the wrist than the knuckle by more than this factor,
    /// and bent if by less.
    var extendedRatio = 1.4
    var bentRatio = 1.3

    // MARK: Hand leaving and returning

    /// How long the hand may go unseen in the middle of a gesture before the gesture is cancelled.
    var lossGrace = 0.25
    /// A drag waits for the hand longer: it can be taken out of the frame and brought back still pinching,
    /// like repositioning a mouse.
    var dragGrace = 1.0
    /// A miss shorter than this is treated as a Vision glitch on motion blur rather than the hand leaving:
    /// no rewind and no soft landing.
    var dropoutGrace = 0.1
    /// How long after the hand returns a pinch is not trusted: a hand entering the frame is not fully visible.
    var landingPinchBlock = 0.15

    // MARK: Low light

    /// In the dark the joints jitter and Vision loses the hand more often: the filter cutoff is lower, a flicker of
    /// the hand takes longer to count as leaving, the hand is awaited longer in the middle of a gesture, and a pinch
    /// takes one frame longer to confirm.
    var lowLightCutoffScale = 0.5
    var lowLightDropoutGrace = 0.25
    var lowLightLossGrace = 0.4
    var lowLightConfirmExtra = 0.033
}

extension GestureConfig {
    /// The user's personal settings: they carry over unchanged into a new version of the thresholds.
    static let personalKeys: Set<String> = [
        "mapping", "preferredHand", "speed", "slowGain", "fastGain", "slowSpeed", "fastSpeed", "minCutoff", "beta",
        "invertX", "invertY", "activeRegion", "scrollGain", "naturalScroll", "momentumDecay", "momentumMinSpeed",
        "requiresEngagement", "oneHandScroll",
    ]

    /// The hand as the engine sees it: without low-confidence points. The pipeline and the replay
    /// cut them off the same way.
    func visible(_ hand: HandPose) -> HandPose {
        hand.filtered(minConfidence: minConfidence, overrides: [.littleTip: pinkyMinConfidence])
    }

    /// All settings fields, as they are named in JSON.
    static var keys: Set<String> {
        let data = (try? JSONEncoder().encode(GestureConfig())) ?? Data()
        return Set(((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]).keys).union(["preferredHand"])
    }

    /// The synthesized `Codable` fails at the first field missing from the record, and the saved settings would be
    /// lost entirely. Here anything missing takes its default, and thresholds from earlier versions are replaced
    /// with the current ones.
    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let readsThresholds = stored >= Self.currentVersion
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) throws {
            guard readsThresholds || Self.personalKeys.contains(key.stringValue),
                  let decoded = try container.decodeIfPresent(T.self, forKey: key) else { return }
            value = decoded
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
        try read(.invertX, &invertX)
        try read(.invertY, &invertY)
        try read(.activeRegion, &activeRegion)
        try read(.workAreaGain, &workAreaGain)
        try read(.leash, &leash)
        try read(.scrollGain, &scrollGain)
        try read(.naturalScroll, &naturalScroll)
        try read(.momentumDecay, &momentumDecay)
        try read(.momentumMinSpeed, &momentumMinSpeed)
        try read(.oneHandScroll, &oneHandScroll)
        try read(.requiresEngagement, &requiresEngagement)
        try read(.engageHold, &engageHold)
        try read(.engageDrift, &engageDrift)
        try read(.disengageAfter, &disengageAfter)
        try read(.minConfidence, &minConfidence)
        try read(.pinkyMinConfidence, &pinkyMinConfidence)
        try read(.pinkyMargin, &pinkyMargin)
        try read(.pinchEnter, &pinchEnter)
        try read(.pinchExit, &pinchExit)
        try read(.pinchConfirm, &pinchConfirm)
        try read(.releaseConfirm, &releaseConfirm)
        try read(.pinchStartSpeed, &pinchStartSpeed)
        try read(.limitedPinchStartSpeed, &limitedPinchStartSpeed)
        try read(.minFingerLength, &minFingerLength)
        try read(.rearmOpen, &rearmOpen)
        try read(.looseRelease, &looseRelease)
        try read(.pinchTipGrace, &pinchTipGrace)
        try read(.dragTipGrace, &dragTipGrace)
        try read(.dragTravel, &dragTravel)
        try read(.stillSpeed, &stillSpeed)
        try read(.armDelay, &armDelay)
        try read(.cancelTravel, &cancelTravel)
        try read(.rightClickHold, &rightClickHold)
        try read(.releaseHold, &releaseHold)
        try read(.fistEnter, &fistEnter)
        try read(.fistExit, &fistExit)
        try read(.fistUnknownHold, &fistUnknownHold)
        try read(.scrollPoseEnter, &scrollPoseEnter)
        try read(.scrollPoseExit, &scrollPoseExit)
        try read(.scrollGrace, &scrollGrace)
        try read(.scrollPoseSpeed, &scrollPoseSpeed)
        try read(.extendedRatio, &extendedRatio)
        try read(.bentRatio, &bentRatio)
        try read(.lossGrace, &lossGrace)
        try read(.dragGrace, &dragGrace)
        try read(.dropoutGrace, &dropoutGrace)
        try read(.landingPinchBlock, &landingPinchBlock)
        try read(.lowLightCutoffScale, &lowLightCutoffScale)
        try read(.lowLightDropoutGrace, &lowLightDropoutGrace)
        try read(.lowLightLossGrace, &lowLightLossGrace)
        try read(.lowLightConfirmExtra, &lowLightConfirmExtra)
    }
}

enum PointerAction: Equatable, Sendable {
    /// Relative movement in screen points, the y axis points down.
    case move(dx: Double, dy: Double)
    /// Absolute position as a fraction of the main screen, the y axis points down.
    case moveTo(x: Double, y: Double)
    case leftDown
    case leftUp
    case rightClick
    /// Scroll in pixels using the mouse wheel convention: a positive `dy` scrolls up.
    case scroll(dx: Double, dy: Double, phase: ScrollPhase)
    /// Return the cursor to where it was before the movement at time `since`: a rewind of the motion with which
    /// the hand left the frame. A reverse move can't express this: near the screen edge, clamping swallowed part
    /// of the movements.
    case rewind(since: Double)
}

/// Where the cursor is and what screen it is on: the engine uses them to keep the hand in the frame's work area.
struct CursorContext: Equatable, Sendable {
    /// Position on the screen as fractions, 0 to 1 on each axis, origin at the top left.
    var position: CGPoint
    /// Screen size in points.
    var size: CGSize
}

enum ScrollPhase: Equatable, Sendable {
    case began, changed, ended
    case momentumBegan, momentum, momentumEnded
}

enum GesturePhase: String, Equatable, Sendable {
    case noHand
    /// The hand is visible but control has not been taken yet: the cursor stays put, gestures are not accepted.
    case standby
    case hover
    case clutch
    /// The pinch is held but the button is not pressed yet: the outcome will be decided by hold time and hand travel.
    case pinched
    case dragging
    case scrolling

    /// A gesture that must not be abandoned halfway: a pinch is held, a button is held, or a scroll is in progress.
    var isActive: Bool {
        switch self {
        case .pinched, .dragging, .scrolling: true
        case .noHand, .standby, .hover, .clutch: false
        }
    }
}

/// A ring around the cursor while a gesture builds up time: without it a hold can't be timed blindly.
enum GestureCue: Equatable, Sendable {
    case none
    /// The palm is being held to take control: a fraction from 0 to 1.
    case engaging(Double)
    /// The pinch is held without travel: the fraction of the way to a right-click.
    case holding(Double)
    /// Release without travel and it becomes a right-click.
    case rightClick
}

/// What the engine saw in the last frame: for the log and replay.
struct GestureFeatures: Equatable, Sendable {
    /// Palm size S in frame heights, median over five frames.
    var scale: Double?
    /// The pinch gap in S and the finger the thumb is closer to.
    var gap: Double?
    var finger: HandJoint?
    /// Speed of the hand's anchor in S per second.
    var speed: Double = 0
    /// Hand travel since the pinch began, in S.
    var travel: Double?
    /// Length of the pinching finger in projection, in S.
    var fingerLength: Double?
    /// Palm length to its width.
    var edgeRatio: Double?
    /// The frame shows a fist (`true`), an open hand (`false`) or is unclear.
    var fist: Bool?
    /// The frame shows the "two fingers" pose.
    var twoFingers: Bool?
    /// Gap from the thumb to the pinky in S, if the pinky is not curled.
    var pinkyGap: Double?
    /// The "two fingers" pose holds (a soft check for an already started scroll).
    var twoFingersHold: Bool?
}
