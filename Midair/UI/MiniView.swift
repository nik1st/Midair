import AppKit
import SwiftUI

/// A floating mini window above all windows: whether the hand is visible, where it is in the frame and where it went.
/// Needed when the main window is hidden and the cursor suddenly stops responding.
@MainActor
final class MiniViewPanel {
    private static let autosaveName = "MidairMiniView"
    private let panel: NSPanel

    init(model: AppModel) {
        let host = DraggableHostingView(rootView: MiniView().environment(model))
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = host
        if !panel.setFrameUsingName(Self.autosaveName), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 16, y: screen.minY + 16))
        }
        panel.setFrameAutosaveName(Self.autosaveName)
    }

    func setVisible(_ visible: Bool) {
        if visible {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            panel.orderOut(nil)
        }
    }
}

/// A borderless window can be dragged by any spot: it has no title bar.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

struct MiniView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.status
        let mirrored = model.config.invertX
        // The diagram follows the frame proportions of the leading camera: narrower for 4:3 than for 16:9,
        // while the window size stays the same.
        let aspect = status.handAspect
        VStack(alignment: .leading, spacing: 6) {
            LiveMinimap(mirrored: mirrored)
                .frame(width: min(224, 126 * aspect), height: min(126, 224 / aspect))
                .overlay(alignment: .topLeading) {
                    if status.isDual {
                        MinimapBadge(text: status.leader == .desk ? "desk" : "face")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if status.isDark {
                        MinimapBadge(text: "dark", symbol: "moon.fill")
                    }
                }
                .frame(maxWidth: .infinity)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: status.phase.symbol)
                    .foregroundStyle(status.phase.tint)
                Text(status.hint)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text("\(status.framesPerSecond) fps")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .frame(height: 30, alignment: .top)
        }
        .padding(8)
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Frame diagram with the hand from the latest snapshot. The hand changes with every snapshot,
/// and only the diagram redraws with it.
private struct LiveMinimap: View {
    @Environment(AppModel.self) private var model
    let mirrored: Bool

    var body: some View {
        HandMinimap(hand: model.liveHand, lastSeen: model.lastSeenHand, phase: model.status.phase, mirrored: mirrored)
    }
}

/// Caption in the corner of the frame diagram.
private struct MinimapBadge: View {
    let text: LocalizedStringKey
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.5), in: Capsule())
        .padding(4)
    }
}

/// Frame diagram: the hand skeleton, a glow on a nearby edge and, once the hand is gone, its last position
/// and an arrow toward where it went.
struct HandMinimap: View {
    let hand: HandPose?
    let lastSeen: HandPose?
    let phase: GesturePhase
    let mirrored: Bool

    var body: some View {
        let aspect = (hand ?? lastSeen)?.aspect ?? 16.0 / 9.0
        ZStack {
            Rectangle().fill(.black.opacity(0.6))
            if let hand {
                SkeletonOverlay(hand: hand, phase: phase, mirrored: mirrored)
                EdgeGlow(margins: hand.edgeMargins, aspect: aspect, mirrored: mirrored)
            } else if let lastSeen {
                // The gesture color stays while the gesture holds without a hand: you can see the drag isn't dropped.
                SkeletonOverlay(hand: lastSeen, phase: phase, mirrored: mirrored)
                    .opacity(0.3)
                if let edge = lastSeen.nearestEdge(within: HandHint.exitMargin) {
                    ExitArrow(edge: edge.displayed(mirrored: mirrored))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct EdgeGlow: View {
    let margins: [FrameEdge: Double]
    let aspect: Double
    let mirrored: Bool

    var body: some View {
        Canvas { context, size in
            let video = SkeletonOverlay.videoRect(in: size, aspect: aspect)
            let thickness = video.height * 0.07
            for (edge, margin) in margins where margin < HandHint.warnMargin {
                let strength = 1 - max(margin, 0) / HandHint.warnMargin
                let rect = switch edge.displayed(mirrored: mirrored) {
                case .left: CGRect(x: video.minX, y: video.minY, width: thickness, height: video.height)
                case .right: CGRect(x: video.maxX - thickness, y: video.minY, width: thickness, height: video.height)
                case .top: CGRect(x: video.minX, y: video.minY, width: video.width, height: thickness)
                case .bottom: CGRect(x: video.minX, y: video.maxY - thickness, width: video.width, height: thickness)
                }
                context.fill(Path(rect), with: .color(.red.opacity(0.3 + 0.6 * strength)))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ExitArrow: View {
    let edge: FrameEdge

    var body: some View {
        let (symbol, alignment): (String, Alignment) = switch edge {
        case .left: ("arrow.left", .leading)
        case .right: ("arrow.right", .trailing)
        case .top: ("arrow.up", .top)
        case .bottom: ("arrow.down", .bottom)
        }
        Image(systemName: symbol)
            .font(.title2.weight(.bold))
            .foregroundStyle(.orange)
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

enum HandHint {
    /// Closer than this to an edge (as a fraction of the frame), the hand counts as "at the edge".
    static let warnMargin = 0.08
    /// If the hand vanished closer than this to an edge, it went past that edge rather than getting lost mid-frame.
    static let exitMargin = 0.15

    static func text(for snapshot: TrackingSnapshot, lastSeen: HandPose?, mirrored: Bool) -> String {
        if snapshot.isSuspended { return String(localized: "Paused: you're using the keyboard or mouse") }
        if let hand = snapshot.hand {
            guard let edge = hand.nearestEdge(within: warnMargin) else { return cueText(snapshot.cue) ?? String(localized: snapshot.phase.title) }
            // Desk View looks down at the desk: the bottom of its frame is the desk edge near the person,
            // the top is the edge near the screen.
            let onDesk = snapshot.isDual && snapshot.leader == .desk
            return switch edge.displayed(mirrored: mirrored) {
            case .bottom: onDesk ? String(localized: "At the near edge of the desk: move your hand away from you") : String(localized: "At the bottom edge: raise your hand")
            case .top: onDesk ? String(localized: "At the far edge of the desk: move your hand toward you") : String(localized: "At the top edge: lower your hand")
            case .left: String(localized: "At the left edge: move your hand to the right")
            case .right: String(localized: "At the right edge: move your hand to the left")
            }
        }
        if snapshot.phase == .dragging { return String(localized: "Holding the drag: bring your pinching hand back") }
        guard let lastSeen else {
            return snapshot.isDark ? String(localized: "No hand in view: it's dark, add some light") : String(localized: "No hand in view: raise your palm to the camera")
        }
        guard let edge = lastSeen.nearestEdge(within: exitMargin) else {
            return snapshot.isDark ? String(localized: "Hand lost: it's dark, add some light") : String(localized: "Hand lost mid-frame: turn your palm to the camera")
        }
        return switch edge.displayed(mirrored: mirrored) {
        case .bottom: String(localized: "Hand left the frame at the bottom")
        case .top: String(localized: "Hand left the frame at the top")
        case .left: String(localized: "Hand left the frame on the left")
        case .right: String(localized: "Hand left the frame on the right")
        }
    }

    /// What releasing the pinch will do: without a hint, a blind hold is guesswork.
    private static func cueText(_ cue: GestureCue) -> String? {
        switch cue {
        case .holding: String(localized: "Hold for a right-click or move your hand to drag")
        case .rightClick: String(localized: "Release for a right-click")
        case .none, .engaging: nil
        }
    }

    /// The frame edge the hand is at, or the one it went past mid-gesture: from it, an arrow at the cursor
    /// shows where to bring the hand back. Edges are in Vision coordinates, without mirroring.
    static func edge(for snapshot: TrackingSnapshot, lastSeen: HandPose?) -> FrameEdge? {
        if let hand = snapshot.hand { return hand.nearestEdge(within: warnMargin) }
        // The gesture holds without a hand (a drag waits up to a second for it): hint where to bring it back from.
        guard snapshot.phase.isActive else { return nil }
        return lastSeen?.nearestEdge(within: exitMargin)
    }
}

extension FrameEdge {
    /// The edge as it appears on the mirrored preview image.
    func displayed(mirrored: Bool) -> FrameEdge {
        guard mirrored else { return self }
        switch self {
        case .left: return .right
        case .right: return .left
        case .top, .bottom: return self
        }
    }
}
