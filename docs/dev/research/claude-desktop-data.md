# Данные Claude Desktop

Что и где хранит приложение Claude. Формат недокументирован и меняется между версиями —
всё, на что опирается запись, проверяй на текущей версии.

Пометки: **проверено** — видели сами (с датой); **по коду конкурентов** — так читают и
пишут их инструменты (см. competitors.md); **гипотеза** — не подтверждено.

## Папка данных профиля

Стандартная: macOS `~/Library/Application Support/Claude`; Windows — папка пакета MSIX
(`%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude`), изнутри пакета
видна как `%APPDATA%\Claude`. Профили лаунчера — `Claude-<имя>` рядом (Windows:
`%APPDATA%\Claude-<имя>`). Подробности поиска — `lib/src/claude/*_claude_host.dart`.

Содержимое (проверено на macOS, 2026-10-03; имена, без содержимого):

| Путь | Что |
|---|---|
| `claude-code-sessions/<account>/<org>/local_<uuid>.json` | Карточки сессий вкладки Code (ниже) |
| `claude-code-sessions/<account>/<org>/deleted_<id>` | Маркеры удалённых сессий (по коду конкурентов) |
| `claude-code-sessions/<account>/<org>/scheduled-tasks.json` | Запланированные задачи (по коду конкурентов) |
| `local-agent-mode-sessions/<a>/<b>/local_*.json` | Сессии Cowork; в них есть `accountName`, `emailAddress`, `processName` (по коду claudius) |
| `local-agent-mode-sessions/skills-plugin/…` | Навыки Cowork |
| `claude-code/<версия>/` | Встроенные версии Claude Code, которые запускает вкладка Code (проверено на macOS, 2026-10-03) |
| `config.json` | Настройки приложения; `lastKnownAccountUuid`, ключи `dxt:allowlistLastUpdated:<org>`; верхние `darkMode`, `scale`, … Claude переписывает из памяти — писать только при закрытом |
| `claude_desktop_config.json` | `mcpServers`, `preferences` (`menuBarEnabled` и др.). Переписывается при выходе — писать только при закрытом |
| `plan-usage-history.json` | История процентов лимитов (читает `profile_usage.dart`) |
| `buddy-tokens.json` | `tokens-today.tokens`, `tokens-today.date` — токены за день (по коду claudius) |
| `extensions-blocklist.json` | В `url` первого элемента — `…/organizations/<org>/…` (по коду claudius) |
| `cowork-enabled-cli-ops.json` | `ownerAccountId` (по коду claudius) |
| `ant-did`, `ccd-ids.json`, `ant-device-registry.json` | Идентификаторы устройства |
| `Claude Extensions/<id>`, `Claude Extensions Settings/<id>.json` | Расширения (по коду claudius) |
| `IndexedDB`, `Local Storage`, `Cookies`, `Local State`, `Preferences` | Вход и состояние Chromium — **не трогаем никогда** |
| `<папка>-3p/` (macOS), `%LOCALAPPDATA%\Claude-3p` (Windows) | Локальная библиотека настроек: `egressProxyUrl`, `disableAutoUpdates` (Kill Switch) |

Журнал приложения: macOS — `~/Library/Logs/Claude/main.log` (проверено 2026-10-03; отдельной
папки журналов у профиля `Claude-<имя>` не найдено — **гипотеза**: журнал общий для всех профилей);
Windows — по claude-switcher `%LOCALAPPDATA%\<имя папки профиля>\logs\main.log`
(**проверить**, особенно для пакета MSIX). Полезные строки: `boot: done` (загрузка
закончена), `Loaded N persisted sessions from …/claude-code-sessions/<a>/<o>`,
`Windows session ending (shutdown) - quitting the app`.

## Карточка сессии Code

`local_<uuid>.json` (поля проверены на macOS, 2026-10-03):

`sessionId` (`local_<uuid>`, совпадает с именем файла), `cliSessionId` (имя файла
переписки), `cwd`, `originCwd`, `title`, `titleSource`, `createdAt`, `lastActivityAt`,
`lastFocusedAt` (мс), `isArchived`, `model`, `effort`, `permissionMode`,
`completedTurns`, `remoteMcpServersConfig` (бывает больше 1 МБ), `writtenBranches`,
`chromePermissionMode`, `alwaysAllowedReasons`, `sessionPermissionUpdates`, `spawnSeed`,
`promptAppendSnapshot`, `classifierSummaryEnabled`, `reportFindingsCard`,
`remoteControlAutoEligible`, `lastSpawnRootDetected`. Встречаются ещё (по коду ccs):
`enabledMcpTools`, `bridgeSessionIds`, `scheduledTaskId`, `chromeTabGroupId`,
`transcriptUnavailable`.

- Claude показывает карточки только из папки **текущего аккаунта и активной организации**.
- `cliSessionId` меняется при каждом возобновлении сессии; имя файла карточки — постоянное.
- `completedTurns` не монотонен — не сравнивать по нему «кто новее»; сравнивать по
  `lastActivityAt`.
- `transcriptUnavailable` и отсутствие переписки — нормальное состояние: Claude Code удаляет
  старые переписки (по умолчанию через 30 дней).
- Маркер `deleted_<id>` **не прячет** карточку, лежащую рядом: восстановленная рядом с
  маркером карточка снова видна (проверено ccs). Поэтому при переносе маркер нужно
  проверять самим, по обоим id: `deleted_<cliSessionId>` и `deleted_<local_uuid>`.

## Переписка Code

`<папка Claude Code>/projects/<закодированный cwd>/<cliSessionId>.jsonl`, рядом может быть
папка `<cliSessionId>/` (подагенты). Папка Claude Code — `~/.claude` или
`$CLAUDE_CONFIG_DIR`. Кодирование пути: `re.sub(r"[^A-Za-z0-9]", "-", cwd)`; до ~июля 2026
было `[^A-Za-z0-9_]` — искать по обеим схемам (так делает ccs). Память проекта —
`projects/<закодированный cwd>/memory/`.

## Аккаунт и организация профиля

Источники (у конкурентов разные, ни один не идеален):

| Что | Источник | Надёжность |
|---|---|---|
| account | `config.json` → `lastKnownAccountUuid` | бывает устаревшим после смены аккаунта (ccs) |
| account | `cowork-enabled-cli-ops.json` → `ownerAccountId` | есть, если включали Cowork |
| org | `main.log`: папка с максимальным N в `Loaded N persisted sessions from …` | лучший; при выходе из аккаунта Claude ненадолго читает пустую папку (claude-switcher) |
| org | `extensions-blocklist.json` → UUID из `…/organizations/<org>/…` | claudius |
| org | самый свежий ключ `dxt:allowlistLastUpdated:<org>` в `config.json` | эвристика (multi-claude-switcher) |
| почта | `local-agent-mode-sessions/…/local_*.json` → `emailAddress` | есть, если были сессии Cowork |
| запасной | папка `claude-code-sessions/<a>/<o>` с самыми свежими карточками | только если папка одна или выбор очевиден |

Правило для лаунчера: сверять несколько источников; если не сходятся — «не определено».

Проверено 2026-10-03 на трёх профилях автора (Claude 2.19675.0, macOS):
`lastKnownAccountUuid` и `ownerAccountId` совпадают; организация из
`extensions-blocklist.json` совпадает с ключом `dxt:allowlistLastUpdated:<org>` и с папкой
карточек. В основном профиле лежит и папка карточек **прежнего** аккаунта — выбирать
папку «по наличию» нельзя. Почты в файлах Desktop нет (в карточках Cowork — только если
им пользовались); надёжный источник — `oauthAccount` в `.claude.json` Claude Code
(`accountUuid`, `emailAddress`, `organizationUuid`, `organizationName`, без токенов): у
профиля со своей памятью — `<папка профиля>/claude-config/.claude.json`, у остальных —
общий `~/.claude.json`, и тогда он верен, только если `accountUuid` совпал.

`buddy-tokens.json`: `{"tokens-today": {"date": "ГГГГ-ММ-ДД", "tokens": <int>}}` (проверено).

## Правила переноса сессии

Собрано из ошибок конкурентов (подробности — competitors.md):

1. В пути заменить **и аккаунт, и организацию** на целевые. Без организации сессия
   ложится в папку, которую Claude не читает (баг multi-claude-switcher, две недели).
2. Не переносить, если в цели есть `deleted_<cliSessionId>` или `deleted_<local_uuid>`.
3. Дубликат — то же имя файла или тот же `cliSessionId`.
4. Запись — во временный файл и переименование, с сохранением времени изменения.
   Прерванная прямая запись оставляет обрезанный файл со свежим временем, который потом
   «побеждает» как более новый.
5. Убрать `remoteMcpServersConfig`, `enabledMcpTools`, `bridgeSessionIds`,
   `scheduledTaskId`; сбросить `alwaysAllowedReasons`, `sessionPermissionUpdates`,
   `chromePermissionMode`, `chromeTabGroupId` (ccs: карточка со 132 КБ стала 715 Б и
   работает).
6. Переписка — копией в папку Claude Code цели (после 1.6.0 у профилей разные папки).
7. Целевой профиль закрыт. Символические ссылки вместо копий — нет: по claude-switcher
   Claude не пишет в папку сессий, если она ссылка (не подтверждено, но и claudius,
   который делает ссылки, обратного не доказывает).
8. Снимок папки `<account>/<org>` цели — вместе с `deleted_*` — до записи.

## Безопасные ключи настроек (из claudius)

Можно переносить между профилями — не привязаны к аккаунту:

- `config.json`: `darkMode`, `scale`, `multiTitleBar`.
- `claude_desktop_config.json` → `preferences`: `menuBarEnabled`, `quickEntryShortcut`,
  `chicagoEnabled`, `sidebarMode`, `remoteToolsDeviceName`, `coworkScheduledTasksEnabled`,
  `ccdScheduledTasksEnabled`, `coworkWebSearchEnabled`, `launchPreviewPersistSession`.

Всё остальное — не переносить (пример привязанного к аккаунту: `bypassPermissionsOptInByAccount`).

## Claude Code внутри Desktop

Проверено по коду Claude 2.19675.0 (macOS, `app.asar` → `.vite/build/*.js`, 2026-10-03).
Распаковать для чтения: заголовок asar — JSON после 16 байт (`<IIII>`: …, размер
заголовка, …, длина JSON), файлы — по `offset` от `8 + размер заголовка`.

- **Папка Claude Code для вкладки Code** определяется так (`resolveEffectiveClaudeConfigDir`):
  1. переменная `CLAUDE_CONFIG_DIR` из **настроек переменных окружения самого Claude**,
     если пользователь её там задал;
  2. иначе — `process.env.CLAUDE_CONFIG_DIR` процесса Claude;
  3. иначе — `~/.claude`.

  Найденную папку Claude явно передаёт запускаемому Claude Code (`CLAUDE_CONFIG_DIR: …` в
  окружении процесса). Значит, лаунчеру достаточно запустить Claude профиля с этой
  переменной. Путь — абсолютный и нормализованный: «тильду», относительные пути и
  пробелы по краям Claude считает «расходящимися» и для части функций отвергает; путь на
  сетевом диске (UNC) — тоже.
- **Настройки переменных окружения Claude** хранятся зашифрованными через
  `safeStorage` (ключ — в Связке ключей / DPAPI). Лаунчер их не читает и не пишет. Если
  пользователь сам задал там `CLAUDE_CONFIG_DIR`, она главнее переменной лаунчера —
  показать это в диагностике (C-5) нельзя без расшифровки, поэтому только описать в README.
- **Вход для вкладки Code** Claude передаёт сам: `CLAUDE_CODE_OAUTH_TOKEN` и тип подписки
  в окружении запускаемого Claude Code. От папки Claude Code вход не зависит — новая папка
  не потребует входа.
- **Глобальная настройка Claude Code** — `.claude<суффикс>.json` в `CLAUDE_CONFIG_DIR`
  (без переменной — в домашней папке), если нет `.config.json` в папке.
- **Cowork** запускает свой Claude Code со своей папкой (`env: {CLAUDE_CONFIG_DIR: …,
  localAgent: true}`) — переменная лаунчера его не касается.
- **Символические ссылки внутри папки Claude Code.** Перед записью в эту папку Claude
  проверяет путь: если любая **промежуточная** часть пути под папкой — символическая
  ссылка, запись отклоняется («symlink at a non-leaf component below the co-writable
  boundary»). Разрешено: ссылка на всю папку целиком (`~/.claude` → …) и ссылка-файл
  (последняя часть пути). Значит, папку `skills/` ссылкой делать нельзя — Claude не
  сможет писать в навыки профиля; ссылки на отдельные файлы (`agents/x.md`) — можно;
  ссылка на папку отдельного навыка — запись внутрь неё будет отклонена.
- **Передать переменную на macOS:** `open -n --env CLAUDE_CONFIG_DIR=… -a Claude.app
  --args --user-data-dir=…` — работает на macOS 26.6 (проверено 2026-10-03: переменная видна
  в окружении процесса, `ps eww`). Есть ли `--env` на старых macOS (поддерживаем с 10.15) —
  **не проверено**; запасной путь — прямой запуск `Claude.app/Contents/MacOS/Claude`.

## Windows: Cowork

- Служба машины Cowork ищет образ в `%APPDATA%\<имя папки профиля>\vm_bundles` и игнорирует
  `--user-data-dir`, поэтому профили — в `%APPDATA%` (claude-desktop-clone; у нас так и есть).
  Ссылки (junction/symlink) на `vm_bundles` служба не открывает.
- Две машины Cowork одновременно — по claude-desktop-clone ошибка `HYPERVISOR_SERVICE_ERROR`
  (**проверить**, P-E3).
- Длинные пути в `vm_bundles` упираются в 260 символов (issue в claude-desktop-profiles).
