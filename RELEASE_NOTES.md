# MP4Splice v1.0.1

A native macOS app to **join** and **split** video files, built in Swift + SwiftUI on
AVFoundation. Universal binary (Apple Silicon + Intel), no bundled binaries, no Carbon.
A clean-room successor to the old wxWidgets/ffmpeg MP4Tools.

## Highlights

### Join
- Drag-and-drop files in, or use Choose Files.
- Automatic Finder-style natural sorting (numeric-aware), with manual reorder and a sort menu.
- Per-file info (resolution, frame rate, video/audio codec, audio bitrate).
- Mismatch warnings that flag files differing from the majority and say what differs.
- Smart output filename suggested from the shared name of the inputs.

### Split
- Built-in video preview player (AVKit).
- Three modes: equal parts, custom split points, and extract a single range by start/end timecode.
- "Use playhead" buttons to capture in/out points from the preview.

### Re-encoding (optional, hardware-accelerated via VideoToolbox)
- Codec: H.264 or HEVC.
- Resolution: 480p, 720p, 1080p, 2K, 4K, 8K (aspect-preserving).
- Frame rate: NTSC (29.97), PAL (25), 24, 30, 60, 120, 240.
- Letterbox or fill when aspect ratios differ.
- Live bitrate recommendations pane (from the VideoToolbox guide) by content type, with
  HEVC suggested at ~2/3 of H.264; click a value to apply it.

### Job queue
- Add multiple join/split jobs and keep working while they run.
- Sequential background processing with live progress, an active-job indicator on every pane,
  cancel-and-delete, reveal-in-Finder for completed jobs, and collision-free output names.

## Requirements
- macOS 13.0 or later
- Apple Silicon or Intel Mac

## Install
Download `MP4Splice.dmg`, open it, and drag **MP4Splice** into the Applications folder.
The app is signed with a Developer ID and notarized by Apple, so it launches normally with
no Gatekeeper warning. Then eject the disk image.
