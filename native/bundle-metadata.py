"""Generate local bundle metadata instead of committing machine-specific paths."""
from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parent.parent
bundles = (
    ('FrameTranslate', 'FrameTranslate', 'Frame Translate', 'local.frame.translation'),
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
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
