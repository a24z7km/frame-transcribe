'use strict';
const $ = id => document.getElementById(id);
let file = null, token = '', busy = false, segments = [], pollTimer, lastState = 'idle';
let translating = false, translatedSource = '';
let translationTimer;
function status(message, error = false) { $('status').textContent = message; $('status').classList.toggle('error', error); }
function buttons() {
  $('start').disabled = busy || translating || !file || !token;
  $('file').disabled = busy || translating;
  $('model').disabled = busy;
  $('cancel').hidden = !busy || lastState === 'uploading';
  $('result').readOnly = busy || translating;
  $('japanese').readOnly = translating;
  $('translate').disabled = busy || translating || !token || !$('result').value.trim();
  $('translate').textContent = $('japanese').value.trim() ? '再翻訳' : '翻訳';
  $('prepare-translation').disabled = busy || translating || !token;
  $('cancel-translation').hidden = !translating;
  $('copy-ja').disabled = !$('japanese').value.trim();
  $('txt-ja').disabled = !$('japanese').value.trim();
  const empty = !$('result').value.trim();
  $('copy').disabled = empty;
  $('txt').disabled = empty;
  $('srt').disabled = !segments.length || busy;
  const words = $('result').value.trim().match(/\S+/g) || [];
  $('word-count').textContent = words.length ? `${words.length.toLocaleString()}語` : '';
}
function selectFile(selected) {
  if (busy || translating || !selected) return;
  if (!/\.(mp3|mp4)$/i.test(selected.name) || !selected.size || selected.size > 4 * 1024 ** 3) {
    status('MP3または音声入りMP4（4GB以下）を選んでください。', true); return;
  }
  file = selected;
  $('file-name').textContent = selected.name;
  $('file-detail').textContent = `${(selected.size / 1024 ** 2).toFixed(1)} MB`;
  status(''); buttons();
}
$('file').addEventListener('change', e => selectFile(e.target.files[0]));
for (const event of ['dragenter', 'dragover']) $('drop').addEventListener(event, e => { e.preventDefault(); if (!busy) $('drop').classList.add('drag'); });
for (const event of ['dragleave', 'drop']) $('drop').addEventListener(event, e => { e.preventDefault(); $('drop').classList.remove('drag'); });
$('drop').addEventListener('drop', e => selectFile(e.dataTransfer.files[0]));
window.addEventListener('dragover', e => e.preventDefault());
window.addEventListener('drop', e => e.preventDefault());
$('result').addEventListener('input', () => {
  if (translatedSource && translatedSource !== $('result').value.trim()) translationStatus('原文を変更しました');
  buttons();
});
$('japanese').addEventListener('input', buttons);
async function poll(restoreTranslation = false) {
  try {
    const response = await fetch('/api/status');
    if (!response.ok) throw new Error();
    const job = await response.json();
    lastState = job.state;
    busy = !!job.running;
    if (job.segments) segments = job.segments;
    if (typeof job.text === 'string' && job.state !== 'idle') $('result').value = job.text;
    $('progress-wrap').hidden = !busy;
    $('bar').style.width = `${job.progress || 0}%`;
    if (job.state === 'error') status(job.message || '処理できませんでした', true);
    else status(busy ? (job.state === 'transcribing' ? `${job.progress || 0}%` : '準備中…') : '');
    if (job.state === 'cancelled') status(busy ? '停止しています…' : '中止しました。途中までの結果は保存できます。');
    buttons();
    if (!busy && job.state === 'done') await pollTranslation(restoreTranslation);
    if (busy) pollTimer = setTimeout(poll, 1200);
  } catch {
    status('アプリとの接続が切れました。起動用ファイルを確認してください。', true);
    if (busy) pollTimer = setTimeout(poll, 3000);
  }
}
$('start').addEventListener('click', async () => {
  if (busy || translating || !file) return;
  $('japanese').value = ''; translatedSource = ''; translationStatus('');
  busy = true; lastState = 'uploading'; segments = []; $('result').value = ''; buttons();
  status('読み込み中…');
  $('progress-wrap').hidden = false; $('bar').style.width = '0%';
  try {
    const response = await fetch('/api/transcribe', {method: 'POST', headers: {'X-App-Token': token, 'X-Model': $('model').value, 'Content-Type': 'application/octet-stream'}, body: file});
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || '開始できませんでした。');
    clearTimeout(pollTimer); poll();
  } catch (error) { busy = false; status(error.message, true); buttons(); }
});
$('cancel').addEventListener('click', async () => {
  try {
    const response = await fetch('/api/cancel', {method: 'POST', headers: {'X-App-Token': token}});
    if (!response.ok) throw new Error();
    status('停止しています…');
  } catch { status('停止できませんでした。もう一度お試しください。', true); }
});
$('copy').addEventListener('click', async () => {
  try { await navigator.clipboard.writeText($('result').value); status('テキストをコピーしました。'); }
  catch { $('result').focus(); $('result').select(); status('テキストを選択しました。⌘Cでコピーできます。'); }
});
function download(text, extension, suffix = '') {
  const url = URL.createObjectURL(new Blob([text], {type: 'text/plain;charset=utf-8'}));
  const link = document.createElement('a'); link.href = url;
  link.download = `${file ? file.name.replace(/\.(mp3|mp4)$/i, '') : 'transcript'}${suffix}.${extension}`;
  link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
}
$('txt').addEventListener('click', () => download($('result').value, 'txt'));
function stamp(seconds) {
  const ms = Math.round(seconds * 1000);
  return `${String(Math.floor(ms / 3600000)).padStart(2,'0')}:${String(Math.floor(ms / 60000) % 60).padStart(2,'0')}:${String(Math.floor(ms / 1000) % 60).padStart(2,'0')},${String(ms % 1000).padStart(3,'0')}`;
}
$('srt').addEventListener('click', () => download(segments.map((s, i) => `${i + 1}\n${stamp(s.start)} --> ${stamp(s.end)}\n${s.text}\n`).join('\n'), 'srt'));
(async () => {
  try { const response = await fetch('/api/session'); if (!response.ok) throw new Error(); token = (await response.json()).token; await poll(true); if (lastState !== 'done' && !busy) await pollTranslation(true); buttons(); }
  catch { status('start.commandからアプリを起動してください。', true); }
})();

function translationStatus(message, error = false) {
  $('translation-status').textContent = message;
  $('translation-status').classList.toggle('error', error);
}
async function pollTranslation(restore = false) {
  try {
    const response = await fetch('/api/translation');
    if (!response.ok) throw new Error('翻訳の状況を取得できませんでした。');
    const job = await response.json();
    translating = !!job.running;
    if (restore && job.source && (job.running || job.text)) $('result').value = job.source;
    if (!job.prepareOnly && typeof job.text === 'string' && job.state !== 'idle') $('japanese').value = job.text;
    if (job.state === 'done' && !job.running && !job.prepareOnly) translatedSource = job.source;
    if (job.state !== 'idle') {
      let message = job.state === 'error' ? job.message : (job.running ? (job.state === 'translating' && job.total ? `${job.completed || 0} / ${job.total}` : '準備中…') : '');
      translationStatus(message, job.state === 'error');
    }
    buttons();
    if (translating) translationTimer = setTimeout(() => pollTranslation(), 1000);
  } catch (error) {
    translationStatus('アプリとの接続が切れました。翻訳結果は再接続後に表示します。', true);
    if (translating) translationTimer = setTimeout(() => pollTranslation(), 3000);
  }
}
async function beginTranslation(prepare = false) {
  if (busy || translating) return;
  const source = $('result').value.trim();
  if (!prepare && !source) return;
  translating = true; buttons();
  translationStatus('準備中…');
  try {
    const response = await fetch(prepare ? '/api/translation/prepare' : '/api/translate', {method: 'POST', headers: {'X-App-Token': token, 'Content-Type': 'application/json'}, body: JSON.stringify({text: source})});
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || '翻訳を開始できませんでした。');
    if (!prepare) { translatedSource = ''; $('japanese').value = ''; }
    clearTimeout(translationTimer);
    await pollTranslation();
  } catch (error) {
    translating = false; translationStatus(error.message, true); buttons();
  }
}
$('translate').addEventListener('click', () => beginTranslation());
$('prepare-translation').addEventListener('click', () => beginTranslation(true));
$('cancel-translation').addEventListener('click', async () => {
  try {
    const response = await fetch('/api/translation/cancel', {method: 'POST', headers: {'X-App-Token': token}});
    if (!response.ok) throw new Error();
    translationStatus('翻訳を停止しています…');
  } catch { translationStatus('停止できませんでした。もう一度お試しください。', true); }
});
$('copy-ja').addEventListener('click', async () => {
  try { await navigator.clipboard.writeText($('japanese').value); translationStatus('日本語訳をコピーしました。'); }
  catch { $('japanese').focus(); $('japanese').select(); translationStatus('日本語訳を選択しました。⌘Cでコピーできます。'); }
});
$('txt-ja').addEventListener('click', () => download($('japanese').value, 'txt', '.ja'));
