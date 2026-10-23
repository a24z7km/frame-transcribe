"""Apple on-device translation. Never connects to a web translation service."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parent
HELPER = ROOT / 'native/FrameTranslate.app/Contents/MacOS/FrameTranslate'
MAX_TEXT_BYTES = 2 * 1024 * 1024

class TranslationError(Exception):
    pass

def split_text(text, limit=1200):
    """Sentence-aware bounded chunks, with no manual splitting or dropped words."""
    if not isinstance(text, str) or not text.strip() or len(text.encode('utf-8')) > MAX_TEXT_BYTES:
        raise ValueError('翻訳する英文を入力してください（最大2MB）。')
    sentences = re.split(r'(?<=[.!?])\s+|\n+', text.strip())
    chunks, current = [], ''
    for sentence in sentences:
        rest = sentence.strip()
        while len(rest) > limit:
            if current:
                chunks.append(current)
                current = ''
            cut = rest.rfind(' ', 0, limit + 1)
            if cut <= 0:
                cut = limit
            chunks.append(rest[:cut])
            rest = rest[cut:].strip()
        if not rest:
            continue
        if current and len(current) + 1 + len(rest) > limit:
            chunks.append(current)
            current = rest
        else:
            current = f'{current} {rest}'.strip()
    if current:
        chunks.append(current)
    return chunks

class TranslationManager:
    def __init__(self):
        self.lock = threading.Lock()
        self.process = None
        self.job = {'state': 'idle', 'running': False, 'text': '', 'source': ''}

    def snapshot(self):
        with self.lock:
            return dict(self.job)

    def start(self, text, prepare=False):
        chunks = [] if prepare else split_text(text)
        if not HELPER.is_file():
            raise TranslationError('Apple翻訳の実行ファイルがありません。start.commandからアプリを起動してください。')
        with self.lock:
            if self.job.get('running'):
                raise TranslationError('前の翻訳が終了するまでお待ちください。')
            self.job = {'state': 'preparing', 'running': True, 'text': '', 'source': '' if prepare else text.strip(), 'prepareOnly': prepare, 'progress': 0, 'completed': 0, 'total': len(chunks), 'message': 'Apple翻訳を起動しています。初回は別ウィンドウで言語モデルを準備します。'}
        threading.Thread(target=self._run, args=(chunks,), daemon=True).start()

    def start_automatic(self, text):
        """Keep the English result available even if translation cannot start."""
        try:
            self.start(text)
        except (TranslationError, ValueError, OSError) as error:
            with self.lock:
                self.job = {'state': 'error', 'running': False, 'text': '',
                            'source': text, 'message': str(error)}

    def cancel(self):
        with self.lock:
            if not self.job.get('running'):
                return
            message = '翻訳を中止しました。言語モデルの取得はMac側で続く場合があります。' if self.job['state'] == 'preparing' else '翻訳を中止しました。途中までの訳文は保存できます。'
            self.job.update(state='cancelled', message=message)
            if self.process and self.process.poll() is None:
                try:
                    os.killpg(self.process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass

    def _run(self, chunks):
        process = None
        try:
            with tempfile.TemporaryFile(mode='w+t') as errors:
                with self.lock:
                    if self.job['state'] == 'cancelled':
                        return
                    process = subprocess.Popen([str(HELPER)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, text=True, start_new_session=True)
                    self.process = process
                process.stdin.write(json.dumps({'chunks': chunks}, ensure_ascii=False))
                process.stdin.close()
                for line in process.stdout:
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(event, dict):
                        continue
                    with self.lock:
                        if self.job['state'] != 'cancelled':
                            self.job.update({key: value for key, value in event.items() if key in ('state', 'message', 'text', 'progress', 'completed', 'total')})
                code = process.wait()
                with self.lock:
                    if self.job['state'] not in ('cancelled', 'error') and (code or self.job['state'] != 'done'):
                        self.job.update(state='error', message='Apple翻訳が終了しました。ダウンロード画面を閉じた場合は、もう一度「翻訳モデルを準備」を押してください。')
        except (OSError, ValueError):
            with self.lock:
                if self.job['state'] != 'cancelled':
                    self.job.update(state='error', message='Apple翻訳を起動できませんでした。start.commandからアプリを起動し直してください。')
        finally:
            if process and process.poll() is None:
                process.terminate()
                process.wait()
            if process:
                if not process.stdin.closed:
                    process.stdin.close()
                process.stdout.close()
            with self.lock:
                self.process = None
                self.job['running'] = False
