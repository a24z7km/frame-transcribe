"""Install only the two Frame apps into the user's Applications folder."""
from pathlib import Path
import argparse
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
APPLICATIONS = Path.home() / 'Applications'
APPLICATIONS.mkdir(exist_ok=True)

def install(source, target, identifier):
    if target.exists():
        current = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
        if current.get('CFBundleIdentifier') != identifier:
            raise SystemExit(f'別のアプリがあるため上書きしていません: {target}')
    shutil.copytree(source, target, dirs_exist_ok=True, copy_function=shutil.copyfile)
    info_path = target / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info.update(CFBundleIdentifier=identifier, FrameProjectRoot=str(ROOT), CFBundleVersion='4')
    for binary in (target / 'Contents/MacOS').iterdir():
        if binary.is_file(): binary.chmod(0o755)
    if identifier == 'local.frame.desktop-launcher':
        info['CFBundleURLTypes'] = [{'CFBundleURLName':'local.frame.launch','CFBundleTypeRole':'Viewer','CFBundleURLSchemes':['frame-transcribe']}]
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run(['xattr','-d','com.apple.FinderInfo',str(target)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    subprocess.run(['codesign','--force','--sign','-',str(target)],check=True)
    subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-f',str(target)],check=True)
    print('Installed:', target)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--live-only', action='store_true', help='Update only Frame Live')
    options = parser.parse_args()
    install(ROOT/'native/FrameLive.app', APPLICATIONS/'Frame Live.app', 'local.frame.live')
    if not options.live_only:
        install(ROOT/'native/Frame.app', APPLICATIONS/'Frame 文字起こし.app', 'local.frame.desktop-launcher')
