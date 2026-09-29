#!/usr/bin/env bash
# Собирает DMG-образ для macOS: внутри «Claude Launcher.app» и ссылка на
# «Программы» — установка перетаскиванием.
#
# Запуск из корня репозитория после `flutter build macos --release`:
#   tool/make_dmg.sh 1.0.0
# Готовый образ: build/installer/ClaudeLauncher-<версия>.dmg
set -euo pipefail

version="${1:?Укажите версию, например: tool/make_dmg.sh 1.0.0}"
app="build/macos/Build/Products/Release/Claude Launcher.app"
out_dir="build/installer"
dmg="$out_dir/ClaudeLauncher-$version.dmg"

[ -d "$app" ] || { echo "Нет $app — сначала flutter build macos --release" >&2; exit 1; }

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

# ditto сохраняет права, ссылки и расширенные атрибуты внутри бандла.
ditto "$app" "$staging/Claude Launcher.app"

# Flutter подписывает бандл ad-hoc, а при повторной сборке меняет вложенный
# App.framework — подпись становится невалидной, и на другом Mac скачанное
# приложение считается «повреждённым». Переподписываем целиком и проверяем.
codesign --force --deep --sign - "$staging/Claude Launcher.app"
codesign --verify --deep --strict "$staging/Claude Launcher.app"
ln -s /Applications "$staging/Программы"

mkdir -p "$out_dir"
rm -f "$dmg"
hdiutil create \
  -volname "Claude Launcher" \
  -srcfolder "$staging" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$dmg" >/dev/null

echo "$dmg"
