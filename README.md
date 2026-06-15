# MP4Splice

A native macOS app to **join** and **split** MP4 files, written in Swift and SwiftUI on top
of AVFoundation. Universal — runs natively on Apple Silicon (arm64) and Intel, with no bundled
binaries and no legacy Carbon dependencies.

This is a clean-room rewrite of the old wxWidgets/ffmpeg C++ "MP4Tools" app.

## Download

Grab the latest signed, notarized `MP4Splice.dmg` from the
[Releases page](https://github.com/chasecheney/mp4splice/releases). Open the disk image and
drag MP4Splice into Applications — it launches with no Gatekeeper warning.

## Features

- **Join** — add multiple MP4 files, reorder them, and combine into a single file.
- **Split** — cut one MP4 into equal-length parts, or at custom split points.
- Lossless by default (passthrough export); optional re-encode for mismatched formats.
- Live progress and a preview of output segments before splitting.

## Requirements

- macOS 13.0+
- Xcode 15+

## Build & run

```sh
open MP4Splice/MP4Splice.xcodeproj
```

Press **⌘R** in Xcode, or build from the command line:

```sh
xcodebuild -project MP4Splice/MP4Splice.xcodeproj -scheme MP4Splice -configuration Release build
```

The first build prompts you to select a development team for signing (Signing & Capabilities).

## Repository layout

```
MP4Splice/        Xcode project and Swift source (the app)
local/            Local-only reference material — git-ignored, not published
```

See [`MP4Splice/README.md`](MP4Splice/README.md) for project internals and architecture.

## License

Released under the [MIT License](LICENSE), © 2026 ChaseCheney LLC. This is a clean-room
rewrite that shares no code with the GPL-licensed original MP4Tools.
