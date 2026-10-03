# Как это решили другие

Механики конкурентов, которые нам нужны, — со ссылками на их код. Лицензии нас не
ограничивают (личный проект), но код переписываем под себя, а не копируем вслепую.
Клонировать для чтения — во временную папку: `git clone --depth 1 <адрес>`.

| Проект | Язык | Чем полезен |
|---|---|---|
| [multi-claude-switcher](https://github.com/miou1107/multi-claude-switcher) | Go | Синхронизация сессий, снимки, перезапись account/org |
| [claude-switcher](https://github.com/beyondworks/claude-switcher) | Python | Бережное закрытие на Windows, синхронизация с удалениями, объединение настроек |
| [claude-code-sessions (ccs)](https://pypi.org/project/claude-code-sessions/) | Python | Самый аккуратный перенос: маркеры удаления, очистка карточки, журнал и undo |
| [claude-desktop-profiles](https://github.com/longnc100500/claude-desktop-profiles) | TS | Пример наивного переноса (как не надо) |
| [claudius](https://github.com/democra-ai/claudius) | Rust | Матрица общего доступа, безопасные ключи, локальная статистика, индикатор LIVE |
| [claude-profile-manager](https://github.com/daforester/claude-profile-manager) | Go | Маршрутизация `claude://`, `CLAUDE_CONFIG_DIR`, параллельный запуск |
| [ai-multi-instance](https://github.com/Zoltak-Dev/ai-multi-instance) | Python | Windows: запуск из WindowsApps, вход через «снимок» папки |
| [claude-desktop-clone](https://github.com/vodongha/claude-desktop-clone) | PowerShell | Windows: Cowork и `%APPDATA%` |

## Бережное закрытие на Windows

claude-switcher, `src/claude_switch.py` (`win_wait_ready`, `win_quit`, `quit_app`):

- Закрытие окна и `taskkill` без `/F` только прячут Claude в трей.
- Выходит он штатно на ту же пару сообщений, что шлёт Windows при выходе из сеанса:
  `WM_QUERYENDSESSION` (0x11), затем `WM_ENDSESSION` (0x16, wParam=1), каждому окну
  верхнего уровня процесса, через `SendMessageTimeoutW(…, SMTO_ABORTIFHUNG, 3000)`.
  В журнале Claude: `Windows session ending (shutdown) - quitting the app`.
- Если послать во время загрузки, Claude завершается без своей уборки. Поэтому сначала
  ждут строку `boot: done` в `main.log` этого запуска (время строки ≥ времени старта
  процесса), не дольше 30 с.
- Ждут выхода до `QUIT_TIMEOUT` секунд. На macOS — SIGTERM (у нас —
  `NSRunningApplication.terminate`, это то же Cmd+Q).

## Перенос сессий

**ccs** (`claude_code_sessions.py`, ~12 тыс. строк, Windows-only запись):
- Копирует карточку, только если: это `local_*.json`; имени нет в цели; переписка
  существует; в цели нет `deleted_<cliSessionId>` и `deleted_<local id>`.
- `transform_row`: удаляет тяжёлые и привязанные поля (см. research, «Правила переноса»);
  `--verbatim` — без преобразования.
- По умолчанию dry-run, запись — `--apply`. Журнал `~/.claude-code-journal/ops/<id>/manifest.json`
  с исходным и новым содержимым, статусы `journaled → writing → completed`, `recover`,
  `undo` (отказ, если цель изменилась). Отказ работать, если запущен Desktop.

**multi-claude-switcher** (`core/sync.go`, `core/align.go`, `core/backup.go`, `core/tidy.go`):
- Перезапись account и org в пути (`orgRemapper`); `tidy.go` — уборка последствий бага,
  когда org не переписывался.
- Дубликаты — по пути; одинаковое содержимое пропускается; разное — побеждает mtime.
  Маркеры `deleted_*` не проверяет — удалённые сессии возвращаются (не повторять).
- Копирование: временный файл → rename, сохранение mtime, права `0600`, `Lstat` против
  записи через ссылку. Снимки `backups/<профиль>_<время>` с `deleted_*`, 5 последних,
  счётчик против совпадения времени; `RestoreBackup` сам делает снимок.
- Перед синхронизацией закрывает Claude и потом открывает те профили, что были открыты.

**claude-switcher** (`src/cs_sync.py`):
- Синхронизирует целые папки `<acct>/<org>` разных профилей; файлы по имени, новее —
  побеждает.
- Удаления распространяются через `sync-state.json` (пересечение после прошлого прогона):
  было у всех, пропало у одного — удаляется у всех (в `trash/<дата>/`).
- Остановка, если удаляется больше 20 % и больше 5 файлов.
- Работает раз в 20 с при открытом приложении — безопасно только потому, что открыт
  один аккаунт. Нам — только при закрытом целевом профиле.

**claudius** — делает символическую ссылку папки сессий цели на папку источника;
отмена — глубокая копия. Не подходит нам (см. research, п. 7).

## Объединение настроек

claude-switcher (`cs_share.py`, только при закрытом Claude): трёхстороннее объединение с
базой `share-base/` для `claude_desktop_config.json`, `git-worktrees.json`,
`mcp-user-tool-toggles.json`, `developer_settings.json`. `config.json` и cookies не трогает.

claudius (`src-tauri/src/lib.rs`): MCP — по одному серверу в `mcpServers[name]`, запись
атомарная; расширения и навыки Cowork — ссылками; настройки — по списку разрешённых
ключей (`SAFE_UI_KEYS`, `SAFE_DESKTOP_PREF_KEYS`, около строки 2708). Никогда не трогает
`Local Storage`, `IndexedDB`, `Cookies*`, `Preferences`, `Local State`.

## Отдельная папка Claude Code

claude-profile-manager, `internal/launcher/env.go` (`ProcessEnv`): ставит
`CLAUDE_CONFIG_DIR=<профиль>/claude-code` и для CLI, и для Desktop (`OpenDesktop`,
`DeliverURL`); убирает `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
`CLAUDE_CODE_OAUTH_TOKEN`. claude-desktop-clone — опционально ставит `CLAUDE_CONFIG_DIR`
перед `Start-Process`, потому что `--user-data-dir` не изолирует `~/.claude`.
Запуск на macOS — напрямую бинарником `Claude.app/Contents/MacOS/Claude` (`os_darwin.go`),
поэтому окружение доходит.

## Параллельный запуск

- macOS: claudius и claude-desktop-multi — `open -n -a Claude.app --args --user-data-dir=…`;
  claude-profile-manager — прямой запуск бинарника. Single-instance lock Electron — на папку
  данных, поэтому экземпляры с разными папками не мешают друг другу.
- Windows MSIX: ai-multi-instance и claude-desktop-clone запускают `claude.exe` прямо из
  `WindowsApps`; claude-profile-manager и claude-desktop-multi считают, что нельзя, и делают
  копию приложения. У нас — прямой запуск, при отказе — через пакет; копия не нужна.
- claudius, индикатор LIVE: `ps -Aww -o args=`, процессы `Claude.app/Contents/MacOS/Claude`
  без Helper/Renderer/GPU, `--user-data-dir=` из аргументов. У нас это уже есть.

## Маршрутизация `claude://`

claude-profile-manager — единственный, кто это сделал:
- Windows (`internal/launcher/protocol_windows.go`): `HKCU\Software\Classes\claude`
  (`URL Protocol`, `DefaultIcon`, `shell\open\command = "<exe>" handle-url "%1"`), плюс
  ProgID, `Capabilities\URLAssociations` и `RegisteredApplications`, чтобы попасть в
  «Приложения по умолчанию». Если `UrlAssociations\claude\UserChoice` чужой — подсказка и
  кнопка `ms-settings:defaultapps`. Действующую команду проверяет `AssocQueryStringW`.
  Первая настройка — тестовая ссылка, Windows спрашивает «Как открыть?».
- macOS (`protocol_darwin.go`, `scripts/macos-url-scheme.sh`, `internal/urlevent/urlevent_darwin.m`):
  `CFBundleURLTypes` в Info.plist, `LSRegisterURL` + `LSSetDefaultHandlerForURLScheme`;
  ссылка приходит Apple Event `kAEGetURL`.
- Claude перерегистрирует себя при каждом старте: CPM проверяет раз в 3 с, после запуска
  профиля — через 2/5/10/20 с, на Windows ждёт изменения ключа (`RegNotifyChangeKeyValue`).
  Прежний обработчик — в `protocol-backup.txt`, возвращается при выключении.
- Выбор профиля (`internal/launcher/deeplink.go`): метка последнего запуска
  `{profileId, at}`, действительна 10 минут и одноразовая; иначе окно выбора.
- Доставка: `exec(exe, "--user-data-dir=<профиль>", url)` — второй запуск с той же папкой
  передаёт ссылку работающему экземпляру. На macOS — **не проверено**, что Claude берёт
  ссылку из аргументов (обычно приходит `open-url`).
- Запасной путь — вставка ссылки из буфера (`links.go`, `pasteSignInLink`). Журнал —
  без параметров ссылки.

ai-multi-instance маршрутизацию не делает (считает, что на современной Windows нельзя:
UCPD и активация протокола MSIX) и входит через «снимок»: прячет стандартную папку,
пользователь входит в чистый Claude, папка переносится в профиль. Для нас — запасной план,
если маршрутизация на Windows не заработает.

## Лимиты (для справки, не делаем так)

claude-profile-manager читает OAuth-токен Claude Code и спрашивает
`https://api.anthropic.com/api/oauth/usage`, а истёкший токен сам обновляет и
**записывает обратно** — мы так не делаем. ai-multi-instance расшифровывает cookie
`sessionKey` — тоже не делаем. У нас лимиты — из локальных файлов Claude
(`profile_usage.dart`); claudius тоже не показывает квоты, объясняя почему.
