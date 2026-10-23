#!/bin/zsh
set -eu
cd "${0:A:h}"
python3 bundle-metadata.py
mkdir -p FrameTranslate.app/Contents/MacOS
swiftc -parse-as-library -O -target arm64-apple-macos15.0 -module-cache-path "${TMPDIR:-/tmp}/frame-swift-module-cache" FrameTranslate.swift -o FrameTranslate.app/Contents/MacOS/FrameTranslate
xattr -d com.apple.FinderInfo FrameTranslate.app 2>/dev/null || true
codesign --force --sign - FrameTranslate.app
