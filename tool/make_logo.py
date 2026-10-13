"""Builds every logo/icon asset from assets/brand/logo.svg.

    python tool/make_logo.py

Renders the SVG with headless Chrome (or Edge), then writes:
  assets/brand/mark.svg      cat + play mark only (no wordmark)
  assets/brand/logo.png      full logo, transparent, trimmed   (in-app)
  assets/brand/mark.png      mark only, transparent, 512 px    (in-app)
  windows/runner/resources/app_icon.ico
  macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / 'assets' / 'brand'
BG = (0x03, 0x06, 0x0E, 255)
MARK_VIEWBOX = '330 124 656 656'  # square crop around the cat + play triangle

BROWSERS = [
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    'google-chrome', 'chromium',
]


def browser():
    for b in BROWSERS:
        if os.path.exists(b) or shutil.which(b):
            return b
    sys.exit('Chrome/Edge not found')


def make_mark_svg():
    src = (BRAND / 'logo.svg').read_text()
    paths = re.findall(r'<path [^>]*/>', src)
    # 0: blue play triangle, 2: cat head, 3: cat eye. The rest is the "CAT" wordmark.
    body = paths[0] + paths[2] + paths[3]
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{MARK_VIEWBOX}" '
           f'width="1024" height="1024">{body}</svg>\n')
    (BRAND / 'mark.svg').write_text(svg)


def render(svg: Path, size: int) -> Image.Image:
    with tempfile.TemporaryDirectory() as tmp:
        html = Path(tmp) / 'r.html'
        png = Path(tmp) / 'r.png'
        html.write_text(
            '<html><body style="margin:0;background:transparent">'
            f'<img src="{svg.as_uri()}" width="{size}" height="{size}" style="display:block">'
            '</body></html>')
        subprocess.run([
            browser(), '--headless', '--disable-gpu', '--hide-scrollbars',
            '--allow-file-access-from-files', '--default-background-color=00000000',
            f'--window-size={size},{size}', f'--screenshot={png}', html.as_uri(),
        ], check=True, capture_output=True)
        return Image.open(png).convert('RGBA').copy()


def app_icon(mark: Image.Image, n=1024) -> Image.Image:
    """The mark on a dark rounded square, like the brand artwork."""
    big = n * 4
    mask = Image.new('L', (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0.04 * big, 0.04 * big, 0.96 * big, 0.96 * big), radius=0.215 * big, fill=255)
    mask = mask.resize((n, n), Image.LANCZOS)
    img = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    img.paste(Image.new('RGBA', (n, n), BG), (0, 0), mask)
    m = int(n * 0.74)
    img.alpha_composite(mark.resize((m, m), Image.LANCZOS), ((n - m) // 2, (n - m) // 2))
    return img


def main():
    make_mark_svg()
    logo = render(BRAND / 'logo.svg', 1024)
    mark = render(BRAND / 'mark.svg', 2048)
    logo.crop(logo.getbbox()).save(BRAND / 'logo.png')  # trimmed to the artwork
    mark.resize((512, 512), Image.LANCZOS).save(BRAND / 'mark.png')

    icon = app_icon(mark)
    icon.save(ROOT / 'windows' / 'runner' / 'resources' / 'app_icon.ico',
              sizes=[(x, x) for x in (16, 20, 24, 32, 40, 48, 64, 128, 256)])
    mac = ROOT / 'macos' / 'Runner' / 'Assets.xcassets' / 'AppIcon.appiconset'
    for x in (16, 32, 64, 128, 256, 512, 1024):
        icon.resize((x, x), Image.LANCZOS).save(mac / f'app_icon_{x}.png')
    print('ok')


if __name__ == '__main__':
    main()
