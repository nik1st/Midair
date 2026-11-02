import CoreGraphics
import Foundation

/// The 21 hand landmarks in the same order that Vision and MediaPipe return them.
enum HandJoint: Int, CaseIterable, Sendable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

enum Chirality: String, Codable, CaseIterable, Sendable {
    case left, right
}

/// A single detected hand, independent of Vision so that the gesture logic can be tested.
///
/// Coordinates are isotropic: `y` runs from 0 to 1 over the frame height (origin at the bottom, as in Vision),
/// `x` from 0 to `aspect`. The unit of length is one frame height, so distances are comparable along both axes.
struct HandPose: Equatable, Sendable {
    private(set) var points: [CGPoint?]
    /// Vision's confidence in each point, from 0 to 1; 0 for points that were not found.
    private(set) var confidences: [Double]
    var chirality: Chirality?
    var confidence: Double
    /// Frame width divided by height.
    var aspect: Double

    /// Points without an entry in `confidences` get 1.
    init(points: [HandJoint: CGPoint], confidences: [HandJoint: Double] = [:], chirality: Chirality? = nil,
         confidence: Double = 1, aspect: Double = 16.0 / 9.0) {
        var array = [CGPoint?](repeating: nil, count: HandJoint.allCases.count)
        var levels = [Double](repeating: 0, count: HandJoint.allCases.count)
        for (joint, point) in points {
            array[joint.rawValue] = point
            levels[joint.rawValue] = confidences[joint] ?? 1
        }
        self.points = array
        self.confidences = levels
        self.chirality = chirality
        self.confidence = confidence
        self.aspect = aspect
    }

    subscript(_ joint: HandJoint) -> CGPoint? {
        points[joint.rawValue]
    }

    /// How many joints are visible, out of 21.
    var visibleJointCount: Int {
        points.count(where: { $0 != nil })
    }

    /// The same hand minus the points where Vision's confidence is below `minConfidence` (or its own threshold
    /// from `overrides`). The detector returns every point it finds and the core filters them out, so the threshold
    /// can be swept by replaying the log, which records the confidences too.
    func filtered(minConfidence: Double, overrides: [HandJoint: Double] = [:]) -> HandPose {
        var filtered = self
        for joint in HandJoint.allCases where confidences[joint.rawValue] < overrides[joint] ?? minConfidence {
            let index = joint.rawValue
            filtered.points[index] = nil
            filtered.confidences[index] = 0
        }
        return filtered
    }

    func distance(_ a: HandJoint, _ b: HandJoint) -> Double? {
        guard let p = self[a], let q = self[b] else { return nil }
        return hypot(p.x - q.x, p.y - q.y)
    }

    /// Palm size: finger distances are normalized by it, so thresholds don't depend on how far the hand is.
    var scale: Double? {
        if let length = distance(.wrist, .middleMCP), length > 0.01 {
            return length
        }
        if let width = distance(.indexMCP, .littleMCP), width > 0.01 {
            return width * 1.4
        }
        return nil
    }

    /// A point that barely moves during a pinch: the center of the wrist and knuckles.
    /// If the cursor followed a fingertip, it would drift off the target at the moment of the click.
    var anchor: CGPoint? {
        let joints: [HandJoint] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let available = joints.compactMap { self[$0] }
        guard available.count == joints.count else { return nil }
        let sum = available.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / Double(available.count), y: sum.y / Double(available.count))
    }

    /// Distance from the thumb tip to another fingertip, in palm sizes.
    func pinchRatio(_ fingertip: HandJoint) -> Double? {
        guard let scale, let gap = distance(.thumbTip, fingertip) else { return nil }
        return gap / scale
    }

    /// A finger is curled if its tip is closer to the wrist than its middle joint.
    func isCurled(tip: HandJoint, pip: HandJoint) -> Bool? {
        guard let tipToWrist = distance(tip, .wrist), let pipToWrist = distance(pip, .wrist) else { return nil }
        return tipToWrist < pipToWrist
    }

    /// Fist: all four fingers are curled. A relaxed pinch doesn't count here, since its other fingers
    /// are only slightly curled. The engine decides on a fist by `fistVote`; this rule remains for the old
    /// gesture layout in replay.
    var isFist: Bool {
        let fingers: [(HandJoint, HandJoint)] = [
            (.indexTip, .indexPIP), (.middleTip, .middlePIP), (.ringTip, .ringPIP), (.littleTip, .littlePIP),
        ]
        let curled = fingers.compactMap { isCurled(tip: $0.0, pip: $0.1) }
        return curled.count == fingers.count && curled.allSatisfy { $0 }
    }
}

/// The four fingers other than the thumb.
enum Finger: CaseIterable, Sendable {
    case index, middle, ring, little

    var mcp: HandJoint {
        switch self {
        case .index: .indexMCP
        case .middle: .middleMCP
        case .ring: .ringMCP
        case .little: .littleMCP
        }
    }

    var pip: HandJoint {
        switch self {
        case .index: .indexPIP
        case .middle: .middlePIP
        case .ring: .ringPIP
        case .little: .littlePIP
        }
    }

    var tip: HandJoint {
        switch self {
        case .index: .indexTip
        case .middle: .middleTip
        case .ring: .ringTip
        case .little: .littleTip
        }
    }
}

extension HandPose {
    /// Palm size for the engine thresholds: the mean of the palm length and 1.4 times its width, if both are visible.
    /// The average jitters less between frames: 9% versus 16% for length alone in the log.
    var blendedScale: Double? {
        let length = distance(.wrist, .middleMCP).flatMap { $0 > 0.01 ? $0 : nil }
        let width = distance(.indexMCP, .littleMCP).flatMap { $0 > 0.01 ? $0 * 1.4 : nil }
        switch (length, width) {
        case let (length?, width?): return (length + width) / 2
        case let (length?, nil): return length
        case let (nil, width?): return width
        case (nil, nil): return nil
        }
    }

    /// Palm length to its width. For a palm turned edge-on to the camera, the projected width almost vanishes.
    var edgeRatio: Double? {
        guard let length = distance(.wrist, .middleMCP), let width = distance(.indexMCP, .littleMCP), width > 0.005 else { return nil }
        return length / width
    }

    /// Whether the frame shows a fist, judged by the fingers that are visible: a curled finger keeps its tip closer
    /// to the wrist than its middle joint. It is a fist if three or more fingers are curled and none is straight,
    /// an open hand if at least two are straight, otherwise `nil`: this frame doesn't tell.
    var fistVote: Bool? {
        let curled = Finger.allCases.compactMap { isCurled(tip: $0.tip, pip: $0.pip) }
        let bent = curled.count(where: { $0 })
        let straight = curled.count - bent
        if bent >= 3, straight == 0 { return true }
        if straight >= 2 { return false }
        return nil
    }

    /// How extended a finger is: how many times farther the tip is from the wrist than the knuckle.
    func extensionRatio(of finger: Finger) -> Double? {
        guard let tip = distance(finger.tip, .wrist), let mcp = distance(finger.mcp, .wrist), mcp > 0.005 else { return nil }
        return tip / mcp
    }

    /// The "two fingers" pose: index and middle fingers extended, ring finger and pinky curled. Whether the fingers
    /// are together or apart doesn't matter: in live testing they were held together. `nil` if the visible joints
    /// can't tell.
    func twoFingerVote(extended: Double, bent: Double) -> Bool? {
        func isExtended(_ finger: Finger) -> Bool? {
            if isCurled(tip: finger.tip, pip: finger.pip) == true { return false }
            return extensionRatio(of: finger).map { $0 > extended }
        }
        func isBent(_ finger: Finger) -> Bool? {
            if isCurled(tip: finger.tip, pip: finger.pip) == true { return true }
            return extensionRatio(of: finger).map { $0 < bent }
        }
        guard let index = isExtended(.index), let middle = isExtended(.middle) else { return nil }
        guard index, middle else { return false }
        // The curled ring finger and pinky are often hidden behind the palm: one is enough if the other isn't straight.
        let others = [isBent(.ring), isBent(.little)]
        if others.contains(false) { return false }
        return others.contains(true) ? true : nil
    }

    /// Whether an already started "two fingers" pose holds: until the ring finger and pinky have both straightened,
    /// as on an open palm.
    /// The index and middle fingers can bend any way, up to a fist: that's how fingers get "lifted" off a trackpad.
    /// A single slightly straightened pinky doesn't break the pose: in live testing it relaxed mid-motion.
    func twoFingerHoldVote(extended: Double) -> Bool? {
        let opened = [Finger.ring, .little].map { finger -> Bool? in
            if isCurled(tip: finger.tip, pip: finger.pip) == true { return false }
            return extensionRatio(of: finger).map { $0 > extended }
        }
        if opened.allSatisfy({ $0 == true }) { return false }
        return opened.contains(false) ? true : nil
    }
}

/// Frame edges in Vision coordinates, not mirrored.
enum FrameEdge: Sendable {
    case left, right, top, bottom
}

extension HandPose {
    /// Distance from the hand to each frame edge, as a fraction of the frame. Vision loses the hand when a noticeable
    /// part of it goes past the edge, so it's worth warning early.
    var edgeMargins: [FrameEdge: Double] {
        let xs = points.compactMap { $0?.x }.map { $0 / aspect }
        let ys = points.compactMap { $0?.y }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return [:] }
        return [.left: minX, .right: 1 - maxX, .bottom: minY, .top: 1 - maxY]
    }

    /// The nearest edge, if the hand has come closer to it than `threshold`.
    func nearestEdge(within threshold: Double) -> FrameEdge? {
        edgeMargins.filter { $0.value < threshold }.min { $0.value < $1.value }?.key
    }
}

extension HandPose {
    /// The same hand in a horizontally mirrored frame. Desk View shows the desk from the person's point of view, so
    /// a hand moving right goes right there but left on the front camera: mirroring aligns the axes of both cameras.
    func flippedHorizontally() -> HandPose {
        var flipped = self
        flipped.points = points.map { $0.map { CGPoint(x: aspect - $0.x, y: $0.y) } }
        return flipped
    }
}

extension HandPose {
    /// A rough center of all visible points: for recognizing the hand from frame to frame, not for the cursor.
    var center: CGPoint? {
        let available = points.compactMap { $0 }
        guard !available.isEmpty else { return nil }
        let sum = available.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / Double(available.count), y: sum.y / Double(available.count))
    }
}

/// Which hand drives the cursor and which is the other one. While the hands are tracked, we go by their positions
/// rather than the "left/right" label, which Vision mixes up on the fly. The preferred side is only considered
/// when the leading hand is looked up afresh.
///
/// Remembers the positions of both hands and matches them jointly. It used to pick the hand closest to the leading
/// one, so as soon as Vision lost the leading hand for a frame, the other hand became the leading one and the choice
/// stuck to it. That is how, in the middle of a two-hand scroll, the fist became the leading hand and a new scroll
/// did not start for 10 seconds: the engine waits for a fist on the second hand (log of November 2, 121.8-137.4 s).
struct HandTracker: Sendable {
    /// A lone hand farther than this from the previous position is no longer considered the same hand.
    static let gate = 0.25
    /// How long the position of the second hand is remembered after it disappears.
    static let secondMemory = 1.0

    private var lead: CGPoint?
    private var second: CGPoint?
    private var secondSeen = -Double.infinity

    /// Splits the frame's hands into the leading one and the other one; `phase` is the engine phase after the previous
    /// frame. In `noHand` the engine considers the leading hand gone: only then is its position forgotten and the
    /// leading hand searched for anew; until then a leading hand that vanished for a frame stays vanished, and the
    /// other hand does not take its place. A leading fist is not swapped on the fly when the other hand is open:
    /// once control is taken, a fist on the leading hand means a clutch, and swapping would trigger a two-hand
    /// scroll from a stray second hand. Swapping before taking control was checked against the logs of November 1-2:
    /// the number of scrolls in them jumped both ways (20 and 13, 8 and 15), i.e. the behavior became unpredictable.
    mutating func assign(_ hands: [HandPose], preferred: Chirality?, phase: GesturePhase, time: Double) -> (hand: HandPose?, other: HandPose?) {
        if phase == .noHand { lead = nil }
        if time - secondSeen > Self.secondMemory { second = nil }
        let hands = hands.filter { $0.center != nil }
        var hand: HandPose?
        var other: HandPose?
        if let lead {
            switch hands.count {
            case 0:
                break
            case 1:
                let only = hands[0]
                let toLead = Self.distance(only.center, lead)
                let toSecond = second.map { Self.distance(only.center, $0) } ?? .infinity
                if toSecond < toLead, toSecond < Self.gate {
                    // The leading hand vanished for a frame, and the other hand is visible.
                    other = only
                } else if toLead < Self.gate || Self.pick([only], preferred: preferred) != nil {
                    hand = only
                } else {
                    other = only
                }
            default:
                let (a, b) = (hands[0], hands[1])
                let straight = Self.distance(a.center, lead) + (second.map { Self.distance(b.center, $0) } ?? 0)
                let crossed = Self.distance(b.center, lead) + (second.map { Self.distance(a.center, $0) } ?? 0)
                // No distance threshold: the scrolling hand leaves the frame and comes back far from where it vanished,
                // while the other hand's fist stays in place all that time (log of November 1 21:46, 33.8 s).
                (hand, other) = straight <= crossed ? (a, b) : (b, a)
            }
        } else {
            hand = Self.pick(hands, preferred: preferred)
            other = hands.first { $0 != hand }
            second = nil
        }
        if let center = hand?.center { self.lead = center }
        if let center = other?.center {
            second = center
            secondSeen = time
        }
        return (hand, other)
    }

    /// The leading hand afresh: of the preferred side if one is set, an open hand before a fist, a larger hand before
    /// a smaller one. A fist paired with an open hand is the hand that holds a scroll, or a clutch, while the user
    /// means to drive the cursor with the open one.
    private static func pick(_ hands: [HandPose], preferred: Chirality?) -> HandPose? {
        let candidates = preferred.map { side in hands.filter { $0.chirality == side } } ?? hands
        return candidates.max { lhs, rhs in
            let lhsFist = lhs.fistVote == true
            let rhsFist = rhs.fistVote == true
            if lhsFist != rhsFist { return lhsFist }
            return (lhs.scale ?? 0) < (rhs.scale ?? 0)
        }
    }

    private static func distance(_ point: CGPoint?, _ other: CGPoint) -> Double {
        guard let point else { return .infinity }
        return hypot(point.x - other.x, point.y - other.y)
    }
}
