#!/usr/bin/env python3
"""Local English audio transcription. Standard-library HTTP server, isolated worker."""
import json, os, secrets, signal, subprocess, sys, tempfile, threading, time, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse
from translation import TranslationManager, TranslationError

ROOT = Path(__file__).resolve().parent
TOKEN = secrets.token_urlsafe(32)
LOCK = threading.Lock()
JOB = {'state': 'idle'}
PROCESS = None
PORT = int(os.environ.get('PORT', '8765'))
MAX_BYTES = 4 * 1024**3
TRANSLATION = TranslationManager()

def run_job(path, model):
    global PROCESS
    try:
        with LOCK:
            if JOB['state'] == 'cancelled':
                return
            PROCESS = subprocess.Popen([sys.executable, str(ROOT / 'worker.py'), path, model], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
            process = PROCESS
        # Drain stderr to disk so model diagnostics cannot block the worker.
        with tempfile.TemporaryFile(mode='w+t') as errors:
            def drain():
                for line in process.stderr:
                    errors.write(line)
            reader = threading.Thread(target=drain, daemon=True)
            reader.start()
            for line in process.stdout:
                try:
                    update = json.loads(line)
                except ValueError:
                    continue
                with LOCK:
                    if JOB['state'] != 'cancelled':
                        JOB.update(update)
            code = process.wait()
            reader.join()
            with LOCK:
                if JOB['state'] not in ('cancelled', 'error') and (code or JOB['state'] != 'done'):
                    JOB.update(state='error', message='処理に失敗しました。音声入りのMP3・MP4か、空き容量とネット接続を確認してください。')
    except Exception:
        with LOCK:
            if JOB['state'] != 'cancelled':
                JOB.update(state='error', message='文字起こしを開始できませんでした。アプリを再起動してください。')
    finally:
        Path(path).unlink(missing_ok=True)
        with LOCK:
            PROCESS = None
            JOB['running'] = False

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, code, body, mime='application/json; charset=utf-8'):
        data = json.dumps(body, ensure_ascii=False).encode() if isinstance(body, dict) else body
        self.send_response(code)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        self.wfile.write(data)

    def valid_host(self):
        return self.headers.get('Host') in (f'127.0.0.1:{PORT}', f'localhost:{PORT}')

    def do_GET(self):
        if not self.valid_host():
            return self.reply(403, {'error': 'Local access only'})
        path = urlparse(self.path).path
        if path == '/api/health':
            return self.reply(200, {'app': 'frame-local', 'root': str(ROOT), 'pid': os.getpid()})
        if path == '/api/status':
            with LOCK:
                return self.reply(200, dict(JOB))
        if path == '/api/translation':
            return self.reply(200, TRANSLATION.snapshot())
        if path == '/api/session':
            return self.reply(200, {'token': TOKEN})
        files = {'/': ('index.html', 'text/html; charset=utf-8'), '/app.js': ('app.js', 'text/javascript; charset=utf-8'), '/styles.css': ('styles.css', 'text/css; charset=utf-8')}
        if path not in files:
            return self.reply(404, {'error': 'Not found'})
        name, mime = files[path]
        self.reply(200, (ROOT / 'dist' / name).read_bytes(), mime)

    def do_POST(self):
        global JOB
        if not self.valid_host() or self.headers.get('X-App-Token') != TOKEN:
            return self.reply(403, {'error': 'ページを再読み込みしてください。'})
        path = urlparse(self.path).path
        if path == '/api/translation/cancel':
            TRANSLATION.cancel()
            return self.reply(200, {'ok': True})
        if path in ('/api/translate', '/api/translation/prepare'):
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 3 * 1024 * 1024:
                    return self.reply(413, {'error': '翻訳データが大きすぎます（英文は最大2MB）。'})
                self.connection.settimeout(30)
                payload = json.loads(self.rfile.read(length))
                if not isinstance(payload, dict):
                    raise ValueError()
                with LOCK:
                    if JOB.get('running'):
                        return self.reply(409, {'error': '文字起こしが終了するまでお待ちください。'})
                    TRANSLATION.start(payload.get('text'), prepare=path.endswith('/prepare'))
                return self.reply(202, {'ok': True})
            except (ValueError, UnicodeError, TypeError):
                return self.reply(400, {'error': '翻訳する英文を入力してください（最大2MB）。'})
            except TranslationError as error:
                return self.reply(409, {'error': str(error)})
            except OSError:
                return self.reply(408, {'error': '翻訳データの読み込みに失敗しました。'})
        if path == '/api/cancel':
            with LOCK:
                JOB['state'] = 'cancelled'
                if PROCESS and PROCESS.poll() is None:
                    try:
                        os.killpg(PROCESS.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            return self.reply(200, {'ok': True})
        if path != '/api/transcribe':
            return self.reply(404, {'error': 'Not found'})
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            length = 0
        if not 0 < length <= MAX_BYTES:
            return self.reply(413, {'error': '空ではない4GB以下のMP3・MP4を選んでください。'})
        model = self.headers.get('X-Model', 'tiny.en')
        if model not in ('tiny.en', 'base.en'):
            return self.reply(400, {'error': 'モデルが無効です。'})
        with LOCK:
            if JOB.get('running') or TRANSLATION.snapshot().get('running'):
                return self.reply(409, {'error': '前の処理が終了するまでお待ちください。'})
            JOB = {'state': 'uploading', 'running': True, 'progress': 0, 'segments': [], 'text': '', 'message': 'ファイルを読み込んでいます'}
        upload_path = None
        try:
            self.connection.settimeout(120)
            with tempfile.NamedTemporaryFile(suffix='.media', delete=False) as file:
                upload_path = file.name
                remaining = length
                while remaining:
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise OSError('Incomplete upload')
                    file.write(chunk)
                    remaining -= len(chunk)
            with LOCK:
                JOB.update(state='loading', message='音声モデルを準備しています（初回はダウンロード）')
            threading.Thread(target=run_job, args=(upload_path, model), daemon=True).start()
            self.reply(202, {'ok': True})
        except (OSError, TimeoutError):
            if upload_path:
                Path(upload_path).unlink(missing_ok=True)
            with LOCK:
                JOB.update(state='error', running=False, message='ファイルの読み込みに失敗しました。もう一度お試しください。')
            self.reply(400, {'error': 'ファイルの読み込みに失敗しました。'})

if __name__ == '__main__':
    server = ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
    print(f'Local: http://127.0.0.1:{PORT}', flush=True)
    if '--no-open' not in sys.argv:
        threading.Timer(0.7, lambda: webbrowser.open(f'http://127.0.0.1:{PORT}')).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        if PROCESS and PROCESS.poll() is None:
            os.killpg(PROCESS.pid, signal.SIGTERM)
    finally:
        TRANSLATION.cancel()
        server.server_close()
