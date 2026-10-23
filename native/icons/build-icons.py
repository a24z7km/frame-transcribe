"""Package the selected image assets into macOS multiresolution icons."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
for name in ('frame', 'frame-live'):
    iconset = ROOT / f'{name}.iconset'
    iconset.mkdir(exist_ok=True)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = '@2x' if scale == 2 else ''
            output = iconset / f'icon_{size}x{size}{suffix}.png'
            subprocess.run(['sips', '-z', str(size * scale), str(size * scale),
                            str(ROOT / f'{name}.png'), '--out', str(output)],
                           check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(ROOT / f'{name}.icns')], check=True)
