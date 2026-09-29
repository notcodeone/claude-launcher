"""Фон окна DMG-образа: название, подсказка и стрелка от приложения к «Программам».

Рисует фон в 1x и 2x и склеивает в tool/dmg/background.tiff — Finder сам
выберет нужное разрешение. Положение значков задано в tool/dmg/settings.py:
центры (170, 200) и (490, 200), окно 660×400.

Запуск на macOS (шрифт SF Pro из системы, tiffutil): python3 tool/generate_dmg_background.py
"""

import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 660, 400
APP_X, APPLICATIONS_X, ICONS_Y = 170, 490, 200

# Цвета светлой темы приложения (lib/src/ui/theme.dart).
BACKGROUND = (255, 255, 255)
TEXT = (10, 10, 10)
MUTED = (110, 113, 121)
ARROW = (199, 199, 204)

FONT = "/System/Library/Fonts/SFNS.ttf"
OUT = Path(__file__).parent / "dmg"


def font(size, weight):
    face = ImageFont.truetype(FONT, size)
    face.set_variation_by_name(weight)
    return face


def draw(scale):
    # Рисуем крупнее и уменьшаем — так линии стрелки получаются сглаженными.
    ss = scale * 4
    image = Image.new("RGB", (WIDTH * ss, HEIGHT * ss), BACKGROUND)
    canvas = ImageDraw.Draw(image)

    def text(y, value, size, weight, color):
        face = font(size * ss, weight)
        width = canvas.textlength(value, font=face)
        canvas.text(((WIDTH * ss - width) / 2, y * ss), value, font=face, fill=color)

    text(44, "ClaudeLauncher", 24, b"Bold", TEXT)
    text(80, "Перетащите значок в папку «Программы»", 14, b"Regular", MUTED)

    # Стрелка между значками (значки 128 px, по бокам — место под них).
    start, end, y = APP_X + 88, APPLICATIONS_X - 88, ICONS_Y
    stroke = 4 * ss
    canvas.line([(start * ss, y * ss), ((end - 3) * ss, y * ss)], fill=ARROW, width=stroke)
    head = 14
    canvas.line(
        [((end - head) * ss, (y - head) * ss), (end * ss, y * ss), ((end - head) * ss, (y + head) * ss)],
        fill=ARROW,
        width=stroke,
        joint="curve",
    )
    for x, yy in [(start, y), (end - head, y - head), (end - head, y + head)]:
        r = stroke / 2
        canvas.ellipse([x * ss - r, yy * ss - r, x * ss + r, yy * ss + r], fill=ARROW)

    # Подвал, как в окне приложения.
    small = font(11 * ss, b"Regular")
    canvas.text((24 * ss, (HEIGHT - 30) * ss), "© 2026 ClaudeLauncher", font=small, fill=MUTED)
    signature = "Designed by NotCode"
    canvas.text(
        ((WIDTH - 24) * ss - canvas.textlength(signature, font=small), (HEIGHT - 30) * ss),
        signature,
        font=small,
        fill=MUTED,
    )
    return image.resize((WIDTH * scale, HEIGHT * scale), Image.LANCZOS)


def main():
    OUT.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        one, two = Path(tmp) / "background.png", Path(tmp) / "background@2x.png"
        draw(1).save(one, dpi=(72, 72))
        draw(2).save(two, dpi=(144, 144))
        subprocess.run(
            ["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(OUT / "background.tiff")],
            check=True,
            capture_output=True,
        )
    print(OUT / "background.tiff")


if __name__ == "__main__":
    main()
