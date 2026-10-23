#!/bin/zsh
set -eu
cd "${0:A:h}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
for dependency in python3 ffmpeg ffprobe swiftc; do
  if ! command -v "$dependency" >/dev/null; then
    echo "必要なコマンドがありません: $dependency（READMEを確認してください）"
    exit 1
  fi
done
[[ -x .venv/bin/python ]] || python3 -m venv .venv
.venv/bin/python -m pip install --only-binary=:all: -r requirements.txt
echo '英語の音声認識モデルを準備しています…'
.venv/bin/python -c 'from faster_whisper import WhisperModel; WhisperModel("tiny.en", device="cpu", compute_type="int8", download_root=".models")'
zsh native/build.sh
zsh native/build-live.sh
zsh native/build-launcher.sh
python3 native/icons/build-icons.py
python3 native/install-live.py
swiftc -module-cache-path "${TMPDIR:-/tmp}/frame-swift-module-cache" native/icons/SetFrameIcons.swift -o .runtime-set-frame-icons
./.runtime-set-frame-icons "$PWD/native/icons"
echo '準備完了。ApplicationsのFrame 文字起こし、またはFrame Liveを開いてください。'
