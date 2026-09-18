# Changelog

## 1.0.0
First release.

- Closes orphaned `cmd.exe` launcher windows whose process tree no longer contains a worker process.
- Two safety nets (port-listener keep-set with ancestor walk, worker-process detection) plus a
  configurable grace period.
- `-DryRun`, per-decision logging with reasons, log trimming.
- Config-driven: launcher patterns, worker process names, liveness ports, log path.
- `install.ps1` registers/removes a scheduled task (no admin rights, nothing copied).
- 7 self-tests that fabricate real console windows, including a guard that asserts the test config
  was actually loaded.
