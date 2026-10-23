# Frame icons — selected concept 01

Created with the built-in image generation tool, using the approved concept board as a reference. Source PNGs have transparent margins; ICNS files include 16–1024 px representations.

- `frame.png` / `frame.icns`: ivory tile, green frame and waveform, file transcription app.
- `frame-live.png` / `frame-live.icns`: forest green tile, ivory frame and waveform, orange live dot.
- `installed-preview.png`: verified Finder display of both installed apps.

Prompt set: extract and refine the approved top-left ivory Frame icon and bottom-left green Frame Live icon separately; preserve the open rounded frame and seven rounded waveform bars, centered in a macOS squircle with transparent margins, restrained shading, no labels or numbers; retain the orange status dot only for Live.

`build-icons.py` packages the PNGs with macOS sips and iconutil. If iconutil reports an invalid iconset from a restricted environment, run the build in the normal macOS environment.

`SetFrameIcons.swift` installs Finder custom icons as file metadata. It verifies that executable bytes and Info.plist bytes remain unchanged. Installed app signatures were verified after applying both icons. This avoids changing the app identity associated with the existing audio-capture permission.

To reapply after an app replacement:

```sh
swiftc -module-cache-path /tmp/frame-swift-module-cache native/icons/SetFrameIcons.swift -o /tmp/set-frame-icons
/tmp/set-frame-icons "$PWD/native/icons"
```
