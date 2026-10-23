"""Load the model only for a job; free all model memory on process exit."""
import json, os, subprocess, sys
from pathlib import Path

def emit(**data):
    print(json.dumps(data, ensure_ascii=False), flush=True)

def main(path, model_name):
    import numpy as np
    from faster_whisper import WhisperModel
    root = Path(__file__).resolve().parent
    probe = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration:stream=codec_type', '-of', 'json', path], capture_output=True, text=True, check=True)
    metadata = json.loads(probe.stdout)
    if not any(s.get('codec_type') == 'audio' for s in metadata.get('streams', [])):
        emit(state='error', message='このファイルには音声トラックがありません。')
        return
    duration = float(metadata.get('format', {}).get('duration', 0))
    model = WhisperModel(model_name, device='cpu', compute_type='int8', cpu_threads=min(4, os.cpu_count() or 2), num_workers=1, download_root=str(root / '.models'))
    emit(state='transcribing', message='英語の音声を文字起こししています', duration=duration)
    # Decode five minutes at a time: the whole file is never held in RAM.
    decoder = subprocess.Popen(['ffmpeg', '-nostdin', '-v', 'error', '-threads', '1', '-i', path, '-map', '0:a:0', '-vn', '-f', 's16le', '-ac', '1', '-ar', '16000', '-'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    segments, offset = [], 0.0
    try:
        while True:
            pcm = decoder.stdout.read(300 * 16000 * 2)
            if not pcm:
                break
            audio = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
            results, _ = model.transcribe(audio, language='en', task='transcribe', beam_size=1, temperature=0, condition_on_previous_text=False)
            for segment in results:
                text = segment.text.strip()
                if text:
                    segments.append({'start': round(offset + segment.start, 3), 'end': round(offset + segment.end, 3), 'text': text})
                emit(segments=segments, text='\n'.join(s['text'] for s in segments), progress=min(99, int((offset + segment.end) / duration * 100)) if duration else 0)
            offset += len(audio) / 16000
        if decoder.wait() != 0:
            raise ValueError('Cannot decode audio')
        emit(state='done', progress=100, segments=segments, text='\n'.join(s['text'] for s in segments), message='完了しました' if segments else '完了：英語の発話を検出できませんでした')
    finally:
        if decoder.poll() is None:
            decoder.terminate()
        decoder.wait()

if __name__ == '__main__':
    try:
        main(sys.argv[1], sys.argv[2])
    except Exception as error:
        emit(state='error', message='音声の処理に失敗しました。ファイルの破損、ネット接続、空き容量を確認してください。')
        print(str(error), file=sys.stderr)
        sys.exit(1)
