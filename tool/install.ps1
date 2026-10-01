# Установка и обновление ClaudeLauncher на Windows одной командой (PowerShell):
#
#   irm https://raw.githubusercontent.com/notcodeone/claude-launcher/main/tool/install.ps1 | iex
#
# Скачанный так установщик не получает пометку «из интернета», поэтому
# SmartScreen не предупреждает о неизвестном издателе. Ставит последнюю версию
# для текущего пользователя, без прав администратора, и запускает её.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo = 'notcodeone/claude-launcher'
$release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest"
$asset = $release.assets | Where-Object { $_.name -like 'ClaudeLauncher-Setup-*.exe' } |
  Select-Object -First 1
if (-not $asset) { throw 'В последнем выпуске нет установщика' }

$setup = Join-Path $env:TEMP $asset.name
Write-Host "Скачиваю $($asset.name)…"
Invoke-WebRequest $asset.browser_download_url -OutFile $setup
# На случай, если пометка всё же есть.
Unblock-File $setup

# /update=1 — установщик дождётся выхода запущенного лаунчера и запустит новый.
Get-Process claude_launcher -ErrorAction SilentlyContinue | Stop-Process
Start-Process $setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/update=1' -Wait
Remove-Item $setup -ErrorAction SilentlyContinue
Write-Host "Готово: ClaudeLauncher $($release.tag_name) установлен."
