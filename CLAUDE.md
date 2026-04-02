# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

```bash
xcodebuild -project fishEye.xcodeproj -scheme fishEye -configuration Debug build
```

Requires macOS 15.0+, Swift 5.0, Xcode 16+. No external dependencies — pure Apple system frameworks (CoreImage, ImageIO, CoreGraphics, SwiftUI).

## Architecture

A macOS SwiftUI app that converts stereo image pairs (side-by-side left/right in a single file) into spatial HEIC files recognized by visionOS Photos on Apple Vision Pro.

**Pipeline:** `ContentView` → `SpatialImageConverter` → optional `FisheyeProcessor` → optional `SuperResolutionProcessor` → spatial HEIC output.

- **ContentView.swift** — UI with drag-drop/file picker, processing toggles (fisheye, CA correction, super resolution), batch conversion loop
- **SpatialImageConverter.swift** — Loads CR3 RAW (via CIRAWFilter) or standard images, splits into left/right halves, delegates to optional processors, writes spatial HEIC with stereo metadata
- **FisheyeProcessor.swift** — Canon RF-S 3.9mm dual fisheye processing: circle detection (centroid + radial scan), equidistant-to-equirectangular projection (144° lens FOV → 180° VR180 output), per-channel chromatic aberration correction, edge trim, left/right swap for Canon prism optics
- **SuperResolutionProcessor.swift** — 2x upscaling with two strategies: independent (per-eye) and averaged (SR on shared content, preserve disparity via residuals). Uses CILanczosScaleTransform as placeholder for future Core ML neural SR.

## Critical: Spatial HEIC Metadata

Stereo metadata must be per-image properties passed to `CGImageDestinationAddImage`, NOT destination-level via `CGImageDestinationSetProperties`. This is the most common failure mode — see `Readme.md` for the full list of required keys (camera extrinsics/intrinsics, stereo group flags, disparity adjustment, primary image marker).

## Canon Dual Fisheye Specifics

- Equidistant projection: r = f·θ
- 144° FOV, 60mm baseline, prism optics swap left/right
- Circle detection uses brightness centroid + median radial scan
- Edge trim (3%) removes chromatic fringe at physical circle boundary
- Output is VR180-ready: 180° equirectangular with 144° content centered, black padding beyond
