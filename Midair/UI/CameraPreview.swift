import AVFoundation
import SwiftUI

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool
    /// Changes on every camera start: a new configuration has a new connection, so mirroring is set again.
    let generation: Int

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.mirrored = mirrored
        view.applyMirroring()
    }
}

final class PreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    var mirrored = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        previewLayer.videoGravity = .resizeAspect
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        previewLayer
    }

    override func layout() {
        super.layout()
        applyMirroring()
    }

    func applyMirroring() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}

struct SkeletonOverlay: View {
    let hand: HandPose?
    let phase: GesturePhase
    let mirrored: Bool

    private static let bones: [(HandJoint, HandJoint)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP),
    ]

    var body: some View {
        Canvas { context, size in
            guard let hand else { return }
            let frame = Self.videoRect(in: size, aspect: hand.aspect)
            func project(_ point: CGPoint) -> CGPoint {
                let x = point.x / hand.aspect
                return CGPoint(x: frame.minX + (mirrored ? 1 - x : x) * frame.width,
                               y: frame.minY + (1 - point.y) * frame.height)
            }

            var bones = Path()
            for (from, to) in Self.bones {
                guard let a = hand[from], let b = hand[to] else { continue }
                bones.move(to: project(a))
                bones.addLine(to: project(b))
            }
            context.stroke(bones, with: .color(phase.tint), style: StrokeStyle(lineWidth: 3, lineCap: .round))

            for joint in HandJoint.allCases {
                guard let point = hand[joint] else { continue }
                let p = project(point)
                let radius: CGFloat = [.thumbTip, .indexTip, .middleTip].contains(joint) ? 5 : 3.5
                context.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                             with: .color(.white))
            }

            // The ring shows the anchor point the cursor follows.
            if let anchor = hand.anchor {
                let p = project(anchor)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                               with: .color(phase.tint), lineWidth: 3)
            }
        }
        .allowsHitTesting(false)
    }

    /// The rectangle the video occupies with `.resizeAspect`.
    static func videoRect(in size: CGSize, aspect: Double) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        if size.width / size.height > aspect {
            let width = size.height * aspect
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
        let height = size.width / aspect
        return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
    }
}
