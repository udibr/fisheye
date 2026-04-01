import Foundation
import CoreGraphics
import CoreImage

/// Strategy for maintaining stereo consistency when applying super resolution.
enum SRStrategy {
    /// Apply SR to each eye independently. Simple but may introduce
    /// inconsistencies between left and right that confuse depth perception.
    case independent

    /// Average both eyes into a mono image, apply SR to the average,
    /// then reconstruct left and right by adding back the upscaled difference.
    /// Shared detail is consistent; only the stereo disparity varies.
    case averaged
}

/// Applies super resolution (2x) to stereo image pairs.
///
/// Design for experimentation:
/// - Switch `strategy` to compare consistency approaches.
/// - Replace `upscaleSingle(_:)` with a Core ML model for true neural SR.
///   The current implementation uses CILanczosScaleTransform (high-quality
///   resampling, not neural SR) as a working baseline.
final class SuperResolutionProcessor {

    var strategy: SRStrategy = .independent

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Public API

    /// Upscale a stereo pair to 2x resolution using the current strategy.
    func upscale(left: CGImage, right: CGImage) -> (left: CGImage, right: CGImage) {
        switch strategy {
        case .independent:
            return (upscaleSingle(left), upscaleSingle(right))
        case .averaged:
            return upscaleAveraged(left: left, right: right)
        }
    }

    // MARK: - Single Image Upscale

    /// Upscale a single image to 2x.
    /// Replace this method with a Core ML model for true neural super resolution.
    func upscaleSingle(_ image: CGImage) -> CGImage {
        let ciImage = CIImage(cgImage: image)

        guard let filter = CIFilter(name: "CILanczosScaleTransform") else {
            return image
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(2.0, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard let output = filter.outputImage,
              let result = ciContext.createCGImage(output, from: output.extent)
        else {
            return image
        }
        return result
    }

    // MARK: - Averaged Strategy

    /// Average both eyes, apply SR to the average, reconstruct stereo from upscaled differences.
    ///
    /// The idea: shared scene content (most of the image) gets a single consistent SR pass.
    /// Stereo disparity (small pixel shifts) is preserved via simple upscaling of the
    /// per-eye residuals, avoiding SR hallucination differences between eyes.
    ///
    /// Reconstruction:
    ///   avg       = (left + right) / 2
    ///   leftDiff  = left - avg       (half the stereo disparity)
    ///   rightDiff = right - avg
    ///   srAvg     = SR(avg)
    ///   srLeft    = srAvg + upscale(leftDiff)
    ///   srRight   = srAvg + upscale(rightDiff)
    private func upscaleAveraged(left: CGImage, right: CGImage) -> (left: CGImage, right: CGImage) {
        let width = left.width
        let height = left.height
        let bpp = 4
        let bytesPerRow = width * bpp
        let pixelCount = height * bytesPerRow

        // Read pixel data
        let leftData = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        let rightData = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        let avgData = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        let leftDiffData = UnsafeMutablePointer<Int16>.allocate(capacity: pixelCount)
        let rightDiffData = UnsafeMutablePointer<Int16>.allocate(capacity: pixelCount)
        defer {
            leftData.deallocate()
            rightData.deallocate()
            avgData.deallocate()
            leftDiffData.deallocate()
            rightDiffData.deallocate()
        }

        let colorSpace = left.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue

        guard let leftCtx = CGContext(data: leftData, width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                       space: colorSpace, bitmapInfo: bitmapInfo),
              let rightCtx = CGContext(data: rightData, width: width, height: height,
                                        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                        space: colorSpace, bitmapInfo: bitmapInfo)
        else {
            return (upscaleSingle(left), upscaleSingle(right))
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        leftCtx.draw(left, in: rect)
        rightCtx.draw(right, in: rect)

        // Compute average and signed differences
        for i in 0..<pixelCount {
            let l = Int16(leftData[i])
            let r = Int16(rightData[i])
            avgData[i] = UInt8((l + r) / 2)
            leftDiffData[i] = l - Int16(avgData[i])
            rightDiffData[i] = r - Int16(avgData[i])
        }

        // Create average CGImage and apply SR
        guard let avgCtx = CGContext(data: avgData, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace, bitmapInfo: bitmapInfo),
              let avgImage = avgCtx.makeImage()
        else {
            return (upscaleSingle(left), upscaleSingle(right))
        }

        let srAvg = upscaleSingle(avgImage)

        // Simple 2x upscale of differences (bilinear — no SR hallucination)
        let srLeftDiff = upscaleDifference(leftDiffData, width: width, height: height)
        let srRightDiff = upscaleDifference(rightDiffData, width: width, height: height)

        // Reconstruct: srAvg + upscaled difference
        let srLeft = reconstructFromAverage(srAvg: srAvg, diff: srLeftDiff, colorSpace: colorSpace)
        let srRight = reconstructFromAverage(srAvg: srAvg, diff: srRightDiff, colorSpace: colorSpace)

        return (srLeft, srRight)
    }

    // MARK: - Helpers for Averaged Strategy

    /// Bilinear 2x upscale of a signed Int16 difference buffer.
    private func upscaleDifference(
        _ data: UnsafePointer<Int16>, width: Int, height: Int
    ) -> UnsafeMutablePointer<Int16> {
        let bpp = 4
        let outW = width * 2
        let outH = height * 2
        let outData = UnsafeMutablePointer<Int16>.allocate(capacity: outW * outH * bpp)

        for j in 0..<outH {
            let srcY = Double(j) / 2.0
            let y0 = min(Int(srcY), height - 1)
            let y1 = min(y0 + 1, height - 1)
            let fy = srcY - Double(y0)

            for i in 0..<outW {
                let srcX = Double(i) / 2.0
                let x0 = min(Int(srcX), width - 1)
                let x1 = min(x0 + 1, width - 1)
                let fx = srcX - Double(x0)

                for ch in 0..<bpp {
                    let p00 = Double(data[y0 * width * bpp + x0 * bpp + ch])
                    let p10 = Double(data[y0 * width * bpp + x1 * bpp + ch])
                    let p01 = Double(data[y1 * width * bpp + x0 * bpp + ch])
                    let p11 = Double(data[y1 * width * bpp + x1 * bpp + ch])

                    let val = (1.0 - fx) * (1.0 - fy) * p00
                        + fx * (1.0 - fy) * p10
                        + (1.0 - fx) * fy * p01
                        + fx * fy * p11

                    outData[j * outW * bpp + i * bpp + ch] = Int16(val)
                }
            }
        }
        return outData
    }

    /// Add a signed Int16 difference buffer back onto a CGImage.
    private func reconstructFromAverage(
        srAvg: CGImage, diff: UnsafeMutablePointer<Int16>, colorSpace: CGColorSpace
    ) -> CGImage {
        let width = srAvg.width
        let height = srAvg.height
        let bpp = 4
        let bytesPerRow = width * bpp
        let pixelCount = height * bytesPerRow

        let avgData = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        let outData = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        defer {
            avgData.deallocate()
            diff.deallocate()
        }

        guard let ctx = CGContext(data: avgData, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                   space: colorSpace,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else {
            outData.deallocate()
            return srAvg
        }
        ctx.draw(srAvg, in: CGRect(x: 0, y: 0, width: width, height: height))

        for i in 0..<pixelCount {
            let val = Int16(avgData[i]) + diff[i]
            outData[i] = UInt8(min(max(val, 0), 255))
        }

        guard let outCtx = CGContext(data: outData, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let result = outCtx.makeImage()
        else {
            outData.deallocate()
            return srAvg
        }

        outData.deallocate()
        return result
    }
}
