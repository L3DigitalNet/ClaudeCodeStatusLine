# Installation

This document is the authoritative install guide.

## 1. Detect the operating system

- **macOS, Linux, or WSL** → use `statuslinepy`, the Python implementation.
- **Windows through PowerShell or CMD** → use `statusline.ps1`.
- **Windows with Git Bash** → use `statuslinepy` when Python 3.10.7+ is installed. Otherwise use `statusline.ps1`, which Git Bash can also run.

> `statusline.sh` and `statusline` in this repository are **not** Claude Code status lines. They render the footer of a different CLI, so do not configure either one in `settings.json`. Until 2026-08-02, `statusline.sh` was the Bash implementation of this status line. That version has been removed; see [Migrating from `statusline.sh`](#migrating-from-statuslinesh).

## 2. Clone the repo

Clone to `~/.claude/statusline/` on Unix, or `%USERPROFILE%\.claude\statusline\` on Windows. If that directory already exists and is a git clone of this repo, update it with the fast-forward-only command in [Updating](#updating) instead of re-cloning.

### macOS / Linux clone

```bash
git clone https://github.com/chrisdpurcell/ClaudeCodeStatusLine ~/.claude/statusline
chmod +x ~/.claude/statusline/statuslinepy ~/.claude/statusline/statuslinepy-sub
```

Install the pinned dependencies into the `python3` interpreter that will run `statuslinepy` (the first `python3` on `PATH`, because the script starts with `#!/usr/bin/env python3`). Then verify both imports:

```bash
python3 -m pip install --user -r ~/.claude/statusline/requirements.txt
python3 -c 'import humanize, rich'
```

### Windows PowerShell clone

```powershell
git clone https://github.com/chrisdpurcell/ClaudeCodeStatusLine "$env:USERPROFILE\.claude\statusline"
```

## 3. Configure `settings.json`

Add (or update) the `statusLine` key in `~/.claude/settings.json` (Unix) or `%USERPROFILE%\.claude\settings.json` (Windows). Merge with existing keys — preserve pre-existing settings and do not overwrite unrelated keys.

### macOS / Linux settings

```json
{ "statusLine": { "type": "command", "command": "~/.claude/statusline/statuslinepy" } }
```

If the dependencies are installed in a different interpreter than the first `python3` on `PATH`, name that interpreter explicitly, for example `"command": "/usr/bin/python3 ~/.claude/statusline/statuslinepy"`.

To also enable the subagent status line, configure `subagentStatusLine` (preserving any pre-existing custom `subagentStatusLine` setting if present):

```json
{
	"statusLine": { "type": "command", "command": "~/.claude/statusline/statuslinepy" },
	"subagentStatusLine": {
		"type": "command",
		"command": "~/.claude/statusline/statuslinepy-sub"
	}
}
```

### Windows settings

```json
{
	"statusLine": {
		"type": "command",
		"command": "pwsh -NoProfile -ExecutionPolicy Bypass -File ~/.claude/statusline/statusline.ps1"
	}
}
```

If PowerShell 7+ (`pwsh`) is not installed, fall back to Windows PowerShell 5.1:

```json
{
	"statusLine": {
		"type": "command",
		"command": "powershell -NoProfile -ExecutionPolicy Bypass -File ~/.claude/statusline/statusline.ps1"
	}
}
```

> `-ExecutionPolicy Bypass` is **process-scoped** — it does not change your machine's PowerShell policy. Without it, a default `Restricted` or `AllSigned` policy (common on locked-down corporate machines) silently rejects the unsigned script and Claude Code shows no status line with no error.
>
> If `~` does not resolve in your installation, use an absolute path. On Windows, use a forward-slash path such as `C:/Users/your-name/.claude/statusline/statusline.ps1`, which works from both Git Bash and PowerShell.

## 4. Restart Claude Code

After saving `settings.json`, start a new session or restart Claude Code if the configuration does not reload immediately.

## Updating

Update the installed clone to the latest commit on `main`:

```bash
git -C ~/.claude/statusline pull --ff-only origin main
```

On Windows PowerShell, use:

```powershell
git -C "$env:USERPROFILE\.claude\statusline" pull --ff-only origin main
```

No `settings.json` changes are needed when your command already points at `statuslinepy`, `statuslinepy-sub`, or `statusline.ps1`.

### Migrating from `statusline.sh`

If `statusLine.command` still points at `~/.claude/statusline/statusline.sh`, you are no longer running this status line: since 2026-08-02 that file renders a different CLI's footer, which shows `idle` and 0% usage under Claude Code. To migrate:

1. Install the Python dependencies as described in [macOS / Linux clone](#macos--linux-clone).
2. Change `statusLine.command` to `~/.claude/statusline/statuslinepy`.

## Uninstalling

1. Remove `statusLine` from `settings.json`. Remove `subagentStatusLine` only if its command points to `~/.claude/statusline/statuslinepy-sub`.
2. Delete the clone: `rm -rf ~/.claude/statusline` (or the Windows equivalent).

## Requirements

- Claude Code (Pro/Max subscription for rate-limit and extra-usage display)
- macOS / Linux / WSL (`statuslinepy`): `curl`, Python 3.10.7 or newer, and the exact Rich and Humanize versions in `requirements.txt`
- Windows (`statusline.ps1`): PowerShell 5.1+ (default on Windows 10/11)
- `git` in `PATH` (needed to clone or update; optional at runtime, where it enables `@branch` annotations)
