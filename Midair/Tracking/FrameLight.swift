import CoreMedia
import CoreVideo

enum FrameLight {
    /// What the camera itself reports about light in the frame's `MetadataDictionary` attachment. The keys are undocumented
    /// (they show up in the `DualCameraProbe` report), so everything is optional: without them darkness is judged
    /// by frame brightness alone.
    struct CameraReport {
        /// Illuminance estimate in lux.
        var lux: Double?
        /// Auto exposure hit its limit: exposure time and gain are at maximum, the frame won't get any brighter.
        var exposureLimited: Bool?
    }

    static func cameraReport(of sampleBuffer: CMSampleBuffer) -> CameraReport {
        guard let metadata = CMGetAttachment(sampleBuffer, key: "MetadataDictionary" as CFString,
                                             attachmentModeOut: nil) as? NSDictionary else { return CameraReport() }
        return CameraReport(lux: (metadata["AdaptiveLuxValue"] as? NSNumber)?.doubleValue,
                            exposureLimited: (metadata["AELimitsReached"] as? NSNumber)?.boolValue)
    }

    /// Average frame brightness from 0 to 1 over a sparse grid of points: a few thousand reads, microseconds.
    static func brightness(of buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA { return bgraBrightness(of: buffer) }
        guard CVPixelBufferIsPlanar(buffer), let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return 0.5 }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let step = 16
        var sum = 0
        var count = 0
        for y in stride(from: step / 2, to: height, by: step) {
            let row = luma + y * bytesPerRow
            for x in stride(from: step / 2, to: width, by: step) {
                sum += Int(row[x])
                count += 1
            }
        }
        guard count > 0 else { return 0.5 }
        // Mac camera frames are in 420v format: their luma ranges from 16 to 235.
        return min(max((Double(sum) / Double(count) - 16) / 219, 0), 1)
    }

    /// The same brightness for BGRA frames, which Vision receives. The buffer is already locked for reading.
    private static func bgraBrightness(of buffer: CVPixelBuffer) -> Double {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0.5 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let step = 16
        var sum = 0
        var count = 0
        // while loops instead of stride: in a debug build the stride iterator shows up in the profile.
        var y = step / 2
        while y < height {
            let row = pixels + y * bytesPerRow
            var x = step / 2
            while x < width {
                // BT.601 luma from B, G, R with weights 29, 150 and 77 out of 256; full range, from 0 to 255.
                let pixel = row + x * 4
                sum += Int(pixel[0]) * 29 + Int(pixel[1]) * 150 + Int(pixel[2]) * 77
                count += 1
                x += step
            }
            y += step
        }
        guard count > 0 else { return 0.5 }
        return min(max(Double(sum) / Double(count * 256 * 255), 0), 1)
    }
}
