#!/bin/zsh
cd "${0:A:h}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then
  echo 'FFmpegが必要です。Homebrewで brew install ffmpeg を実行してください。'
  read '?Enterで終了'; exit 1
fi
if [[ ! -x .venv/bin/python ]]; then
  python3 -m venv .venv || exit 1
fi
if ! .venv/bin/python -c 'import faster_whisper' >/dev/null 2>&1; then
  .venv/bin/python -m pip install --only-binary=:all: -r requirements.txt || exit 1
fi
if [[ ! -x native/FrameTranslate.app/Contents/MacOS/FrameTranslate || native/FrameTranslate.swift -nt native/FrameTranslate.app/Contents/MacOS/FrameTranslate ]]; then
  echo 'Apple翻訳の準備をしています…'
  ./native/build.sh || { echo 'Apple翻訳の準備に失敗しました。'; read '?Enterで終了'; exit 1; }
fi
exec .venv/bin/python server.py
