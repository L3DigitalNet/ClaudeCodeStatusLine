# Source: https://github.com/chrisdpurcell/ClaudeCodeStatusLine
# Originally created by Daniel Oliveira (https://github.com/daniel3303/ClaudeCodeStatusLine); maintained by Chris Purcell.

$VERSION = "1.8.2"
# Two lines, pipe-aligned grid (column width = max visible width of its two cells):
#   Model [✦] effort  | tokens %used | 5h N%    @reset | [+added]   | cwd@branch[:worktree]
#   vVERSION [$x/$y]  | Fable N%     | 7d N% Day@reset | [-removed] | ~/path/to/cwd
# Cells are positional: row 2 always renders version/Fable/7d (dim '-' placeholders for
# unknown version / absent Fable weekly); the extra-usage '$used/$limit' rides in the
# version cell when enabled; Fable is the Fable-scoped weekly usage % (col 2), or a 😢 in
# place of the percent when the Fable weekly limit is unavailable (the label always stays);
# the +added/-removed pair is inserted into BOTH rows together, only while the tree is dirty.
# The trailing column is cwd-derived and shared: row 1 shows basename@branch[:worktree],
# row 2 the full path with $USERPROFILE collapsed to '~'; both cells appear or omit together,
# so when there is no cwd both rows simply end after their usage cells. The worktree name
# (--worktree sessions only) rides on the end of row 1's branch as ':name', hidden with its
# colon otherwise. The 5h/7d cells right-align their percents and stack their '@'s; the
# effort word (col 1), token % and Fable % (col 2) and the extra-usage dollars (col 1)
# likewise right-align to their column's edge so they stack vertically. The ✦ between model
# and effort appears only when thinking.enabled is true.

# Read input from stdin
$input = @($Input) -join "`n"

if (-not $input) {
    Write-Host -NoNewline "Claude"
    exit 0
}

# ANSI escape - use [char]0x1b for PowerShell 5 compatibility ("`e" is PS7+ only)
$esc = [char]0x1b

# ANSI colors matching oh-my-posh theme
$blue   = "${esc}[38;2;0;153;255m"
$orange = "${esc}[38;2;255;176;85m"
$green  = "${esc}[38;2;0;160;0m"
$cyan   = "${esc}[38;2;46;149;153m"
$red    = "${esc}[38;2;255;85;85m"
$yellow = "${esc}[38;2;230;200;0m"
$purple = "${esc}[38;2;167;139;250m"
$white  = "${esc}[38;2;220;220;220m"
$dim    = "${esc}[2m"
$reset  = "${esc}[0m"

# Format token counts (e.g., 50k / 200k)
function Format-Tokens([long]$num) {
    # Round half-up via AwayFromZero (.NET's default Round is banker's/half-to-even, which
    # surprises readers: 2500 must render 3k, not 2k). Unit is chosen from the *rounded*
    # value so 999500..999999 promote to 1M instead of an out-of-range "1000k". Suffixes
    # follow SI casing — lowercase k, uppercase M — matching the model block's "1M".
    if ($num -ge 1000000) {
        # Invariant culture for the decimal separator, matching Bash awk's period output;
        # a comma-decimal locale would otherwise render "1,2M" here where Bash prints "1.2M".
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $val = [math]::Round($num / 1000000.0, 1, [MidpointRounding]::AwayFromZero)
        if ($val -eq [math]::Floor($val)) { return $val.ToString("F0", $inv) + "M" }
        return $val.ToString("F1", $inv) + "M"
    }
    elseif ($num -ge 1000) {
        $k = [int][math]::Round($num / 1000.0, 0, [MidpointRounding]::AwayFromZero)
        if ($k -ge 1000) { return "1M" }
        return "${k}k"
    }
    else { return "$num" }
}

# Return color escape based on usage percentage
function Get-UsageColor([int]$pct) {
    if ($pct -ge 90) { return $red }
    elseif ($pct -ge 70) { return $orange }
    elseif ($pct -ge 50) { return $yellow }
    else { return $green }
}

# Visible (printable) length of a cell: character count with the script's own SGR
# color escapes stripped — the only escape family this script emits. .Length counts
# the single-width ✦ (BMP) as 1, matching Bash ${#} under UTF-8.
function Get-VisibleLength([string]$s) {
    return ($s -replace "$([char]27)\[[0-9;]*m", '').Length
}

# Credits (cents) -> dollar string: whole dollars render as integers ('0', '25'),
# fractional keep two decimals ('3.50'). Invariant culture pins the '.' separator.
function Format-Credits([double]$credits) {
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $v = $credits / 100
    if ($v -eq [math]::Floor($v)) { return $v.ToString("F0", $inv) }
    return $v.ToString("F2", $inv)
}

# Null coalescing helper for PowerShell 5 compatibility (?? is PS7+ only)
function Coalesce($value, $default) {
    if ($null -ne $value) { return $value } else { return $default }
}

# Return $true if $a > $b using semantic versioning
function Test-VersionGreaterThan([string]$a, [string]$b) {
    try {
        $sa = $a -replace '^v', ''
        $sb = $b -replace '^v', ''
        # [version] requires at least major.minor; a bare "2" throws where Bash's version_gt
        # treats missing components as 0. Append ".0" to a dot-less string so a short tag like
        # "v2" compares as "2.0" (> "1.5.0") instead of throwing and returning $false.
        if ($sa -notmatch '\.') { $sa = "$sa.0" }
        if ($sb -notmatch '\.') { $sb = "$sb.0" }
        $va = [version]$sa
        $vb = [version]$sb
        return $va -gt $vb
    } catch {
        return $false
    }
}

# ===== Extract data from JSON =====
$data = $input | ConvertFrom-Json

$modelName = if ($data.model.display_name) { $data.model.display_name } else { "Claude" }
$modelName = ($modelName -replace '\s*\((\d+\.?\d*[kKmM])\s+context\)', ' $1').Trim()  # "(1M context)" → "1M"

# Context window
$size = if ($data.context_window.context_window_size) { [long]$data.context_window.context_window_size } else { 200000 }
if ($size -eq 0) { $size = 200000 }

# Token usage
$inputTokens = if ($data.context_window.current_usage.input_tokens) { [long]$data.context_window.current_usage.input_tokens } else { 0 }
$cacheCreate = if ($data.context_window.current_usage.cache_creation_input_tokens) { [long]$data.context_window.current_usage.cache_creation_input_tokens } else { 0 }
$cacheRead   = if ($data.context_window.current_usage.cache_read_input_tokens) { [long]$data.context_window.current_usage.cache_read_input_tokens } else { 0 }
$current = $inputTokens + $cacheCreate + $cacheRead

$usedTokens  = Format-Tokens $current
$totalTokens = Format-Tokens $size

# Percent of context used. Claude Code now ships context_window.used_percentage
# precomputed (input-only formula — excludes output_tokens — which matches our own
# current sum). Prefer it; fall back to computing it ourselves for older CLIs or when
# the field is absent (current_usage is null before the first API call / after /compact).
# A literal 0 is a real value here, so honor it rather than treating it as absent.
if ($null -ne $data.context_window.used_percentage) {
    $pctUsed = [math]::Floor([double]$data.context_window.used_percentage)
} elseif ($size -gt 0) {
    $pctUsed = [math]::Floor($current * 100 / $size)
} else {
    $pctUsed = 0
}
# Config directory (respects CLAUDE_CONFIG_DIR override)
$claudeConfigDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".claude" }

$effortLevel = $null
if ($data.effort.level) {
    $effortLevel = [string]$data.effort.level
} elseif ($env:CLAUDE_CODE_EFFORT_LEVEL) {
    $effortLevel = $env:CLAUDE_CODE_EFFORT_LEVEL
} else {
    $settingsPath = Join-Path $claudeConfigDir "settings.json"
    if (Test-Path $settingsPath) {
        try {
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            if ($settings.effortLevel) { $effortLevel = $settings.effortLevel }
        } catch {}
    }
}
if (-not $effortLevel) { $effortLevel = "medium" }
# Lowercase so the rendered word matches Bash, which lowercases before its case statement.
# (PowerShell's switch is already case-insensitive, but the arms echo $effortLevel verbatim,
# so without this an input like "Max" would render capitalized here but lowercase in Bash.)
# Invariant lowercasing avoids the Turkish-I trap: "HIGH".ToLower() under tr-TR yields "hıgh",
# which would miss the switch arm and render an unmapped word.
$effortLevel = ([string]$effortLevel).ToLowerInvariant()

# Extended-thinking flag — drives the ✦ marker fused onto the effort word below.
$thinkingEnabled = $data.thinking.enabled

# ===== Claude CLI version =====
# Prefer the version Claude Code passes on stdin (the exact running client) — no subprocess.
# Fall back to the cached `claude --version` shell-out (1h TTL) only when stdin omits it
# (older CLIs / manual invocation), preserving graceful degradation.
$cacheDir = Join-Path $env:TEMP "claude"
$cliVersion = if ($data.version) { [string]$data.version } else { $null }

if (-not $cliVersion) {
    $cliVersionCache = Join-Path $cacheDir "statusline-cli-version"
    $cliVersionMaxAge = 3600

    if (Test-Path $cliVersionCache) {
        $cvMtime = (Get-Item $cliVersionCache).LastWriteTime
        $cvAge = ((Get-Date) - $cvMtime).TotalSeconds
        if ($cvAge -lt $cliVersionMaxAge) {
            # Get-Content -Raw returns $null for an empty file; calling .Trim() on $null throws.
            # Read first, then trim/assign only when non-empty.
            $cvCached = Get-Content $cliVersionCache -Raw
            if ($cvCached) { $cliVersion = $cvCached.Trim() }
        }
    }

    if (-not $cliVersion) {
        try {
            $cvOutput = & claude --version 2>$null
            if ($cvOutput) {
                $cliVersion = ($cvOutput -split '\s')[0]
                if ($cliVersion) {
                    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
                    $cliVersion | Set-Content $cliVersionCache -Force
                }
            }
        } catch {}
    }
}

# ===== Build cells for the two-line grid =====
# Cells are positional (see header): a missing cell in row 2 renders a dim '-' —
# otherwise later cells slide left and the pipes stop aligning; row 1's cwd cell
# is trailing and simply omitted when absent.

# Model [✦] effort — row 1, column 1: one fused, space-joined cell. The ✦ sits
# between the model name and the effort word (only when thinking is enabled).
$effortPart = ""
switch ($effortLevel) {
    "low"    { $effortPart = "${dim}${effortLevel}${reset}" }
    "medium" { $effortPart = "${orange}med${reset}" }
    "high"   { $effortPart = "${green}${effortLevel}${reset}" }
    "xhigh"  { $effortPart = "${purple}${effortLevel}${reset}" }
    "max"    { $effortPart = "${red}${effortLevel}${reset}" }
    default  { $effortPart = "${green}${effortLevel}${reset}" }
}
# Split the fused cell into a prefix (bare model name) and the effort group so the effort can be
# right-aligned to column 1's edge after the version cell is finalized (see the effort
# right-align pass below Format-ExtraUsage). The ✦ thinking marker joins the effort GROUP (not
# the prefix) so the right-align pad lands between the model name and '✦ effort', keeping the ✦
# flush against the effort word at the pipe. Built in natural (1-space) form, which is also the
# width Format-ExtraUsage measures to size column 1. Mirrors Bash.
if ($thinkingEnabled -eq $true) { $effortPart = "${purple}✦${reset} ${effortPart}" }
$modelPrefix = "${blue}${modelName}${reset}"
$modelCell = "${modelPrefix} ${effortPart}"

# Worktree name — read before the cwd block so it can ride on row 1's branch. stdin
# .worktree.name exists only in --worktree isolation sessions.
$worktreeName = $data.worktree.name

# Current working directory drives BOTH trailing cells: row 1's basename@branch[:worktree]
# ($cwdCell) and row 2's full path with $USERPROFILE collapsed to '~' ($pathCell). Both are
# cwd-derived, so they appear or omit together as column partners. Prefer
# workspace.current_dir (the documented-preferred alias); fall back to .cwd for older CLIs.
$cwd = if ($data.workspace.current_dir) { $data.workspace.current_dir } else { $data.cwd }
$cwdCell = ""
$pathCell = ""
$diffAddedCell = ""
$diffRemovedCell = ""
if ($cwd) {
    $displayDir = Split-Path $cwd -Leaf
    $gitBranch = $null
    try {
        $gitBranch = git -C $cwd rev-parse --abbrev-ref HEAD 2>$null
    } catch {}
    $cwdCell = "${green}${displayDir}${reset}"
    if ($gitBranch) {
        $cwdCell += "${dim}@${reset}${blue}${gitBranch}${reset}"
        # Worktree rides on the end of the branch as ':name' (dim ':' + cyan name), only in
        # --worktree sessions; the colon and name hide together otherwise.
        if ($worktreeName) { $cwdCell += "${dim}:${reset}${cyan}${worktreeName}${reset}" }
        try {
            # Unstaged line changes, tracked files only — rendered as a stacked column
            # pair (+added over -removed) that exists only while the tree is dirty.
            $numstat = git -C $cwd diff --numstat 2>$null
            if ($numstat) {
                $added = 0; $deleted = 0
                foreach ($line in $numstat) {
                    $parts = $line -split '\s+'
                    if ($parts[0] -match '^\d+$') { $added += [int]$parts[0] }
                    if ($parts[1] -match '^\d+$') { $deleted += [int]$parts[1] }
                }
                if (($added + $deleted) -gt 0) {
                    $diffAddedCell = "${green}+${added}${reset}"
                    $diffRemovedCell = "${red}-${deleted}${reset}"
                }
            }
        } catch {}
    }
    # Row 2's trailing cell: the full path with a leading $USERPROFILE collapsed to '~'
    # (e.g. C:\Users\me\projects\x -> ~\projects\x), matching Bash's $HOME collapse. Accept
    # either separator so a Unix-style cwd (WSL) collapses too.
    $displayPath = "$cwd"
    $homeDir = $env:USERPROFILE
    if ($homeDir) {
        if ($displayPath -eq $homeDir) {
            $displayPath = '~'
        } elseif ($displayPath.StartsWith("$homeDir/") -or $displayPath.StartsWith("$homeDir\")) {
            $displayPath = '~' + $displayPath.Substring($homeDir.Length)
        }
    }
    $pathCell = "${cyan}${displayPath}${reset}"
}

# Token cell (row 1, col 2). Split into prefix (used/total) and percent so the percent can be
# right-aligned to column 2's edge once the Fable cell (row 2) is sized — see the token
# right-align pass below Format-FableCell. Built in natural (1-space) form, which is also what
# Format-FableCell measures to size column 2. Mirrors Bash.
$tokensPrefix = "${orange}${usedTokens}/${totalTokens}${reset}"
$tokensPct = "${green}${pctUsed}%${reset}"
$tokensCell = "${tokensPrefix} ${tokensPct}"

# CLI version — row 2, column 1. Positional, so unknown renders '-' rather than
# vanishing (vanishing would slide the whole second row left).
$versionCell = if ($cliVersion) { "${orange}v${cliVersion}${reset}" } else { "${dim}-${reset}" }

# ===== OAuth token resolution =====
function Get-OAuthToken {
    # 1. Explicit env var override
    if ($env:CLAUDE_CODE_OAUTH_TOKEN) {
        return $env:CLAUDE_CODE_OAUTH_TOKEN
    }

    # 2. Windows Credential Manager (via cmdkey/CredentialManager)
    try {
        if (Get-Command "cmdkey.exe" -ErrorAction SilentlyContinue) {
            # Try reading from Windows Credential Manager using PowerShell
            $credPath = Join-Path $env:LOCALAPPDATA "Claude Code\credentials.json"
            if (Test-Path $credPath) {
                $creds = Get-Content $credPath -Raw | ConvertFrom-Json
                $token = $creds.claudeAiOauth.accessToken
                if ($token -and $token -ne "null") { return $token }
            }
        }
    } catch {}

    # 3. Credentials file (cross-platform fallback)
    $credsFile = Join-Path $claudeConfigDir ".credentials.json"
    if (Test-Path $credsFile) {
        try {
            $creds = Get-Content $credsFile -Raw | ConvertFrom-Json
            $token = $creds.claudeAiOauth.accessToken
            if ($token -and $token -ne "null") { return $token }
        } catch {}
    }

    return $null
}

# ===== Usage limits =====
# First, try to use rate_limits data provided directly by Claude Code in the JSON input.
# This is the most reliable source — no OAuth token or API call required.
$builtinFiveHourPct = $data.rate_limits.five_hour.used_percentage
$builtinFiveHourReset = $data.rate_limits.five_hour.resets_at
$builtinSevenDayPct = $data.rate_limits.seven_day.used_percentage
$builtinSevenDayReset = $data.rate_limits.seven_day.resets_at

$useBuiltin = ($null -ne $builtinFiveHourPct) -or ($null -ne $builtinSevenDayPct)

# When builtin values are all zero AND reset timestamps are missing, it likely indicates
# an API failure on Claude's side — fall through to cached data instead of displaying
# misleading 0%. Genuine zero responses (after a billing reset) still include valid
# resets_at timestamps, so we trust those.
$effectiveBuiltin = $false
if ($useBuiltin) {
    # Trust builtin if any percentage is non-zero
    if (($null -ne $builtinFiveHourPct -and [math]::Floor([double]$builtinFiveHourPct) -ne 0) -or
        ($null -ne $builtinSevenDayPct -and [math]::Floor([double]$builtinSevenDayPct) -ne 0)) {
        $effectiveBuiltin = $true
    }
    # Also trust if reset timestamps are present — genuine zero responses include valid reset times
    if (-not $effectiveBuiltin) {
        if (($null -ne $builtinFiveHourReset -and "$builtinFiveHourReset" -ne "null" -and "$builtinFiveHourReset" -ne "0") -or
            ($null -ne $builtinSevenDayReset -and "$builtinSevenDayReset" -ne "null" -and "$builtinSevenDayReset" -ne "0")) {
            $effectiveBuiltin = $true
        }
    }
}

# Cache setup — used as primary source for API path, and as fallback when builtin reports zero.
# Key the filename by an 8-char sha256 of the config dir (mirrors statusline.sh) so distinct
# CLAUDE_CONFIG_DIR accounts don't share/clobber one cache and read each other's usage figures.
$cacheDir = Join-Path $env:TEMP "claude"
$cfgHash = ([System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($claudeConfigDir))) -replace '-', '').ToLower().Substring(0, 8)
$cacheFile = Join-Path $cacheDir "statusline-usage-cache-$cfgHash.json"
# Separate fetch-throttle stamp: ONLY the OAuth-fetch path below touches it. The refresh
# gate keys off THIS mtime, not the cache file's, because the builtin rate_limits path
# rewrites the cache at the end of every render — using the cache mtime would keep it
# perpetually "fresh" and starve the fetch (the sole source of extra_usage), staling the
# extra-credits figure whenever renders arrive <cacheMaxAge apart.
$fetchStamp = Join-Path $cacheDir "statusline-usage-fetched-$cfgHash"
$cacheMaxAge = 60  # seconds between API calls

if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }

$needsRefresh = $true
$usageData = $null

# Refresh gate: fresh only if the fetch stamp was touched < cacheMaxAge ago.
if (Test-Path $fetchStamp) {
    $stampMtime = (Get-Item $fetchStamp).LastWriteTime
    $stampAge = ((Get-Date) - $stampMtime).TotalSeconds
    if ($stampAge -lt $cacheMaxAge) {
        $needsRefresh = $false
    }
}

# Always load the cache when non-empty (no age check — freshness is the stamp's job; mirrors
# Bash's `[ -s ]`). Available as fallback regardless of data source.
if ((Test-Path $cacheFile) -and ((Get-Item $cacheFile).Length -gt 0)) {
    $usageData = Get-Content $cacheFile -Raw
}

# Refresh API cache when stale — runs regardless of builtin rate_limits because
# extra_usage is only exposed through the OAuth usage endpoint (not stdin JSON).
# Throttled to cacheMaxAge and stampede-locked via the fetch stamp for shared panes.
if ($needsRefresh) {
    # Touch the stamp up front: it is BOTH the throttle (gates the next fetch for cacheMaxAge)
    # and the stampede lock (parallel panes see a fresh stamp and skip their own fetch). The
    # cache file is never touched here, so builtin-path cache rewrites can't reset the throttle.
    if (Test-Path $fetchStamp) {
        (Get-Item $fetchStamp).LastWriteTime = Get-Date
    } else {
        New-Item -ItemType File -Path $fetchStamp -Force | Out-Null
    }
    $token = Get-OAuthToken
    if ($token) {
        try {
            # Present the real running client version so the usage endpoint applies its normal
            # rate-limit bucket, not the aggressive one it reserves for atypical User-Agents.
            # A hardcoded version silently rots (it had drifted 160+ releases); source it live —
            # stdin .version is the exact client invoking us, then the cached CLI version. The
            # literal is only a last resort for the (production-impossible) both-empty case.
            $clientVersion = if ($data.version) { [string]$data.version } elseif ($cliVersion) { $cliVersion } else { "2.1.197" }
            $headers = @{
                "Accept"         = "application/json"
                "Content-Type"   = "application/json"
                "Authorization"  = "Bearer $token"
                "anthropic-beta" = "oauth-2025-04-20"
                "User-Agent"     = "claude-code/$clientVersion"
            }
            $response = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" `
                -Headers $headers -Method Get -TimeoutSec 10 -ErrorAction Stop
            # Only cache a real usage payload (mirrors Bash's `jq -e '.five_hour'`). A 200 with an
            # unexpected body (maintenance/error JSON, shape change) would otherwise poison the cache
            # for the full TTL and render as "5h 0% | 7d 0%"; reject it and keep the last-valid cache.
            if ($null -ne $response.five_hour) {
                $usageData = $response | ConvertTo-Json -Depth 10
                $usageData | Set-Content $cacheFile -Force
            }
        } catch {}
    }
    # On fetch failure $usageData keeps the value loaded from the cache before this block
    # (mirrors Bash — no re-read). No empty cache file is ever created, so there is nothing
    # to clean up.
}

# Format ISO reset time to compact local time
function Format-ResetTime([string]$isoStr, [string]$style) {
    if (-not $isoStr -or $isoStr -eq "null") { return $null }
    try {
        $dt = [DateTimeOffset]::Parse($isoStr, [System.Globalization.CultureInfo]::InvariantCulture).LocalDateTime
        switch ($style) {
            # 24-hour, capitalized, invariant culture — matches Bash strftime %H:%M / %a@%H:%M / %b %-d.
            "time"     { return $dt.ToString("HH:mm", [System.Globalization.CultureInfo]::InvariantCulture) }
            "datetime" { return $dt.ToString("ddd@HH:mm", [System.Globalization.CultureInfo]::InvariantCulture) }
            default    { return $dt.ToString("MMM d", [System.Globalization.CultureInfo]::InvariantCulture) }
        }
    } catch { return $null }
}

# Format Unix epoch reset time to compact local time
function Format-EpochResetTime([object]$epoch, [string]$style) {
    if ($null -eq $epoch -or "$epoch" -eq "null" -or "$epoch" -eq "") { return $null }
    try {
        $dt = [DateTimeOffset]::FromUnixTimeSeconds([long]$epoch).LocalDateTime
        switch ($style) {
            # 24-hour, capitalized, invariant culture — matches Bash strftime %H:%M / %a@%H:%M / %b %-d.
            "time"     { return $dt.ToString("HH:mm", [System.Globalization.CultureInfo]::InvariantCulture) }
            "datetime" { return $dt.ToString("ddd@HH:mm", [System.Globalization.CultureInfo]::InvariantCulture) }
            default    { return $dt.ToString("MMM d", [System.Globalization.CultureInfo]::InvariantCulture) }
        }
    } catch { return $null }
}

$sep = " ${dim}|${reset} "

# Compute the extra_usage cell (row 2, column 2) from API usage data — extra_usage
# is not available via stdin rate_limits. Returns the cell string. Positional:
# defaults to a dim '-' (disabled / no data); shows dollar figures whenever
# is_enabled, INCLUDING a $0 month — the old hide-at-$0.00 rule is gone because a
# grid cell cannot vanish. The grid assembler owns separators; no leading ' | '.
# Compute the extra-usage dollars FRAGMENT (row 2, col 1 — appended to $versionCell).
# Returns a colored "$used/$limit" when enabled + numeric; a "${green}enabled${reset}"
# marker when enabled but unparseable; "" otherwise (nothing gets appended to the version).
function Format-ExtraUsage($usage) {
    if (-not $usage) { return "" }
    try {
        if ($usage.extra_usage.is_enabled -ne $true) { return "" }

        $usedRaw = $usage.extra_usage.used_credits
        $limitRaw = $usage.extra_usage.monthly_limit

        # Parse with invariant culture so the decimal is always '.', matching Bash's
        # LC_NUMERIC=C awk (comma-decimal locales would render "0,00").
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $usedNum = 0.0
        $limitNum = 0.0
        if ([double]::TryParse([string]$usedRaw, [System.Globalization.NumberStyles]::Float, $inv, [ref]$usedNum) -and
            [double]::TryParse([string]$limitRaw, [System.Globalization.NumberStyles]::Float, $inv, [ref]$limitNum)) {
            $used = Format-Credits $usedNum
            $limit = Format-Credits $limitNum
            $pct = [math]::Floor([double](Coalesce $usage.extra_usage.utilization 0))
            $color = Get-UsageColor $pct
            return "${color}`$${used}/`$${limit}${reset}"
        } else {
            return "${green}enabled${reset}"
        }
    } catch {
        return ""
    }
}

# Fable weekly usage cell (row 2, col 2) from the API response limits[] array. Hardcoded to
# display_name=="Fable". When the Fable weekly limit is ABSENT (Fable left subscription plans
# 2026-07-07, non-Fable accounts, or no API data) the cell does NOT vanish or dim to '-': the
# 'Fable' label stays and the percent becomes a 😢, holding the column until Fable returns.
# @() forces array iteration over a scalar limits. Mirrors Bash render_fable.
function Format-FableCell($usage, $tokensCell) {
    # Default = Fable unavailable. Overwritten below only when a numeric Fable percent exists.
    $pctTxt = "😢"
    $color = $reset
    if ($usage) {
        try {
            $entry = @($usage.limits) | Where-Object { $_.scope.model.display_name -eq 'Fable' } | Select-Object -First 1
            if ($entry -and $null -ne $entry.percent) {
                $pct = [math]::Floor([double]$entry.percent)
                $color = Get-UsageColor $pct
                $pctTxt = "${pct}%"
            }
        } catch {}
    }
    # Right-align the value ('NN%' or 😢) to column 2's edge; 'Fable' stays left, pad goes
    # between (1-space minimum). Column 2's width is max(tokens row 1, Fable row 2) and
    # tokensCell is the only row-1 cell there. 'Fable' is a fixed 5 visible chars; the value's
    # width comes from Get-VisibleLength (😢 is a surrogate pair -> .Length 2 = its display width).
    $labLen = 5
    $plen = Get-VisibleLength $pctTxt
    $tok = Get-VisibleLength $tokensCell
    $natural = $labLen + 1 + $plen
    $target = [math]::Max($tok, $natural)
    $gap = $target - $labLen - $plen
    return "${white}Fable${reset}" + (' ' * $gap) + "${color}${pctTxt}${reset}"
}

# Parse usage_data once (used by both branches below for extra_usage)
$parsedUsage = $null
if ($usageData) {
    try {
        $parsedUsage = if ($usageData -is [string]) { $usageData | ConvertFrom-Json } else { $usageData }
    } catch {}
}

# 5h/7d cell pieces + the extra cell. Defaults are the no-data placeholders;
# branches overwrite. $fhTime/$sdTime include their leading '@'; $sdPrefix is the
# weekday ('' for 5h).
$fhPctTxt = "-"; $fhColor = $dim; $fhTime = ""
$sdPctTxt = "-"; $sdColor = $dim; $sdPrefix = ""; $sdTime = ""
$extraCell = "${dim}-${reset}"

if ($effectiveBuiltin) {
    # ---- Use rate_limits data provided directly by Claude Code in JSON input ----
    # resets_at values are Unix epoch integers in this source
    if ($null -ne $builtinFiveHourPct) {
        $fiveHourPct = [math]::Floor([double]$builtinFiveHourPct)
        $fhPctTxt = "${fiveHourPct}%"
        $fhColor = Get-UsageColor $fiveHourPct
        $fiveHourReset = Format-EpochResetTime $builtinFiveHourReset "time"
        if ($fiveHourReset) { $fhTime = "@${fiveHourReset}" }
    }

    if ($null -ne $builtinSevenDayPct) {
        $sevenDayPct = [math]::Floor([double]$builtinSevenDayPct)
        $sdPctTxt = "${sevenDayPct}%"
        $sdColor = Get-UsageColor $sevenDayPct
        $sevenDayReset = Format-EpochResetTime $builtinSevenDayReset "datetime"
        if ($sevenDayReset) {
            $sdPrefix = ($sevenDayReset -split '@')[0]
            $sdTime = "@" + ($sevenDayReset -split '@')[1]
        }
    }

    # Cache builtin values so they're available as fallback when API is unavailable.
    # Convert epoch resets_at to ISO 8601 for compatibility with the API-format cache parser.
    # Use invariant culture to avoid locale-dependent decimal separators in JSON.
    # Preserve extra_usage from prior API response so we don't clobber it.
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $fhVal = if ($builtinFiveHourPct) { ([double]$builtinFiveHourPct).ToString($inv) } else { "0" }
    $sdVal = if ($builtinSevenDayPct) { ([double]$builtinSevenDayPct).ToString($inv) } else { "0" }
    $fhResetJson = "null"
    if ($null -ne $builtinFiveHourReset -and "$builtinFiveHourReset" -ne "null" -and "$builtinFiveHourReset" -ne "0") {
        try {
            $fhResetJson = '"' + [DateTimeOffset]::FromUnixTimeSeconds([long]$builtinFiveHourReset).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) + '"'
        } catch {}
    }
    $sdResetJson = "null"
    if ($null -ne $builtinSevenDayReset -and "$builtinSevenDayReset" -ne "null" -and "$builtinSevenDayReset" -ne "0") {
        try {
            $sdResetJson = '"' + [DateTimeOffset]::FromUnixTimeSeconds([long]$builtinSevenDayReset).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) + '"'
        } catch {}
    }
    $extraJson = "null"
    if ($parsedUsage -and $parsedUsage.extra_usage) {
        try {
            $extraJson = $parsedUsage.extra_usage | ConvertTo-Json -Depth 5 -Compress
        } catch {}
    }
    # Preserve the model-scoped limits[] array (Fable weekly) across the builtin rewrite,
    # mirroring the Bash side. ConvertTo-Json collapses a 1-element array to a bare object;
    # -AsArray would fix it but is PowerShell 6+ only and this script also targets Windows
    # PowerShell 5.1, so serialize each element and re-bracket manually — an array on ALL
    # versions, and it round-trips back to an iterable .limits under ConvertFrom-Json.
    $limitsJson = "null"
    if ($parsedUsage -and $parsedUsage.limits) {
        try {
            $elems = @($parsedUsage.limits) | ForEach-Object { $_ | ConvertTo-Json -Depth 6 -Compress }
            $limitsJson = "[" + ($elems -join ",") + "]"
        } catch {}
    }
    $fallbackJson = "{`"five_hour`":{`"utilization`":$fhVal,`"resets_at`":$fhResetJson},`"seven_day`":{`"utilization`":$sdVal,`"resets_at`":$sdResetJson},`"limits`":$limitsJson,`"extra_usage`":$extraJson}"
    $fallbackJson | Set-Content $cacheFile -Force
} elseif ($parsedUsage -and $null -ne $parsedUsage.five_hour) {
    # ---- Fall back: API-fetched usage data ----
    # Require .five_hour (mirrors Bash's `jq -e '.five_hour'`) so a cache object lacking it
    # falls through to the placeholder branch instead of rendering a misleading "5h 0% | 7d 0%".
    try {
        # ---- 5-hour (current) ----
        $fiveHourPct = [math]::Floor([double](Coalesce $parsedUsage.five_hour.utilization 0))
        $fiveHourReset = Format-ResetTime $parsedUsage.five_hour.resets_at "time"
        $fhPctTxt = "${fiveHourPct}%"
        $fhColor = Get-UsageColor $fiveHourPct
        if ($fiveHourReset) { $fhTime = "@${fiveHourReset}" }

        # ---- 7-day (weekly) ----
        $sevenDayPct = [math]::Floor([double](Coalesce $parsedUsage.seven_day.utilization 0))
        $sevenDayReset = Format-ResetTime $parsedUsage.seven_day.resets_at "datetime"
        $sdPctTxt = "${sevenDayPct}%"
        $sdColor = Get-UsageColor $sevenDayPct
        if ($sevenDayReset) {
            $sdPrefix = ($sevenDayReset -split '@')[0]
            $sdTime = "@" + ($sevenDayReset -split '@')[1]
        }

    } catch {}
} else {
    # No valid usage data — the '-' placeholder defaults above stand.
}

# extra-usage dollars ride in the version cell (row 2, col 1); Fable weekly takes col 2.
# Both read the API response only — compute once here after every branch populated $parsedUsage.
$extraDollars = Format-ExtraUsage $parsedUsage
if ($extraDollars) {
    # Right-align the extra-usage dollars to column 1's RIGHT edge (flush with the ' | '),
    # padding BETWEEN the version and the dollars. Column 1's width is max(model row 1,
    # version row 2); $modelCell is the only row-1 cell, so pre-expand now (2-space minimum
    # gap when the version cell is the wider of the two). Mirrors the Bash side.
    $edVlen = Get-VisibleLength $versionCell
    $edDlen = Get-VisibleLength $extraDollars
    $edMlen = Get-VisibleLength $modelCell
    $edNatural = $edVlen + 2 + $edDlen
    $edTarget = [math]::Max($edMlen, $edNatural)
    $edGap = $edTarget - $edVlen - $edDlen
    $versionCell = $versionCell + (' ' * $edGap) + $extraDollars
}

# Right-align the effort word to column 1's RIGHT edge so it stays flush with the ' | ' and
# doesn't drift when the version+dollars cell is the wider of the two — otherwise the generic
# pad pass would add the slack AFTER the effort word (high dollars widened col 1 and pushed
# 'effort' off the pipe). Col 1's width is max(model natural, finalized version cell); pad
# BETWEEN the model name and the '✦ effort' group (1-space min). Run unconditionally, mirroring Bash.
$mCol = [math]::Max((Get-VisibleLength $versionCell), (Get-VisibleLength $modelCell))
$mPfxW = Get-VisibleLength $modelPrefix
$mEffW = Get-VisibleLength $effortPart
$mGap = [math]::Max(1, $mCol - $mPfxW - $mEffW)
$modelCell = $modelPrefix + (' ' * $mGap) + $effortPart

$extraCell = Format-FableCell $parsedUsage $tokensCell

# Right-align the token percent to column 2's RIGHT edge so it stacks under the Fable
# percent (row 2). Format-FableCell has already sized $extraCell to column 2's width
# (max of the token natural width and the Fable cell), so pad BETWEEN used/total and the
# percent up to it — a 1-space minimum matches the natural form when tokens is wider. Mirrors Bash.
$tkCol = [math]::Max((Get-VisibleLength $extraCell), (Get-VisibleLength $tokensCell))
$tkPfxW = Get-VisibleLength $tokensPrefix
$tkPctW = Get-VisibleLength $tokensPct
$tkGap = [math]::Max(1, $tkCol - $tkPfxW - $tkPctW)
$tokensCell = $tokensPrefix + (' ' * $tkGap) + $tokensPct

# ---- Compose the 5h/7d cells with internal %/@ alignment ----
# Right-align the percent strings to a shared width, and pad-left the pre-'@'
# fragment (always empty for 5h, the weekday for 7d) so the two '@'s stack. Widths
# derive from the actual values — a 3-digit 100% or a '-' placeholder self-adjusts.
$pctW = [math]::Max($fhPctTxt.Length, $sdPctTxt.Length)
$preW = $sdPrefix.Length
$fiveCell = "${white}5h${reset} " + (' ' * ($pctW - $fhPctTxt.Length)) + "${fhColor}${fhPctTxt}${reset}"
if ($fhTime) { $fiveCell += " " + (' ' * $preW) + "${dim}${fhTime}${reset}" }
$sevenCell = "${white}7d${reset} " + (' ' * ($pctW - $sdPctTxt.Length)) + "${sdColor}${sdPctTxt}${reset}"
if ($sdTime) { $sevenCell += " ${dim}${sdPrefix}${sdTime}${reset}" }

# ===== Update check (cached, 24h TTL) =====
# Set STATUSLINE_CHECK_UPDATES=false to disable the update check (no network calls).
$updateLine = ""
if ($env:STATUSLINE_CHECK_UPDATES -cne "false") {
    $versionCacheFile = Join-Path $cacheDir "statusline-version-cache.json"
    $versionCacheMaxAge = 86400  # 24 hours

    $versionNeedsRefresh = $true
    $versionData = $null

    if (Test-Path $versionCacheFile) {
        $vcMtime = (Get-Item $versionCacheFile).LastWriteTime
        $vcAge = ((Get-Date) - $vcMtime).TotalSeconds
        if ($vcAge -lt $versionCacheMaxAge) {
            $versionNeedsRefresh = $false
        }
        $versionData = Get-Content $versionCacheFile -Raw
    }

    if ($versionNeedsRefresh) {
        if (Test-Path $versionCacheFile) {
            (Get-Item $versionCacheFile).LastWriteTime = Get-Date
        } else {
            New-Item -ItemType File -Path $versionCacheFile -Force | Out-Null
        }
        try {
            $vcResponse = Invoke-RestMethod -Uri "https://api.github.com/repos/chrisdpurcell/ClaudeCodeStatusLine/releases/latest" `
                -Headers @{ "Accept" = "application/vnd.github+json" } -Method Get -TimeoutSec 5 -ErrorAction Stop
            $versionData = $vcResponse | ConvertTo-Json -Depth 10
            $versionData | Set-Content $versionCacheFile -Force
        } catch {
            if ((Test-Path $versionCacheFile) -and (Get-Item $versionCacheFile).Length -eq 0) {
                Remove-Item $versionCacheFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($versionData) {
        try {
            $vcParsed = if ($versionData -is [string]) { $versionData | ConvertFrom-Json } else { $versionData }
            $latestTag = $vcParsed.tag_name
            # The version cache is untrusted (poisonable on shared-temp systems) and the tag is
            # rendered raw into the terminal — restrict it to version characters so a crafted
            # tag_name can't inject ANSI/OSC escape sequences.
            $latestTag = "$latestTag" -replace '[^v0-9.]', ''
            if ($latestTag -and (Test-VersionGreaterThan $latestTag $VERSION)) {
                $updateLine = "`n${dim}Update available: ${latestTag} → Tell Claude: `"Find my installed status bar and update it`"${reset}"
            }
        } catch {}
    }
}

# ===== Assemble the two-line grid =====
# Column width = max visible width of the column's two cells; every cell except the
# last of its row pads right with PLAIN spaces to that width, so the ' | ' separators
# stack vertically. Both rows share the same three leading cells (version/Fable/7d in
# row 2); the trailing cwd column is optional and appears in both rows or neither.
$r1 = @($modelCell, $tokensCell, $fiveCell)
$r2 = @($versionCell, $extraCell, $sevenCell)
# The +added/-removed pair is inserted into BOTH rows together (never one alone), so the
# cwd cell (row 1) and path cell (row 2) stay column partners whether or not it appears.
if ($diffAddedCell) {
    $r1 += $diffAddedCell
    $r2 += $diffRemovedCell
}
# $cwdCell and $pathCell are both set iff cwd is present, so they are appended together
# (same trailing column) or omitted together — no positional '-' placeholder needed.
if ($cwdCell) { $r1 += $cwdCell }
if ($pathCell) { $r2 += $pathCell }

$line1 = ""; $line2 = ""
$maxCols = [math]::Max($r1.Count, $r2.Count)
for ($i = 0; $i -lt $maxCols; $i++) {
    $c1 = if ($i -lt $r1.Count) { $r1[$i] } else { $null }
    $c2 = if ($i -lt $r2.Count) { $r2[$i] } else { $null }
    $w1 = if ($null -ne $c1) { Get-VisibleLength $c1 } else { 0 }
    $w2 = if ($null -ne $c2) { Get-VisibleLength $c2 } else { 0 }
    $w = [math]::Max($w1, $w2)
    if ($null -ne $c1) {
        if ($i -lt ($r1.Count - 1)) { $line1 += $c1 + (' ' * ($w - $w1)) + $sep }
        else { $line1 += $c1 }
    }
    if ($null -ne $c2) {
        if ($i -lt ($r2.Count - 1)) { $line2 += $c2 + (' ' * ($w - $w2)) + $sep }
        else { $line2 += $c2 }
    }
}

# Output
Write-Host -NoNewline "$line1`n$line2$updateLine"

exit 0
