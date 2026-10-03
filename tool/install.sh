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

# Сверяем с суммой из выпуска (SHA256SUMS.txt — с версии 1.5.10).
if curl -fsSL "$(dirname "$url")/SHA256SUMS.txt" -o "$work/sums" 2>/dev/null; then
  expected="$(awk -v f="$(basename "$url")" '$2 == f || $2 == "*" f { print $1 }' "$work/sums")"
  actual="$(shasum -a 256 "$work/ClaudeLauncher.dmg" | awk '{ print $1 }')"
  if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
    echo "Контрольная сумма не совпала — файл повреждён при скачивании. Попробуйте ещё раз." >&2
    exit 1
  fi
fi

hdiutil attach "$work/ClaudeLauncher.dmg" -nobrowse -readonly -noautoopen \
  -mountpoint "$work/mnt" -quiet

# Главный процесс лаунчера — ровно путь, без аргументов: у фоновых есть флаги
# (--kill-switch-guard), а у наблюдателя /bin/sh путь к лаунчеру — в конце
# командной строки.
# Без -q: grep -q выходит на первом совпадении и обрывает ps, а с pipefail
# такой конвейер считается неудачным — лаунчер «не найден».
main_running() {
  ps -axo args= | grep -xF "$app/Contents/MacOS/ClaudeLauncher" >/dev/null
}

# Запущенный лаунчер просим выйти, как из его меню.
if main_running; then
  echo "Закрываю запущенный ClaudeLauncher…"
  osascript -e 'quit app "ClaudeLauncher"' >/dev/null 2>&1 || true
  # С Kill Switch выход дольше: лаунчер передаёт затвор фоновому процессу.
  # Подменять приложение раньше нельзя — Claude останется без сети.
  for _ in $(seq 1 60); do
    main_running || break
    sleep 0.5
  done
  if main_running; then
    echo "ClaudeLauncher не вышел за 30 секунд. Выйдите из него через меню и повторите." >&2
    exit 1
  fi
fi

rm -rf "$app"
ditto "$work/mnt/ClaudeLauncher.app" "$app"
# На случай, если пометка всё же есть (например, DMG скачан браузером).
xattr -cr "$app" 2>/dev/null || true

# -n: новый экземпляр. Без него macOS, увидев запущенный фоновый процесс
# лаунчера (затвор Kill Switch), покажет его, а не запустит новую версию.
# Без прокси из окружения: в терминале Claude Code это затвор Kill Switch, и
# лаунчер унаследовал бы его.
env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy -u ALL_PROXY \
  -u all_proxy open -n "$app"
echo "Готово: $(defaults read "$app/Contents/Info" CFBundleShortVersionString) в «Программах»."
