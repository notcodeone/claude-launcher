"""Генерирует все значки лаунчера из одного знака — «искры» Claude и спереди
справа снизу «играть», как на кнопке запуска профиля:

- иконка приложения: белый знак на чёрной плитке (macOS, Windows, уведомления
  Windows, картинка мастера установки);
- строка меню macOS: чёрный шаблон без фона — цвет подставляет система;
- трей Windows: без фона, чёрный для светлой панели задач и белый для тёмной;
- шапка окна лаунчера: знак без фона, приложение красит его цветом текста.

«Искра» — tool/icon/claude_spark.png: белая маска, выделенная из значка
приложения Claude (знак Anthropic).

Запуск на macOS: python3 tool/generate_icons.py  (нужны Pillow и tiffutil)
"""
import math
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SPARK = ROOT / "tool" / "icon" / "claude_spark.png"
SS = 8  # суперсэмплинг для сглаживания
BLACK = (10, 10, 10, 255)
WHITE = (255, 255, 255, 255)

# Раскладка знака в долях стороны плитки.
SPARK_CENTER, SPARK_DIAMETER = (0.484, 0.5), 0.725
PLAY_CENTER, PLAY_SIZE, PLAY_GAP = (0.785, 0.756), 0.294, 0.0275


def capsule(draw, a, b, radius, fill):
    """Отрезок со скруглёнными концами."""
    (x1, y1), (x2, y2) = a, b
    length = math.hypot(x2 - x1, y2 - y1)
    nx, ny = -(y2 - y1) / length * radius, (x2 - x1) / length * radius
    draw.polygon(
        [(x1 + nx, y1 + ny), (x2 + nx, y2 + ny), (x2 - nx, y2 - ny), (x1 - nx, y1 - ny)],
        fill=fill,
    )
    for x, y in (a, b):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=fill)


def play(draw, center, size, fill, grow=0.0):
    """«Играть», как на кнопке запуска: треугольник (6,3)–(20,12)–(6,21) в сетке
    24 (Lucide), залитый, со скруглёнными углами. [grow] — раздуть контур: так
    рисуется вырез вокруг знака."""
    cx, cy = center
    k = size / 24
    # Центр масс треугольника левее середины сетки — сдвигаем вправо.
    ox, oy = cx - 12 * k + 1.3 * k, cy - 12 * k
    points = [(ox + 6 * k, oy + 3 * k), (ox + 20 * k, oy + 12 * k), (ox + 6 * k, oy + 21 * k)]
    draw.polygon(points, fill=fill)
    for a, b in zip(points, points[1:] + points[:1]):
        capsule(draw, a, b, 1.8 * k + grow, fill)


def mark(s, play_size=PLAY_SIZE, gap=PLAY_GAP):
    """Знак маской (L) на квадрате-плитке со стороной s: «искра», а спереди
    «играть» — лучи за ней срезаны по её контуру."""
    mask = Image.new("L", (s, s), 0)
    d = round(SPARK_DIAMETER * s)
    spark = Image.open(SPARK).getchannel("A").resize((d, d), Image.LANCZOS)
    mask.paste(spark, (round(SPARK_CENTER[0] * s - d / 2), round(SPARK_CENTER[1] * s - d / 2)))
    draw = ImageDraw.Draw(mask)
    center = PLAY_CENTER[0] * s, PLAY_CENTER[1] * s
    play(draw, center, play_size * s, 0, grow=gap * s)
    play(draw, center, play_size * s, 255)
    return mask


def app_icon(size):
    """Белый знак на чёрной скруглённой плитке, с полями как у иконок macOS."""
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle(
        (0.1 * s, 0.1 * s, 0.9 * s, 0.9 * s), radius=0.18 * s, fill=BLACK
    )
    t, o = round(0.8 * s), round(0.1 * s)
    img.paste(WHITE, (o, o, o + t, o + t), mark(t))
    return img.resize((size, size), Image.LANCZOS)


def bare_mark(size, color, margin=0.06):
    """Знак без фона на весь квадрат (с полем [margin]) — для строки меню и трея.
    В 16–44 px «играть» крупнее и зазор шире, иначе они сливаются с лучами."""
    m = mark(size * SS, play_size=0.36, gap=0.045)
    m = m.crop(m.getbbox())
    side = round(max(m.size) * (1 + margin))
    square = Image.new("L", (side, side), 0)
    square.paste(m, ((side - m.width) // 2, (side - m.height) // 2))
    img = Image.new("RGBA", (side, side), color[:3] + (0,))
    img.putalpha(square)
    return img.resize((size, size), Image.LANCZOS)


def main():
    tray = ROOT / "assets" / "tray"
    tray.mkdir(parents=True, exist_ok=True)

    # Строка меню macOS: шаблон 22 pt (больше строка не вмещает) — 22 и 44 px
    # в одном TIFF, система выберет. Размер задан и в lib/src/tray.dart.
    with tempfile.TemporaryDirectory() as tmp:
        one, two = Path(tmp) / "t.png", Path(tmp) / "t@2x.png"
        bare_mark(22, BLACK, margin=0.02).save(one, dpi=(72, 72))
        bare_mark(44, BLACK, margin=0.02).save(two, dpi=(144, 144))
        subprocess.run(
            ["tiffutil", "-cathidpicheck", str(one), str(two),
             "-out", str(tray / "tray_icon_template.tiff")],
            check=True,
            capture_output=True,
        )

    # Трей Windows: 16 px при 100 % масштаба, крупнее — для 125–400 %.
    ico_sizes = [(n, n) for n in [16, 20, 24, 32, 40, 48, 64]]
    bare_mark(256, BLACK).save(tray / "tray_icon_light.ico", sizes=ico_sizes)
    bare_mark(256, WHITE).save(tray / "tray_icon_dark.ico", sizes=ico_sizes)

    appiconset = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for n in [16, 32, 64, 128, 256, 512, 1024]:
        app_icon(n).save(appiconset / f"app_icon_{n}.png")
    app_icon(256).save(
        ROOT / "windows" / "runner" / "resources" / "app_icon.ico",
        sizes=[(n, n) for n in [16, 24, 32, 48, 64, 128, 256]],
    )

    # Уведомления Windows: значок приложения файлом (путь уходит в реестр).
    icon = ROOT / "assets" / "icon"
    icon.mkdir(parents=True, exist_ok=True)
    app_icon(256).save(icon / "app_icon.png")
    # Знак в шапке окна: 20 pt, с запасом до 4x; цвет задаёт приложение (цвет текста).
    bare_mark(80, BLACK, margin=0.02).save(icon / "mark.png")

    # Картинка мастера установки Inno Setup: область 58 px при 100 % масштаба,
    # до 159 px при 250 %. BMP на белом — как фон мастера.
    installer = ROOT / "windows" / "installer"
    for n in [58, 87, 116, 159]:
        image = Image.new("RGBA", (n, n), WHITE)
        image.alpha_composite(app_icon(n))
        image.convert("RGB").save(installer / f"wizard_small_{n}.bmp")


if __name__ == "__main__":
    main()
