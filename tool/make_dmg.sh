#!/usr/bin/env bash
# Собирает DMG-образ для macOS: окно установки с фоном, «ClaudeLauncher.app»
# и ссылкой на «Программы» — установка перетаскиванием.
#
# Окно (фон, размер, положение значков) берётся готовым из шаблона
# tool/dmg/template.dmg, сборка только кладёт в него приложение. Фон в macOS 26
# должен задать сам Finder — записи dmgbuild и AppleScript он не принимает, —
# поэтому шаблон готовится один раз (tool/make_dmg_template.sh), а здесь
# файловая система шаблона не пересоздаётся и ссылки Finder на фон остаются
# верными. Finder и AppleScript при сборке не нужны — работает и в CI.
#
# Запуск из корня репозитория после `flutter build macos --release`:
#   tool/make_dmg.sh 1.0.0
# Готовый образ: build/installer/ClaudeLauncher-<версия>.dmg
set -euo pipefail

version="${1:?Укажите версию, например: tool/make_dmg.sh 1.0.0}"
app="build/macos/Build/Products/Release/ClaudeLauncher.app"
template="tool/dmg/template.dmg"
out_dir="build/installer"
dmg="$out_dir/ClaudeLauncher-$version.dmg"

[ -d "$app" ] || { echo "Нет $app — сначала flutter build macos --release" >&2; exit 1; }

work="$(mktemp -d)"
mnt="$work/mnt"
trap 'hdiutil detach "$mnt" -quiet 2>/dev/null || true; rm -rf "$work"' EXIT

# Шаблон — в записываемый образ, с местом под приложение.
hdiutil convert "$template" -format UDRW -o "$work/rw.dmg" >/dev/null
size_mb=$(($(du -sm "$app" | cut -f1) + 20))
hdiutil resize -size "${size_mb}m" "$work/rw.dmg" >/dev/null
mkdir "$mnt"
hdiutil attach "$work/rw.dmg" -readwrite -nobrowse -noautoopen -mountpoint "$mnt" >/dev/null

# ditto сохраняет права, ссылки и расширенные атрибуты внутри бандла.
ditto "$app" "$work/ClaudeLauncher.app"

# Flutter подписывает бандл ad-hoc, а при повторной сборке меняет вложенный
# App.framework — подпись становится невалидной, и на другом Mac скачанное
# приложение считается «повреждённым». Переподписываем целиком и проверяем —
# на обычном диске: внутри тома образа codesign падает.
codesign --force --deep --sign - "$work/ClaudeLauncher.app"
codesign --verify --deep --strict "$work/ClaudeLauncher.app"

# Заглушку из шаблона меняем на приложение с тем же именем — к имени привязано
# положение значка.
rm -rf "$mnt/ClaudeLauncher.app"
ditto "$work/ClaudeLauncher.app" "$mnt/ClaudeLauncher.app"

hdiutil detach "$mnt" -quiet
mkdir -p "$out_dir"
rm -f "$dmg"
hdiutil convert "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg" >/dev/null

echo "$dmg"
