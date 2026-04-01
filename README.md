//
//  README.md
//  fishEye
//
//  Created by Ehud Ben-Reuven on 3/31/26.
//
This App convert raw image to immersive spatial image to be viewed on Apple Vision Pro (running visionOS 26).
The RAW CR3 image has side by side the left and right images making a spatial image (the width of the image is divided in two).
The result image is a HEIC file marked as a spatial image according to Apple standards and when viewed inside the Photos App inside the Apple Vision Pro it appears as a spatial image with depth.

## Key Points for Creating Spatial HEIC Photos

For visionOS Photos to recognize a HEIC as a spatial image, the following metadata must be embedded via `CGImageDestinationAddImage` per-image properties (NOT via `CGImageDestinationSetProperties`):

1. **Stereo pair group (`kCGImagePropertyGroups`)** — Must be passed as a **per-image** property to each `CGImageDestinationAddImage` call. Setting it at the destination level with `CGImageDestinationSetProperties` silently fails to write the HEIF stereo entity group.

2. **Separate left/right flags** — The left image must carry `kCGImagePropertyGroupImageIsLeftImage: true` and the right image `kCGImagePropertyGroupImageIsRightImage: true`. Do NOT use `kCGImagePropertyGroupImageIndexLeft`/`IndexRight` alone — those set the group-level index mapping but don't tag individual images.

3. **Camera extrinsics (`kIIOMetadata_CameraExtrinsicsKey`)** — Required. The stereo baseline is encoded as the position difference between the two cameras:
   - Left eye position: `[0, 0, 0]`
   - Right eye position: `[baselineInMeters, 0, 0]` (e.g., `[0.064, 0, 0]` for 64mm)
   - Both use identity rotation: `[1, 0, 0, 0, 1, 0, 0, 0, 1]`

4. **Camera intrinsics (`kIIOMetadata_CameraModelKey`)** — Required. A 3x3 pinhole camera matrix as a flat 9-element array `[fx, 0, cx, 0, fy, cy, 0, 0, 1]` where:
   - `fx = fy = (imageWidth * 0.5) / tan(horizontalFOV * 0.5)` (focal length in pixels)
   - `cx = imageWidth / 2`, `cy = imageHeight / 2` (principal point at image center)
   - Must also set `kIIOCameraModel_ModelType: kIIOCameraModelType_SimplifiedPinhole`

5. **Disparity adjustment (`kCGImagePropertyGroupImageDisparityAdjustment`)** — Required. An integer encoding the horizontal disparity shift as a fraction of image width times 1e4 (e.g., `200` means 2%). Use `0` for no adjustment.

6. **Primary image (`kCGImagePropertyPrimaryImage`)** — Pass `[kCGImagePropertyPrimaryImage: 0]` as the `destinationProperties` parameter when creating `CGImageDestinationCreateWithURL`.

7. **No alpha (`kCGImagePropertyHasAlpha: false`)** — Set on each image to avoid unnecessary alpha channel overhead.

All keys above are available since macOS 13.0 / iOS 16.0 (ImageIO framework).

## Reference
the ``./examples/0S9A9186.heic`` file is a working spatial photo.

