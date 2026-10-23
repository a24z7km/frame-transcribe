#!/bin/zsh
set -eu
cd "${0:A:h}"
python3 bundle-metadata.py
swiftc -parse-as-library -O -target arm64-apple-macos15.0 -module-cache-path "${TMPDIR:-/tmp}/frame-swift-module-cache" FrameLauncher.swift -o Frame.app/Contents/MacOS/Frame
xattr -d com.apple.FinderInfo Frame.app 2>/dev/null || true
codesign --force --sign - Frame.app
