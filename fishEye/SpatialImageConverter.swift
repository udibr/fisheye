import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum ConversionError: LocalizedError {
    case cannotLoadImage
    case cannotSplitImage
    case cannotCreateDestination
    case finalizationFailed

    var errorDescription: String? {
        switch self {
        case .cannotLoadImage:
            return "Failed to load the input image. Make sure the file is a supported RAW or image format."
        case .cannotSplitImage:
            return "Failed to split the side-by-side image into left and right halves."
        case .cannotCreateDestination:
            return "Failed to create the output HEIC file."
        case .finalizationFailed:
            return "Failed to finalize the spatial HEIC file."
        }
    }
}

final class SpatialImageConverter {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Full conversion pipeline: load image, optionally process fisheye, write spatial HEIC.
    func convert(input: URL, output: URL, fisheyeProcessor: FisheyeProcessor? = nil) throws {
        let fullImage = try loadImage(from: input)

        let left: CGImage
        let right: CGImage
        let baselineMeters: Double
        let horizontalFOV: Double

        if let processor = fisheyeProcessor {
            let result = processor.process(fullImage: fullImage)
            left = result.left
            right = result.right
            baselineMeters = 0.060  // Canon dual fisheye: 60mm
            horizontalFOV = processor.outputFOVDegrees
        } else {
            let pair = try splitSideBySide(image: fullImage)
            left = pair.left
            right = pair.right
            baselineMeters = 0.064
            horizontalFOV = 65.0
        }

        try writeSpatialHEIC(
            leftImage: left, rightImage: right, to: output,
            baselineMeters: baselineMeters, horizontalFOVDegrees: horizontalFOV)
    }

    // MARK: - Load Image

    /// Load an image from a URL. Supports CR3 RAW and common image formats.
    func loadImage(from url: URL) throws -> CGImage {
        // Try CIRAWFilter first for RAW files
        if let rawImage = loadRAWImage(from: url) {
            return rawImage
        }
        // Fallback to CGImageSource for non-RAW formats
        if let image = loadWithImageSource(from: url) {
            return image
        }
        throw ConversionError.cannotLoadImage
    }

    private func loadRAWImage(from url: URL) -> CGImage? {
        guard let rawFilter = CIRAWFilter(imageURL: url) else { return nil }
        guard let outputImage = rawFilter.outputImage else { return nil }
        return ciContext.createCGImage(outputImage, from: outputImage.extent)
    }

    private func loadWithImageSource(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Split Side-by-Side

    /// Split a side-by-side stereo image into left and right halves.
    func splitSideBySide(image: CGImage) throws -> (left: CGImage, right: CGImage) {
        let halfWidth = image.width / 2
        let height = image.height

        let leftRect = CGRect(x: 0, y: 0, width: halfWidth, height: height)
        let rightRect = CGRect(x: halfWidth, y: 0, width: halfWidth, height: height)

        guard let leftImage = image.cropping(to: leftRect),
              let rightImage = image.cropping(to: rightRect) else {
            throw ConversionError.cannotSplitImage
        }

        return (leftImage, rightImage)
    }

    // MARK: - Strip Alpha

    /// Re-render a CGImage without alpha channel to avoid unnecessary size/memory overhead in HEIC.
    private func stripAlpha(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return image
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    // MARK: - Write Spatial HEIC

    /// Create a spatial HEIC file with stereo pair metadata from left and right images.
    func writeSpatialHEIC(
        leftImage: CGImage, rightImage: CGImage, to outputURL: URL,
        baselineMeters: Double = 0.064, horizontalFOVDegrees: Double = 65.0
    ) throws {
        let leftImage = stripAlpha(leftImage)
        let rightImage = stripAlpha(rightImage)

        // Write to a temp file first (sandbox always allows), then move to user-chosen location
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".heic")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            UTType.heic.identifier as CFString,
            2,
            [kCGImagePropertyPrimaryImage: 0] as CFDictionary
        ) else {
            throw ConversionError.cannotCreateDestination
        }

        // Camera intrinsics from horizontal FOV
        let imageWidth = Double(leftImage.width)
        let imageHeight = Double(leftImage.height)
        let horizontalFOVDegrees = horizontalFOVDegrees
        let horizontalFOVRadians = horizontalFOVDegrees / 180.0 * .pi
        let focalLength = (imageWidth * 0.5) / tan(horizontalFOVRadians * 0.5)
        let intrinsics: [Double] = [
            focalLength, 0, imageWidth / 2.0,
            0, focalLength, imageHeight / 2.0,
            0, 0, 1
        ]

        // Camera extrinsics: baseline expressed as position difference
        let baselineInMeters = baselineMeters
        let identityRotation: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let leftPosition: [Double] = [0, 0, 0]
        let rightPosition: [Double] = [baselineInMeters, 0, 0]

        // Disparity adjustment encoded as integer (fraction * 1e4)
        let disparityAdjustment = 0

        let leftProperties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyHasAlpha: false,
            kCGImagePropertyGroups: [
                kCGImagePropertyGroupIndex: 0,
                kCGImagePropertyGroupType: kCGImagePropertyGroupTypeStereoPair,
                kCGImagePropertyGroupImageIsLeftImage: true,
                kCGImagePropertyGroupImageDisparityAdjustment: disparityAdjustment,
            ] as [CFString: Any],
            kCGImagePropertyHEIFDictionary: [
                kIIOMetadata_CameraExtrinsicsKey: [
                    kIIOCameraExtrinsics_Position: leftPosition,
                    kIIOCameraExtrinsics_Rotation: identityRotation,
                ],
                kIIOMetadata_CameraModelKey: [
                    kIIOCameraModel_Intrinsics: intrinsics,
                    kIIOCameraModel_ModelType: kIIOCameraModelType_SimplifiedPinhole,
                ],
            ]
        ]

        let rightProperties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyHasAlpha: false,
            kCGImagePropertyGroups: [
                kCGImagePropertyGroupIndex: 0,
                kCGImagePropertyGroupType: kCGImagePropertyGroupTypeStereoPair,
                kCGImagePropertyGroupImageIsRightImage: true,
                kCGImagePropertyGroupImageDisparityAdjustment: disparityAdjustment,
            ] as [CFString: Any],
            kCGImagePropertyHEIFDictionary: [
                kIIOMetadata_CameraExtrinsicsKey: [
                    kIIOCameraExtrinsics_Position: rightPosition,
                    kIIOCameraExtrinsics_Rotation: identityRotation,
                ],
                kIIOMetadata_CameraModelKey: [
                    kIIOCameraModel_Intrinsics: intrinsics,
                    kIIOCameraModel_ModelType: kIIOCameraModelType_SimplifiedPinhole,
                ],
            ]
        ]

        CGImageDestinationAddImage(destination, leftImage, leftProperties as CFDictionary)
        CGImageDestinationAddImage(destination, rightImage, rightProperties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.finalizationFailed
        }

        // Copy from temp to user-selected output location
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.copyItem(at: tempURL, to: outputURL)
    }
}
