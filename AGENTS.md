# Agent Notes

This repo contains a personal PowerShell profile. Treat the `profile/` tree as the source of truth; `profile/Microsoft.PowerShell_profile.ps1` is the entrypoint and `profile/profile.d` contains the installable parts.

## Rules

- Preserve the current p10k classic-inspired prompt appearance unless explicitly asked to change it.
- Preserve the direct dependency policy: `ls`/`cat`/`grep`/`find`/`sdr` call `lsd`/`bat`/`rg`/`fd`/`sd` directly and should not gain fallback behavior.
- Do not reintroduce `zoxide`, `fzf`, or `PSFzf` unless explicitly requested.
- Keep interactive-only features gated to interactive ConsoleHost sessions, including `-NoExit -Command` sessions.
- Keep async prompt updater scripts in `profile/profile.d/prompt-updaters` readable and source-controlled; do not move them back into generated cache scripts or large here-strings in `10-prompt.ps1`.
- Preserve reftable compatibility by using Git plumbing for branch/ref identity instead of parsing `.git/HEAD` or files under `.git/refs`.
- When adding profile part scripts, keep them under `profile/profile.d` so `scripts/install.ps1` syncs them recursively.
- Preserve `jrun` interrupt semantics: the first Ctrl+C remains cooperative, a second Ctrl+C or the three-second deadline terminates the Job Object, and interrupted runs return 130. Keep `npm` and `npx` routed through `mise x -- node` with the resolved installation's `npm-cli.js`/`npx-cli.js`; do not fall back to the `npm.cmd`/`npx.cmd` batch wrappers or `node --run`, and keep `npm run`, `npm run-script`, and `npx` under `jrun`. Keep the npm script-shell environment (`npm_config_script_shell`, `MSYS_NO_PATHCONV`) scoped to the call rather than set for the session.
- Keep winget dependencies unpinned so installs resolve the highest package versions available from the winget source.
- Run Cargo for `jrun` from `profile/profile.d/job-runner` or set `CARGO_TARGET_DIR` outside `profile/`. Never leave `target/` inside the installable profile tree because the installer mirrors it recursively.
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

From a real, unredirected Windows Terminal, measure interactive startup with:

```powershell
.\scripts\test-profile.ps1 -InteractiveRuns 20
```

The test script recursively parses the entry profile and every `.ps1` file under `profile/profile.d`, runs the Rust `jrun` unit and real Windows process-tree integration tests, then runs policy checks, isolated smoke tests, and a batch startup benchmark. The optional interactive benchmark is intentionally unavailable in redirected automation.
