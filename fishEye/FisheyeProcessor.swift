import Foundation
import CoreGraphics

/// Parameters for a detected fisheye circle in an image.
struct FisheyeCircle {
    var centerX: Double
    var centerY: Double
    var radius: Double
}

/// Processes dual fisheye images from Canon RF-S 3.9mm f/3.5 STM Dual Fisheye lens.
///
/// Pipeline: circle detection → left/right swap → chromatic aberration correction →
/// equidistant fisheye to equirectangular projection.
///
/// Canon RF-S 3.9mm specs:
/// - Equidistant projection (r = f · θ)
/// - 144° specified FOV (~154° actual, Canon crops in EOS VR Utility)
/// - 60mm baseline between lens centers
/// - Image circles ~3340px diameter on R7 sensor (6960×4640)
/// - Prism optics swap left/right: left sensor half = right eye
final class FisheyeProcessor {

    /// Lens field of view in degrees.
    var lensFOVDegrees: Double = 144.0

    /// Output equirectangular FOV in degrees (180 for VR180-ready output).
    var outputFOVDegrees: Double = 180.0

    /// Output image size in pixels (square). 0 = auto-compute from circle size.
    var outputSize: Int = 0

    /// Chromatic aberration correction coefficients.
    /// Applied as radial scale per channel: r_ch = r · (1 + ca · (r/R)²).
    /// Positive pushes outward, negative inward (relative to green).
    var caRed: Double = 0.0008
    var caBlue: Double = -0.0004

    // MARK: - Public API

    /// Process a full side-by-side dual fisheye image into corrected left and right
    /// equirectangular images ready for spatial HEIC encoding.
    /// Output covers outputFOVDegrees (default 180°) with the lens content (144°)
    /// centered inside and black padding beyond the lens FOV.
    func process(fullImage: CGImage) -> (left: CGImage, right: CGImage) {
        let halfWidth = fullImage.width / 2
        let height = fullImage.height

        // Split into sensor halves
        let sensorLeft = fullImage.cropping(
            to: CGRect(x: 0, y: 0, width: halfWidth, height: height))!
        let sensorRight = fullImage.cropping(
            to: CGRect(x: halfWidth, y: 0, width: halfWidth, height: height))!

        // Canon prism optics swap: sensor left = right eye, sensor right = left eye
        let leftEyeFisheye = sensorRight
        let rightEyeFisheye = sensorLeft

        // Detect circles
        let leftCircle = detectCircle(in: leftEyeFisheye)
        let rightCircle = detectCircle(in: rightEyeFisheye)

        // Use the smaller radius so both eyes have the same angular coverage
        let commonRadius = min(leftCircle.radius, rightCircle.radius)
        let leftCircleNorm = FisheyeCircle(
            centerX: leftCircle.centerX, centerY: leftCircle.centerY, radius: commonRadius)
        let rightCircleNorm = FisheyeCircle(
            centerX: rightCircle.centerX, centerY: rightCircle.centerY, radius: commonRadius)

        // Output size: preserve angular resolution within the lens content.
        // Circle of radius R covers lensFOV/2 degrees; output covers outputFOV/2 degrees.
        // pixels_per_degree = R / (lensFOV/2)
        // output_half = pixels_per_degree * (outputFOV/2)
        let computedSize: Int
        if outputSize > 0 {
            computedSize = outputSize
        } else {
            let pixelsPerDegree = commonRadius / (lensFOVDegrees / 2.0)
            computedSize = Int(pixelsPerDegree * outputFOVDegrees)
        }

        let leftEquirect = fisheyeToEquirectangular(
            image: leftEyeFisheye, circle: leftCircleNorm, size: computedSize)
        let rightEquirect = fisheyeToEquirectangular(
            image: rightEyeFisheye, circle: rightCircleNorm, size: computedSize)

        return (leftEquirect, rightEquirect)
    }

    // MARK: - Circle Detection

    /// Detect the fisheye image circle by finding the centroid and radius of bright pixels.
    func detectCircle(in image: CGImage) -> FisheyeCircle {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: height * bytesPerRow)
        defer { data.deallocate() }

        guard let context = CGContext(
            data: data, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else {
            return fallbackCircle(width: width, height: height)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let threshold: UInt16 = 20
        let step = 4  // subsample for speed

        // Centroid of bright pixels (binary weight — all bright pixels contribute equally)
        var sumX = 0.0, sumY = 0.0, count = 0.0
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let brightness =
                    UInt16(data[offset]) + UInt16(data[offset + 1]) + UInt16(data[offset + 2])
                if brightness > threshold * 3 {
                    sumX += Double(x)
                    sumY += Double(y)
                    count += 1
                }
            }
        }

        guard count > 100 else {
            return fallbackCircle(width: width, height: height)
        }

        let cx = sumX / count
        let cy = sumY / count

        // Find radius: scan radially, record outermost bright pixel per direction, take median
        let numAngles = 360
        var radii: [Double] = []
        radii.reserveCapacity(numAngles)

        for i in 0..<numAngles {
            let angle = Double(i) * .pi * 2.0 / Double(numAngles)
            var lastBrightR = 0.0
            let maxR = Double(max(width, height)) / 2

            var r = 10.0
            while r < maxR {
                let px = Int(cx + r * cos(angle))
                let py = Int(cy + r * sin(angle))
                guard px >= 0 && px < width && py >= 0 && py < height else { break }

                let offset = py * bytesPerRow + px * bytesPerPixel
                let brightness =
                    UInt16(data[offset]) + UInt16(data[offset + 1]) + UInt16(data[offset + 2])
                if brightness > threshold * 3 {
                    lastBrightR = r
                }
                r += 2.0
            }

            if lastBrightR > 100 {
                radii.append(lastBrightR)
            }
        }

        radii.sort()
        let radius =
            radii.isEmpty
            ? Double(min(width, height)) / 2.0 * 0.96
            : radii[radii.count / 2]

        return FisheyeCircle(centerX: cx, centerY: cy, radius: radius)
    }

    private func fallbackCircle(width: Int, height: Int) -> FisheyeCircle {
        FisheyeCircle(
            centerX: Double(width) / 2,
            centerY: Double(height) / 2,
            radius: Double(min(width, height)) / 2 * 0.96)
    }

    // MARK: - Fisheye to Equirectangular

    /// Convert an equidistant fisheye image to equirectangular projection.
    /// Output grid covers outputFOVDegrees (180° for VR180). Lens content (lensFOVDegrees)
    /// is centered; pixels beyond the lens FOV remain black.
    /// Includes per-channel chromatic aberration correction during remapping.
    func fisheyeToEquirectangular(
        image: CGImage, circle: FisheyeCircle, size: Int
    ) -> CGImage {
        let inWidth = image.width
        let inHeight = image.height
        let bytesPerPixel = 4
        let inBytesPerRow = inWidth * bytesPerPixel

        // Read input pixels
        let inData = UnsafeMutablePointer<UInt8>.allocate(capacity: inHeight * inBytesPerRow)
        defer { inData.deallocate() }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let inContext = CGContext(
            data: inData, width: inWidth, height: inHeight,
            bitsPerComponent: 8, bytesPerRow: inBytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else {
            return image
        }
        inContext.draw(image, in: CGRect(x: 0, y: 0, width: inWidth, height: inHeight))

        // Prepare output
        let outWidth = size
        let outHeight = size
        let outBytesPerRow = outWidth * bytesPerPixel
        let outData = UnsafeMutablePointer<UInt8>.allocate(capacity: outHeight * outBytesPerRow)
        // zero-fill (black background — areas beyond lens FOV stay black)
        outData.initialize(repeating: 0, count: outHeight * outBytesPerRow)

        // Output grid covers outputFOVDegrees (e.g. 180°)
        let outputFOVRad = outputFOVDegrees * .pi / 180.0
        // Lens content covers lensFOVDegrees (e.g. 144°)
        let maxTheta = lensFOVDegrees / 2.0 * .pi / 180.0  // max angle from axis in the fisheye
        let R = circle.radius
        let cx = circle.centerX
        let cy = circle.centerY

        let caCoeffs = [caRed, 0.0, caBlue]  // per-channel: R, G, B

        // Process rows in parallel
        DispatchQueue.concurrentPerform(iterations: outHeight) { j in
            // latitude: output grid spans ±outputFOV/2
            let lat = (0.5 - Double(j) / Double(outHeight)) * outputFOVRad
            let cosLat = cos(lat)
            let sinLat = sin(lat)

            for i in 0..<outWidth {
                // longitude: output grid spans ±outputFOV/2
                let lon = (Double(i) / Double(outWidth) - 0.5) * outputFOVRad

                // 3D direction (optical axis = +Z)
                let dirX = cosLat * sin(lon)
                let dirY = sinLat
                let dirZ = cosLat * cos(lon)

                // Angle from optical axis
                let theta = acos(min(max(dirZ, -1.0), 1.0))
                // Beyond the lens FOV — leave black
                if theta > maxTheta { continue }

                // Azimuth in the fisheye image plane
                let phi = atan2(dirY, dirX)

                let outOffset = j * outBytesPerRow + i * bytesPerPixel

                // Sample each color channel with individual CA correction
                // Equidistant fisheye: r = R · θ / maxTheta
                for ch in 0..<3 {
                    let normalizedR = theta / maxTheta
                    let correctedTheta = theta * (1.0 + caCoeffs[ch] * normalizedR * normalizedR)
                    let r = R * correctedTheta / maxTheta

                    let fishX = cx + r * cos(phi)
                    let fishY = cy - r * sin(phi)

                    outData[outOffset + ch] = bilinearSample(
                        data: inData, width: inWidth, height: inHeight,
                        bytesPerRow: inBytesPerRow, x: fishX, y: fishY, channel: ch)
                }
                outData[outOffset + 3] = 255
            }
        }

        // Create output image
        guard let outContext = CGContext(
            data: outData, width: outWidth, height: outHeight,
            bitsPerComponent: 8, bytesPerRow: outBytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
            let result = outContext.makeImage()
        else {
            outData.deallocate()
            return image
        }

        outData.deallocate()
        return result
    }

    // MARK: - Bilinear Interpolation

    private func bilinearSample(
        data: UnsafePointer<UInt8>, width: Int, height: Int,
        bytesPerRow: Int, x: Double, y: Double, channel: Int
    ) -> UInt8 {
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let x1 = x0 + 1
        let y1 = y0 + 1

        guard x0 >= 0 && x1 < width && y0 >= 0 && y1 < height else { return 0 }

        let fx = x - Double(x0)
        let fy = y - Double(y0)

        let p00 = Double(data[y0 * bytesPerRow + x0 * 4 + channel])
        let p10 = Double(data[y0 * bytesPerRow + x1 * 4 + channel])
        let p01 = Double(data[y1 * bytesPerRow + x0 * 4 + channel])
        let p11 = Double(data[y1 * bytesPerRow + x1 * 4 + channel])

        let value =
            (1.0 - fx) * (1.0 - fy) * p00
            + fx * (1.0 - fy) * p10
            + (1.0 - fx) * fy * p01
            + fx * fy * p11

        return UInt8(min(max(value, 0), 255))
    }
}
