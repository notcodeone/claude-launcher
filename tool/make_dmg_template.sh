#!/usr/bin/env bash
# Готовит шаблон окна DMG — tool/dmg/template.dmg (см. tool/make_dmg.sh).
# Нужен, только если меняется фон или раскладка окна.
#
# Фон окна в macOS 26 должен задать сам Finder: записи dmgbuild, AppleScript и
# ссылку на скрытый файл он не принимает. Поэтому один шаг — ручной: скрипт
# откроет окно и подскажет, что сделать. Запускать на macOS 26 или новее — на
# них фон, заданный в прежних версиях, не виден.
#
# Запуск из корня репозитория (нужны python3 и Xcode Command Line Tools):
#   python3 tool/generate_dmg_background.py   # если менялся фон
#   tool/make_dmg_template.sh
set -euo pipefail

out="tool/dmg/template.dmg"
background="tool/dmg/background.tiff"
icons="macos/Runner/Assets.xcassets/AppIcon.appiconset"
volume="/Volumes/ClaudeLauncher"

[ -e "$volume" ] && { echo "Уже смонтирован $volume — извлеките его" >&2; exit 1; }

work="$(mktemp -d)"
trap 'hdiutil detach "$volume" -quiet 2>/dev/null || true; rm -rf "$work"' EXIT

# Библиотеки для .DS_Store — в своём окружении Python.
venv="build/dmg-template-venv"
if [ ! -x "$venv/bin/python" ]; then
  python3 -m venv "$venv"
  "$venv/bin/pip" install --quiet --disable-pip-version-check \
    "ds_store==1.3.1" "mac_alias==2.2.2"
fi

# Значок тома — значок приложения.
iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
  cp "$icons/app_icon_$size.png" "$iconset/icon_${size}x${size}.png"
  cp "$icons/app_icon_$((size * 2)).png" "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o "$work/AppIcon.icns"

# Том: заглушка приложения (make_dmg.sh заменит её), ссылка на «Программы», фон.
hdiutil create -size 40m -fs HFS+ -volname ClaudeLauncher -layout SPUD \
  "$work/rw.dmg" >/dev/null
hdiutil attach "$work/rw.dmg" -readwrite -noautoopen >/dev/null
mkdir "$volume/ClaudeLauncher.app"
ln -s /Applications "$volume/Программы"
cp "$background" "$volume/background.tiff"
cp "$work/AppIcon.icns" "$volume/.VolumeIcon.icns"
SetFile -a C "$volume"
open "$volume"

cat <<'EOF'

В открывшемся окне Finder:
  1. Вид → Показать параметры вида.
  2. Фон: Изображение.
  3. Перетащите значок background.tiff из окна в квадрат «Перетащите изображение сюда».
  4. Закройте панель и окно.
EOF
read -r -p "Готово? Нажмите Enter. "

# Finder записывает настройки при извлечении тома.
hdiutil detach "$volume" -quiet
hdiutil attach "$work/rw.dmg" -readwrite -nobrowse -noautoopen >/dev/null

# Раскладку окна дописываем сами, а записи Finder о фоне (ссылка в icvp,
# pBB0, pBBk) сохраняем как есть: .DS_Store пишется заново целиком — правка
# на месте портит файл, который записал Finder.
"$venv/bin/python" - "$volume" <<'EOF'
import os
import sys

from ds_store import DSStore, store

volume = sys.argv[1]
path = os.path.join(volume, ".DS_Store")
# Закладку, которую пишет macOS 26, библиотека не разбирает — берём байты.
store.codecs.pop(b"pBBk", None)

with DSStore.open(path, "r") as d:
    finder = {(e.filename, e.code): e.value for e in d}
icvp = finder.get((".", b"icvp"))
if not icvp or icvp.get("backgroundType") != 2 or "backgroundImageAlias" not in icvp:
    sys.exit("Фон не задан — повторите шаг в Finder")

icvp.update(
    arrangeBy="none",
    iconSize=128.0,
    textSize=13.0,
    showIconPreview=False,
    scrollPositionX=0.0,
    scrollPositionY=0.0,
)
os.remove(path)
with DSStore.open(path, "w+") as d:
    d["."]["vSrn"] = ("long", 1)
    # Окно 660×400 по содержимому (фон), плюс заголовок.
    d["."]["bwsp"] = {
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
        "ShowStatusBar": False,
        "ShowTabView": False,
        "ShowToolbar": False,
        "SidebarWidth": 180,
        "WindowBounds": "{{200, 160}, {660, 428}}",
    }
    d["."]["icvp"] = icvp
    d["."]["icvl"] = ("type", b"icnv")
    for code in (b"pBB0", b"pBBk"):
        if (".", code) in finder:
            d["."][code.decode()] = ("blob", bytes(finder[(".", code)]))
    # Центры значков — как на фоне (tool/generate_dmg_background.py).
    d["ClaudeLauncher.app"]["Iloc"] = (170, 200)
    d["Программы"]["Iloc"] = (490, 200)
    d["background.tiff"]["Iloc"] = (330, 520)
EOF

# Файл фона прячем флагом: скрытый по имени (с точкой) Finder как фон не берёт.
chflags hidden "$volume/background.tiff"
hdiutil detach "$volume" -quiet
rm -f "$out"
hdiutil convert "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$out" >/dev/null
echo "$out"
