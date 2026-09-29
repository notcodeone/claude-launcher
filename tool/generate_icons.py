"""Генерирует иконки лаунчера: трей (macOS/Windows) и иконку приложения.

Запуск: python3 tool/generate_icons.py  (нужен Pillow)
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SS = 8  # суперсэмплинг для сглаживания
BLACK = (10, 10, 10, 255)
WHITE = (255, 255, 255, 255)


def glyph(size, color, scale=1.0):
    """Два профиля: закрашенный круг и кольцо поверх него с зазором."""
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    mask = Image.new("L", (s, s), 0)
    draw = ImageDraw.Draw(mask)
    r = 0.27 * s * scale
    stroke = 0.095 * s * scale
    gap = 0.07 * s * scale
    left = (0.5 - 0.17 * scale) * s, 0.5 * s
    right = (0.5 + 0.17 * scale) * s, 0.5 * s

    def circle(center, radius, fill):
        x, y = center
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=fill)

    circle(left, r, 255)
    circle(right, r + gap, 0)          # зазор вокруг второго профиля
    circle(right, r, 255)
    circle(right, r - stroke, 0)       # второй профиль — кольцо
    img.paste(Image.new("RGBA", (s, s), color), (0, 0), mask)
    return img.resize((size, size), Image.LANCZOS)


def app_icon(size):
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle(
        (0.1 * s, 0.1 * s, 0.9 * s, 0.9 * s), radius=0.18 * s, fill=BLACK
    )
    img = img.resize((size, size), Image.LANCZOS)
    img.alpha_composite(glyph(size, WHITE, scale=0.78))
    return img


def main():
    tray = ROOT / "assets" / "tray"
    tray.mkdir(parents=True, exist_ok=True)
    glyph(36, (0, 0, 0, 255)).save(tray / "tray_icon_template.png")
    # В трее Windows фон бывает и светлым, и тёмным — берём чёрный квадрат с белым знаком.
    ico_sizes = [16, 20, 24, 32, 40, 48, 64]
    app_icon(256).save(tray / "tray_icon.ico", sizes=[(n, n) for n in ico_sizes])

    appiconset = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for n in [16, 32, 64, 128, 256, 512, 1024]:
        app_icon(n).save(appiconset / f"app_icon_{n}.png")
    app_icon(256).save(
        ROOT / "windows" / "runner" / "resources" / "app_icon.ico",
        sizes=[(n, n) for n in [16, 24, 32, 48, 64, 128, 256]],
    )


if __name__ == "__main__":
    main()
