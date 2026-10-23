"""Build/sign outside cloud-synced folders, then copy the bundle contents back."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent
bundle, source, executable = sys.argv[1:]
target = root / f'{bundle}.app' / 'Contents'
with tempfile.TemporaryDirectory(prefix='frame-native-build-') as directory:
    app = Path(directory) / f'{bundle}.app'
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    shutil.copyfile(target / 'Info.plist', contents / 'Info.plist')
    binary = contents / 'MacOS' / executable
    subprocess.run(['swiftc', '-parse-as-library', '-O', '-target', 'arm64-apple-macos15.0',
                    '-module-cache-path', str(Path(tempfile.gettempdir()) / 'frame-swift-module-cache'),
                    str(root / source), '-o', str(binary)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    shutil.copytree(contents, target, dirs_exist_ok=True, copy_function=shutil.copyfile)
    (target / 'MacOS' / executable).chmod(0o755)
