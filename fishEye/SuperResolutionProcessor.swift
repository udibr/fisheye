import Foundation
import CoreGraphics
import CoreImage
import CoreML

/// Strategy for maintaining stereo consistency when applying super resolution.
enum SRStrategy: String, CaseIterable {
    case independent = "Independent"
    case averaged = "Averaged"
}

/// Algorithm used for the super resolution upscaling step.
enum SRAlgorithm: String, CaseIterable {
    case lanczos = "Lanczos"
    case coreML = "Core ML"
}

/// Applies super resolution (2x) to stereo image pairs.
///
/// Design for experimentation:
/// - Switch `strategy` to compare stereo consistency approaches.
/// - Switch `algorithm` between Lanczos (classical) and Core ML (neural SR).
/// - For Core ML, add a .mlmodel file to the Xcode project. The model should
///   accept an image input and produce a 2x upscaled image output.
final class SuperResolutionProcessor {

    var strategy: SRStrategy = .independent
    var algorithm: SRAlgorithm = .lanczos

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Core ML state
    private var mlModel: MLModel?
    private var modelInputName: String = ""
    private var modelOutputName: String = ""
    private var modelTileWidth: Int = 0   // 0 = flexible input size
    private var modelTileHeight: Int = 0
    private var modelPixelFormat: OSType = kCVPixelFormatType_32BGRA

    private var modelLoadAttempted = false

    /// Whether a Core ML model is loaded and ready.
    var isCoreMLModelLoaded: Bool {
        if mlModel == nil && !modelLoadAttempted {
            modelLoadAttempted = true
            try? loadCoreMLModel()
        }
        return mlModel != nil
    }

    // MARK: - Core ML Model Loading

    /// Load a Core ML super resolution model from the app bundle.
    /// Uses the Xcode-generated SuperResolution class from SuperResolution.mlpackage.
    func loadCoreMLModel() throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try SuperResolution(configuration: config).model
        mlModel = model

        // Detect input spec
        if let (name, desc) = model.modelDescription.inputDescriptionsByName.first {
            modelInputName = name
            if let constraint = desc.imageConstraint {
                let fmt = constraint.pixelFormatType
                modelPixelFormat = fmt != 0 ? fmt : kCVPixelFormatType_32BGRA

                switch constraint.sizeConstraint.type {
                case .unspecified:
                    modelTileWidth = 0
                    modelTileHeight = 0
                case .range:
                    // If range max is very large, treat as flexible
                    let maxW = constraint.sizeConstraint.pixelsWideRange.upperBound - 1
                    let maxH = constraint.sizeConstraint.pixelsHighRange.upperBound - 1
                    modelTileWidth = maxW > 8192 ? 0 : maxW
                    modelTileHeight = maxH > 8192 ? 0 : maxH
                case .enumerated:
                    if let size = constraint.sizeConstraint.enumeratedImageSizes
                        .max(by: { $0.pixelsWide < $1.pixelsWide }) {
                        modelTileWidth = size.pixelsWide
                        modelTileHeight = size.pixelsHigh
                    }
                @unknown default:
                    modelTileWidth = constraint.pixelsWide
                    modelTileHeight = constraint.pixelsHigh
                }
            }
        }

        // Detect output name
        if let (name, _) = model.modelDescription.outputDescriptionsByName.first {
            modelOutputName = name
        }
    }

    // MARK: - Public API

    /// Upscale a stereo pair to 2x resolution using the current strategy and algorithm.
    func upscale(left: CGImage, right: CGImage) -> (left: CGImage, right: CGImage) {
        // Lazy-load Core ML model if needed
        if algorithm == .coreML && mlModel == nil {
            do {
                try loadCoreMLModel()
            } catch {
                print("Core ML model load failed: \(error.localizedDescription). Falling back to Lanczos.")
                algorithm = .lanczos
            }
        }

        switch strategy {
        case .independent:
            return (upscaleSingle(left), upscaleSingle(right))
        case .averaged:
            return upscaleAveraged(left: left, right: right)
        }
    }

    // MARK: - Single Image Upscale

    /// Upscale a single image to 2x using the selected algorithm.
    func upscaleSingle(_ image: CGImage) -> CGImage {
        switch algorithm {
        case .lanczos:
            return upscaleLanczos(image)
        case .coreML:
            return upscaleCoreML(image)
        }
    }

    private func upscaleLanczos(_ image: CGImage) -> CGImage {
        let ciImage = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return image }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(2.0, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let output = filter.outputImage,
              let result = ciContext.createCGImage(output, from: output.extent)
        else { return image }
        return result
    }

    // MARK: - Core ML

    private func upscaleCoreML(_ image: CGImage) -> CGImage {
        guard let model = mlModel else {
            return upscaleLanczos(image)
        }

        // Check if image fits within the model's accepted range
        let fitsInRange = modelTileWidth == 0 ||
            (image.width <= modelTileWidth && image.height <= modelTileHeight)

        if fitsInRange {
            // Ensure even dimensions (required by pixel_unshuffle)
            let evenW = image.width & ~1
            let evenH = image.height & ~1
            let processImage: CGImage
            if evenW != image.width || evenH != image.height {
                processImage = image.cropping(to: CGRect(x: 0, y: 0, width: evenW, height: evenH)) ?? image
            } else {
                processImage = image
            }
            if let result = processThroughModel(processImage, model: model) {
                return result
            }
        }

        // Image too large or processing failed — tile with a practical even size
        let tileW = modelTileWidth > 0 ? min(modelTileWidth, 1024) & ~1 : 512
        let tileH = modelTileHeight > 0 ? min(modelTileHeight, 1024) & ~1 : tileW
        if let result = upscaleCoreMLTiled(image, model: model, tileW: tileW, tileH: tileH) {
            return result
        }

        print("Core ML processing failed, falling back to Lanczos")
        return upscaleLanczos(image)
    }

    private func processThroughModel(_ image: CGImage, model: MLModel) -> CGImage? {
        guard let inputBuffer = createPixelBuffer(from: image) else { return nil }

        do {
            let input = try MLDictionaryFeatureProvider(
                dictionary: [modelInputName: MLFeatureValue(pixelBuffer: inputBuffer)]
            )
            let output = try model.prediction(from: input)

            guard let outputValue = output.featureValue(for: modelOutputName),
                  let outputBuffer = outputValue.imageBufferValue else {
                return nil
            }

            let ciImage = CIImage(cvPixelBuffer: outputBuffer)
            return ciContext.createCGImage(ciImage, from: ciImage.extent)
        } catch {
            print("Core ML prediction error: \(error)")
            return nil
        }
    }

    /// Tile-based processing for models with fixed input size.
    private func upscaleCoreMLTiled(_ image: CGImage, model: MLModel,
                                     tileW: Int, tileH: Int) -> CGImage? {
        let scale = 2
        let imgW = image.width
        let imgH = image.height
        let outW = imgW * scale
        let outH = imgH * scale
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        guard let outCtx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        var y = 0
        while y < imgH {
            var x = 0
            while x < imgW {
                let tw = min(tileW, imgW - x)
                let th = min(tileH, imgH - y)

                // CGImage.cropping uses top-left origin
                guard let tile = image.cropping(to: CGRect(x: x, y: y, width: tw, height: th)) else {
                    x += tileW
                    continue
                }

                // Pad to model input size if tile is smaller
                let processInput: CGImage
                if tw < tileW || th < tileH {
                    processInput = padImage(tile, toWidth: tileW, toHeight: tileH,
                                            colorSpace: colorSpace) ?? tile
                } else {
                    processInput = tile
                }

                if let processed = processThroughModel(processInput, model: model) {
                    // Crop out the valid region (remove padding)
                    let cropW = tw * scale
                    let cropH = th * scale
                    if let cropped = processed.cropping(
                        to: CGRect(x: 0, y: 0, width: cropW, height: cropH)
                    ) {
                        // CGContext.draw uses bottom-left origin
                        let ctxY = outH - (y * scale) - cropH
                        outCtx.draw(cropped,
                                    in: CGRect(x: x * scale, y: ctxY,
                                               width: cropW, height: cropH))
                    }
                }

                x += tileW
            }
            y += tileH
        }

        return outCtx.makeImage()
    }

    // MARK: - Pixel Buffer Helpers

    private func createPixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let ciImage = CIImage(cgImage: image)
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, image.width, image.height,
            modelPixelFormat, nil, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }
        ciContext.render(ciImage, to: pb)
        return pb
    }

    private func padImage(_ image: CGImage, toWidth: Int, toHeight: Int,
                          colorSpace: CGColorSpace) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: toWidth, height: toHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        // Place image at top-left (in CGContext bottom-left coords, that's y = toHeight - height)
        ctx.draw(image, in: CGRect(x: 0, y: toHeight - image.height,
                                    width: image.width, height: image.height))
        return ctx.makeImage()
    }

    // MARK: - Averaged Strategy

    /// Average both eyes, apply SR to the average, reconstruct stereo from upscaled differences.
    private func upscaleAveraged(left: CGImage, right: CGImage) -> (left: CGImage, right: CGImage) {
        let width = left.width
        let height = left.height
        let bpp = 4
        let bytesPerRow = width * bpp
        let pixelCount = height * bytesPerRow

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

        for i in 0..<pixelCount {
            let l = Int16(leftData[i])
            let r = Int16(rightData[i])
            avgData[i] = UInt8((l + r) / 2)
            leftDiffData[i] = l - Int16(avgData[i])
            rightDiffData[i] = r - Int16(avgData[i])
        }

        guard let avgCtx = CGContext(data: avgData, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace, bitmapInfo: bitmapInfo),
              let avgImage = avgCtx.makeImage()
        else {
            return (upscaleSingle(left), upscaleSingle(right))
        }

        let srAvg = upscaleSingle(avgImage)

        let srLeftDiff = upscaleDifference(leftDiffData, width: width, height: height)
        let srRightDiff = upscaleDifference(rightDiffData, width: width, height: height)

        let srLeft = reconstructFromAverage(srAvg: srAvg, diff: srLeftDiff, colorSpace: colorSpace)
        let srRight = reconstructFromAverage(srAvg: srAvg, diff: srRightDiff, colorSpace: colorSpace)

        return (srLeft, srRight)
    }

    // MARK: - Helpers for Averaged Strategy

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
