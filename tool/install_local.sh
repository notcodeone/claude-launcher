#!/usr/bin/env bash
# Ставит собранный локально лаунчер (build/macos/…/Release) вместо установленного —
# для проверок до выпуска. Только macOS.
#
#   flutter build macos --release && tool/install_local.sh
#
# Старое приложение заменяется, только когда лаунчер вышел полностью: при включённом
# Kill Switch он при выходе передаёт затвор фоновому процессу, и, если подменить
# приложение посреди этого, затвор не запустится — Claude останется без сети, а у
# недовышедшего лаунчера пропадут иконки (его файлы уже удалены).
set -euo pipefail

fresh="build/macos/Build/Products/Release/ClaudeLauncher.app"
app="/Applications/ClaudeLauncher.app"
[ -d "$fresh" ] || { echo "Сначала: flutter build macos --release" >&2; exit 1; }

# Главный процесс лаунчера — без флагов (фоновые: --kill-switch-guard,
# --return-claude-notifications и наблюдатель /bin/sh).
main_running() { pgrep -f "$app/Contents/MacOS/ClaudeLauncher\$" >/dev/null; }

if main_running; then
  echo "Прошу ClaudeLauncher выйти…"
  osascript -e 'quit app "ClaudeLauncher"' >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do main_running || break; sleep 0.5; done
  if main_running; then
    echo "ClaudeLauncher не вышел за 30 секунд — приложение не заменено." >&2
    exit 1
  fi
fi

# Фоновый затвор Kill Switch (если запущен) продолжает работать из памяти:
# новый лаунчер при запуске заберёт у него работу.
rm -rf "$app"
ditto "$fresh" "$app"
xattr -cr "$app" 2>/dev/null || true
open "$app"

for _ in $(seq 1 60); do main_running && break; sleep 0.5; done
if main_running; then
  echo "Готово: $(defaults read "$app/Contents/Info" CFBundleShortVersionString) запущен."
else
  echo "Лаунчер не запустился за 30 секунд — откройте его из «Программ»." >&2
  exit 1
fi
