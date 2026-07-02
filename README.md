# Claude Code Status Line

A custom status line for [Claude Code](https://claude.com/claude-code) that displays the model, reasoning effort, token usage, rate limits, reset times, and the installed CLI version in two compact, aligned lines. It runs as an external shell command, so it does not slow down Claude Code or consume any extra tokens.

> **Actively maintained.** This is an independent continuation of [daniel3303/ClaudeCodeStatusLine](https://github.com/daniel3303/ClaudeCodeStatusLine), maintained by [@chrisdpurcell](https://github.com/chrisdpurcell). See the [changelog](CHANGELOG.md) for what's new. **To get notified of updates:** click **Watch → Custom → Releases** at the top of the repo — or leave the built-in update check on, which flags a new release in the status line itself.

## Screenshot

![Status Line Screenshot](screenshot.png)

## What it shows

The status line is a two-line grid. Pipes align vertically, each column sizing itself to the wider of its two cells:

```text
Sonnet 5 ✦ high | 435k/1M (44%) | 5h  4%    @16:40 | ClaudeCodeStatusLine@main
v2.1.198        | extra $0/$25  | 7d 12% Sun@19:00 | my-worktree
```

| Cell | Position | Description |
|------|----------|-------------|
| **Model + Effort** | row 1, col 1 | Model name (a `(1M context)` suffix collapses to `1M`), a `✦` when extended thinking is enabled, and the reasoning effort level (`low`, `med`, `high`, `xhigh`, `max`) |
| **Tokens** | row 1, col 2 | Used / total context-window tokens (% used) |
| **5h** | row 1, col 3 | 5-hour rate-limit usage percentage and reset time |
| **CWD@Branch** | row 1, col 4 | Current folder name, git branch, and unstaged line changes (+/-, tracked files only: staged and untracked changes aren't counted); omitted when Claude Code supplies no working directory |
| **Version** | row 2, col 1 | Installed Claude Code CLI version, or `-` when unknown |
| **Extra** | row 2, col 2 | Extra-usage credits spent / limit whenever extra usage is enabled (whole dollars drop the cents: `$0/$25`); `-` when disabled |
| **7d** | row 2, col 3 | 7-day rate-limit usage percentage and reset time |
| **Worktree** | row 2, col 4 | Worktree name in `--worktree` sessions; `-` otherwise |
| **Update** | line 3 | Appears when a new release is available (checked every 24h) |

Within the 5h/7d column the percentages right-align and the `@` reset markers stack, so the two rows read as one table.

Usage percentages are floored and color-coded: green (&lt;50%) → yellow (≥50%) → orange (≥70%) → red (≥90%).

## Installation

Ask Claude Code:

> Clone https://github.com/chrisdpurcell/ClaudeCodeStatusLine to `~/.claude/statusline/` (or `%USERPROFILE%\.claude\statusline\` on Windows) and configure it as my status bar by following its INSTALL.md.

Claude will clone the repo to that path, pick the right script for your OS, and update `settings.json`. Full step-by-step instructions Claude follows live in [INSTALL.md](INSTALL.md).

Restart Claude Code after Claude saves the configuration.

### Updating

When the status line shows a new release is available, ask Claude:

> Find my installed status bar and update it.

Or update it yourself:

```bash
git -C ~/.claude/statusline pull
```

No `settings.json` changes are needed — the path stays valid across versions.

## Requirements

- Claude Code with OAuth authentication (Pro/Max subscription for rate-limit and extra-usage data)
- `git` in `PATH`
- macOS / Linux: `jq` and `curl`
- Windows: PowerShell 5.1+ (default on Windows 10/11)

## Caching

Usage data from the Anthropic API is cached for 60 seconds at `statusline-usage-cache-<hash>.json`, under `${XDG_RUNTIME_DIR:-/tmp}/claude/` on Linux/macOS (a per-user runtime directory when available, falling back to `/tmp`) or `%TEMP%\claude\...` on Windows. A small fetch-stamp file alongside it tracks the 60-second throttle independently of cache writes. Release checks are cached for 24 hours. All caches are shared across concurrent Claude Code instances to avoid rate limits.

## Update Notifications

The status line checks GitHub for new releases once every 24 hours via an outbound HTTP request to `api.github.com`. When a newer version is available, a second line appears below the status line. The check fails silently if the API is unreachable.

To disable the update check entirely (no network calls), set it to the exact string `false`:

```bash
export STATUSLINE_CHECK_UPDATES=false
```

Any other value, including `0` or `False`, leaves the check enabled.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release history.

## License

MIT — see [LICENSE](LICENSE).

## Credits

Originally created by **Daniel Oliveira** ([@daniel3303](https://github.com/daniel3303/ClaudeCodeStatusLine)). This repository is an independent continuation, now maintained by **Chris Purcell** ([@chrisdpurcell](https://github.com/chrisdpurcell)). Thanks to Daniel for the original work.

[![Website](https://img.shields.io/badge/Website-FF6B6B?style=for-the-badge&logo=safari&logoColor=white)](https://danielapoliveira.com/)
[![X](https://img.shields.io/badge/X-000000?style=for-the-badge&logo=x&logoColor=white)](https://x.com/daniel_not_nerd)
[![LinkedIn](https://img.shields.io/badge/LinkedIn-0077B5?style=for-the-badge&logo=linkedin&logoColor=white)](https://www.linkedin.com/in/daniel-ap-oliveira/)
