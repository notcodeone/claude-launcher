# Установка и обновление ClaudeLauncher на Windows одной командой (PowerShell):
#
#   irm https://raw.githubusercontent.com/notcodeone/claude-launcher/main/tool/install.ps1 | iex
#
# Скачанный так установщик не получает пометку «из интернета», поэтому
# SmartScreen не предупреждает о неизвестном издателе. Ставит последнюю версию
# для текущего пользователя, без прав администратора, и запускает её.
#
# Всё — внутри блока: через iex переменные и настройки иначе остались бы
# в сессии PowerShell пользователя.
& {
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

  # Закрываем только свой лаунчер — не запущенный другими пользователями.
  # Сначала — как из его меню (--quit): он вернёт Claude уведомления и, если
  # включён Kill Switch, передаст затвор своему фоновому процессу.
  $session = (Get-Process -Id $PID).SessionId
  $running = @(Get-CimInstance Win32_Process -Filter "Name = 'claude_launcher.exe'" |
    Where-Object { $_.SessionId -eq $session })
  $main = @($running | Where-Object {
    $_.CommandLine -notmatch '--kill-switch-guard|--return-claude-notifications|--cleanup'
  })
  if ($main.Count -gt 0) {
    Start-Process $main[0].ExecutablePath -ArgumentList '--quit' -WindowStyle Hidden
    # Ждём сами процессы, а не код выхода: лаунчер до 1.5.9 --quit не знает.
    # Не вышел за 10 секунд — закрываем принудительно. Фоновые процессы
    # лаунчера не трогаем: их закроет установщик, а новый лаунчер заберёт работу.
    $main | ForEach-Object {
      Wait-Process -Id $_.ProcessId -Timeout 10 -ErrorAction SilentlyContinue
      Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
    }
  }

  # /update=1 — установщик дождётся выхода лаунчера и запустит новый. Ждём только
  # сам установщик: Start-Process -Wait ждал бы и запущенный им лаунчер.
  $process = Start-Process $setup -PassThru -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/update=1'
  $process.WaitForExit()
  Remove-Item $setup -ErrorAction SilentlyContinue
  if ($process.ExitCode -ne 0) { throw "Установщик завершился с кодом $($process.ExitCode)" }
  Write-Host "Готово: ClaudeLauncher $($release.tag_name) установлен."
}
