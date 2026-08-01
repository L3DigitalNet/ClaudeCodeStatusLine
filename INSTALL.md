# Installation

This document is the authoritative install guide. It is written to be executed step-by-step by Claude Code when a user asks to install or update this status line.

## 1. Detect the operating system

- **macOS, Linux, or WSL** → use `statusline.sh`, or `statuslinepy` when the Python runtime below is installed (WSL is a real Linux userland)
- **Windows-native shells** (PowerShell, CMD, Git Bash) → use `statusline.ps1`

## 2. Clone the repo

Clone to `~/.claude/statusline/` on Unix, or `%USERPROFILE%\.claude\statusline\` on Windows. If that directory already exists and is a git clone of this repo, run `git pull` in it instead of re-cloning.

**macOS / Linux**

```bash
git clone https://github.com/chrisdpurcell/ClaudeCodeStatusLine ~/.claude/statusline
chmod +x ~/.claude/statusline/statusline.sh ~/.claude/statusline/statuslinepy ~/.claude/statusline/statuslinepy-sub
```

To use the Python implementation, install its pinned dependencies into the `python3` interpreter, then verify both imports:

```bash
python3 -m pip install --user -r ~/.claude/statusline/requirements.txt
python3 -c 'import humanize, rich'
```

**Windows (PowerShell)**

```powershell
git clone https://github.com/chrisdpurcell/ClaudeCodeStatusLine "$env:USERPROFILE\.claude\statusline"
```

## 3. Configure `settings.json`

Add (or update) the `statusLine` key in `~/.claude/settings.json` (Unix) or `%USERPROFILE%\.claude\settings.json` (Windows). Merge with existing keys — preserve pre-existing settings and do not overwrite unrelated keys.

**macOS / Linux**

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

**Windows**

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
> `~` is expanded by Claude Code v2.1.47+ on both Unix and Windows. On older Claude Code versions, replace `~/.claude/statusline/statusline.ps1` with `%USERPROFILE%\.claude\statusline\statusline.ps1` (CMD / PowerShell) or `$USERPROFILE\.claude\statusline\statusline.ps1` (Git Bash / WSL).

## 4. Restart Claude Code

The status line is loaded at startup. After saving `settings.json`, tell the user to restart Claude Code (or start a new session) for the change to take effect.

## Updating

Pull the latest release:

```bash
git -C ~/.claude/statusline pull
```

No `settings.json` changes are needed — the command paths are stable across versions.

## Uninstalling

1. Remove `statusLine` from `settings.json`. Remove `subagentStatusLine` only if its command points to `~/.claude/statusline/statuslinepy-sub`.
2. Delete the clone: `rm -rf ~/.claude/statusline` (or the Windows equivalent).

## Requirements

- Claude Code (Pro/Max subscription for rate-limit and extra-usage display)
- Bash implementation (macOS / Linux): `jq` and `curl`
- Python implementation: `curl`, `python3` 3.10+, and the exact Rich and Humanize versions in `requirements.txt`; `jq` is not required
- Windows: PowerShell 5.1+ (default on Windows 10/11)
- `git` in `PATH` (optional — enables `@branch` annotations)

To use the Bash implementation, install `jq` with the system package manager (`brew install jq`, `apt install jq`, etc.).
