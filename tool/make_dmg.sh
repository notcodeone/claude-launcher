#!/usr/bin/env bash
# Собирает DMG-образ для macOS: внутри «ClaudeLauncher.app» и ссылка на
# «Программы» — установка перетаскиванием.
#
# Запуск из корня репозитория после `flutter build macos --release`:
#   tool/make_dmg.sh 1.0.0
# Готовый образ: build/installer/ClaudeLauncher-<версия>.dmg
set -euo pipefail

version="${1:?Укажите версию, например: tool/make_dmg.sh 1.0.0}"
app="build/macos/Build/Products/Release/ClaudeLauncher.app"
out_dir="build/installer"
dmg="$out_dir/ClaudeLauncher-$version.dmg"

[ -d "$app" ] || { echo "Нет $app — сначала flutter build macos --release" >&2; exit 1; }

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

# ditto сохраняет права, ссылки и расширенные атрибуты внутри бандла.
ditto "$app" "$staging/ClaudeLauncher.app"

# Flutter подписывает бандл ad-hoc, а при повторной сборке меняет вложенный
# App.framework — подпись становится невалидной, и на другом Mac скачанное
# приложение считается «повреждённым». Переподписываем целиком и проверяем.
codesign --force --deep --sign - "$staging/ClaudeLauncher.app"
codesign --verify --deep --strict "$staging/ClaudeLauncher.app"
ln -s /Applications "$staging/Программы"

mkdir -p "$out_dir"
rm -f "$dmg"
hdiutil create \
  -volname "ClaudeLauncher" \
  -srcfolder "$staging" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$dmg" >/dev/null

echo "$dmg"
