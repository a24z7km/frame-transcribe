"""Generate local bundle metadata instead of committing machine-specific paths."""
from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parent.parent
bundles = (
    ('FrameTranslate', 'FrameTranslate', 'Frame Translate', 'local.frame.translation'),
    ('FrameLive', 'FrameLive', 'Frame Live', 'local.frame.live.build'),
    ('Frame', 'Frame', 'Frame 文字起こし', 'local.frame.launcher'),
)
for folder, executable, name, identifier in bundles:
    contents = ROOT / 'native' / f'{folder}.app' / 'Contents'
    (contents / 'MacOS').mkdir(parents=True, exist_ok=True)
    info = dict(CFBundleExecutable=executable, CFBundleIdentifier=identifier,
                CFBundleName=name, CFBundleDisplayName=name,
                CFBundlePackageType='APPL', CFBundleVersion='4',
                LSMinimumSystemVersion='15.0', NSHighResolutionCapable=True)
    if folder != 'FrameTranslate':
        info.update(FrameProjectRoot=str(ROOT), LSUIElement=True)
    if folder == 'FrameLive':
        info['NSAudioCaptureUsageDescription'] = '選んだブラウザの再生音声を、このMac内で英語字幕と日本語訳にします。マイクの音声は取得しません。'
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
