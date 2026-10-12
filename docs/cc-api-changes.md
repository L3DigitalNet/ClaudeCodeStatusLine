# Claude Code API and status-line changes since v1.8.2

Last verified: 2026-10-12

This reference records Claude Code changes since ClaudeCodeStatusLine v1.8.2, the last functional script update on 2026-07-05. The comparison baseline is Claude Code v2.1.201, the latest client represented in the repository at that point. The first research pass (2026-07-31) covered changes through v2.1.220, released 2026-07-25. The second pass (2026-10-12) covers v2.1.221 through v2.1.296, released 2026-10-09, which is the current comparison target.

The conclusions distinguish documented contracts from internal implementation details and upstream bug reports:

- **Documented:** supported by the official status-line contract or release notes.
- **Locally verified:** observed in the official v2.1.201, v2.1.220, and v2.1.296 Linux client artifacts. This proves that a marker ships in those clients, not that Anthropic supports it as a public API.
- **Upstream report:** reproducible evidence in the Anthropic Claude Code issue tracker, but not a documented compatibility guarantee.

## Executive summary

- No documented breaking change was found in the main `statusLine` stdin JSON through v2.1.296. Every change is additive, and the current scripts ignore the new fields safely.
- The main status line gained two documented additions: a `prompt_cache` object (v2.1.251, extended in v2.1.260) and `rate_limits.spend_limit` for Claude apps gateway users (v2.1.251, dollar fields in v2.1.284). `pr.kind` and GitLab merge-request data were added in v2.1.234.
- `subagentStatusLine` data grew in three steps: per-task model and context size in v2.1.205+, per-task effort in v2.1.213+, and `agentType` in v2.1.293+. `effort` may be a number (a thinking-token budget) as well as a level string.
- Claude Code still exposes only generic five-hour and seven-day rate limits to the main status line (plus gateway `spend_limit`). Model-scoped windows such as Fable weekly, and `extra_usage`, remain available only from the internal `/api/oauth/usage` endpoint. The open tracking request is [#73770]; the earlier requests were closed as duplicates.
- Claude Code v2.1.296 still contains the internal `/api/oauth/usage` path and the `oauth-2025-04-20` beta marker. The `limits[]` shape this repository reads was unchanged in a live response on 2026-10-12. The endpoint remains undocumented and rate-limited. Since v2.1.284, Claude Code backs off its own polling after a 429.
- The 1M-reported-as-200k issue ([#76751]) was closed by the stale bot, not fixed. No release note announces a fix, so the defensive check below is still warranted.
- The model lineup changed: Fable 5.1 (v2.1.257), Opus 5.5 (v2.1.280), Sonnet 5.5 (v2.1.284), and Haiku 5.5 (v2.1.293) are now the defaults, all with 1M context. These are display and test cases, not schema breaks. Fable weekly limits are populated again in the usage endpoint.

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

## Confirmed changes from v2.1.221 through v2.1.296

These entries come from the GitHub release notes for each tag. Some tags have no published release (v2.1.242–244, 253–256, 262, 264, and 279), so their changes could not be checked. Release bodies were filtered by keyword, so an entry that uses none of the status-line, usage, context, credential, model, effort, or worktree terms may be missing.

### Status-line contract

- **v2.1.234 (2026-08-17):** GitLab merge requests populate `pr.number`, `pr.url`, and the new `pr.kind` (`"mr"`).
- **v2.1.239:** Cost estimates, including `cost.total_cost_usd`, include the 1.1× premium for US-only inference in data-residency workspaces.
- **v2.1.246 (2026-08-25):** Status-line cost and duration no longer reset after visiting the agents view. Upstream issue [#77970] remains open.
- **v2.1.251 (2026-08-28):** Added `rate_limits.spend_limit` (`used_percentage`, `resets_at`) for Claude apps gateway users, and a `prompt_cache` object.
- **v2.1.260 (2026-09-03):** `prompt_cache` gained `last_miss_cause` and `miss_causes`. `workspace.repo` now populates for gitlab.com projects in subgroups.
- **v2.1.284 (2026-09-28):** `rate_limits.spend_limit` gained `used_usd`, `limit_usd`, and `period`. These need v2.1.284 on both the client and the gateway.
- **v2.1.293 (2026-10-07):** `subagentStatusLine` tasks gained `agentType`. On Windows, stopping a status-line command can no longer kill an unrelated process that reused its PID.
- **v2.1.295 (2026-10-08):** `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` no longer hides the gateway spend limit.
- **v2.1.296 (2026-10-09):** Sonnet 5.5 cache reads are priced at $0.10 per million tokens in `cost.total_cost_usd` (previously $0.20).

### Usage and rate limits

- **v2.1.236:** `/usage` shows the usage-credits spend row for Team and Enterprise members.
- **v2.1.261:** `/usage` no longer drops the model-specific weekly row while the usage endpoint is rate-limited.
- **v2.1.283:** The weekly Fable limit shows in `/usage` even with telemetry disabled.
- **v2.1.284:** `/usage`, `/extra-usage`, and the IDE usage views back off after the plan-usage endpoint returns a rate-limit or login rejection. Claude Code's own pollers now cooperate with the 429 this repository's fetches can also receive.
- **v2.1.295:** Headless `rate_limit_event` warnings state whether extra usage is enabled.

### Context window

- **v2.1.223:** `CLAUDE_CODE_DISABLE_1M_CONTEXT` holds every native-1M model to 200k.
- **v2.1.247:** Sonnet 5 auto-compacts near its full 1M window (about 967k).
- **v2.1.260, v2.1.271:** Fixed silent drops to 200k: Fable agents ignoring a pinned `[1m]` model tag, and `--resume` losing `[1m]` across model families.
- **v2.1.281:** `/context` includes messages added since the last response, so it can read higher than the status line's `context_window`.
- **v2.1.285, v2.1.287:** Sessions behind a custom `ANTHROPIC_BASE_URL` use 1M where the model supports it. Opus 4.7+ and Fable default to 1M on Bedrock, Vertex, Foundry, and the gateway without a `[1m]` suffix.
- **v2.1.286:** The fallback notice says when a fallback reduced the window from 1M to 200k.

These fixes are related to, but do not confirm a fix for, the 200k misreport described below.

### Models, effort, and thinking

- **v2.1.257 (2026-09-01):** Fable 5.1 (`claude-fable-5-1`, 1M context) became the default Fable.
- **v2.1.280 (2026-09-22):** Opus 5.5 (`claude-opus-5-5`, 1M context) became the default Opus.
- **v2.1.283:** The `/model` picker no longer appends "(1M context)" to Opus rows that already default to 1M. The status line's `model.display_name` may therefore lack the suffix this repository collapses to `1M`, while `context_window.context_window_size` still reports 1M.
- **v2.1.284 (2026-09-28):** Sonnet 5.5 (`claude-sonnet-5-5`, 1M context) became the default Sonnet.
- **v2.1.287:** Selecting Fable in `/model` on a claude.ai login saves an alias that follows the newest Fable.
- **v2.1.293 (2026-10-07):** Haiku 5.5 (`claude-haiku-5-5`, 1M context) became the default Haiku.
- **v2.1.221:** Fixed the thinking toggle having no effect when a session started with thinking off.
- **v2.1.250, v2.1.280:** `/effort` saves a default per model, and launch-default effort no longer overrides `/effort` on Opus 4.7, Opus 4.8, and Fable 5.
- **v2.1.292 (2026-10-06):** The Agent tool accepts an `effort` parameter, so subagent tasks carry an explicit `effort` more often.

### Credentials

The credential fixes below do not change storage locations or the lookup order this repository uses.

- **v2.1.225:** A transient 401 no longer replaces a long-lived `CLAUDE_CODE_OAUTH_TOKEN` with the stored login's short-lived token.
- **v2.1.281, v2.1.286, v2.1.288, v2.1.290:** Several fixes for macOS Keychain writes and a leftover `.credentials.json` file.
- **v2.1.287:** A revoked login reports "OAuth token revoked".

## Main `statusLine` contract

An exact local string comparison of the official v2.1.201 and v2.1.220 Linux artifacts found all of these markers in both versions:

- Context-window size, current usage, total input/output tokens, used and remaining percentages, and `exceeds_200k_tokens`
- `session_id`, `session_name`, `prompt_id`, and `transcript_path`
- Workspace, repository, PR, linked-worktree, and `--worktree` data
- Cost, duration, lines added, and lines removed
- `fast_mode`, main-session effort, thinking, Vim mode, agent name, and output style
- Generic five-hour and seven-day rate limits
- `refreshInterval`, `hideVimModeIndicator`, and `subagentStatusLine`

No new documented main-status field appeared between the baseline and v2.1.220. Between v2.1.221 and v2.1.296, the additions are `prompt_cache`, `rate_limits.spend_limit`, and `pr.kind`. The current official schema, fetched 2026-10-12, contains:

```text
model
cwd, workspace, version, output_style
cost, context_window, exceeds_200k_tokens
fast_mode, effort, thinking, rate_limits
session_id, session_name, prompt_id, transcript_path
vim, agent, pr, worktree
prompt_cache
```

The v2.1.296 payload builder, locally verified, also emits an undocumented `remote.session_id` for remote-control sessions.

### New since v2.1.220

- **`rate_limits.spend_limit`:** Contains `used_percentage`, `resets_at`, and optionally `used_usd`, `limit_usd`, and `period` (`daily`, `weekly`, or `monthly`). It appears only for Claude apps gateway users with a spend limit, after the first API response. The v2.1.296 client emits the dollar fields only when the gateway reports USD. `rate_limits` can now appear for gateway users as well as Pro/Max subscribers. The current scripts read only `five_hour` and `seven_day`, so the new key is ignored.
- **`prompt_cache`:** Contains `warm`, `caching_observed`, `ttl`, `expires_at` (epoch seconds), `requests`, `misses`, `expected_rebuilds`, `hit_ratio`, `cache_write_tokens`, `miss_recache_tokens`, `last_miss_at`, `last_miss_cause`, `miss_causes`, and `recache_tokens_if_cold`. The object is absent until the session has made an API request.
- **`pr.kind` and GitLab data:** `pr.kind` is `"mr"` for GitLab merge requests. `pr.review_state` was already present.
- **Idle rerender at reset times:** Locally verified in v2.1.296, Claude Code schedules a rerender at the earliest of `rate_limits.*.resets_at` and, while warm, `prompt_cache.expires_at`. Reset countdowns and cache-warmth indicators therefore refresh without `refreshInterval`.

The `statusLine` settings keys are unchanged: `type`, `command`, `padding`, `refreshInterval`, and `hideVimModeIndicator`. The documentation now notes that changing `command` bypasses the 300 ms debounce.

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
id, name, type, agentType, status, description, label
startTime, model, effort
contextWindowSize, tokenCount, tokenSamples
cwd
```

Claude Code sends at most the 16 most recent `tokenSamples` per task. It kills the command after 5 seconds (locally verified in v2.1.296). An omitted `id` keeps the default row, and an empty `content` hides that row. `content` may contain ANSI and OSC 8 sequences. Plugin-provided `subagentStatusLine` commands do not run under `allowManagedHooksOnly`.

The command returns one JSON line per visible task:

```json
{ "id": "task-id", "content": "rendered task row" }
```

Version constraints:

- `model` and `contextWindowSize` require Claude Code v2.1.205 or later.
- `effort` requires v2.1.213 or later and is absent when inherited. The first research pass recorded v2.1.214 from release notes; the official documentation states v2.1.213. `effort` may be a level string or a number (a thinking-token budget). `statuslinepy-sub` renders a numeric value verbatim.
- `agentType` requires v2.1.293 or later.
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

The stale bot closed the issue as "not planned" on 2026-09-03. No release through v2.1.296 announces a fix, and v2.1.223–v2.1.287 fixed only related 1M-to-200k drops. The official contract says extended-context models should report `1000000`.

The current Bash and PowerShell implementations prefer the supplied `used_percentage` and display the supplied denominator, so this payload becomes approximately `357k/200k 100%`.

A defensive implementation should:

1. Detect when calculated current tokens or `total_input_tokens` exceed the reported `context_window_size`.
2. Stop treating the denominator and precomputed percentage as authoritative.
3. Use an explicit 1M model label when Claude Code supplies one.
4. Otherwise render an unknown denominator, such as `357k/?`, instead of hardcoding every instance of a model to 1M. Context availability can vary by model alias, plan, provider, and feature entitlement.

Source: [1M-context status-line regression].

### The OAuth usage endpoint remains internal

v2.1.201, v2.1.220, and v2.1.296 all contain these locally verified markers:

```text
/api/oauth/usage
oauth-2025-04-20
extra_usage
model_scoped
weekly_scoped
seven_day_overage_included
```

No post-v1.8.2 endpoint, header, or response-schema migration was found. A live response on 2026-10-12 had top-level `five_hour`, `seven_day`, `extra_usage`, and `limits`. Its `limits[]` entries carry `kind` (`session`, `weekly_all`, `weekly_scoped`), `group`, `percent`, `severity`, `resets_at`, `scope`, and `is_active`. The Fable weekly entry still has `kind: "weekly_scoped"` and `scope.model.display_name: "Fable"`. This does not make the endpoint supported: it is absent from Anthropic's public API documentation and can change without notice.

The main status-line contract still forwards only:

```text
rate_limits.five_hour
rate_limits.seven_day
rate_limits.spend_limit   (Claude apps gateway only)
```

It does not forward `model_scoped`, Fable/Opus/Sonnet weekly buckets, or `extra_usage`. Requests [#77846], [#79022], and [#82656] were closed as duplicates in August 2026. [#52661] was closed as not planned. The surviving tracking request is [#73770], which remains open.

Migration rule: when Anthropic documents and ships those stdin fields, prefer them and retire direct OAuth credential access. Do not add a second internal control-request or `.claude.json` dependency as an interim workaround.

### Usage metadata is account-wide and rate-limited

Claude Code v2.1.208 acknowledges usage-endpoint throttling by retaining last-known data, and v2.1.284 makes its own usage views back off after a 429 or login rejection. A detailed upstream report describes 10–15 concurrent sessions receiving account-wide HTTP 429 responses with `Retry-After` values around 500–700 seconds while inference continued normally.

The current scripts share a per-`CLAUDE_CONFIG_DIR` fetch stamp, which prevents their own panes from starting identical requests simultaneously. They still retry after a fixed 60 seconds and cannot coordinate with Claude Code's own pollers.

Recommended cache behavior:

- Capture the HTTP status and positive `Retry-After` value.
- Persist a shared next-attempt timestamp.
- Use bounded exponential backoff when the endpoint provides no usable delay.
- Never interpret a metadata 429 as plan exhaustion.
- Retain the last valid response and expose its age.
- Validate cached JSON before rendering it.
- Replace a successful cache write interruption-safely; Claude Code cancels an in-flight renderer when a newer status update arrives.

Source: [concurrent usage-polling report]. The stale bot closed it as "not planned" on 2026-09-03.

### Credential scope and rotation

Official authentication documentation still describes macOS Keychain storage, Linux `~/.claude/.credentials.json` mode `0600`, the Windows credentials file, and `CLAUDE_CONFIG_DIR` relocation. No storage migration was found. The documentation now states that macOS falls back to `~/.claude/.credentials.json` when the Keychain rejects a write, such as a locked Keychain over SSH. The scripts check `<config dir>/.credentials.json` after the Keychain on every platform, so they already cover that fallback. Their GNOME Keyring fallback is not part of the documented contract.

`CLAUDE_CODE_OAUTH_TOKEN` takes precedence over stored credentials and can be generated with `claude setup-token`. The authentication documentation states that `setup-token` tokens can only make model requests, so they can lack the profile scope required by `/api/oauth/usage`. The read-only usage-scope request [usage-read scope request] was closed as "not planned" on 2026-09-17. Treat HTTP 403 as an unsupported token scope, not necessarily an invalid login. Generic stdin `rate_limits` may remain available while endpoint-only Fable or extra-usage data is not.

Sources: [authentication documentation], [setup-token scope report], and [usage-read scope request].

### Cost data is not yet a strong default feature

Claude Code v2.1.211 fixed cost not resetting after `/clear`, and v2.1.246 fixed cost and duration resetting after the agents view. Remaining reports:

- [#77970] (agents-view reset) remains open despite the v2.1.246 fix.
- The Fable cost undercount ([#77373]) was closed as "not planned" without a recorded fix.
- The `$` label on non-USD accounts ([#75621]) was closed as "not planned" without a recorded fix.
- `cost.total_cost_usd` uses list prices unless a `modelPricing` table applies. It changes as model prices change, for example the Sonnet 5.5 cache-read price in v2.1.296.

If added, cost should be opt-in, labeled as an estimate, and kept distinct from monthly extra-usage credits. Sources: [agents-view cost reset], [Fable cost report], and [currency-label report].

### Upstream rendering limitations

These are Claude Code defects or constraints rather than fixes for this repository:

- Custom output can disappear after an assistant response in Windows/VS Code even while the command continues to run: [Windows render issue] (open).
- Fullscreen TUI mode could suppress a custom status line: [fullscreen issue]. This is the only listed issue closed as completed (2026-08-16); the fixing version is not named.
- A reported macOS regression can silently fall back to the default status line: [macOS fallback issue] (closed "not planned" 2026-09-04; not confirmed fixed).
- Windows paths containing backslashes can be mangled when Git Bash executes the command. The repository's forward-slash `~/.claude/...` installation paths avoid the reported form: [Windows path issue] (closed "not planned").
- Enterprise `allowManagedHooksOnly` or `disableAllHooks` policy can disable custom status lines: [managed-hooks issue] (exemption request closed "not planned" 2026-09-20).
- A terminal resize does not trigger a rerender: [resize-trigger request] (open).

## Prioritized capability backlog

- **P0 — Detect inconsistent context-window payloads.** Prevent a known, confidently wrong display on 1M sessions.
- **P0 — Add a retry-aware usage cache with stale age.** Reduce account-wide metadata pressure and make fallback state honest. Claude Code itself backs off since v2.1.284, so this repository's fixed 60-second retry is now the less cooperative poller.
- **P1 — Add opt-in Bash and PowerShell `subagentStatusLine` scripts.** Use the genuinely new per-task model, context, and effort data.
- **P1 — Render model-scoped limits dynamically.** Accommodate future models without hardcoded names. Keep this behind the isolated internal endpoint until stdin supports it.
- **P2 — Add adaptive width tiers.** Use official width channels and preserve identity/context before lower-priority cells.
- **P2 — Add optional session, PR, repository, and fast-mode cells.** Use stable, zero-network stdin data that already exists. PR cells should handle GitLab `pr.kind: "mr"`.
- **P2 — Optional prompt-cache warmth cell.** `prompt_cache.warm` and `expires_at` are documented zero-network data, and Claude Code rerenders at expiry.
- **P3 — Render gateway `spend_limit`.** This is relevant only to Claude apps gateway users. It would be the first documented stdin source of dollar spend.
- **P2 — Add OSC 8 links.** Enable PR/repository navigation after visible-width handling supports OSC framing.
- **P3 — Add estimated session cost and duration.** Treat them as optional because upstream correctness defects remain open.
- **P3 — Add quota depletion forecasting.** Keep it experimental; stale timestamps are initially more reliable than projected exhaustion.

## Public Claude API impact

ClaudeCodeStatusLine does not call the public Messages or Models APIs. Public Claude Platform changes after 2026-07-05 therefore do not require a code change. Opus 5, Fable 5.1, Opus 5.5, Sonnet 5.5, and Haiku 5.5 affect the displayed model and context test matrix, but not the request protocol used by this repository.

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
- Release notes for v2.1.221 through v2.1.296: `https://github.com/anthropics/claude-code/releases/tag/v2.1.<N>`

### Upstream issues and requests

- [1M-context status-line regression]
- [#73770] (open tracking request for per-model weekly limits in stdin)
- [#52661]
- [#77846]
- [#79022]
- [#82656]
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
[#73770]: https://github.com/anthropics/claude-code/issues/73770
[#52661]: https://github.com/anthropics/claude-code/issues/52661
[#77846]: https://github.com/anthropics/claude-code/issues/77846
[#79022]: https://github.com/anthropics/claude-code/issues/79022
[#82656]: https://github.com/anthropics/claude-code/issues/82656
[#76751]: https://github.com/anthropics/claude-code/issues/76751
[#77970]: https://github.com/anthropics/claude-code/issues/77970
[#77373]: https://github.com/anthropics/claude-code/issues/77373
[#75621]: https://github.com/anthropics/claude-code/issues/75621
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
