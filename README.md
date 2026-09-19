# zombie-window-cleaner

**Closes the orphaned console windows that service launchers leave behind on Windows.**

You start a service from a `.bat` file (n8n, a dev server, a tunnel, a script that ends with
`pause`). The service dies or you restart it — and the console window stays on your taskbar
forever. Restart a few times and you have a pile of dead windows. This tool cleans them up
automatically and never touches the launcher that owns the running service.

```
  PASS  orphaned launcher window is closed             window removed; test config used: True
  PASS  launcher with a live worker survives           worker process detection; test config used: True
  PASS  live service chain (port listener) survives    keep-set protection; test config used: True
  PASS  just-started launcher is inside the grace period graceSeconds protection; test config used: True
  PASS  -DryRun removes nothing                        dry-run safety; test config used: True
  PASS  dry run is recorded in the log                 audit trail
  PASS  default config next to the script is used      no -Config argument; log written: True
RESULT: ALL PASS (7/7 passed)
```

---

## Why it is safe to run unattended

A tool that force-kills processes must never take down the service it is supposed to protect.
Three independent rules enforce that:

| Rule | What it means |
|---|---|
| **Keep-set** | The process listening on each configured port **and every ancestor of it** is never touched — that is the live service and the launcher that started it. |
| **Worker detection** | A window is only a candidate if **nothing in its process tree** is a configured worker process (`node.exe`, `cloudflared.exe`, …). A service that is starting up always has a worker under it. |
| **Grace period** | Windows younger than `graceSeconds` are skipped, so double-clicking a launcher and running the cleaner in the same minute is harmless. |

Everything else is opt-in and reversible:

- `-DryRun` reports what would be killed and kills nothing (and says so in the log).
- Every decision is appended to a log file, including *why* a window was kept.

---

## Quick start

```powershell
# 1. look at what is going on, change nothing
.\zombie-window-cleaner.ps1 -DryRun -Verbose

# 2. configure it for your service
Copy-Item config.example.json cleanup-config.json
notepad cleanup-config.json          # launcherMatch / livenessPorts / workerProcesses

# 3. real run
.\zombie-window-cleaner.ps1

# 4. install the background task (every 15 minutes)
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Config .\cleanup-config.json

# 5. ... and remove it again whenever you like
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

No admin rights are needed, nothing is copied anywhere, and the task simply runs the script in
place. Uninstalling removes the task and nothing else.

**The scheduled task runs completely invisibly.** It is launched through `hidden-runner.vbs`,
because on Windows 11 (where Windows Terminal is the default terminal host) a task using
`powershell -WindowStyle Hidden` still flashes a terminal window on every run.

---

## Configuration

`cleanup-config.json` (all keys optional — see `config.example.json`):

| Key | Default | Meaning |
|---|---|---|
| `launcherMatch` | `n8n-serve`, `n8n start`, `start-public` | Substrings matched against a `cmd.exe` window's **command line or window title** |
| `workerProcesses` | `node.exe`, `cloudflared.exe` | Process names that mean "the service under this window is alive" |
| `livenessPorts` | `5678` | Ports whose listener (plus ancestors) form the keep-set |
| `graceSeconds` | `60` | Skip windows younger than this |
| `logFile` | `cleanup.log` next to the script | Append-only audit trail |
| `maxLogBytes` | `204800` | Log is trimmed to the last 200 lines beyond this size |

Parameters: `-Config <path>`, `-DryRun`, `-LogFile <path>`, plus the usual `-Verbose`.

---

## How it works

1. Resolve the keep-set: for each `livenessPorts` entry, find the listening PID and walk its
   parent chain upward.
2. Find candidate windows: `cmd.exe` processes whose command line or window title matches
   `launcherMatch`.
3. For each candidate: skip it if it is in the keep-set, if any descendant is in the keep-set,
   if any descendant is a worker process, or if it is younger than `graceSeconds`.
4. Otherwise close it (descendants first) and log it.

That is the whole tool — ~180 lines of PowerShell, no dependencies, works on Windows
PowerShell 5.1 and PowerShell 7.

---

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

The tests do not mock anything: they fabricate real console windows (a launcher `.bat` whose path
contains the match pattern), run the cleaner against a real config, and assert on real process
state. Each test also asserts that **its own config file was actually loaded**, so a cleaner that
silently fell back to defaults cannot pass for the wrong reason.

Covered: orphan removal, live-worker protection, keep-set protection, grace period, dry-run safety,
log audit trail, and default-config resolution.

---

## Design notes (bugs this project hit, so you do not have to)

- **Never name a PowerShell parameter `$pid`.** It collides with the automatic variable, the
  function silently receives the wrong process id, and a "safe" cleaner happily kills the live
  service chain. (This project's first version did exactly that — the tests caught it.)
- **`$PSScriptRoot` is empty while `param()` defaults are evaluated.** A default like
  `-Config (Join-Path $PSScriptRoot 'cleanup-config.json')` fails when the script is invoked with
  `-File`. Resolve the path inside the body instead.
- **In a hidden or minimised window, `timeout /t N` exits immediately** (stdin is redirected) —
  use a `ping`-style wait if you need a long-lived test process.
- **`$cfg = $defaults` in PowerShell is a reference, not a copy.** Iterating its keys while writing
  to it throws *"Collection was modified"* and silently leaves you on the defaults.

## Limitations

- Windows only (it uses `Get-CimInstance` / `Get-NetTCPConnection`).
- Only `cmd.exe` launcher windows are considered; PowerShell-hosted launchers are not matched.
- It closes windows for services it is told about — it does not supervise or restart anything.
- A window is judged by its process tree at scan time; a service that is fully idle with no child
  process and no listening port looks orphaned. Configure a `livenessPorts` entry for those.

## License

MIT — see [LICENSE](LICENSE).
