import CoreGraphics
import Foundation
import Testing

/// A hand centered near `(x, y)` in frame-height units: fingers extended upward or bent into a fist.
private func hand(at x: Double, _ y: Double, fist: Bool = false, size: Double = 0.12, side: Chirality? = nil) -> HandPose {
    var points: [HandJoint: CGPoint] = [.wrist: CGPoint(x: x, y: y - size)]
    let fingers: [(HandJoint, HandJoint, HandJoint, HandJoint)] = [
        (.indexMCP, .indexPIP, .indexDIP, .indexTip), (.middleMCP, .middlePIP, .middleDIP, .middleTip),
        (.ringMCP, .ringPIP, .ringDIP, .ringTip), (.littleMCP, .littlePIP, .littleDIP, .littleTip),
    ]
    for (index, (mcp, pip, dip, tip)) in fingers.enumerated() {
        let fx = x - size * 0.3 + Double(index) * size * 0.2
        points[mcp] = CGPoint(x: fx, y: y)
        points[pip] = CGPoint(x: fx, y: y + size * 0.3)
        // In a fist the tip is curled back toward the palm: closer to the wrist than the middle joint.
        points[dip] = CGPoint(x: fx, y: fist ? y + size * 0.15 : y + size * 0.5)
        points[tip] = CGPoint(x: fx, y: fist ? y - size * 0.1 : y + size * 0.7)
    }
    points[.thumbCMC] = CGPoint(x: x - size * 0.4, y: y - size * 0.7)
    points[.thumbMP] = CGPoint(x: x - size * 0.5, y: y - size * 0.4)
    points[.thumbIP] = CGPoint(x: x - size * 0.55, y: y - size * 0.2)
    points[.thumbTip] = CGPoint(x: x - size * 0.6, y: y)
    return HandPose(points: points, chirality: side)
}

@Test func syntheticHandsReadAsOpenAndFist() {
    #expect(hand(at: 0.6, 0.5).fistVote == false)
    #expect(hand(at: 1.2, 0.5, fist: true).fistVote == true)
}

@Test func lostLeadDoesNotHandItsPlaceToTheFist() {
    // Journal of 2 November, 121.75 s: Vision lost the scrolling hand for two frames and only the second hand's
    // fist was left in the frame.
    var tracker = HandTracker()
    let open = hand(at: 0.94, 0.45)
    let fist = hand(at: 1.21, 0.56, fist: true)
    var result = tracker.assign([open, fist], preferred: nil, phase: .hover, time: 0)
    #expect(result.hand == open && result.other == fist)
    result = tracker.assign([fist], preferred: nil, phase: .hover, time: 0.033)
    #expect(result.hand == nil && result.other == fist)
    result = tracker.assign([fist], preferred: nil, phase: .hover, time: 0.066)
    #expect(result.hand == nil && result.other == fist)
    // The hand came back: Vision returns hands in any order, and the open one stays the lead.
    let back = hand(at: 0.91, 0.40)
    result = tracker.assign([fist, back], preferred: nil, phase: .hover, time: 0.1)
    #expect(result.hand == back && result.other == fist)
}

@Test func handsKeepTheirRolesWhateverOrderVisionGivesThem() {
    var tracker = HandTracker()
    var x = 0.5
    _ = tracker.assign([hand(at: x, 0.5), hand(at: 1.1, 0.5, fist: true)], preferred: nil, phase: .hover, time: 0)
    for frame in 1...20 {
        // The lead hand scrolls quickly toward the fist, Vision swaps the order of the hands every other frame.
        x += 0.02
        let lead = hand(at: x, 0.5)
        let fist = hand(at: 1.1, 0.5, fist: true)
        let hands = frame.isMultiple(of: 2) ? [lead, fist] : [fist, lead]
        let result = tracker.assign(hands, preferred: nil, phase: .hover, time: Double(frame) / 30)
        #expect(result.hand == lead)
    }
}

@Test func fastStrokeTowardTheFistDoesNotSwapHands() {
    // The old selection took the hand closest to the lead's previous position: a hand that moved 0.25 in one frame
    // lost to a fist 0.2 away.
    var tracker = HandTracker()
    _ = tracker.assign([hand(at: 0.5, 0.5), hand(at: 0.3, 0.5, fist: true)], preferred: nil, phase: .hover, time: 0)
    let lead = hand(at: 0.75, 0.5)
    let result = tracker.assign([hand(at: 0.3, 0.5, fist: true), lead], preferred: nil, phase: .hover, time: 0.033)
    #expect(result.hand == lead)
}

@Test func newLeadIsTheOpenHandRatherThanTheFist() {
    var tracker = HandTracker()
    // The fist is closer to the camera and larger, but the cursor is meant to be driven by the open hand.
    let fist = hand(at: 1.2, 0.5, fist: true, size: 0.16)
    let open = hand(at: 0.6, 0.5, size: 0.12)
    let result = tracker.assign([fist, open], preferred: nil, phase: .hover, time: 0)
    #expect(result.hand == open && result.other == fist)
}

@Test func lonelyFistStillLeadsAsLiftedMouse() {
    var tracker = HandTracker()
    let fist = hand(at: 0.8, 0.5, fist: true)
    #expect(tracker.assign([fist], preferred: nil, phase: .hover, time: 0).hand == fist)
}

@Test func clutchedLeadIsNotSwappedForAnIdleOpenHand() {
    // The lead hand clenched into a fist to reposition, while the second hand simply rests in the frame, open.
    var tracker = HandTracker()
    _ = tracker.assign([hand(at: 0.6, 0.5), hand(at: 1.3, 0.4)], preferred: nil, phase: .hover, time: 0)
    let clutched = hand(at: 0.6, 0.5, fist: true)
    let result = tracker.assign([hand(at: 1.3, 0.4), clutched], preferred: nil, phase: .hover, time: 0.033)
    #expect(result.hand == clutched)
}

@Test func secondHandLeadsOnlyAfterTheEngineGivesUpOnTheLead() {
    var tracker = HandTracker()
    let second = hand(at: 1.3, 0.4)
    _ = tracker.assign([hand(at: 0.6, 0.5), second], preferred: nil, phase: .hover, time: 0)
    #expect(tracker.assign([second], preferred: nil, phase: .hover, time: 0.1).hand == nil)
    let result = tracker.assign([second], preferred: nil, phase: .noHand, time: 0.4)
    #expect(result.hand == second && result.other == nil)
}

@Test func forgottenSecondHandDoesNotCaptureTheLead() {
    var tracker = HandTracker()
    _ = tracker.assign([hand(at: 0.6, 0.5), hand(at: 1.3, 0.4)], preferred: nil, phase: .hover, time: 0)
    // The second hand left, and a couple of seconds later the lead hand arrived at its place.
    var x = 0.6
    var result: (hand: HandPose?, other: HandPose?) = (nil, nil)
    for frame in 1...60 {
        x = min(x + 0.02, 1.3)
        result = tracker.assign([hand(at: x, 0.4)], preferred: nil, phase: .hover, time: 2 + Double(frame) / 30)
    }
    #expect(result.hand != nil)
}

@Test func preferredSideCountsOnlyWhenSearchingAnew() {
    var tracker = HandTracker()
    let right = hand(at: 0.6, 0.5, side: .right)
    let left = hand(at: 1.2, 0.5, side: .left)
    #expect(tracker.assign([left, right], preferred: .right, phase: .hover, time: 0).hand == right)
    // Vision mixed up the label on the fly: it is the same hand, and it stays the lead.
    let relabeled = hand(at: 0.62, 0.5, side: .left)
    #expect(tracker.assign([relabeled, hand(at: 1.2, 0.5, side: .right)], preferred: .right, phase: .hover, time: 0.033).hand == relabeled)
}

@Test func liftedMouseKeepsTheFistLeading() {
    // Control is taken, the lead hand is clenched into a fist to reposition it: the open second hand doesn't take over.
    var tracker = HandTracker()
    _ = tracker.assign([hand(at: 0.6, 0.5), hand(at: 1.3, 0.4)], preferred: nil, phase: .hover, time: 0)
    let clutched = hand(at: 0.6, 0.5, fist: true)
    #expect(tracker.assign([clutched, hand(at: 1.3, 0.4)], preferred: nil, phase: .clutch, time: 0.033).hand == clutched)
}
