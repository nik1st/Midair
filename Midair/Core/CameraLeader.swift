import Foundation

/// Camera in "Two cameras" mode: the main camera looks at the person and sees a raised hand,
/// Desk View of the same sensor looks down at the desk and sees a lowered one.
enum CameraSource: Sendable {
    case main, desk
}

/// Decides which of the two cameras drives the cursor: the one that sees the hand more confidently
/// and not near the edge. Switching needs a margin and several frames in a row, so the leading camera
/// doesn't flip back and forth while both cameras see the hand.
struct CameraLeader {
    private(set) var current = CameraSource.main
    private var latest: [CameraSource: (quality: Double, time: Double)] = [:]
    private var challengerFrames = 0

    /// How much better the other camera must see the hand, and for how many frames in a row, to take the lead.
    private static let margin = 0.15
    private static let confirmFrames = 3
    /// A hand closer to the edge than this (as a fraction of the frame) is about to leave the frame,
    /// so that camera is trusted half as much.
    private static let edgeMargin = 0.08
    /// A frame from the leading camera older than this doesn't count: its stream may have been interrupted.
    private static let staleAfter = 0.2

    /// Accounts for the hand found in a frame from camera `source`. Returns `true` if the leading camera changed.
    mutating func update(source: CameraSource, hand: HandPose?, time: Double) -> Bool {
        let quality = Self.quality(of: hand)
        latest[source] = (quality, time)
        guard source != current else { return false }
        let leading = latest[current].flatMap { time - $0.time < Self.staleAfter ? $0.quality : nil } ?? 0
        challengerFrames = quality > leading + Self.margin ? challengerFrames + 1 : 0
        guard challengerFrames >= Self.confirmFrames else { return false }
        current = source
        challengerFrames = 0
        return true
    }

    private static func quality(of hand: HandPose?) -> Double {
        guard let hand, hand.scale != nil else { return 0 }
        return hand.nearestEdge(within: edgeMargin) == nil ? hand.confidence : hand.confidence / 2
    }
}
