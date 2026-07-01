# Agent Notes

This repo contains a personal PowerShell profile. Treat the `profile/` tree as the source of truth; `profile/Microsoft.PowerShell_profile.ps1` is the entrypoint and `profile/profile.d` contains the installable parts.

## Rules

- Preserve the current p10k classic-inspired prompt appearance unless explicitly asked to change it.
- Preserve the direct dependency policy: `ls`/`cat`/`grep` call `lsd`/`bat`/`rg` directly and should not gain fallback behavior.
- Do not reintroduce `zoxide`, `fzf`, or `PSFzf` unless explicitly requested.
- Keep interactive-only features gated to interactive ConsoleHost sessions, including `-NoExit -Command` sessions.
- Keep async prompt updater scripts in `profile/profile.d/prompt-updaters` readable and source-controlled; do not move them back into generated cache scripts or large here-strings in `10-prompt.ps1`.
- Preserve reftable compatibility by using Git plumbing for branch/ref identity instead of parsing `.git/HEAD` or files under `.git/refs`.
- When adding profile part scripts, keep them under `profile/profile.d` so `scripts/install.ps1` syncs them recursively.
- Measure startup impact before and after performance-related changes.

## Validation

Run:

```powershell
.\scripts\test-profile.ps1
```

Use a larger sample when reviewing startup cost:

```powershell
.\scripts\test-profile.ps1 -Runs 20
```

The test script recursively parses the entry profile and every `.ps1` file under `profile/profile.d`, then runs policy checks and a startup benchmark.
