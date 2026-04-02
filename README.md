# fishEye

A macOS app that converts stereo image pairs into immersive spatial photos for Apple Vision Pro (visionOS 26).

The input is a RAW CR3 (or standard image) containing side-by-side left and right views in a single file. The app splits the image in half, optionally applies fisheye correction and super resolution, then writes a spatial HEIC file with the required Apple stereo metadata. When viewed in the Photos app on Apple Vision Pro, the result appears as a spatial image with depth.

## Features

- **Drag-and-drop / file picker** — batch convert multiple files at once
- **Canon Dual Fisheye support** — circle detection, equirectangular projection, and chromatic aberration correction for the Canon RF-S 3.9mm f/3.5 STM Dual Fisheye lens
- **Super Resolution (2x)** — upscale stereo pairs using Lanczos or Core ML neural SR (Real-ESRGAN x2)
- **Stereo consistency strategies** — independent per-eye SR or averaged SR that preserves disparity

## Requirements

- macOS 15.0+
- Xcode 16+
- Swift 5.0

No external dependencies — pure Apple system frameworks (CoreImage, ImageIO, CoreGraphics, SwiftUI).

## Build

```bash
xcodebuild -project fishEye.xcodeproj -scheme fishEye -configuration Debug build
```

Or open `fishEye.xcodeproj` in Xcode and press **Cmd+R**.

## Super Resolution: Core ML Model Setup

The app includes a Lanczos upscaler out of the box. For neural super resolution using [Real-ESRGAN x2plus](https://github.com/xinntao/Real-ESRGAN), you need to generate the Core ML model from the pre-trained PyTorch weights:

### 1. Download the pre-trained weights

```bash
curl -L -O https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth
```

This downloads the `RealESRGAN_x2plus.pth` file (~65 MB) into the project root.

### 2. Set up a Python environment

```bash
python3 -m venv venv
source venv/bin/activate
pip install torch coremltools
```

> **Note:** You do _not_ need to install `basicsr` or `realesrgan`. The conversion script includes the full RRDBNet architecture definition.

### 3. Run the conversion script

```bash
python convert_to_coreml.py
```

This will:
1. Load the PyTorch weights from `RealESRGAN_x2plus.pth`
2. Trace the model with a 256×256 sample input
3. Convert to Core ML with flexible input size (64–2048 px), float16 precision
4. Save the result to `fishEye/SuperResolution.mlpackage`

### 4. Add the model to Xcode

Drag `fishEye/SuperResolution.mlpackage` into the Xcode project navigator (under the `fishEye` group). Make sure **"Copy items if needed"** is unchecked (the file is already in place) and that the target **fishEye** is checked.

Xcode automatically compiles `.mlpackage` to `.mlmodelc` at build time and generates a Swift `SuperResolution` class for type-safe inference.

### 5. Use it in the app

Enable **Super Resolution (2x)** in the UI, then select **Core ML** from the Algorithm picker. Images larger than 2048 px are automatically processed in tiles.

## Spatial HEIC Metadata Reference

For visionOS Photos to recognize a HEIC as a spatial image, the following metadata must be embedded via `CGImageDestinationAddImage` per-image properties (**not** via `CGImageDestinationSetProperties`):

1. **Stereo pair group (`kCGImagePropertyGroups`)** — Must be passed as a per-image property to each `CGImageDestinationAddImage` call. Setting it at the destination level silently fails to write the HEIF stereo entity group.

2. **Left/right flags** — The left image must carry `kCGImagePropertyGroupImageIsLeftImage: true` and the right image `kCGImagePropertyGroupImageIsRightImage: true`. Do not rely on `kCGImagePropertyGroupImageIndexLeft`/`IndexRight` alone.

3. **Camera extrinsics (`kIIOMetadata_CameraExtrinsicsKey`)** — Required. The stereo baseline is encoded as the position difference between two cameras:
   - Left eye: `[0, 0, 0]`
   - Right eye: `[baselineInMeters, 0, 0]` (e.g., `[0.064, 0, 0]` for 64 mm)
   - Both use identity rotation: `[1, 0, 0, 0, 1, 0, 0, 0, 1]`

4. **Camera intrinsics (`kIIOMetadata_CameraModelKey`)** — Required. A 3×3 pinhole camera matrix as a flat 9-element array `[fx, 0, cx, 0, fy, cy, 0, 0, 1]` where:
   - `fx = fy = (imageWidth × 0.5) / tan(horizontalFOV × 0.5)` (focal length in pixels)
   - `cx = imageWidth / 2`, `cy = imageHeight / 2` (principal point at center)
   - Must also set `kIIOCameraModel_ModelType: kIIOCameraModelType_SimplifiedPinhole`

5. **Disparity adjustment (`kCGImagePropertyGroupImageDisparityAdjustment`)** — Required. An integer encoding the horizontal disparity shift as a fraction of image width × 10⁴ (e.g., `200` means 2%). Use `0` for no adjustment.

6. **Primary image (`kCGImagePropertyPrimaryImage`)** — Pass `[kCGImagePropertyPrimaryImage: 0]` when creating `CGImageDestinationCreateWithURL`.

7. **No alpha (`kCGImagePropertyHasAlpha: false`)** — Set on each image to avoid unnecessary alpha channel overhead.

All keys are available since macOS 13.0 / iOS 16.0 (ImageIO framework).

## Reference

The file `./examples/0S9A9186.heic` is a working spatial photo that can be used as a reference.

## License

MIT
