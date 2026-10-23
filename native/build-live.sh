#!/bin/zsh
set -eu
cd "${0:A:h}"
python3 bundle-metadata.py
mkdir -p FrameLive.app/Contents/MacOS
swiftc -parse-as-library -O -target arm64-apple-macos15.0 -module-cache-path "${TMPDIR:-/tmp}/frame-swift-module-cache" FrameLive.swift -o FrameLive.app/Contents/MacOS/FrameLive
xattr -d com.apple.FinderInfo FrameLive.app 2>/dev/null || true
codesign --force --sign - FrameLive.app
