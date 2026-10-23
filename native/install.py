"""Install this app into the user Applications folder."""
from pathlib import Path
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
    subprocess.run(['xattr','-cr',str(target)],check=True)
    subprocess.run(['codesign','--force','--sign','-',str(target)],check=True)
    subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-f',str(target)],check=True)
    print('Installed:', target)

if __name__ == '__main__':
    install(ROOT/'native/Frame.app', APPLICATIONS/'Frame 文字起こし.app', 'local.frame.desktop-launcher')
