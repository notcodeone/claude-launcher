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

## Окружение процессов Claude

Проверено 2026-10-03 (macOS, Kill Switch включён): Claude задаёт своим процессам —
вкладке Code, её терминалу — `HTTPS_PROXY`/`HTTP_PROXY` = `egressProxyUrl` (затвор
лаунчера) и `NO_PROXY=localhost,127.0.0.1,::1,.local`. Всё, что агент запускает из
своего терминала, наследует это окружение, — в том числе лаунчер. Поэтому запросы
лаунчера не берут прокси из окружения, если он на этом же компьютере
(`lib/src/http_proxy.dart`), а проверка страны — всегда напрямую.

## Cowork: облачный и локальный (проверено 2026-10-03, Claude 2.19675.0, macOS)

- Отдельной вкладки Cowork нет: значок «облачка» рядом с `</>` открывает экран с полем
  запроса — это и есть Cowork (в журнале `sidebar_mode: 'cowork'`, `landing: 'cowork'`;
  значения `sidebarMode` в коде: `chat`, `code`, `task`, `epitaxy`).
- Задача «создай hello.txt» без выбранной папки выполнилась **в облаке**: локальной
  карточки `local-agent-mode-sessions/…/local_*.json` не появилось, образ машины не
  скачивался (`cowork_vm_node.log`: `rootfs.img missing`), а файл Claude **скачал** в
  `~/Downloads` (`[download] applied web-origin mark`, у файла `com.apple.quarantine` с
  отметкой Claude). Такие сессии живут на сервере, как чаты: видны во всех профилях
  этого аккаунта, переносить нечего; между аккаунтами — невозможно.
- Облачный Cowork работает с компьютером через мост `remote-tools-device`
  (`wss://bridge.claudeusercontent.com`): один `device_id` на компьютер, второй профиль
  получает `bridge error: device_id held by a live connection` и переподключается
  позже — **гипотеза:** доступ облачного Cowork к компьютеру — у одного профиля за раз.
- Журналы Claude общие для всех профилей (`~/Library/Logs/Claude`), даже с
  `--user-data-dir` — различать профили по журналу можно только по аккаунту и времени.
- **С папкой (проверено 2026-10-03):** сессия всё равно облачная (id `session_…`/`cse_…`,
  хранится на сервере), а с компьютером работает через мост «устройства» (в Claude —
  `notmac · Connected`). Локально остаётся только
  `local-agent-mode-sessions/<account>/<org>/remote-session-spaces.json`:
  `entries[] = {sessionId, folders[]}` — какие папки выданы сессии. Карточек
  `local_*.json` нет.
- **Задачу из «Теста» выполнил Claude основного профиля.** Слот моста один на
  устройство и аккаунт: его держал основной Claude (тот же аккаунт), «Тест» получал
  `device_id held by a live connection`. Выданная папка записалась в
  `remote-session-spaces.json` обоих профилей, а машину Cowork («Shell isn't ready yet»)
  начал скачивать основной профиль — в `Claude/vm_bundles/claudevm.bundle`
  (`rootfs.img` ≈ 9,5 ГБ) и `Claude/claude-code-vm/<версия>/`, и продолжил после закрытия
  «Теста». Вывод: при одном аккаунте в нескольких профилях локальные действия Cowork
  выполняет тот экземпляр, что первым занял слот, — изоляции профилей тут нет.
- Каждой машине Cowork нужен свой образ ≈ 9,5 ГБ в папке профиля — на диске это
  заметно при нескольких профилях.

## Ссылки `claude://` (P-E4, проверено по коду 2026-10-03, Claude 2.19675.0, macOS)

- Обработчик `claude://` в системе сейчас один — `/Applications/Claude.app`; `claude-cli://`
  не зарегистрирован никем.
- Claude **при каждом запуске** вызывает `app.setAsDefaultProtocolClient` для своих схем —
  роль обработчика он забирает себе каждый раз (поэтому P-6: лаунчер должен забирать её
  обратно после запуска профиля).
- Есть управляемая настройка `disableDeepLinkRegistration` («Disable claude:// deep-link
  handling»): Claude тогда снимает себя с роли обработчика и игнорирует входящие ссылки,
  **кроме входа** (`claude://login/…`, `claude://claude.ai/<magic-link|sso-callback>`).
  Но поддерживается только в режиме `3p` (`support.scopes: ["3p"]`), а наши профили — `1p`
  (`egressProxyUrl` и `disableAutoUpdates` — `["3p","1p"]`). **Гипотеза:** в `1p` Claude её
  проигнорирует; проверить, только если понадобится.
- Вход на macOS (из `docs/parallel-auth-plan.md`): Google/SSO идут через
  `ASWebAuthenticationSession` — ответ возвращается в вызвавший процесс без `claude://`;
  через ссылку — письмо со ссылкой входа (magic link), SSO-callback и запасной путь через
  браузер. **Гипотеза:** при нескольких открытых профилях вход через Google на Mac уже
  попадает в нужный профиль, а письмо со ссылкой — нет.
- **Проверено автором 2026-10-03 (P-E4):** открыты «Основной», «Тест» и новый профиль
  «Вход» без входа; вход по письму (magic link). Ссылку из письма macOS отдал **основному**
  Claude, а не «Входу». Основной не ждал входа и показал страницу с кодом для входа;
  код ввели во «Входе» — вход прошёл. Основной так и остался на странице с кодом до
  перезапуска (вход в нём не сломался). Вывод: у Claude есть свой запасной путь — код,
  — но ссылка попадает в случайный экземпляр и сбивает его окно. Обработчик лаунчера
  (P-5…P-7) нужен, чтобы ссылка входа сразу шла в профиль, который ждёт входа.
  Вход через Google/SSO внутри Claude живьём ещё не проверен.

## Windows: Cowork

- Служба машины Cowork ищет образ в `%APPDATA%\<имя папки профиля>\vm_bundles` и игнорирует
  `--user-data-dir`, поэтому профили — в `%APPDATA%` (claude-desktop-clone; у нас так и есть).
  Ссылки (junction/symlink) на `vm_bundles` служба не открывает.
- Две машины Cowork одновременно — по claude-desktop-clone ошибка `HYPERVISOR_SERVICE_ERROR`
  (**проверить**, P-E3).
- Длинные пути в `vm_bundles` упираются в 260 символов (issue в claude-desktop-profiles).
