# Claude Code API and status-line changes since v1.8.2

Last verified: 2026-07-31

This reference records Claude Code changes since ClaudeCodeStatusLine v1.8.2, the last functional script update on 2026-07-05. The comparison baseline is Claude Code v2.1.201, the latest client represented in the repository at that point; the current comparison target is v2.1.220, released 2026-07-25.

The conclusions distinguish documented contracts from internal implementation details and upstream bug reports:

- **Documented:** supported by the official status-line contract or release notes.
- **Locally verified:** observed by comparing the official v2.1.201 and v2.1.220 Linux client artifacts. This proves that a marker ships in those clients, not that Anthropic supports it as a public API.
- **Upstream report:** reproducible evidence in the Anthropic Claude Code issue tracker, but not a documented compatibility guarantee.

## Executive summary

- No documented breaking change was found in the main `statusLine` stdin JSON.
- The substantial new capability is richer `subagentStatusLine` data: per-task model and context size in v2.1.205+, and per-task effort in v2.1.214+.
- An open upstream regression can report a 1M-context session as 200k and peg `used_percentage` at 100%. Both current scripts trust those values and can therefore render confidently incorrect context usage.
- Claude Code still contains the internal `/api/oauth/usage` path and `oauth-2025-04-20` beta marker. No replacement or schema migration was found, but the endpoint remains undocumented and aggressively rate-limited.
- Claude Code still exposes only generic five-hour and seven-day rate limits to the main status line. Model-scoped windows and `extra_usage` remain internal.
- Opus 5 is a new display/test case, not a schema break. The current scripts' dynamic model name and context-size handling should accommodate it when Claude Code reports the correct values.

## Confirmed changes after the baseline

- **v2.1.205:** `subagentStatusLine` tasks gained resolved `model` and `contextWindowSize`. A separate renderer can show the actual model and compute `tokenCount / contextWindowSize`. Both fields may be absent while the model is unresolved.
- **v2.1.208:** `/usage` now preserves last-known usage bars and adds an "as of" note when the usage endpoint is rate-limited. Adopt the same honesty pattern for the local OAuth cache: retain the last valid payload, record its age, and indicate staleness.
- **v2.1.211:** `/clear` now resets `cost.total_cost_usd` to zero. Native session cost became more accurate after `/clear`, although other open cost defects remain.
- **v2.1.211:** Shared-credential handling was fixed so parallel sessions no longer all log out together after wake. Credential state is live and shared; read it only when a fetch is necessary and retain the last valid usage payload across transient reads.
- **v2.1.214:** Per-task reasoning `effort` was added to `subagentStatusLine`. Render effort only when present. An absent value means inherited or unavailable and must not be guessed from the main session.
- **v2.1.214:** Stale feature flags after OAuth token rotation were fixed. Do not cache access tokens independently of Claude Code's credential store.
- **v2.1.216:** The custom status-line command no longer runs twice when resuming a session. This reduces duplicate work and endpoint pressure; no local workaround is required.
- **v2.1.217:** Built-in PR footer links gained more reliable SSH/tmux hyperlink detection. Custom OSC 8 links remain possible, but the local visible-width functions must strip OSC 8 framing before links can be added safely.
- **v2.1.219:** Claude Opus 5 became the default Opus model, with a 1M context option and fast mode. Add Opus 5, 1M-context, and fast-mode fixtures. Do not hardcode a closed model enumeration.
- **v2.1.220:** General bug fixes and reliability improvements; no status-line contract change was announced. This is the current research target.

Official references: [status-line documentation], [Claude Code changelog], and [v2.1.220 release].

## Main `statusLine` contract

An exact local string comparison of the official v2.1.201 and v2.1.220 Linux artifacts found all of these markers in both versions:

- Context-window size, current usage, total input/output tokens, used and remaining percentages, and `exceeds_200k_tokens`
- `session_id`, `session_name`, `prompt_id`, and `transcript_path`
- Workspace, repository, PR, linked-worktree, and `--worktree` data
- Cost, duration, lines added, and lines removed
- `fast_mode`, main-session effort, thinking, Vim mode, agent name, and output style
- Generic five-hour and seven-day rate limits
- `refreshInterval`, `hideVimModeIndicator`, and `subagentStatusLine`

No new documented main-status field was found after the baseline. The current official schema contains:

```text
model
cwd, workspace, version, output_style
cost, context_window, exceeds_200k_tokens
fast_mode, effort, thinking, rate_limits
session_id, session_name, prompt_id, transcript_path
vim, agent, pr, worktree
```

The current scripts consume only the subset needed for their existing two-row grid: model, context, effort, thinking, version, worktree/cwd, generic rate limits, and selected fields from the internal usage endpoint.

### Capabilities that are available but not new

These features predate v1.8.2. They remain legitimate candidates, but should not be described as newly added by Claude Code:

- `fast_mode` can provide a compact marker, especially for Opus 5. It is distinct from reasoning effort and extra-usage credits.
- `session_name` can provide human-readable session identity, but may be absent when no custom or AI-generated title exists.
- `workspace.repo.*` and `pr.*` can provide repository and PR status, including an optional clickable link. PR discovery is asynchronous, so fields may be absent.
- `workspace.git_worktree` detects any linked Git worktree. It is broader than `worktree.*`, which applies only to `--worktree` sessions.
- `agent.name` identifies the active configured agent, but not every currently viewed subagent.
- `vim.mode` supports a custom Vim indicator. Pair it with `hideVimModeIndicator: true` to avoid duplicate UI.
- `cost.*` supplies session cost, duration, API wait, and diff counts. Cost is estimated and has unresolved correctness reports.
- `COLUMNS` and `LINES` support width-aware layout tiers, but a terminal resize does not itself trigger a rerender.
- `refreshInterval` refreshes time- or git-dependent data while idle. Its minimum is one second, so it multiplies subprocess work across concurrent sessions.

## New `subagentStatusLine` capability

`subagentStatusLine` is a separate settings entry and execution protocol. It does not extend the main two-row status line automatically.

Claude Code sends one JSON batch containing the available terminal width and a `tasks` array. Relevant task fields include:

```text
id, name, type, status, description, label
startTime, model, effort
contextWindowSize, tokenCount, tokenSamples
cwd
```

The command returns one JSON line per visible task:

```json
{ "id": "task-id", "content": "rendered task row" }
```

Version constraints:

- `model` and `contextWindowSize` require Claude Code v2.1.205 or later.
- `effort` requires v2.1.214 or later and is absent when inherited.
- Every optional field must degrade independently so one unresolved task does not blank the entire row.

Recommended first design:

```text
task/status | model effort | tokens/context | elapsed
```

Implementation requirements:

- Create Bash and PowerShell mirrors, matching the repository's parity rule.
- Use the batch's `columns` value instead of `stty` or `tput`.
- Sanitize task-controlled text, including C0, DEL, C1, SGR, and OSC sequences.
- Avoid per-row Git or model subprocesses; parse the batch once.
- Preserve any existing user `subagentStatusLine` setting during installation.
- Benchmark concurrent renders on Windows before recommending PowerShell 5.1.

## Current compatibility and correctness risks

### 1M context can be reported as 200k

An open Anthropic issue captured a Fable 5 session operating with more than 357k input tokens while status-line stdin reported:

```json
{ "context_window_size": 200000, "used_percentage": 100 }
```

The issue remains open, and no release through v2.1.220 announces a fix. The official contract says extended-context models should report `1000000`.

The current Bash and PowerShell implementations prefer the supplied `used_percentage` and display the supplied denominator, so this payload becomes approximately `357k/200k 100%`.

A defensive implementation should:

1. Detect when calculated current tokens or `total_input_tokens` exceed the reported `context_window_size`.
2. Stop treating the denominator and precomputed percentage as authoritative.
3. Use an explicit 1M model label when Claude Code supplies one.
4. Otherwise render an unknown denominator, such as `357k/?`, instead of hardcoding every instance of a model to 1M. Context availability can vary by model alias, plan, provider, and feature entitlement.

Source: [1M-context status-line regression].

### The OAuth usage endpoint remains internal

Both v2.1.201 and v2.1.220 contain these locally verified markers:

```text
/api/oauth/usage
oauth-2025-04-20
extra_usage
model_scoped
weekly_scoped
seven_day_overage_included
```

No post-v1.8.2 endpoint, header, or response-schema migration was found. This does not make the endpoint supported: it is absent from Anthropic's public API documentation and can change without notice.

The main status-line contract still forwards only:

```text
rate_limits.five_hour
rate_limits.seven_day
```

It does not forward `model_scoped`, Fable/Opus/Sonnet weekly buckets, or `extra_usage`. Multiple open upstream requests explicitly ask Anthropic to move those values into stdin so custom status lines no longer need to read OAuth credentials: [model-scoped request #77846], [request #79022], and [model-scoped plus extra-usage request #82656].

Migration rule: when Anthropic documents and ships those stdin fields, prefer them and retire direct OAuth credential access. Do not add a second internal control-request or `.claude.json` dependency as an interim workaround.

### Usage metadata is account-wide and rate-limited

Claude Code v2.1.208 acknowledges usage-endpoint throttling by retaining last-known data. A detailed upstream report describes 10–15 concurrent sessions receiving account-wide HTTP 429 responses with `Retry-After` values around 500–700 seconds while inference continued normally.

The current scripts share a per-`CLAUDE_CONFIG_DIR` fetch stamp, which prevents their own panes from starting identical requests simultaneously. They still retry after a fixed 60 seconds and cannot coordinate with Claude Code's own pollers.

Recommended cache behavior:

- Capture the HTTP status and positive `Retry-After` value.
- Persist a shared next-attempt timestamp.
- Use bounded exponential backoff when the endpoint provides no usable delay.
- Never interpret a metadata 429 as plan exhaustion.
- Retain the last valid response and expose its age.
- Validate cached JSON before rendering it.
- Replace a successful cache write interruption-safely; Claude Code cancels an in-flight renderer when a newer status update arrives.

Source: [concurrent usage-polling report].

### Credential scope and rotation

Official authentication documentation still describes macOS Keychain storage, Linux `~/.claude/.credentials.json` mode `0600`, the Windows credentials file, and `CLAUDE_CONFIG_DIR` relocation. No storage migration was found.

`CLAUDE_CODE_OAUTH_TOKEN` takes precedence over stored credentials and can be generated with `claude setup-token`. Open reports indicate that these long-lived inference tokens can lack the profile scope required by `/api/oauth/usage`. Treat HTTP 403 as an unsupported token scope, not necessarily an invalid login. Generic stdin `rate_limits` may remain available while endpoint-only Fable or extra-usage data is not.

Sources: [authentication documentation], [setup-token scope report], and [usage-read scope request].

### Cost data is not yet a strong default feature

Claude Code v2.1.211 fixed cost not resetting after `/clear`, but open reports still describe:

- Cost and duration resetting after entering and leaving the agents view
- Fable session cost being undercounted
- Currency labels showing `$` for some non-USD accounts

If added, cost should be opt-in, labeled as an estimate, and kept distinct from monthly extra-usage credits. Sources: [agents-view cost reset], [Fable cost report], and [currency-label report].

### Upstream rendering limitations

These are Claude Code defects or constraints rather than fixes for this repository:

- Custom output can disappear after an assistant response in Windows/VS Code even while the command continues to run: [Windows render issue].
- Fullscreen TUI mode can suppress a custom status line: [fullscreen issue].
- A reported macOS regression can silently fall back to the default status line: [macOS fallback issue].
- Windows paths containing backslashes can be mangled when Git Bash executes the command. The repository's forward-slash `~/.claude/...` installation paths avoid the reported form: [Windows path issue].
- Enterprise `allowManagedHooksOnly` or `disableAllHooks` policy can disable custom status lines: [managed-hooks issue].
- A terminal resize does not trigger a rerender: [resize-trigger request].

## Prioritized capability backlog

- **P0 — Detect inconsistent context-window payloads.** Prevent a known, confidently wrong display on 1M sessions.
- **P0 — Add a retry-aware usage cache with stale age.** Reduce account-wide metadata pressure and make fallback state honest.
- **P1 — Add opt-in Bash and PowerShell `subagentStatusLine` scripts.** Use the genuinely new per-task model, context, and effort data.
- **P1 — Render model-scoped limits dynamically.** Accommodate future models without hardcoded names. Keep this behind the isolated internal endpoint until stdin supports it.
- **P2 — Add adaptive width tiers.** Use official width channels and preserve identity/context before lower-priority cells.
- **P2 — Add optional session, PR, repository, and fast-mode cells.** Use stable, zero-network stdin data that already exists.
- **P2 — Add OSC 8 links.** Enable PR/repository navigation after visible-width handling supports OSC framing.
- **P3 — Add estimated session cost and duration.** Treat them as optional because upstream correctness defects remain open.
- **P3 — Add quota depletion forecasting.** Keep it experimental; stale timestamps are initially more reliable than projected exhaustion.

## Public Claude API impact

ClaudeCodeStatusLine does not call the public Messages or Models APIs. Public Claude Platform changes after 2026-07-05 therefore do not require a code change. Opus 5 affects the displayed model and context test matrix, but not the request protocol used by this repository.

The only Anthropic network dependency in the scripts is the undocumented OAuth usage endpoint. The other external request is GitHub's public latest-release API for the optional update check.

## Sources

### Official documentation and releases

- [Status-line documentation][status-line documentation]
- [Authentication documentation][authentication documentation]
- [Claude Code changelog][Claude Code changelog]
- [Claude Platform release notes]
- [v2.1.205 release]
- [v2.1.208 release]
- [v2.1.211 release]
- [v2.1.214 release]
- [v2.1.216 release]
- [v2.1.217 release]
- [v2.1.219 release]
- [v2.1.220 release]

### Upstream issues and requests

- [1M-context status-line regression]
- [model-scoped request #77846]
- [request #79022]
- [model-scoped plus extra-usage request #82656]
- [concurrent usage-polling report]
- [setup-token scope report]
- [usage-read scope request]
- [agents-view cost reset]
- [Fable cost report]
- [currency-label report]
- [Windows render issue]
- [fullscreen issue]
- [macOS fallback issue]
- [Windows path issue]
- [managed-hooks issue]
- [resize-trigger request]

[status-line documentation]: https://code.claude.com/docs/en/statusline
[authentication documentation]: https://code.claude.com/docs/en/authentication
[Claude Code changelog]: https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md
[Claude Platform release notes]: https://platform.claude.com/docs/en/release-notes/overview
[v2.1.205 release]: https://github.com/anthropics/claude-code/releases/tag/v2.1.205
[v2.1.208 release]: https://github.com/anthropics/claude-code/releases/tag/v2.1.208
[v2.1.211 release]: https://github.com/anthropics/claude-code/releases/tag/v2.1.211
[v2.1.214 release]: https://github.com/anthropics/claude-code/releases/tag/v2.1.214
[v2.1.216 release]: https://github.com/anthropics/claude-code/releases/tag/v2.1.216
[v2.1.217 release]: https://github.com/anthropics/claude-code/releases/tag/v2.1.217
[v2.1.219 release]: https://github.com/anthropics/claude-code/releases/tag/v2.1.219
[v2.1.220 release]: https://github.com/anthropics/claude-code/releases/tag/v2.1.220
[1M-context status-line regression]: https://github.com/anthropics/claude-code/issues/76751
[model-scoped request #77846]: https://github.com/anthropics/claude-code/issues/77846
[request #79022]: https://github.com/anthropics/claude-code/issues/79022
[model-scoped plus extra-usage request #82656]: https://github.com/anthropics/claude-code/issues/82656
[concurrent usage-polling report]: https://github.com/anthropics/claude-code/issues/77477
[setup-token scope report]: https://github.com/anthropics/claude-code/issues/79360
[usage-read scope request]: https://github.com/anthropics/claude-code/issues/81015
[agents-view cost reset]: https://github.com/anthropics/claude-code/issues/77970
[Fable cost report]: https://github.com/anthropics/claude-code/issues/77373
[currency-label report]: https://github.com/anthropics/claude-code/issues/75621
[Windows render issue]: https://github.com/anthropics/claude-code/issues/76051
[fullscreen issue]: https://github.com/anthropics/claude-code/issues/76411
[macOS fallback issue]: https://github.com/anthropics/claude-code/issues/79433
[Windows path issue]: https://github.com/anthropics/claude-code/issues/79236
[managed-hooks issue]: https://github.com/anthropics/claude-code/issues/74925
[resize-trigger request]: https://github.com/anthropics/claude-code/issues/76988
