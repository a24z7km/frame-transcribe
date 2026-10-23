#!/bin/zsh
set -eu
cd "${0:A:h}"
python3 bundle-metadata.py
python3 build-native.py FrameTranslate FrameTranslate.swift FrameTranslate
