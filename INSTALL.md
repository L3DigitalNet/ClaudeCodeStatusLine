# Installation

This document is the authoritative install guide.

## 1. Detect the operating system

- **macOS, Linux, WSL, or Windows with Git Bash** → use `statusline.sh`, or `statuslinepy` when the Python runtime below is installed
- **Windows through PowerShell or CMD** → use `statusline.ps1`

Git Bash can also invoke the PowerShell implementation; choose the Bash implementation when its `jq` dependency is available.

## 2. Clone the repo

Clone to `~/.claude/statusline/` on Unix, or `%USERPROFILE%\.claude\statusline\` on Windows. If that directory already exists and is a git clone of this repo, update it with the fast-forward-only command in [Updating](#updating) instead of re-cloning.

### macOS / Linux clone

```bash
git clone https://github.com/chrisdpurcell/ClaudeCodeStatusLine ~/.claude/statusline
chmod +x ~/.claude/statusline/statusline.sh ~/.claude/statusline/statuslinepy ~/.claude/statusline/statuslinepy-sub
```

To use the Python implementation, install its pinned dependencies into the `python3` interpreter that will run `statuslinepy`, then verify both imports:

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
{ "statusLine": { "type": "command", "command": "~/.claude/statusline/statusline.sh" } }
```

For the Python implementation, use its extensionless executable instead:

```json
{ "statusLine": { "type": "command", "command": "~/.claude/statusline/statuslinepy" } }
```

To enable the subagent status line with Python, configure `subagentStatusLine` (preserving any pre-existing custom `subagentStatusLine` setting if present):

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

No `settings.json` changes are needed — the command paths are stable across `main` updates.

## Uninstalling

1. Remove `statusLine` from `settings.json`. Remove `subagentStatusLine` only if its command points to `~/.claude/statusline/statuslinepy-sub`.
2. Delete the clone: `rm -rf ~/.claude/statusline` (or the Windows equivalent).

## Requirements

- Claude Code (Pro/Max subscription for rate-limit and extra-usage display)
- Bash implementation (macOS / Linux): `jq` and `curl`
- Python implementation: `curl`, Python 3.10.7 or newer, and the exact Rich and Humanize versions in `requirements.txt`; `jq` is not required
- Windows: PowerShell 5.1+ (default on Windows 10/11)
- `git` in `PATH` (needed to clone or update; optional at runtime, where it enables `@branch` annotations)

To use the Bash implementation, install `jq` with the system package manager (`brew install jq`, `apt install jq`, etc.).
