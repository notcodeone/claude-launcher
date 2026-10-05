#!/usr/bin/env bash
# Подписывает ClaudeLauncher.app сертификатом «NotCode Code Signing», если он есть
# в связках (CI — из секретов, у автора — в связке login), иначе — ad-hoc.
#
#   tool/sign_macos.sh <путь к ClaudeLauncher.app>
#
# Зачем свой сертификат: macOS привязывает разрешения приложения («Всегда
# разрешать» для «Claude Safe Storage», «Автоматизация») к требованию подписи.
# У ad-hoc это отпечаток файла — он меняется с каждой сборкой, и после
# обновления macOS спрашивает снова. С сертификатом требование постоянное:
# `identifier "com.notcodeone.claudeLauncher" and certificate root = H"42ce…"`.
# Сертификат самоподписанный: пользователям ставить его не нужно, предупреждения
# Gatekeeper он не убирает. Публичная часть — tool/signing/notcode-code-signing.pem.
set -euo pipefail

app="$1"
identity="NotCode Code Signing"

if security find-identity -v -p codesigning | grep -qF "\"$identity\""; then
  sign="$identity"
else
  echo "Сертификата «$identity» нет — подписываю ad-hoc (разрешения macOS сбросятся после обновления)." >&2
  sign="-"
fi

# --preserve-metadata=entitlements: права приложения (Apple Events) — из сборки
# Flutter, требование подписи — новое, по сертификату.
codesign --force --deep --preserve-metadata=entitlements --sign "$sign" "$app"
codesign --verify --deep --strict "$app"
codesign -dr - "$app" 2>&1 | grep designated >&2
