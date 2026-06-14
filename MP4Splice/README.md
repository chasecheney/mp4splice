# MP4Splice (Swift / macOS)

A native macOS rewrite of MP4Splice (Joiner + Splitter) in Swift and SwiftUI, built on
AVFoundation. No bundled binaries, no Carbon, fully native on Apple Silicon (arm64) and
Intel. This replaces the legacy wxWidgets/ffmpeg C++ app.

## Features

- **Join** tab — add multiple MP4 files, reorder them, and combine into one file.
- **Split** tab — cut one MP4 into equal-length parts, or at custom split points (in seconds).
- Lossless by default via passthrough export; optional re-encode for mismatched formats.
- Live progress and a preview of the output segments before splitting.

## Requirements

- macOS 13.0 or later
- Xcode 15 or later

## Build & run

Open the project and run:

```sh
open MP4Splice.xcodeproj
```

Press **⌘R** in Xcode. Or from the command line:

```sh
xcodebuild -project MP4Splice.xcodeproj -scheme MP4Splice -configuration Release build
```

The first build will prompt you to pick a development team for signing (Signing & Capabilities
tab). For local use, automatic signing with your personal Apple ID is enough.

## Project layout

```
MP4Splice/
  MP4SpliceApp.swift        App entry (SwiftUI lifecycle)
  ContentView.swift        TabView: Join / Split
  Models/
    MediaItem.swift        Source file model (duration, size)
  Services/
    VideoError.swift       Typed errors
    ExportHelper.swift     Runs AVAssetExportSession with progress
    VideoJoiner.swift      Concatenate via AVMutableComposition
    VideoSplitter.swift    Segment via export timeRange
    Panels.swift           Open/save NSPanels
  Views/
    JoinView.swift
    SplitView.swift
  Assets.xcassets          App icon + accent color slots
  MP4Splice.entitlements    App Sandbox + user-selected file access
```

## How processing works

By default (no re-encode), joining builds an `AVMutableComposition` and exports with
`AVAssetExportPresetPassthrough` — a lossless remux. Splitting runs one passthrough export
per segment with a `timeRange`. These paths do no encoding and are fast.

Toggle **Re-encode** to route through `ReencodeEngine`, an `AVAssetReader` → `AVAssetWriter`
pipeline that gives explicit control over output format:

- **Codec** — H.264 or HEVC (H.265)
- **Video bitrate** — 1–50 Mbps average target
- **Audio bitrate** — 128/192/256/320 kbps AAC
- **Sample rate** — 44.1 or 48 kHz

A video composition normalizes per-clip rotation and size into one render space, so joins
between mismatched sources work. On Apple Silicon, VideoToolbox runs H.264/HEVC encoding on
the hardware media engine automatically, so re-encoding is hardware-accelerated.

## Notes / next steps

- The app icon slots are empty placeholders — drop real PNGs into `Assets.xcassets/AppIcon.appiconset`.
- Passthrough join requires inputs with compatible formats; otherwise enable Re-encode.
- `project.yml` is an optional XcodeGen spec to regenerate the project if it drifts.
- To distribute outside your machine, enable Developer ID signing and notarization.
