import AppKit
import QuartzCore
import SwiftUI

/// Badge of the current gesture next to the cursor: without feedback, mid-air gestures are hard to read.
/// The ring around the badge fills while the palm or the pinch builds up time: blue while the palm takes control,
/// orange while a held pinch is heading for a right-click. When the hand is at a frame edge, an arrow next to it
/// shows where to bring the hand back.
@MainActor
final class CursorHUD: NSObject {
    private let size = CGSize(width: 52, height: 26)
    private var panel: NSPanel?
    private var host: NSHostingView<CursorBadge>?
    private var current: CursorBadge?
    /// Display ticks on which the badge catches up with the cursor. Snapshots come 30 times a second, while the cursor
    /// glides in step with the display: a badge that moved only with snapshots would lag and jerk.
    private var link: CADisplayLink?
    private var lastMouse: NSPoint?
    private var movedAt: CFTimeInterval = 0

    /// `edge` is the frame edge the hand is at, as it appears on the preview.
    func show(phase: GesturePhase, cue: GestureCue, edge: FrameEdge?) {
        guard phase != .noHand else { return hide() }
        let panel = panel ?? makePanel()
        // The ring changes in tenths: otherwise the badge would redraw with every snapshot.
        let badge = CursorBadge(phase: phase, ring: CursorRing(cue), edge: edge)
        if badge != current {
            host?.rootView = badge
            current = badge
        }
        let link = link ?? makeLink(for: panel)
        if follow() || !panel.isVisible {
            movedAt = CACurrentMediaTime()
            link.isPaused = false
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Also called with every snapshot while the badge isn't needed: no point hiding an already hidden panel.
    func hide() {
        current = nil
        link?.isPaused = true
        if panel?.isVisible == true { panel?.orderOut(nil) }
    }

    /// Places the badge at the cursor; `true` if the cursor moved since last time.
    private func follow() -> Bool {
        let mouse = NSEvent.mouseLocation
        guard mouse != lastMouse else { return false }
        lastMouse = mouse
        panel?.setFrameOrigin(NSPoint(x: mouse.x + 12, y: mouse.y - 12 - size.height))
        return true
    }

    @objc private func tick(_ link: CADisplayLink) {
        if follow() {
            movedAt = link.timestamp
        } else if link.timestamp - movedAt > 0.25 {
            // The cursor is still: ticks aren't needed until it moves, and the next snapshot will notice the move.
            link.isPaused = true
        }
    }

    private func makeLink(for panel: NSPanel) -> CADisplayLink {
        let link = panel.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        return link
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: CursorBadge(phase: .hover, ring: nil, edge: nil))
        panel.contentView = host
        self.panel = panel
        self.host = host
        return panel
    }
}

/// Readiness ring at the badge: the fraction in tenths and the stage color.
struct CursorRing: Equatable {
    enum Stage: Equatable {
        case engaging, holding, rightClick
    }

    var stage: Stage
    var tenths: Int

    init?(_ cue: GestureCue) {
        switch cue {
        case .none: return nil
        case let .engaging(fraction): (stage, tenths) = (.engaging, Int(fraction * 10))
        case let .holding(fraction): (stage, tenths) = (.holding, Int(fraction * 10))
        case .rightClick: (stage, tenths) = (.rightClick, 10)
        }
    }

    var tint: Color {
        switch stage {
        case .engaging: .blue
        case .holding, .rightClick: .orange
        }
    }
}

struct CursorBadge: View, Equatable {
    let phase: GesturePhase
    let ring: CursorRing?
    let edge: FrameEdge?

    var body: some View {
        HStack(spacing: 0) {
            Self.circle(symbol, tint: phase.tint, ring: ring)
            if let edge {
                Self.circle(edge.returnSymbol, tint: .orange, ring: nil)
            }
        }
        .frame(width: 52, height: 26, alignment: .leading)
    }

    /// When releasing will give a right-click, the badge shows it.
    private var symbol: String {
        ring?.stage == .rightClick ? "contextualmenu.and.cursorarrow" : phase.symbol
    }

    private static func circle(_ symbol: String, tint: Color, ring: CursorRing?) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(tint, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
            .overlay {
                if let ring {
                    Circle()
                        .trim(from: 0, to: Double(ring.tenths) / 10)
                        .stroke(ring.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(-3)
                }
            }
            .frame(width: 26, height: 26)
    }
}

private extension FrameEdge {
    /// Arrow from the edge into the frame: that's where the hand should go back.
    var returnSymbol: String {
        switch self {
        case .left: "arrow.right"
        case .right: "arrow.left"
        case .top: "arrow.down"
        case .bottom: "arrow.up"
        }
    }
}

extension GesturePhase {
    var title: LocalizedStringResource {
        switch self {
        case .noHand: "No hand in view"
        case .standby: "Hold an open palm still to start"
        case .hover: "Cursor"
        case .clutch: "Fist: the cursor stays put"
        case .pinched: "Pinch: release to click or move your hand to drag"
        case .dragging: "Dragging"
        case .scrolling: "Scrolling: move your hand; a fist or bent fingers reposition it"
        }
    }

    var symbol: String {
        switch self {
        case .noHand: "hand.raised.slash"
        case .standby: "hand.raised"
        case .hover: "cursorarrow"
        case .clutch: "pause.fill"
        case .pinched: "cursorarrow.click"
        case .dragging: "arrow.up.and.down.and.arrow.left.and.right"
        case .scrolling: "arrow.up.and.down"
        }
    }

    var tint: Color {
        switch self {
        case .noHand, .standby, .clutch: .gray
        case .hover: .blue
        case .pinched, .dragging: .green
        case .scrolling: .purple
        }
    }
}
