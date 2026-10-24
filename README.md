# vpngate-finder

Find working **VPN Gate** servers for the **SoftEther VPN Client** on Windows — parallel scan, one-keystroke connect, session watchdog.

Поиск рабочих серверов **VPN Gate** для **SoftEther VPN Client** под Windows — параллельное сканирование, подключение одной клавишей, сторож сессии.

---

## 🇬🇧 English

**vpngate-finder** automates the boring part of using [VPN Gate](https://www.vpngate.net/en/): instead of clicking through the client's server list one by one, it downloads the current server list, TCP-probes every server on every port in parallel, shows a latency-sorted table, and connects you through a copy of your own VPN Gate account — verifying that traffic really flows through the tunnel.

### Requirements

- Windows 10 or 11
- [SoftEther VPN Client](https://www.vpngate.net/en/download.aspx) installed (the standard installer already includes the VPN Gate plugin)
- Administrator rights (`vg.bat` self-elevates via UAC)

### Quick start

1. Download `vg.bat` and `Find-VpnGate.ps1` into any folder (or clone this repository).
2. Double-click `vg.bat` (it will ask for admin rights — that is normal).
3. Wait ~15–20 seconds for the scan, then type a server number or press `A`.

### The menu

| Key | Action |
|---|---|
| `1..N` | connect to that server |
| `A` | sweep all live servers until one accepts the connection |
| `B` | rescan: fresh list, fresh probes |
| `D` | test the current session (is traffic really going through it?) |
| `C` | exit |

### Command-line options

| Flag | Meaning |
|---|---|
| `-Connect` | after the scan, try the best candidates automatically |
| `-Country US,JP` | only scan these countries |
| `-Exclude RU,BY,UA` | hide servers of these countries |
| `-CountryPriority TH,JP` | sweep order: these countries first |
| `-Index 12` | connect to row #12 of the table |
| `-ConnectTries 8` | cap the number of sweep attempts (0 = all) |
| `-ConnectWaitSec 6` | seconds per attempt before dropping it |
| `-ProbeTimeoutMs 5000` | TCP probe timeout (increase on lossy networks) |
| `-KeepTunnel` | do not drop the current session when re-probing |
| `-CsvPath file.csv` | use a manually saved server list |
| `-DisconnectAfter` | disconnect after a successful test |
| `-Watchdog` | keep the VPN alive: auto-restore and rescan when the session drops (Ctrl+C to stop) |

### How it works

1. The server list is downloaded from the official VPN Gate CDN (`download.vpngate.jp`), with fallback to `vpngate.net` and a local cache.
2. Parallel TCP probes (64 threads) filter out dead servers and measure latency.
3. Connect attempts go through a copy of **your own** VPN Gate account, exported with all of its settings — VPN Gate servers accept genuine VPN Gate clients and may refuse bare accounts.
4. Every established session is verified: the public IP must actually change.
5. A 3-second "door check" detects when your network is dropping new VPN handshakes, so you don't waste minutes sweeping while the block wave is active.

### Watchdog

`vg.bat -Watchdog` keeps your VPN alive: it connects automatically, watches the session every 30 seconds, and re-scans + re-connects whenever the session drops. Useful when your ISP opens and closes VPN handshakes in waves. Stop with `Ctrl+C`.

### Troubleshooting

- **A UAC prompt at start** — the SoftEther client service only accepts commands from administrators; the launcher self-elevates.
- **`DEAD` in the ping column** — the server did not answer TCP probes; sweeps skip it.
- **`TCP to ... does not connect right now`** — new VPN handshakes are currently blocked on your network. Your existing session keeps working; retry later (the check costs 3 seconds).
- **"Connection Error" plates** — hidden automatically; failures are printed by the script instead.
- **The list looks smaller than in the app** — the app also shows stale cached entries; this tool shows the fresh list only.

### Privacy

The script talks to the public VPN Gate list endpoints (CDN / vpngate.net), probes server addresses, and checks your public IP via `api.ipify.org` / `checkip.amazonaws.com`. Nothing is stored outside your `%TEMP%` folder. No telemetry.

### Disclaimer

VPN Gate is an academic experiment by the University of Tsukaba. Using VPN services may be restricted in your country — check your local laws. This tool is provided as-is, with no warranty.

---

## 🇷🇺 Русский

**vpngate-finder** автоматизирует скучную часть работы с [VPN Gate](https://www.vpngate.net/en/): вместо того чтобы щёлкать по списку серверов в приложении по одному, скрипт скачивает актуальный список, параллельно пробует TCP на всех портах каждого сервера, показывает таблицу с сортировкой по задержке и подключает через копию вашего собственного аккаунта VPN Gate — с проверкой, что трафик реально идёт через туннель.

### Требования

- Windows 10 или 11
- Установленный [SoftEther VPN Client](https://www.vpngate.net/en/download.aspx) (в стандартном установщике уже есть плагин VPN Gate)
- Права администратора (`vg.bat` сам запрашивает их через UAC)

### Быстрый старт

1. Скачайте `vg.bat` и `Find-VpnGate.ps1` в любую папку (или склонируйте репозиторий).
2. Запустите `vg.bat` двойным кликом (запросит права администратора — это нормально).
3. Дождитесь скана (~15–20 секунд), затем введите номер сервера или нажмите `A`.

### Меню

| Клавиша | Действие |
|---|---|
| `1..N` | подключиться к этому серверу |
| `A` | перебрать все живые серверы, пока один не примет подключение |
| `B` | пересканировать: свежий список, новые пробы |
| `D` | проверить текущую сессию (идёт ли трафик реально через неё?) |
| `C` | выход |

### Параметры командной строки

| Флаг | Значение |
|---|---|
| `-Connect` | после скана автоматически перебрать лучших кандидатов |
| `-Country US,JP` | сканировать только эти страны |
| `-Exclude RU,BY,UA` | скрыть серверы этих стран |
| `-CountryPriority TH,JP` | порядок перебора: эти страны первыми |
| `-Index 12` | подключиться к строке №12 таблицы |
| `-ConnectTries 8` | ограничить число попыток перебора (0 = все) |
| `-ConnectWaitSec 6` | секунд на попытку до её сброса |
| `-ProbeTimeoutMs 5000` | таймаут TCP-проб (увеличьте на плохой сети) |
| `-KeepTunnel` | не отключать текущую сессию при повторных пробах |
| `-CsvPath file.csv` | использовать сохранённый вручную список |
| `-DisconnectAfter` | отключиться после успешного теста |
| `-Watchdog` | держать VPN включённым: авто-восстановление и перескан при падении сессии (Ctrl+C для остановки) |

### Как это работает

1. Список серверов скачивается с официального CDN VPN Gate (`download.vpngate.jp`), с запасом: `vpngate.net` и локальный кэш прошлых запусков.
2. Параллельные TCP-пробы (64 потока) отбрасывают мёртвые серверы и замеряют задержку.
3. Попытки подключения идут через копию **вашего собственного** аккаунта VPN Gate, экспортированную со всеми настройками — серверы VPN Gate принимают «настоящих» клиентов VPN Gate и могут отклонять голые аккаунты.
4. Каждая установленная сессия проверяется: публичный IP должен реально измениться.
5. 3-секундная «проверка двери» определяет, сбрасывает ли ваша сеть новые VPN-рукопожатия, — чтобы не тратить минуты на пустой перебор во время блокировочной волны.

### Сторож

`vg.bat -Watchdog` держит ваш VPN включённым: подключает автоматически, следит за сессией каждые 30 секунд и при её падении пересканирует и подключает заново. Удобно, когда провайдер открывает и закрывает VPN-рукопожатия волнами. Остановка — `Ctrl+C`.

### Решение проблем

- **Запрос прав администратора при запуске** — сервис SoftEther принимает команды только от администраторов; лаунчер сам их запрашивает.
- **`DEAD` в колонке пинга** — сервер не ответил на TCP-пробы; перебор его пропускает.
- **`TCP to ... does not connect right now`** — новые VPN-рукопожатия сейчас блокируются вашей сетью. Текущая сессия продолжает работать; повторите позже (проверка стоит 3 секунды).
- **Плашки «Connection Error»** — скрываются автоматически; причины неудач скрипт печатает сам.
- **Список меньше, чем в приложении** — приложение показывает и устаревшие записи из кэша; здесь только свежий список.

### Приватность

Скрипт обращается к публичным эндпоинтам списка VPN Gate (CDN / vpngate.net), проверяет адреса серверов и смотрит ваш публичный IP через `api.ipify.org` / `checkip.amazonaws.com`. Ничего не сохраняется вне вашей папки `%TEMP%`. Телеметрии нет.

### Дисклеймер

VPN Gate — академический эксперимент Университета Цукубы. Использование VPN может быть ограничено в вашей стране — проверьте местные законы. Инструмент предоставляется «как есть», без гарантий.

---

## License / Лицензия

MIT — see [LICENSE](LICENSE).
