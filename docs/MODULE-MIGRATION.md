# Profile Script Module Migration Roadmap

## Status

Implementation is complete in the repository as of 2026-07-20, with one manual
validation item remaining: run the 20-sample interactive benchmark from a real,
unredirected Windows Terminal. The automated suite, 10-cycle import/remove and
reload tests, installed-profile canary, and batch performance gate pass.

Implementation evidence:

- starting commit: `551cc58` (`Stabilize profile session state scope`);
- environment: PowerShell 7.6.3 Core on Windows 10.0.26200;
- fresh pre-migration 20-run medians: `NoProfile` 128.0 ms,
  `BatchSourceProfile` 224.8 ms;
- post-migration 20-run medians: `NoProfile` 123.4 ms,
  `BatchSourceProfile` 227.8 ms;
- batch regression: 3.0 ms, within the greater-of-10-ms-or-5% budget;
- installed source/stage mirror: 10 `.ps1`/`.psm1` part files with matching
  hashes;
- installed external-script canary: poisoned caller state, real Node wrapper,
  three reloads, and a second Node invocation all passed.

The phases below remain the design record and rollback guide. Each phase is
intended to be independently testable, committable, and reversible.

The starting point for the migration is commit `551cc58` (`Stabilize profile
session state scope`). At that point, profile-owned session state uses global
variables to avoid caller script-scope collisions. That fixes the immediate
failure mode, but it leaves internal state and helper functions visible to every
script in the runspace.

The last recorded automated startup result before this plan was written was:

- `NoProfile` median: 136.9 ms
- `BatchSourceProfile` median: 228.8 ms

These numbers are reference data only. Phase 0 must collect a fresh 20-run
baseline on the same machine immediately before implementation begins.

## Why migrate

The profile currently dot-sources its part scripts from
`Microsoft.PowerShell_profile.ps1`. Functions created by those scripts become
session commands, and reliable shared state currently has to be stored in global
variables.

A script module provides a durable scope owned by the module:

- module functions can use `$script:` without binding to the caller's script
  scope;
- internal functions and variables remain private unless explicitly exported;
- imported public commands still work throughout the interactive session;
- module removal provides a defined place to dispose timers, watchers, event
  subscriptions, and child processes;
- reloading can become a controlled remove/import cycle rather than another
  layer of dot-sourced state.

`Import-Module -Global` does not make the module's private state global. It only
places the module's explicitly exported commands in the caller's global command
scope. The module's `$script:` variables remain private to that module instance.

Separate Windows Terminal tabs normally run separate `pwsh` processes, so they
already have separate runspaces and module instances. The stronger isolation
mainly protects commands and scripts running inside the same tab/runspace from
one another.

## Goals

1. Keep profile-owned mutable state in one module-private state object.
2. Export only commands that users or PowerShell itself must call.
3. Preserve the existing prompt appearance, completion behavior, key bindings,
   aliases, Node wrappers, and lazy initialization behavior.
4. Make repeated profile reloads idempotent.
5. Clean up profile-owned asynchronous resources on module removal.
6. Preserve the existing install transaction and rollback behavior.
7. Prevent a caller script's `$script:` variables or helper functions from
   changing profile behavior.
8. Keep startup time within an explicit regression budget.

## Non-goals

- Do not redesign the prompt or change its visual output.
- Do not replace the existing `profile.d` part files with one large generated
  module.
- Do not move prompt updater scripts into generated cache files or here-strings.
- Do not add a module manifest, classes, dependency injection, or a framework
  during this migration.
- Do not add fallback behavior for `lsd`, `bat`, or `rg`.
- Do not add `zoxide`, `fzf`, or `PSFzf`.
- Do not change fnm, carapace, PSReadLine, or Terminal-Icons dependencies.
- Do not attempt to undo process environment changes made by fnm when the module
  is removed. Cleanup applies to resources owned by the module, not the entire
  process environment.

## Target layout

Keep the current part files readable and source-controlled. Add one script
module that owns their scope and orchestration:

```text
profile/
|-- Microsoft.PowerShell_profile.ps1
`-- profile.d/
    |-- PwshProfile.psm1
    |-- 10-prompt.ps1
    |-- 20-node.ps1
    |-- 25-icons.ps1
    |-- 30-psreadline.ps1
    |-- 40-completion.ps1
    |-- 50-aliases.ps1
    |-- 60-utils.ps1
    `-- prompt-updaters/
        |-- Update-AsyncGitStatus.ps1
        `-- Update-AsyncToolchainStatus.ps1
```

The module dot-sources the existing part files into module scope in the current
order:

1. `20-node.ps1`
2. `10-prompt.ps1`
3. `25-icons.ps1`
4. `30-psreadline.ps1`, for interactive ConsoleHost sessions only
5. `40-completion.ps1`, for interactive ConsoleHost sessions only
6. `50-aliases.ps1`
7. `60-utils.ps1`

The order is a compatibility contract. In particular, the prompt can call the
fnm integration, and completion can share prompt and PSReadLine behavior.

The entry profile should eventually do only four things:

1. resolve the module path;
2. remove an existing `PwshProfile` module instance so its cleanup hook runs;
3. import the module globally;
4. install the small global `reload` bridge.

Session classification should move into the module using the current logic based
on host type, redirection, command-line arguments, and `-NoExit`. It must not be
reduced to a simple `$Host.Name` check.

## Target scope model

### Module-private state

Use one plain hashtable instead of many unrelated module variables:

```powershell
$script:State = @{
    SchemaVersion = 1
    Session = @{
        CommandLine   = [Environment]::GetCommandLineArgs()
        IsBatch       = $false
        HasNoExit     = $false
        IsInteractive = $false
    }
    Fnm = @{}
    Prompt = @{}
    Completion = @{}
    Resources = @{
        EventSubscribers = [System.Collections.Generic.List[object]]::new()
        Timers           = [System.Collections.Generic.List[object]]::new()
        Watchers         = [System.Collections.Generic.List[object]]::new()
        Processes        = [System.Collections.Generic.List[object]]::new()
    }
}
```

The exact leaf fields should be migrated from the existing state, not redesigned
speculatively. A single root object gives cleanup and tests one stable place to
find profile-owned state.

Use `$script:State` only inside the module and its module-bound scriptblocks.
Do not export the state object, mirror it into a global variable, or add public
getter/setter commands just for tests.

### Intentionally caller-visible state

Some effects cannot and should not be module-private:

- exported functions and aliases;
- process environment variables such as `PATH` and fnm variables;
- PowerShell's automatic `$global:LASTEXITCODE`;
- PSReadLine handlers and native argument completer registrations;
- the `reload` bridge created by the entry profile.

These are explicit exceptions, not a reason to retain profile-owned globals.

### Public command surface

Freeze the command surface in a test before making helpers private.

Engine entry points:

- `prompt`
- `TabExpansion2`

Prompt controls:

- `Set-LeanPromptSymbolSet`
- `Test-LeanPromptGlyphs`

Conditionally available fnm wrappers, matching current behavior:

- `node`
- `npm`
- `npx`
- `pnpm`
- `yarn`
- `corepack`

User commands:

- `icons`
- `ls`, `l`, `ll`, `la`, `lt`
- `pwd`, `mkdir`, `..`, `...`, `....`
- `g`, `gst`, `gss`, `ga`, `gaa`, `gco`, `gcb`, `gb`, `gc`, `gcmsg`, `gca`
- `gp`, `gl`, `gf`, `gd`, `gds`, `glog`, `gloga`
- `cat`, `grep`
- `which`, `whereis`, `touch`, `mkcd`, `head`, `tail`
- `export`, `env`, `open`, `df`, `Update-Path`

User aliases:

- `xdg-open`
- `refreshenv`

`reload` remains public but should be owned by the entry profile, because
removing a module from a function currently executing inside that same module is
an avoidable lifecycle edge case.

Everything else under `10-prompt.ps1`, `20-node.ps1`,
`30-psreadline.ps1`, and `40-completion.ps1` is private unless a test proves that
PowerShell, PSReadLine, or carapace must resolve it by name after import.

Use one explicit `Export-ModuleMember` call near the end of
`PwshProfile.psm1`. Do not rely on implicit export behavior or wildcard exports.
Dynamic fnm wrapper names can be added to the explicit function list only when
fnm was found and the wrappers were created.

## Lifecycle design

### Import

The module should:

1. initialize a fresh state object;
2. classify the session;
3. load unconditional parts;
4. load interactive-only parts only for an interactive ConsoleHost, including
   supported `-NoExit -Command` sessions;
5. register asynchronous resources in `State.Resources`;
6. explicitly export the public surface.

Part scripts should not independently create top-level global state.

### Runtime callbacks

PSReadLine handlers, event actions, and timer callbacks are the most important
scope tests in the migration.

- Prefer module-bound scriptblocks that close over module-private commands and
  state.
- Where PowerShell runs an action in a separate event job session state, pass
  the minimum required data through `-MessageData`.
- Do not look up private helpers through the caller's global command table.
- Keep the existing background updater scripts as separate process entry
  points. Pass paths and cache metadata explicitly as they do today.

Each callback type needs a focused spike test before its subsystem is migrated.
The spike belongs in the test suite, not as a permanent alternate
implementation.

### Removal

Create one private, idempotent `Stop-PwshProfileRuntime` function. Register it
through the module's `OnRemove` hook.

Cleanup order:

1. prevent new asynchronous refresh work;
2. unregister profile-owned event subscribers;
3. stop and dispose timers;
4. disable and dispose file watchers;
5. stop and dispose profile-owned child processes;
6. remove temporary cache/lock state only where the current implementation
   already owns it;
7. restore caller aliases that the profile deliberately removed.

Every resource cleanup operation must tolerate:

- a resource that was never created;
- a resource that has already completed;
- cleanup being called more than once;
- partial import failure.

Do not remove event subscribers by broad name patterns. Track the exact objects
or source identifiers created by the current module instance.

### Reload

The entry-level `reload` bridge should:

1. call exported `Update-Path`;
2. remove the current module, invoking cleanup;
3. import the same module path globally;
4. report success only after import completes.

Dot-sourcing the entry profile again should follow the same remove/import path.
It must not leave two prompt timers, two file watchers, duplicate completion
prewarm events, or an abandoned fnm initialization process.

## Migration phases

### Phase 0: Freeze the baseline

Purpose: create evidence that later phases preserve behavior.

Tasks:

- Run `.\scripts\test-profile.ps1 -Runs 20`.
- From an unredirected Windows Terminal, run
  `.\scripts\test-profile.ps1 -InteractiveRuns 20`.
- Record the commit, PowerShell version, machine context, batch median, and
  interactive median in the implementation PR or commit notes.
- Capture the public command/alias inventory listed above in an automated test.
- Add a prompt rendering fixture or snapshot if the current tests do not already
  cover every visible segment.
- Record counts and source identifiers for profile-owned event subscribers,
  timers, watchers, and live worker processes after one load.

Acceptance:

- The current suite passes before migration code is introduced.
- The baseline is reproducible enough to distinguish a module regression from
  normal process-start noise.

Rollback:

- No runtime change exists in this phase.

Suggested commit:

```text
Freeze profile module migration baseline
```

### Phase 1: Teach tooling about `.psm1`

Purpose: make module files first-class installable profile sources without
changing runtime behavior.

Tasks:

- Replace `.ps1`-only enumeration in `scripts/install.ps1` with an explicit
  `.ps1`/`.psm1` extension allowlist.
- Parse both extensions before staging and after staging.
- Update mirror validation in `scripts/test-profile.ps1` to compare both
  extensions recursively.
- Update policy-content aggregation to include both extensions.
- Add an inert parser-clean `.psm1` fixture to the installer test or otherwise
  prove that a module file is copied and validated.
- Keep prompt updater `.ps1` files recursively mirrored as they are today.

Do not add `.psd1` support until a manifest is actually needed.

Acceptance:

- Install staging copies `.ps1` and `.psm1` files.
- A syntax error in either extension aborts before the installed profile is
  replaced.
- Transactional rollback tests still pass.
- Runtime behavior and startup measurements are unchanged within noise.

Rollback:

- Revert this commit; no installed profile format depends on it yet.

Suggested commit:

```text
Support script modules in profile tooling
```

### Phase 2: Add a module shell

Purpose: change the loading boundary while preserving the current implementation
as closely as possible.

Tasks:

- Add `profile/profile.d/PwshProfile.psm1`.
- Move session classification and part ordering from the entry profile into the
  module.
- Have the module dot-source the existing parts in the existing order.
- Change the entry profile to remove/import the module.
- Initially tolerate the existing `global:` state and `global:` prompt helpers.
  This phase proves loading and callback compatibility; it does not claim final
  isolation.
- Add clean-process tests for batch, interactive, and `-NoExit -Command`
  classification.
- Verify that the standalone prompt updater scripts still receive valid paths
  after `$PSScriptRoot` changes from the entry profile directory to the
  `profile.d` module directory.

Acceptance:

- All existing behavioral tests pass without changing their expected output.
- The public command inventory is unchanged.
- A second entry-profile load succeeds.
- Installed-profile smoke tests import `PwshProfile`, not a repo-only path.
- Interactive-only parts remain absent in batch sessions.

Rollback:

- Revert the entry and module-shell commit. The part scripts still support the
  previous dot-source loader.

Suggested commit:

```text
Load profile parts through PwshProfile module
```

### Phase 3: Define the public boundary

Purpose: make internal helper functions module-private before moving state.

Tasks:

- Remove `global:` from prompt helper declarations.
- Ensure functions in all part files are created in module scope.
- Create the explicit export list described above.
- Create dynamic fnm wrappers in module scope and export only their known names.
- Confirm that PSReadLine key-handler scriptblocks retain access to private
  functions after module import returns.
- Confirm that registered completion scriptblocks retain access to private
  completion helpers.
- Determine whether carapace's generated `_carapace_completer` must be exported.
  Keep it private if the registered completer scriptblock works without global
  lookup.
- Preserve the original/default `TabExpansion2` implementation privately before
  exporting the profile replacement.
- Track aliases removed for `ls`, `pwd`, `cat`, `curl`, and `wget` so module
  removal can eventually restore the pre-import state.

Acceptance:

- Only the frozen public function and alias inventory is added by the module.
- Names matching internal prefixes such as `Get-LeanPrompt*`,
  `Start-Async*`, `*FnmState*`, and private completion helpers do not appear as
  caller-visible functions.
- Prompt, completion, Ctrl+C handling, and fnm wrapper tests pass.
- Removing the module makes its exported commands disappear or reveals the
  command that was previously shadowed.

Rollback:

- Revert the public-boundary commit while retaining the working module shell.

Suggested commit:

```text
Define the profile module public surface
```

### Phase 4A: Move fnm state into the module

Purpose: migrate the smallest asynchronous subsystem first and reproduce the
original caller-scope failure as a regression test.

Tasks:

- Move `__FnmState` and the executable path into `State.Fnm`.
- Keep `Initialize-FnmForUse`, version-file handling, retry behavior, and
  warning suppression private.
- Register the fnm initialization process in `State.Resources.Processes`.
- Preserve `$global:LASTEXITCODE` usage where the real native exit code is
  intentionally read.
- Add an external-script test that defines incompatible caller `$script:State`
  and `$script:__FnmState` values, then invokes `node`/`npx`.
- Add a test that defines global functions with the same names as fnm private
  helpers and proves the module wrappers do not call them.
- Verify wrapper resolution cannot recurse into the exported wrapper and still
  finds the real `.exe`, `.cmd`, or `.ps1` application.

Acceptance:

- Caller script variables cannot alter fnm initialization.
- Repeated wrapper calls and a directory with `.node-version` or `.nvmrc`
  preserve existing behavior.
- Failure produces at most one warning per module instance.
- Module removal disposes an in-flight initialization process.
- No fnm profile state remains in global variables.

Rollback:

- Revert only the fnm state commit; the module and public boundary remain.

Suggested commit:

```text
Move fnm state into module scope
```

### Phase 4B: Move completion and PSReadLine state

Purpose: isolate the shared interactive input state without changing completion
semantics.

Tasks:

- Move completion caches, interrupt flags, auto-slash state, prewarm state, and
  saved default completion logic into `State.Completion`.
- Replace global helper lookup in PSReadLine handlers with module-bound
  scriptblocks.
- Keep `TabExpansion2` exported because PowerShell resolves it by name.
- Keep the default `TabExpansion2` implementation private and callable by the
  replacement.
- Pass only immutable or synchronized data to event jobs.
- Track and clean up the completion prewarm event by its exact subscriber.
- Update tests that currently patch global internal functions so they execute
  assertions inside module scope or test public behavior instead.

Acceptance:

- Existing completion matrices pass.
- Ctrl+C during completion behaves exactly as before.
- Directory slash handling and path case correction remain unchanged.
- carapace initialization and prewarm remain lazy.
- Reloading ten times leaves no duplicate prewarm event subscriber.
- No completion or PSReadLine profile state remains in global variables.

Rollback:

- Revert the completion state commit without reverting fnm isolation.

Suggested commit:

```text
Move completion state into module scope
```

### Phase 4C: Move prompt and asynchronous worker state

Purpose: isolate the largest and highest-risk subsystem after module callbacks
have already been proven.

Tasks:

- Move prompt palette, cache metadata, redraw state, worker state, generation
  counters, timers, watchers, and event jobs into `State.Prompt`.
- Keep prompt formatting helpers private.
- Keep `prompt` exported.
- Preserve the current async updater files and Git plumbing behavior.
- Pass watcher/timer callback data through module-bound scriptblocks or
  `-MessageData`; do not require global helper functions.
- Track every timer, watcher, subscriber, and worker process as it is created.
- Keep prompt error handling and `$global:LASTEXITCODE` preservation unchanged.
- Convert tests that replace global prompt helpers to module-scope test
  execution or public-output fixtures.

Acceptance:

- Prompt snapshots and width/alignment tests are unchanged.
- Prompt rendering performs no new synchronous Git or toolchain calls.
- Git branch/ref tests continue to use Git plumbing and pass with reftable
  repositories.
- Async cache refresh and redraw behavior pass.
- Reloading ten times leaves one active set of prompt resources.
- Removing the module stops all profile-owned prompt resources.
- No prompt profile state or internal prompt helper functions remain global.

Rollback:

- Revert the prompt state commit without reverting the earlier isolated
  subsystems.

Suggested commit:

```text
Move prompt state into module scope
```

### Phase 5: Make cleanup and reload authoritative

Purpose: turn resource ownership into a tested lifecycle contract.

Tasks:

- Implement the idempotent private `Stop-PwshProfileRuntime`.
- Set the module `OnRemove` hook immediately after state initialization so
  partial imports can also be cleaned up.
- Change `reload` to the entry-level remove/import bridge.
- Restore aliases deliberately removed at import if the module is removed
  without immediate re-import.
- Decide and test collision behavior when a user defines a public command after
  module import. Cleanup must not delete a newer user definition it does not
  own.
- Add import-failure tests at representative points and assert that already
  created resources are disposed.
- Add repeated load/remove cycles in fresh child processes.

Acceptance:

- Ten reload cycles result in one module instance and one owned resource set.
- Ten import/remove cycles end with no owned resources.
- Cleanup can be called twice without errors.
- An interrupted or partially failed import does not leak resources.
- `reload` refreshes `PATH`, reloads the module, and reports success.

Rollback:

- Revert the lifecycle commit. Earlier subsystem isolation remains valid, but
  the branch must not be released until lifecycle tests pass.

Suggested commit:

```text
Make profile reload and cleanup idempotent
```

### Phase 6: Install canary and performance gate

Purpose: verify the repository implementation in the actual installed-profile
location and close the migration.

Tasks:

- Run the complete automated suite.
- Install using `scripts/install.ps1` and verify the installed tree mirrors both
  `.ps1` and `.psm1` sources.
- Start a clean `pwsh` process that loads the installed profile.
- Run the external-script fnm regression scenario against the installed profile.
- Exercise prompt, completion, Node wrappers, and `reload` in a real Windows
  Terminal.
- Run `.\scripts\test-profile.ps1 -Runs 20`.
- Run `.\scripts\test-profile.ps1 -InteractiveRuns 20` from an unredirected
  Windows Terminal.
- Update `README.md` or `docs/FEATURES.md` only where the user-visible loading or
  troubleshooting instructions actually changed.

Acceptance:

- `.\scripts\test-profile.ps1` passes.
- The installed profile imports without warnings in batch and interactive
  sessions.
- The original external `publish.ps1`/Node-command failure class is covered by
  an automated regression test and cannot be reproduced manually.
- `BatchSourceProfile` and interactive medians stay within the performance
  budget below.
- There are no untracked generated module or cache scripts.

Rollback:

- Revert the most recent migration commit and rerun `scripts/install.ps1`, or
  restore the installer's timestamped backup.
- Do not retain a permanent dual-loader feature flag. Git and the transactional
  installer are the rollback mechanisms.

Suggested commit:

```text
Validate profile module isolation
```

## Validation matrix

| Area | Required evidence |
| --- | --- |
| Parsing | Entry profile, all `.ps1` parts, and `PwshProfile.psm1` parse cleanly |
| Policy | Direct `lsd`/`bat`/`rg`, no zoxide/fzf, no Git internal-ref parsing |
| Batch gating | Interactive parts are not loaded in redirected or batch sessions |
| Interactive gating | ConsoleHost and supported `-NoExit -Command` sessions load interactive parts |
| Public API | Exact expected public function and alias inventory |
| Private API | Internal prompt, fnm, PSReadLine, and completion helpers are not caller-visible |
| Caller isolation | Poisoned caller `$script:` variables and same-named functions do not affect the module |
| Prompt | Appearance, width, duration, Git, toolchain, and exit-code fixtures |
| Completion | Path, slash, case, native, carapace, interruption, and Ctrl+C fixtures |
| Node | Async initialization, retry, version-file switching, and all six wrappers |
| Reload | Ten reloads leave one module and one resource set |
| Removal | Ten import/remove cycles leave no owned timers, watchers, subscribers, or processes |
| Install | Source/stage/installed trees mirror `.ps1` and `.psm1` recursively |
| Startup | 20-run batch and interactive measurements remain within budget |

Tests should prefer public behavior. When private inspection is necessary, run a
test scriptblock in the module session state:

```powershell
$module = Get-Module PwshProfile -ErrorAction Stop
& $module {
    # Inspect $script:State or replace a private helper for one focused test.
}
```

Do not export diagnostic commands or state accessors solely to make tests easier.

## Performance budget

Use medians from the same machine and comparable terminal conditions.

- `NoProfile` is environmental reference data, not a profile regression gate.
- Gate the `BatchSourceProfile` median against the fresh Phase 0 baseline.
- Gate the interactive median against the fresh Phase 0 interactive baseline.
- Investigate and block release when either median regresses by more than the
  greater of 10 ms or 5%.
- A median inside the threshold can still be rejected if the change adds
  synchronous Git, fnm, carapace, or Terminal-Icons work to startup.
- If results are close to the threshold, repeat both baseline and branch
  measurements rather than weakening the budget.

The module should not eagerly import optional dependencies. Its startup work
should remain orchestration, function creation, lightweight state
initialization, and the existing asynchronous starts.

## Risk register

| Risk | Consequence | Required mitigation |
| --- | --- | --- |
| A public function is not exported | Existing shell command silently disappears | Freeze and compare the exact public inventory |
| Internal functions remain `global:` | Migration provides little isolation | Assert internal name patterns are absent from the caller scope |
| `TabExpansion2` loses its fallback | Default completion breaks or recurses | Capture the pre-module implementation and test fallback paths |
| PSReadLine handler loses module affinity | Key bindings fail after import returns | Invoke each handler after import in an isolated interactive test |
| Event action resolves caller globals | Async behavior is nondeterministic | Use module-bound callbacks or explicit `-MessageData` |
| carapace requires a global generated helper | Native completion fails after helpers become private | Run a focused scope spike before deciding whether that one helper must be exported |
| Dynamic Node wrapper resolves itself | Infinite recursion | Resolve application command types and test every wrapper |
| Module removal leaks resources | Reload duplicates work and callbacks | Track exact resources and test repeated import/remove cycles |
| Cleanup removes user-owned commands | User customization is lost | Restore only state captured and still owned by the module |
| Alias removal is not reversible | `Remove-Module` leaves caller scope altered | Capture alias definitions/options and restore them on removal |
| `$LASTEXITCODE` is localized accidentally | Prompt or fnm reads the wrong exit code | Keep intentional `$global:LASTEXITCODE` references and regression tests |
| Prompt updater paths change | Async Git/toolchain status stops updating | Resolve updater paths from module root and test real worker launches |
| Installer ignores `.psm1` | Repo tests pass but installed profile fails | Add module-aware parse, stage, mirror, and installed smoke tests first |
| Module import adds startup work | Every new shell becomes slower | Enforce the 20-run performance budget |

## Commit dependency order

```text
baseline tests
    |
module-aware installer/tests
    |
module shell
    |
explicit public boundary
    |
    +-- fnm private state
    |
    +-- completion/PSReadLine private state
    |
    `-- prompt/worker private state
              |
       cleanup and reload
              |
     installed canary + benchmarks
```

Do not combine the three state migrations into one commit. The prompt subsystem
is much larger than fnm, and completion has different callback semantics. Small
commit boundaries make failures attributable and rollback practical.

## Recommended decisions

1. **Use one `.psm1`, without a manifest.** A manifest adds no isolation needed
   by this personal profile. Add one later only if versioning, dependencies, or
   distribution metadata require it.
2. **Keep the existing part files.** The module is the scope boundary and
   loader; it is not a reason to merge readable subsystems.
3. **Use one private state root.** A hashtable is sufficient and avoids classes
   or a custom state API.
4. **Keep `reload` in the entry profile.** This avoids self-removal from an
   executing module function.
5. **Export the minimum proven surface.** If a callback works while its helper is
   private, keep the helper private.
6. **Use tests, not a permanent compatibility mode.** Intermediate commits may
   retain globals temporarily, but the completed migration has one loader and
   one state model.

## Definition of done

The migration is complete only when all of the following are true:

- `Microsoft.PowerShell_profile.ps1` is a small remove/import entry point plus
  the `reload` bridge.
- `PwshProfile.psm1` owns session classification, part order, private state,
  exports, and cleanup.
- All profile-owned mutable state is under module-private `$script:State`.
- Only the documented public commands and aliases are caller-visible.
- Prompt and completion output/behavior match the pre-migration fixtures.
- The fnm external-script collision regression passes.
- Repeated reload and remove/import tests prove that resources do not multiply
  or leak.
- The installer parses and mirrors `.ps1` and `.psm1` files transactionally.
- Full automated, installed-profile, and real-terminal validation passes.
- Startup measurements stay within the defined budget.
- The source tree contains no generated runtime module or hidden compatibility
  implementation.
