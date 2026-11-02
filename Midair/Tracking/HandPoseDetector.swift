import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Vision

/// Finds hands in the frame via Vision. Not thread-safe: call from a single queue.
///
/// Returns all found points with confidences, and the core cuts off low-confidence ones (`HandPose.filtered`):
/// that way the threshold can be tuned by replaying the log.
final class HandPoseDetector {
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()

    /// Vision renders the brightened frame itself, with this context: creating one per frame is expensive.
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let brightening = CIFilter.gammaAdjust()

    private let joints: [(VNHumanHandPoseObservation.JointName, HandJoint)] = [
        (.wrist, .wrist),
        (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP), (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
        (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
        (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
        (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
        (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleDIP, .littleDIP), (.littleTip, .littleTip),
    ]

    /// `gamma` below 1 brightens the frame with an `x^gamma` curve before recognition:
    /// in the dark this can pull the hand out of the shadows.
    func detect(in pixelBuffer: CVPixelBuffer, gamma: Double = 1) throws -> [HandPose] {
        let handler: VNImageRequestHandler
        if gamma < 1, let image = brightened(pixelBuffer, gamma: gamma) {
            handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [.ciContext: context])
        } else {
            handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        }
        try handler.perform([request])
        let aspect = Double(CVPixelBufferGetWidth(pixelBuffer)) / Double(CVPixelBufferGetHeight(pixelBuffer))

        return (request.results ?? []).compactMap { observation in
            guard let recognized = try? observation.recognizedPoints(.all) else { return nil }
            var points: [HandJoint: CGPoint] = [:]
            var confidences: [HandJoint: Double] = [:]
            for (name, joint) in joints {
                guard let point = recognized[name], point.confidence > 0 else { continue }
                points[joint] = CGPoint(x: point.location.x * aspect, y: point.location.y)
                confidences[joint] = Double(point.confidence)
            }
            let chirality: Chirality? = switch observation.chirality {
            case .left: .left
            case .right: .right
            default: nil
            }
            return HandPose(points: points, confidences: confidences, chirality: chirality,
                            confidence: Double(observation.confidence), aspect: aspect)
        }
    }

    private func brightened(_ pixelBuffer: CVPixelBuffer, gamma: Double) -> CIImage? {
        brightening.inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        brightening.power = Float(gamma)
        return brightening.outputImage
    }
}
