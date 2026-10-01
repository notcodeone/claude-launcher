#!/usr/bin/env bash
# Установка и обновление ClaudeLauncher на macOS одной командой:
#
#   curl -fsSL https://raw.githubusercontent.com/notcodeone/claude-launcher/main/tool/install.sh | bash
#
# curl не ставит на файл пометку «скачано из интернета», поэтому Gatekeeper
# не спрашивает, открывать ли неподписанное приложение. Скрипт берёт DMG
# последнего выпуска, кладёт приложение в «Программы» и запускает его.
set -euo pipefail

repo="notcodeone/claude-launcher"
app="/Applications/ClaudeLauncher.app"

url="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" |
  grep -o '"browser_download_url": *"[^"]*\.dmg"' |
  sed -E 's/.*"(https:[^"]+)"$/\1/' | head -1)"
[ -n "$url" ] || { echo "В последнем выпуске нет DMG" >&2; exit 1; }

work="$(mktemp -d)"
trap 'hdiutil detach "$work/mnt" -quiet 2>/dev/null || true; rm -rf "$work"' EXIT

echo "Скачиваю $(basename "$url")…"
curl -fL --progress-bar "$url" -o "$work/ClaudeLauncher.dmg"
hdiutil attach "$work/ClaudeLauncher.dmg" -nobrowse -readonly -noautoopen \
  -mountpoint "$work/mnt" -quiet

# Запущенный лаунчер просим выйти, как из его меню.
if pgrep -xq ClaudeLauncher; then
  echo "Закрываю запущенный ClaudeLauncher…"
  osascript -e 'quit app "ClaudeLauncher"' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -xq ClaudeLauncher || break; sleep 0.5; done
fi

rm -rf "$app"
ditto "$work/mnt/ClaudeLauncher.app" "$app"
# На случай, если пометка всё же есть (например, DMG скачан браузером).
xattr -cr "$app" 2>/dev/null || true

open "$app"
echo "Готово: $(defaults read "$app/Contents/Info" CFBundleShortVersionString) в «Программах»."
