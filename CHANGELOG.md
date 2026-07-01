# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Both implementations — `statusline.sh` (Bash) and `statusline.ps1` (PowerShell) — are
functional mirrors; every entry below applies to both unless noted.

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
- **PowerShell reset times** render 24-hour, capitalized, invariant-culture
  (`14:30` / `Mon@14:30` / `Jul 1`) to match the Bash strftime output, instead of
  12-hour lowercase am/pm.
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
