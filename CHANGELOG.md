# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Both implementations — `statusline.sh` (Bash) and `statusline.ps1` (PowerShell) — are
functional mirrors; every entry below applies to both unless noted.

## [1.6.0] - 2026-07-02

The status line now renders as two lines instead of one, making it readable on narrower
terminals. Colors are unchanged.

### Changed
- **Two-line grid layout:** the segments are arranged in two rows of pipe-separated
  cells, and the pipes align vertically. Each column is as wide as the wider of its
  two cells (content-based; no terminal-width detection).

  ```text
  Sonnet 5 ✦ high | 435k/1M 44%  | 5h  4%    @16:40 | +12 | ClaudeCodeStatusLine@main
  v2.1.198        | extra $0/$25 | 7d 12% Sun@19:00 | -3  | my-worktree
  ```

  Row 1: model with the ✦ thinking marker and effort level (one fused cell), tokens,
  5-hour usage, lines added, cwd@branch. Row 2: CLI version, extra usage, 7-day usage,
  lines removed, worktree. Cells with no data render a dim `-` so the grid stays
  aligned; the cwd cell is simply omitted when Claude Code supplies no working
  directory.
- **Context percentage loses its parentheses:** `435k/1M 44%` instead of
  `435k/1M (44%)`; the green percent is differentiation enough.
- **Line changes get their own column:** the unstaged `(+N -M)` suffix that rode inside
  the cwd cell is now a stacked column of its own (green `+added` over red `-removed`,
  no parentheses). As before, it appears only while the tree is dirty.
- **Thinking marker position:** the `✦` now sits between the model name and the effort
  word (`Sonnet 5 ✦ high`); previously it was appended after the effort word.
- **5h/7d internal alignment:** the two usage cells right-align their percentages and
  stack their `@` reset markers, so `4%` sits under `12%` and `@16:40` under
  `Sun@19:00`.
- **Extra usage is always visible when enabled:** the cell shows dollar figures
  whenever the account has extra usage enabled, including a `$0` month (previously the
  segment was hidden until something was spent). It shows a dim `-` when extra usage
  is disabled or no API data is available.
- **Whole-dollar amounts drop the cents:** `$0/$25` instead of `$0.00/$25.00`;
  fractional amounts keep two decimals (`$3.50`).
- **Version cell placeholder:** when the CLI version cannot be determined, the cell
  renders a dim `-` instead of disappearing.

### Added
- **Worktree segment:** row 2 ends with the worktree name when the session runs in a
  Claude Code `--worktree` isolation session (stdin `worktree.name`), and a dim `-`
  otherwise.

### Fixed
- **Locale-independent ✦ width (Bash):** under a C/POSIX locale the ✦ thinking marker
  was measured as 3 bytes instead of 1 display column, over-padding the first column
  and misaligning the pipes below it. Column widths now count it as a single column
  in any locale. Verified against bash 3.2.57, the version macOS ships.

## [1.5.1] - 2026-07-01

A follow-up review pass on 1.5.0 that closes remaining parity gaps between the two mirrors and fixes a cache-staleness bug found in the review.

### Changed
- **5-hour reset time (Bash):** the built-in 5-hour reset time now tries GNU `date` before BSD `date`, matching the other date paths in the script and avoiding a failed exec per render on Linux.

### Fixed
- **Update-check flag matching (PowerShell):** `STATUSLINE_CHECK_UPDATES=false` matching is now case-sensitive (`-cne`), mirroring Bash's exact-string comparison. Previously `FALSE` or `False` also disabled the update check, but only on Windows.
- **Extra-usage staleness (both):** the built-in `rate_limits` path rewrote the usage cache on every render, which kept resetting the 60-second fetch throttle (mtime-based) without an actual fetch happening, starving the OAuth usage fetch that is the only source of `extra_usage` and leaving the figure frozen during active use. The throttle now lives in a separate fetch-stamp file (`statusline-usage-fetched-<hash>`), touched only by real fetch attempts.
- **Model-name context suffix (Bash, parity):** the `(… context)` normalizer now requires digits plus a `k`/`M` suffix and trims whitespace before collapsing it, matching PowerShell. `(200000 context)` (no unit suffix) is now left verbatim in both mirrors instead of being collapsed by Bash alone.
- **Invariant-culture gaps (PowerShell):** the built-in-path cache's ISO timestamp writes and `[DateTimeOffset]::Parse` now use `InvariantCulture`, so a non-Gregorian default calendar (e.g. `ar-SA`) no longer misformats the timestamp or throws on parse. The effort word is now lowercased with `ToLowerInvariant()` instead of `ToLower()`, closing a Turkish-I mismatch under `tr-TR`.
- **Empty CLI-version cache (PowerShell):** an empty cache file no longer raises a null-method error.
- **Version comparison padding (PowerShell, parity):** single-component release tags are padded before comparison (`v2` → `2.0`), so both mirrors agree on non-three-part release tags.

### Security
- **Cache location (Bash):** caches moved from the fixed, world-visible `/tmp/claude` to `${XDG_RUNTIME_DIR:-/tmp}/claude` (per-user and mode `0700` on systemd distros, falling back to `/tmp` elsewhere; macOS unchanged, and PowerShell already used the per-user `%TEMP%`).
- **Release-tag sanitization (both):** the update-check release tag is stripped to version characters (`v`, digits, dots) before rendering, so a poisoned version cache can no longer inject terminal escape sequences via `tag_name`.

## [1.5.0] - 2026-07-01

Modernization to the current Claude Code stdin schema, plus a comprehensive review that
aligned the two mirrors and closed several robustness and security gaps.

### Added
- **Extended-thinking marker:** a `✦` fuses onto the effort word when the stdin
  `thinking.enabled` field is true.
- **Version from stdin:** the trailing version block reads the stdin `.version` field
  directly, avoiding a `claude --version` subprocess in the common case (the cached
  shell-out remains as a fallback for older CLIs).
- **`workspace.current_dir`:** the cwd block prefers the now-documented-preferred
  `workspace.current_dir`, falling back to top-level `.cwd`.

### Changed
- **Effort block** moved to second-from-left (immediately after the model) with the
  `effort:` label removed, and joined to the model by a plain space rather than a ` | `
  separator.
- **7-day reset** renders as weekday + 24-hour time, e.g. `Sun@19:00` (dropped the month
  and numeric date).
- **Extra-usage block** is hidden until some extra usage has actually been spent this
  month, and reappears automatically once it has.
- **Context %** prefers Claude Code's precomputed `context_window.used_percentage`,
  falling back to the manual token-sum computation when the field is absent.
- **Usage percentages now floor in both mirrors** (previously Bash rounded to nearest
  while PowerShell floored). This keeps the two scripts identical and prevents a fractional
  value like `89.6` from crossing a color threshold in one script but not the other. It also
  aligns the "is this builtin data trustworthy?" check, so a sub-1% value no longer rounds
  up to a trusted `1%` in Bash while PowerShell treats it as `0`.
- **Reset times are 24-hour and locale-invariant in both mirrors.** PowerShell renders
  `14:30` / `Mon@14:30` / `Jul 1` via `InvariantCulture` (instead of 12-hour lowercase am/pm),
  and Bash pins `LC_ALL=C` on the `%a`/`%b` `date` calls so the weekday/month abbreviations are
  English/capitalized regardless of the host `LC_TIME` locale.
- **Effort word is lowercased** before matching in both scripts, so a non-canonical input
  like `Max` renders identically (previously Bash's `case` was case-sensitive while
  PowerShell's `switch` was not).

### Fixed
- **Token humanisation:** half-up rounding, correct `k`→`M` rollover (`999500`→`1M`, not
  `1000k`), and SI casing (lowercase `k`, uppercase `M`).
- **Extra-usage fallback:** malformed/absent credit values render `extra enabled` instead
  of silently vanishing.
- **Stale User-Agent:** the `/api/oauth/usage` request now sources its client version live
  (stdin `.version` → cached CLI version → constant) instead of a hardcoded value that had
  drifted 160+ releases behind and risked the endpoint's aggressive rate-limit bucket.
- **PowerShell usage cache** is now keyed by a hash of `CLAUDE_CONFIG_DIR` (mirroring Bash),
  so two accounts run under different config dirs no longer share and clobber one cache.
- **PowerShell cache read** requires a non-empty file, so a concurrent pane's 0-byte
  stampede-lock file is no longer trusted as fresh (which had dropped the usage blocks).
- **PowerShell placeholder branch:** when no usage data is available, the line now shows
  `5h - | 7d -` (matching Bash) instead of dropping the blocks entirely; the API-fallback
  branch also requires `.five_hour` before rendering.
- **PowerShell cache poisoning:** an API `200` whose body lacks `.five_hour` (maintenance /
  error JSON) is no longer written to the cache; the last-valid cache is kept.
- **PowerShell locale formatting:** extra-usage dollar figures and the fractional-millions
  token suffix use invariant culture, so comma-decimal locales no longer render `$0,00` /
  `1,2M` (the `$0,00` case had also defeated the zero-hide guard).
- **Output escaping (Bash):** the final line is emitted with `printf '%s'` and colors are
  stored as real escape bytes, so a backslash escape (`\n`, `\t`) inside a JSON-derived
  field (display name, cwd, branch) is printed literally instead of expanding and splitting
  the single line.

### Security
- **OAuth token no longer in `curl` argv (Bash):** the `Authorization` header is passed via
  a curl `--config -` read from stdin (`printf` is a shell builtin, so the token never
  enters any process's argument list), closing a window where `ps` / `/proc/<pid>/cmdline`
  exposed the token to other local users during a request.

## [1.4.4]

Baseline inherited from the upstream project
([daniel3303/ClaudeCodeStatusLine](https://github.com/daniel3303/ClaudeCodeStatusLine))
at the point this fork took over maintenance. See the git history for changes prior to 1.5.0.
