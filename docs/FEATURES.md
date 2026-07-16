# Feature Reference

This document describes the behavior of the PowerShell profile in detail. The main [README](../README.md) is the quick-start guide; this file is the functional reference.

## Design Goals

The profile is designed around four priorities:

1. Keep startup and prompt rendering responsive.
2. Reproduce useful Zsh and powerlevel10k interaction patterns in native PowerShell.
3. Keep dependencies explicit instead of silently replacing missing tools with weaker fallbacks.
4. Keep behavior testable in isolated PowerShell processes.

The `profile/` tree is the source of truth. The installed profile is a synchronized copy created by `scripts/install.ps1`.

## Session Loading Model

`profile/Microsoft.PowerShell_profile.ps1` is the entrypoint. It classifies the current PowerShell process before loading profile parts.

The following parts load in every supported session:

- `20-node.ps1`: fnm discovery, environment state, and Node command wrappers.
- `10-prompt.ps1`: prompt rendering, project-path logic, async status caches, and background process helpers.
- `25-icons.ps1`: the on-demand Terminal-Icons helper.
- `50-aliases.ps1`: navigation shortcuts, Git aliases, and direct modern CLI wrappers.
- `60-utils.ps1`: Unix-style helper functions.

The following parts load only in an interactive, unredirected `ConsoleHost` session:

- `30-psreadline.ps1`: PSReadLine options, key bindings, and accepted-command tracking.
- `40-completion.ps1`: path completion, interrupt handling, Carapace integration, and Git-aware path completion.

Interactive detection includes an unredirected `pwsh -NoExit -Command ...` session. Redirected command and file sessions remain non-interactive even when `-NoExit` is present.

Each profile part is dot-sourced independently. A missing or failed part produces a warning without preventing later parts from loading.

## Prompt

### Layout

The prompt uses a two-line, powerlevel10k classic-inspired layout:

```text
<path> <git>                                      <toolchains> <duration>
❯
```

The first line keeps the current path and Git context on the left. Project toolchain versions and command duration are aligned on the right when the terminal is wide enough. Narrow terminals drop the right side before sacrificing the path or Git state.

The second-line arrow is green after a successful command and red after a failed or cancelled command. Prompt rendering preserves the caller's `LASTEXITCODE`.

### Symbol Sets

The default `classic` symbol set uses Nerd Font glyphs and Powerline separators. It preserves the intended p10k-style appearance.

For a plain-text session:

```powershell
$script:LeanPromptSymbolSet = 'ascii'
```

ASCII mode replaces private-use glyphs, including language icons, with readable text. `Test-LeanPromptGlyphs` prints every configured symbol, Unicode codepoint, and terminal cell width for troubleshooting.

### Path Display

Paths are normalized to forward slashes for display. The home directory is represented by `~`.

Project-root discovery recognizes these markers:

- `.git`
- `package.json`
- `go.mod`
- `Cargo.toml`
- `pyproject.toml`
- `.python-version`
- `.node-version`
- `.nvmrc`
- `*.sln`

The search is deliberately bounded and cached briefly. When a project root is found, the prompt preserves meaningful project context while shortening intermediate directories to fit the terminal.

### Git Branch Identity

Branch identity is refreshed synchronously when the current filesystem path changes. This makes the branch name available on the first prompt after `cd`, `Set-Location`, `Push-Location`, `Pop-Location`, or a custom function that changes location.

The profile also requests an immediate branch refresh after commands that can change branch identity, including:

- `git switch`
- `git checkout`
- `git branch -m`, `-M`, or `--move`
- the `g`, `gco`, `gcb`, and `gb` aliases where applicable

Git plumbing is used instead of reading `.git/HEAD` or `.git/refs` directly. This keeps branch detection compatible with both the traditional files ref backend and reftable.

The branch probe preserves these states:

- Attached HEAD: displays the branch name.
- Detached HEAD: displays the short commit hash.
- Unborn branch: displays the initial branch name before the first commit.
- Non-repository directory: displays no Git segment.

Normal attached branches and non-repository directories require one Git process. Detached and unborn states use a second plumbing query only when needed.

### Asynchronous Git Status

The branch name is synchronous, but the expensive working-tree status remains asynchronous. Prompt rendering never runs a synchronous `git status`.

The async updater collects:

- staged files
- modified files
- untracked files
- deleted files
- renamed files
- ahead and behind counts
- stash count
- conflicts
- rebase, merge, cherry-pick, and revert state

The display tokens are:

| Token | Meaning |
|---|---|
| `+N` | Staged files |
| `!N` | Modified files |
| `?N` | Untracked files |
| `xN` | Deleted files |
| `»N` | Renamed files |
| `⇡N` | Commits ahead |
| `⇣N` | Commits behind |
| `≡N` | Stash entries |
| `✖N` | Conflicts |

Operation names such as `rebasing`, `merging`, `cherry-picking`, and `reverting` appear as text.

Status is cached per exact working directory under `$env:LOCALAPPDATA\PowerShell\ProfileCache\AsyncGitStatus`. Positive entries use a short TTL; non-repository entries use a slightly longer negative TTL. A lock file suppresses duplicate updater processes.

When an entry is missing or stale, a hidden `pwsh` process runs the source-controlled updater script. Cache files are published atomically. A filesystem watcher observes the active cache file and asks PSReadLine to redraw the prompt after the new status arrives.

The first prompt in a directory can therefore show the correct branch immediately and add dirty-state details in a later redraw.

### Toolchain Segments

The right prompt can show project-local versions for:

| Toolchain | Marker | Display source |
|---|---|---|
| Node.js | `.node-version` or `.nvmrc` | `node -v` after `fnm use --silent-if-unchanged` |
| Python | `.python-version` | Marker contents |
| Go | `go.mod` | `go` directive |
| Rust | `rust-toolchain.toml` or `rust-toolchain` | Toolchain marker |
| .NET | `global.json` | `sdk.version` |

Toolchain detection runs in a background process and uses a longer cache TTL than Git status. Non-project results are also negatively cached to avoid repeated marker scans.

### Command Duration

PSReadLine records the accepted-line timestamp. The next prompt calculates elapsed time and displays it only when useful:

| Duration | Display |
|---|---|
| Less than 2 seconds | Hidden |
| 2 to 9.9 seconds | Gray, one decimal place |
| 10 to 59.9 seconds | Yellow, one decimal place |
| 60 seconds or more | Red, formatted as minutes and seconds |

## PSReadLine Editing

Interactive sessions use Emacs edit mode with the bell disabled. History duplicates are suppressed, and prefix-history navigation moves the cursor to the end of the recalled line.

History and plugin predictions use the inline view rather than a multi-line list.

### Key Bindings

| Key | Behavior |
|---|---|
| `UpArrow` | Search backward through history using the current prefix |
| `DownArrow` | Search forward through history using the current prefix |
| `Tab` | Open menu completion immediately |
| `Shift+Tab` | Open menu completion or move backward in the active menu |
| `Ctrl+RightArrow` | Accept the next prediction word |
| `Ctrl+W` | Delete backward using `BackwardKillWord` and PSReadLine word delimiters |
| `Ctrl+C` | Cancel the active operation or line while preserving the correct prompt state |

`Ctrl+W` is explicitly rebound after Emacs mode initialization instead of inheriting the default `UnixWordRubout` binding.

### Ctrl+C Behavior

Ctrl+C has separate behavior depending on context:

- During completion, it aborts cooperative work, restores the command buffer to its pre-Tab state, and redraws a failed prompt.
- Inside PSReadLine menu completion, it exits without losing the saved command line.
- Outside completion, it cancels the current line and redraws the prompt arrow in red.
- Ctrl+C already consumed by an interrupted completion transaction is not processed a second time.

The implementation keeps Ctrl+C in PSReadLine's input stream during menu completion. It does not switch Windows console processed-input mode in a way that would steal the key from PSReadLine.

## Completion System

### Completion Routing

The profile wraps `TabExpansion2` and chooses the completion backend from the parsed PowerShell command, parameter metadata, provider, and typed token.

PowerShell parameters confirmed to accept filesystem paths use the fast filesystem backend. This includes common `Path`, `LiteralPath`, `Source`, `SourcePath`, `Destination`, and `DestinationPath` parameters. `Set-Location` and `Push-Location` parameters are restricted to directory candidates.

For native commands, the fast backend is used only when the token is clearly a local path:

- `./` or `../`
- `~/`
- a drive-qualified path
- a local rooted path

Bare native arguments remain with Carapace or the command's default completer so flags, subcommands, refs, package names, and other domain-specific candidates are preserved.

UNC paths, non-filesystem providers, wildcards, quoted expressions, variables, and other complex PowerShell expressions fall back to native completion rather than being guessed.

### Filesystem Matching

Filesystem matching follows these rules:

- Each typed path segment uses case-insensitive prefix matching.
- Results retain their real on-disk case.
- Display paths use `/` even on Windows.
- Directories remain `ProviderContainer` results and end in `/`.
- Files receive a trailing space when they complete the current token.
- Unique intermediate directories can advance automatically to the next segment.
- Ambiguous segments stop at the ambiguous level.
- Substring matching and automatic `-`/`_` interchange are intentionally disabled.

Dot-prefixed entries are shown only when the current segment begins with `.`. Windows Hidden or System entries are omitted for an empty segment but remain available when the user types an explicit prefix.

### Automatic Slash Removal

A slash inserted by directory completion is tracked separately from a slash typed by the user. The automatic slash is removed or replaced when appropriate before:

- another path separator
- Space
- Enter
- `;`, `&`, or `|`

Manually typed separators are never treated as completion-owned text.

### Interruptible Completion

Local enumeration checks for pending console input while it runs. Ctrl+C stops completion silently; another pending key stops the current completion attempt and remains queued for PSReadLine.

Native helpers launched by the completion system use an interruptible process wrapper. The wrapper polls for cancellation and kills the child process tree when necessary instead of waiting indefinitely.

A synchronous third-party completer cannot be forcibly unwound. If Ctrl+C arrives while one is running, the profile restores the saved command buffer after that completer returns.

### Carapace

Carapace provides rich completion for external commands. It is not initialized on the first prompt.

Initialization is attempted:

- once during the first interactive idle period, or
- on the first Tab if idle prewarming has not completed.

Generated completion output is cached under `$env:LOCALAPPDATA\PowerShell\ProfileCache`. A successful cache is reused for the session. Interrupted or failed generation does not publish a partial cache.

Prewarm failure is silent and retryable. If initialization is still unavailable when the user presses Tab, one warning is shown and repeated attempts are suppressed for that session.

### Git-Aware Path Completion

The profile supplements Carapace for these path-oriented Git commands:

- `git add` and `git stage`
- `git restore`
- `git rm`
- `git mv`
- `git clean`
- `git commit`

Candidates are derived from Git status, staged paths, modified paths, tracked paths, or untracked paths as appropriate for the subcommand. Git paths are collected relative to the repository root, preserve real case, and then pass through the same stepwise directory completion rules used by the filesystem backend.

Commands that primarily complete refs or branches, such as checkout-style operations, remain with Carapace.

## Node.js and fnm

If `fnm` is installed, the profile discovers its executable once and maintains a small session state machine: `NotStarted`, `Running`, `Ready`, or `Unavailable`.

In an interactive session, `fnm env --json --resolve-engines=false` starts in a hidden process while the rest of the profile continues loading. The returned environment is applied when ready. PATH entries are merged case-insensitively without duplicating entries that already existed when initialization began.

The following commands are wrapped:

- `node`
- `npm`
- `npx`
- `pnpm`
- `yarn`
- `corepack`

On first use, a wrapper waits for fnm initialization if necessary, applies the environment, checks the current directory for `.node-version` or `.nvmrc`, runs `fnm use --silent-if-unchanged`, and then invokes the real executable with the original arguments.

The prompt performs the same version-file check when changing directories. Repeated prompts in the same versioned directory do not rerun `fnm use`.

Non-interactive sessions do not prewarm fnm. They initialize only if a wrapped Node command is used. A failed prewarm can be retried once on demand, and a persistent failure produces at most one warning per session.

If `fnm` is not installed, this profile part returns without installing the Node wrappers.

## Commands, Aliases, and Helpers

### Directory Listing

These functions call `lsd` directly and always enable icons:

| Command | Behavior |
|---|---|
| `ls`, `l` | Standard listing with directories grouped first |
| `ll` | Long listing |
| `la` | Long listing including hidden entries |
| `lt` | Tree view with depth 2 |

There is intentionally no fallback when `lsd` is missing.

### Navigation

| Command | Destination |
|---|---|
| `..` | Parent directory |
| `...` | Two levels up |
| `....` | Three levels up |
| `mkcd <path>` | Create a directory and enter it |

### Git Aliases

| Alias | Expansion |
|---|---|
| `g` | `git` |
| `gst` | `git status` |
| `gss` | `git status -s` |
| `ga` | `git add` |
| `gaa` | `git add --all` |
| `gco` | `git checkout` |
| `gcb` | `git checkout -b` |
| `gb` | `git branch` |
| `gc` | `git commit` |
| `gcmsg` | `git commit -m` |
| `gca` | `git commit -a` |
| `gp` | `git push` |
| `gl` | `git pull` |
| `gf` | `git fetch` |
| `gd` | `git diff` |
| `gds` | `git diff --staged` |
| `glog` | `git log --oneline --graph --decorate` |
| `gloga` | `git log --oneline --graph --decorate --all` |

All extra arguments are forwarded.

### Modern CLI Wrappers

- `cat` calls `bat --paging=never` and uses the OneHalfDark theme.
- `grep` calls `rg` directly.
- PowerShell's `curl` and `wget` aliases are removed so command resolution can reach real executables.

`lsd`, `bat`, and `rg` are direct dependencies. Their wrappers intentionally fail visibly when the dependency is missing.

### Unix-Style Helpers

| Helper | Behavior |
|---|---|
| `which` | Show the resolved path or command type for each name |
| `whereis` | Show every application, alias, or function matching each name |
| `touch` | Create missing files or update timestamps |
| `head` | Read the first `N` lines from files or pipeline input |
| `tail` | Read the last `N` lines; `-f` follows a file |
| `export` | Set process environment variables from `NAME=value` arguments |
| `env` | Print environment variables as `NAME=value` |
| `open` | Open paths with the Windows default application |
| `xdg-open` | Alias for `open` |
| `df` | Show mounted drive volumes |
| `refreshenv` | Rebuild the process PATH from machine and user registry values |
| `reload` | Refresh PATH and dot-source the installed profile again |
| `icons` | Load Terminal-Icons on demand |

## Dependencies

Required commands:

- PowerShell 7 (`pwsh`)
- Git
- `lsd`
- `bat`
- ripgrep (`rg`)
- `fnm`
- Carapace

Terminal-Icons is optional and loads only when `icons` is called.

The repository intentionally does not require or initialize `zoxide`, `fzf`, or PSFzf.

`packages/winget.ps1` installs the required external tools with exact winget package IDs and stops at the first failed package.

## Installation

Run:

```powershell
.\scripts\install.ps1
```

The installer:

1. Parses the entrypoint and every profile part before touching the destination.
2. Copies the entrypoint and every recursive `*.ps1` file under `profile/profile.d` into a staging directory next to the destination.
3. Parses the staged files again.
4. Moves the current entrypoint and `profile.d` to timestamped backups.
5. Moves the staged `profile.d` and entrypoint into place as a mirrored unit.
6. Rolls back the previous installation if replacement fails.

The active destination is `$PROFILE.CurrentUserCurrentHost` plus a sibling `profile.d` directory. Stale scripts from an older installation do not survive in the active tree.

Use `-NoBackup` to remove permanent backups after a successful installation. Temporary rollback paths are still used during the transaction.

After installation, start a new PowerShell session or run:

```powershell
reload
```

## Runtime Cache

Machine-local runtime data is stored under:

```text
%LOCALAPPDATA%\PowerShell\ProfileCache
```

The cache contains:

- async Git status JSON
- async toolchain status JSON
- lock and temporary files during atomic publication
- generated Carapace completion output

The updater implementation remains in `profile/profile.d/prompt-updaters`; generated cache files are data, not hidden source code.

## Validation

Run the standard validation suite:

```powershell
.\scripts\test-profile.ps1
```

Use more startup samples when comparing performance-sensitive changes:

```powershell
.\scripts\test-profile.ps1 -Runs 20
```

Measure the complete interactive profile from a real, unredirected Windows Terminal:

```powershell
.\scripts\test-profile.ps1 -InteractiveRuns 20
```

Validation covers:

- parser cleanliness for the entrypoint and every recursive profile part
- dependency and maintenance policies
- interactive gating for command, file, redirected, and `-NoExit` sessions
- prompt layout, color, exit status, cache, and async redraw behavior
- attached, detached, unborn, non-repository, files-ref, and reftable Git states
- PSReadLine key bindings and Ctrl+C transactions
- path routing, case preservation, hidden entries, slash handling, and interruption
- Carapace lazy initialization and failure behavior
- Git-aware path completion
- fnm prewarm, retry, environment, and version switching
- installer validation, mirroring, rollback, locking, and backup behavior
- batch and optional interactive startup benchmarks

The batch benchmark launches the repository source profile with `-NoProfile`; it does not accidentally measure a stale installed copy. `MedianMs` is the primary comparison value, while `AverageMs` is reported for context.

## Maintenance Guarantees

The repository tests and agent policy protect these decisions:

- Preserve the p10k classic-inspired prompt appearance unless deliberately changed.
- Keep `ls`, `cat`, and `grep` as direct `lsd`, `bat`, and `rg` integrations without fallback implementations.
- Keep interactive-only code out of redirected and ordinary batch sessions.
- Keep async updater scripts readable and source-controlled.
- Use Git plumbing for ref identity instead of parsing Git internal files.
- Keep recursively installed profile parts under `profile/profile.d`.
- Measure startup before and after performance-sensitive changes.
- Do not reintroduce `zoxide`, `fzf`, or PSFzf unless explicitly requested.
