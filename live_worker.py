"""Bounded, local-only English ASR. stdin: 16 kHz mono float32; stdout: JSON lines."""
import argparse
import json
import math
import queue
import re
import sys
import threading
import time
from pathlib import Path
import numpy as np

RATE = 16000
BLOCK = 1600
STDOUT_LOCK = threading.Lock()

def emit(**event):
    with STDOUT_LOCK:
        print(json.dumps(event, ensure_ascii=False), flush=True)

class PhraseBuffer:
    """Keep at most 7 seconds, including a short pre-roll and bounded overlap."""
    def __init__(self):
        self.preroll = np.zeros(0, dtype=np.float32)
        self.blocks = []
        self.samples = 0
        self.silence = 0
        self.voiced = 0
        self.position = 0
        self.start = 0

    def push(self, block):
        block = np.asarray(block, dtype=np.float32)
        self.position += len(block)
        rms = float(np.sqrt(np.mean(block * block))) if len(block) else 0
        voice = rms >= 0.002
        if not self.blocks:
            if not voice:
                self.preroll = np.concatenate((self.preroll, block))[-int(RATE * .25):]
                return None
            self.start = max(0, self.position - len(block) - len(self.preroll))
            if len(self.preroll):
                self.blocks.append(self.preroll)
                self.samples = len(self.preroll)
            self.preroll = np.zeros(0, dtype=np.float32)
        self.blocks.append(block.copy())
        self.samples += len(block)
        self.voiced += len(block) if voice else 0
        self.silence = 0 if voice else self.silence + len(block)
        if self.samples >= 7 * RATE or (self.silence >= .65 * RATE and self.voiced >= .15 * RATE):
            return self.flush(overlap=self.samples >= 7 * RATE)
        return None

    def flush(self, overlap=False):
        if not self.blocks:
            return None
        audio = np.concatenate(self.blocks)
        result = (audio, self.start / RATE) if self.voiced >= .15 * RATE else None
        self.preroll = audio[-int(.3 * RATE):].copy() if overlap else np.zeros(0, dtype=np.float32)
        self.blocks, self.samples, self.silence, self.voiced = [], 0, 0, 0
        return result

def remove_overlap(previous, current):
    old, new = previous.split(), current.split()
    normalize = lambda values: [re.sub(r'[^\w]', '', value).lower() for value in values]
    for length in range(min(10, len(old), len(new)), 1, -1):
        if normalize(old[-length:]) == normalize(new[:length]):
            return ' '.join(new[length:])
    return current

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', choices=['tiny.en', 'base.en'], default='tiny.en')
    args = parser.parse_args()
    from faster_whisper import WhisperModel
    root = Path(__file__).resolve().parent
    try:
        model = WhisperModel(args.model, device='cpu', compute_type='int8', cpu_threads=3,
                             num_workers=1, download_root=str(root / '.models'), local_files_only=True)
    except Exception:
        emit(type='error', message='音声認識モデルが見つかりません。ファイル文字起こしでモデルを準備してから起動してください。')
        return 1
    pending = queue.Queue(maxsize=2)
    segmentation = PhraseBuffer()
    finished = threading.Event()
    def enqueue(phrase):
        if phrase is None:
            return
        try:
            pending.put_nowait(phrase)
        except queue.Full:
            try: pending.get_nowait()
            except queue.Empty: pass
            pending.put_nowait(phrase)
            emit(type='lag', message='処理が追いつかないため、古い音声を1区間スキップしました。')
    def read_audio():
        try:
            while True:
                data = sys.stdin.buffer.read(BLOCK * 4)
                if not data:
                    break
                if len(data) % 4:
                    emit(type='error', message='音声データの形式が一致しません。停止して起動し直してください。')
                    break
                audio = np.frombuffer(data, dtype='<f4')
                if not np.all(np.isfinite(audio)):
                    continue
                enqueue(segmentation.push(audio))
            enqueue(segmentation.flush())
        finally:
            finished.set()
    reader = threading.Thread(target=read_audio, daemon=True)
    reader.start()
    emit(type='ready', model=args.model)
    previous, previous_end, sequence = '', -100.0, 0
    while not finished.is_set() or not pending.empty():
        try:
            audio, started = pending.get(timeout=.1)
        except queue.Empty:
            continue
        began = time.monotonic()
        results, _ = model.transcribe(audio, language='en', task='transcribe', beam_size=1,
                                     temperature=0, condition_on_previous_text=False,
                                     vad_filter=True, vad_parameters={'min_silence_duration_ms': 400})
        pieces = [segment.text.strip() for segment in results
                  if not (segment.no_speech_prob > .8 and segment.avg_logprob < -1)]
        text = ' '.join(pieces).strip()
        if started < previous_end:
            text = remove_overlap(previous, text)
        if not text:
            continue
        sequence += 1
        emit(type='transcript', id=sequence, english=text, audioStart=started,
             audioEnd=started + len(audio) / RATE, processingSeconds=round(time.monotonic() - began, 3))
        previous, previous_end = text, started + len(audio) / RATE
    emit(type='finished')
    return 0

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        pass
    except Exception:
        emit(type='error', message='音声認識を続けられませんでした。停止して再開してください。')
        raise SystemExit(1)
