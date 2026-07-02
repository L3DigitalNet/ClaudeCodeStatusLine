#!/bin/bash
# Source: https://github.com/chrisdpurcell/ClaudeCodeStatusLine
# Originally created by Daniel Oliveira (https://github.com/daniel3303/ClaudeCodeStatusLine); maintained by Chris Purcell.
# Two lines, pipe-aligned grid (column width = max visible width of its two cells):
#   Model [✦] effort | tokens %used   | 5h N%    @reset | [+added]   | cwd@branch
#   vVERSION         | extra $x/$y    | 7d N% Day@reset | [-removed] | worktree
# Cells are positional: row 2 always renders version/extra/7d/worktree (dim '-'
# placeholders for unknown version / disabled extra / absent worktree); the +added/
# -removed pair is inserted into BOTH rows together, only while the tree is dirty;
# row 1's cwd cell is omitted when there is no cwd. The 5h/7d cells right-align their
# percents and stack their '@'s. The ✦ between model and effort appears only when
# thinking.enabled is true.

set -f  # disable globbing
shopt -s extglob  # extended globs in ${var//pat/} — visible_len strips SGR escapes with *([0-9;])
VERSION="1.6.0"

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ANSI colors matching oh-my-posh theme.
# Stored as REAL escape bytes via $'...' (ANSI-C quoting) rather than literal '\033' strings.
# This lets the final output use printf '%s' instead of '%b': '%b' would also expand any
# backslash escape (\n, \t) embedded in JSON-derived fields (display_name, cwd, branch),
# which could split or corrupt the single line. Real bytes here + '%s' at the end = safe.
blue=$'\033[38;2;0;153;255m'
orange=$'\033[38;2;255;176;85m'
green=$'\033[38;2;0;160;0m'
cyan=$'\033[38;2;46;149;153m'
red=$'\033[38;2;255;85;85m'
yellow=$'\033[38;2;230;200;0m'
purple=$'\033[38;2;167;139;250m'
white=$'\033[38;2;220;220;220m'
dim=$'\033[2m'
reset=$'\033[0m'

# Format token counts (e.g., 50k / 200k)
format_tokens() {
    # Round half-up (awk's default %.0f/%.1f is round-half-to-even, which surprises
    # readers: 2500 must render 3k, not 2k). Unit is chosen from the *rounded* value so
    # 999500..999999 promote to 1M instead of an out-of-range "1000k". Suffixes follow SI
    # casing — lowercase k, uppercase M — matching the model block's "1M".
    awk -v n="$1" 'BEGIN {
        if (n >= 1000000) {
            v = int(n / 100000 + 0.5) / 10          # millions, 1 decimal, half-up
            if (v == int(v)) printf "%dM", v; else printf "%.1fM", v
        } else if (n >= 1000) {
            k = int(n / 1000 + 0.5)                 # thousands, integer, half-up
            if (k >= 1000) printf "1M"              # rounded up out of the k range
            else printf "%dk", k
        } else {
            printf "%d", n
        }
    }'
}

# Floor a (possibly fractional) percentage to an integer, matching PowerShell's
# [math]::Floor and the token-context % path (awk printf %d truncates toward zero).
# All usage percentages floor rather than round so the two mirrors agree and so a
# boundary value like 89.6 doesn't cross a color threshold in one script but not the other.
floor_pct() {
    awk -v n="$1" 'BEGIN { printf "%d", n }'
}

# Visible (printable) length of a cell: character count with the script's own SGR
# color escapes stripped. extglob's *([0-9;]) keeps the glob anchored inside one
# escape — a bare * would greedily eat through to the LAST 'm' in the string. Only
# SGR (ESC[...m) needs stripping: it is the only escape family this script emits.
# Counts characters, not terminal columns: content is ASCII plus the single-width ✦,
# which ${#} counts as 1 under a UTF-8 locale (standard on Claude Code hosts).
visible_len() {
    local s="${1//$'\033'\[*([0-9;])m/}"
    # ✦ is the one non-ASCII glyph the script itself emits. Under a C/POSIX locale
    # ${#} counts its UTF-8 bytes (3) rather than its single display column, which
    # over-pads the column and misaligns the pipes; swap it for one ASCII char
    # before counting so the width is right in any locale. (PowerShell needs no
    # equivalent — .Length already counts it as 1.)
    s="${s//✦/.}"
    printf '%s' "${#s}"
}

# Credits (cents) -> dollar string: whole dollars render as integers ('0', '25'),
# fractional keep two decimals ('3.50'). LC_NUMERIC=C pins the '.' separator.
fmt_credits() {
    LC_NUMERIC=C awk -v c="$1" 'BEGIN { v = c / 100
        if (v == int(v)) printf "%d", v; else printf "%.2f", v }'
}

# Return color escape based on usage percentage
# Usage: usage_color <pct>
usage_color() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then echo "$red"
    elif [ "$pct" -ge 70 ]; then echo "$orange"
    elif [ "$pct" -ge 50 ]; then echo "$yellow"
    else echo "$green"
    fi
}

# Resolve config directory: CLAUDE_CONFIG_DIR (set by alias) or default ~/.claude
claude_config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Cache root for all on-disk caches (CLI version, usage, update check). Prefer the
# per-user, 0700 XDG_RUNTIME_DIR (systemd distros) over a fixed /tmp/claude: /tmp is
# world-visible, so on a shared host another local user could pre-create or poison
# that path. Fall back to /tmp for macOS / older systems that lack XDG_RUNTIME_DIR.
cache_dir="${XDG_RUNTIME_DIR:-/tmp}/claude"

# Return 0 (true) if $1 > $2 using semantic versioning
version_gt() {
    local a="${1#v}" b="${2#v}"
    local IFS='.'
    read -r a1 a2 a3 <<< "$a"
    read -r b1 b2 b3 <<< "$b"
    a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
    b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
    [ "$a1" -gt "$b1" ] 2>/dev/null && return 0
    [ "$a1" -lt "$b1" ] 2>/dev/null && return 1
    [ "$a2" -gt "$b2" ] 2>/dev/null && return 0
    [ "$a2" -lt "$b2" ] 2>/dev/null && return 1
    [ "$a3" -gt "$b3" ] 2>/dev/null && return 0
    return 1
}
# ===== Extract data from JSON =====
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')
# "(1M context)" → "1M". Require at least one digit AND exactly one k/K/m/M suffix so a
# plain "(200000 context)" (no suffix) is left verbatim — matches the PowerShell mirror's
# stricter regex. Second expression trims any leading/trailing whitespace (PS calls .Trim()).
model_name=$(echo "$model_name" | sed -E 's/[[:space:]]*\(([0-9]+\.?[0-9]*[kKmM])[[:space:]]+context\)/ \1/; s/^[[:space:]]+|[[:space:]]+$//g')

# Context window
size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

# Token usage
input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

used_tokens=$(format_tokens $current)
total_tokens=$(format_tokens $size)

# Percent of context used. Claude Code now ships context_window.used_percentage
# precomputed (input-only formula — excludes output_tokens — which matches our own
# current sum). Prefer it; fall back to computing it ourselves for older CLIs or when
# the field is absent (current_usage is null before the first API call / after /compact).
# jq's `// empty` keeps a literal 0, so a real 0% is honored rather than mistaken for absent.
pct_stdin=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
if [ -n "$pct_stdin" ] && [ "$pct_stdin" != "null" ]; then
    pct_used=$(awk -v p="$pct_stdin" 'BEGIN { printf "%d", p }')  # floor to int, matching manual path
elif [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi
settings_path="$claude_config_dir/settings.json"
effort_level=""
stdin_effort=$(echo "$input" | jq -r '.effort.level // empty' 2>/dev/null)
if [ -n "$stdin_effort" ]; then
    effort_level="$stdin_effort"
elif [ -n "$CLAUDE_CODE_EFFORT_LEVEL" ]; then
    effort_level="$CLAUDE_CODE_EFFORT_LEVEL"
elif [ -f "$settings_path" ]; then
    effort_val=$(jq -r '.effortLevel // empty' "$settings_path" 2>/dev/null)
    [ -n "$effort_val" ] && effort_level="$effort_val"
fi
[ -z "$effort_level" ] && effort_level="medium"
# Lowercase so matching is case-insensitive and identical to PowerShell's switch (which is
# case-insensitive by default). Claude Code sends lowercase; this only affects odd inputs
# like CLAUDE_CODE_EFFORT_LEVEL=Max, which must render the same on both mirrors.
effort_level=$(printf '%s' "$effort_level" | tr '[:upper:]' '[:lower:]')

# Extended-thinking flag — drives the ✦ marker fused onto the effort word below.
thinking_enabled=$(echo "$input" | jq -r '.thinking.enabled // empty')

# ===== Claude CLI version =====
# Prefer the version Claude Code passes on stdin (the exact running client) — no subprocess.
# Fall back to the cached `claude --version` shell-out (1h TTL) only when stdin omits it
# (older CLIs / manual invocation), preserving graceful degradation.
cli_version=$(echo "$input" | jq -r '.version // empty')

if [ -z "$cli_version" ]; then
    cli_version_cache="$cache_dir/statusline-cli-version"
    cli_version_max_age=3600

    if [ -f "$cli_version_cache" ]; then
        cv_mtime=$(stat -c %Y "$cli_version_cache" 2>/dev/null || stat -f %m "$cli_version_cache" 2>/dev/null)
        cv_now=$(date +%s)
        cv_age=$(( cv_now - cv_mtime ))
        if [ "$cv_age" -lt "$cli_version_max_age" ]; then
            cli_version=$(cat "$cli_version_cache" 2>/dev/null)
        fi
    fi

    if [ -z "$cli_version" ]; then
        cli_version=$(claude --version 2>/dev/null | awk '{print $1}')
        if [ -n "$cli_version" ]; then
            mkdir -p "$cache_dir" 2>/dev/null
            echo "$cli_version" > "$cli_version_cache"
        fi
    fi
fi

# ===== Build cells for the two-line grid =====
# Cells are positional (see header): a missing cell in row 2 renders a dim '-' —
# otherwise later cells slide left and the pipes stop aligning; row 1's cwd cell
# is trailing and simply omitted when absent.

# Model [✦] effort — row 1, column 1: one fused, space-joined cell. The ✦ sits
# between the model name and the effort word (only when thinking is enabled).
case "$effort_level" in
    low)    effort_part="${dim}${effort_level}${reset}" ;;
    medium) effort_part="${orange}med${reset}" ;;
    high)   effort_part="${green}${effort_level}${reset}" ;;
    xhigh)  effort_part="${purple}${effort_level}${reset}" ;;
    max)    effort_part="${red}${effort_level}${reset}" ;;
    *)      effort_part="${green}${effort_level}${reset}" ;;
esac
model_cell="${blue}${model_name}${reset}"
[ "$thinking_enabled" = "true" ] && model_cell+=" ${purple}✦${reset}"
model_cell+=" ${effort_part}"

# Current working directory — row 1, trailing cell. Prefer workspace.current_dir
# (the documented-preferred alias); fall back to the top-level .cwd for older CLIs.
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
cwd_cell=""
diff_added_cell=""
diff_removed_cell=""
if [ -n "$cwd" ]; then
    display_dir="${cwd##*/}"
    git_branch=$(git -C "${cwd}" rev-parse --abbrev-ref HEAD 2>/dev/null)
    cwd_cell="${cyan}${display_dir}${reset}"
    if [ -n "$git_branch" ]; then
        cwd_cell+="${dim}@${reset}${green}${git_branch}${reset}"
        # Unstaged line changes, tracked files only — rendered as a stacked column
        # pair (+added over -removed) that exists only while the tree is dirty.
        git_stat=$(git -C "${cwd}" diff --numstat 2>/dev/null | awk '{a+=$1; d+=$2} END {if (a+d>0) printf "%d %d", a, d}')
        if [ -n "$git_stat" ]; then
            diff_added_cell="${green}+${git_stat%% *}${reset}"
            diff_removed_cell="${red}-${git_stat##* }${reset}"
        fi
    fi
fi

tokens_cell="${orange}${used_tokens}/${total_tokens}${reset} ${green}${pct_used}%${reset}"

# CLI version — row 2, column 1. Positional, so unknown renders '-' rather than
# vanishing (vanishing would slide the whole second row left).
if [ -n "$cli_version" ]; then
    version_cell="${orange}v${cli_version}${reset}"
else
    version_cell="${dim}-${reset}"
fi

# Worktree — row 2, column 4. stdin .worktree.name exists only in --worktree
# isolation sessions; cyan matches the directory-identity color above it.
worktree_name=$(echo "$input" | jq -r '.worktree.name // empty')
if [ -n "$worktree_name" ]; then
    worktree_cell="${cyan}${worktree_name}${reset}"
else
    worktree_cell="${dim}-${reset}"
fi

# ===== Cross-platform OAuth token resolution (from statusline.sh) =====
# Tries credential sources in order: env var → macOS Keychain → Linux creds file → GNOME Keyring
get_oauth_token() {
    local token=""

    # 1. Explicit env var override
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        echo "$CLAUDE_CODE_OAUTH_TOKEN"
        return 0
    fi

    # 2. macOS Keychain (Claude Code appends a SHA256 hash of CLAUDE_CONFIG_DIR to the service name)
    if command -v security >/dev/null 2>&1; then
        local keychain_svc="Claude Code-credentials"
        if [ -n "$CLAUDE_CONFIG_DIR" ]; then
            local dir_hash
            dir_hash=$(echo -n "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
            keychain_svc="Claude Code-credentials-${dir_hash}"
        fi
        local blob
        blob=$(security find-generic-password -s "$keychain_svc" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    # 3. Linux credentials file
    local creds_file="${claude_config_dir}/.credentials.json"
    if [ -f "$creds_file" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            echo "$token"
            return 0
        fi
    fi

    # 4. GNOME Keyring via secret-tool
    if command -v secret-tool >/dev/null 2>&1; then
        local blob
        blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    echo ""
}

# ===== LINE 2 & 3: Usage limits with progress bars =====
# First, try to use rate_limits data provided directly by Claude Code in the JSON input.
# This is the most reliable source — no OAuth token or API call required.
builtin_five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
builtin_five_hour_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
builtin_seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
builtin_seven_day_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

use_builtin=false
if [ -n "$builtin_five_hour_pct" ] || [ -n "$builtin_seven_day_pct" ]; then
    use_builtin=true
fi

# Cache setup — shared across all Claude Code instances to avoid rate limits
claude_config_dir_hash=$(echo -n "$claude_config_dir" | shasum -a 256 2>/dev/null || echo -n "$claude_config_dir" | sha256sum 2>/dev/null)
claude_config_dir_hash=$(echo "$claude_config_dir_hash" | cut -c1-8)
cache_file="$cache_dir/statusline-usage-cache-${claude_config_dir_hash}.json"
# Separate fetch-throttle stamp: ONLY the OAuth-fetch path below touches it. The refresh
# gate keys off THIS mtime, not the cache file's, because the builtin rate_limits path
# rewrites the cache at the end of every render — using the cache mtime would keep it
# perpetually "fresh" and starve the fetch (the sole source of extra_usage), staling the
# extra-credits figure whenever renders arrive <cache_max_age apart.
fetch_stamp="$cache_dir/statusline-usage-fetched-${claude_config_dir_hash}"
cache_max_age=60  # seconds between API calls
mkdir -p "$cache_dir"

needs_refresh=true
usage_data=""

# Refresh gate: fresh only if the fetch stamp was touched < cache_max_age ago.
if [ -f "$fetch_stamp" ]; then
    stamp_mtime=$(stat -c %Y "$fetch_stamp" 2>/dev/null || stat -f %m "$fetch_stamp" 2>/dev/null)
    now=$(date +%s)
    stamp_age=$(( now - stamp_mtime ))
    if [ "$stamp_age" -lt "$cache_max_age" ]; then
        needs_refresh=false
    fi
fi

# Always load the cache when non-empty (no age check — freshness is the stamp's job). Used
# as primary source for the API path, and as fallback when builtin reports zero.
if [ -f "$cache_file" ] && [ -s "$cache_file" ]; then
    usage_data=$(cat "$cache_file" 2>/dev/null)
fi

# When builtin values are all zero AND reset timestamps are missing, it likely indicates
# an API failure on Claude's side — fall through to cached data instead of displaying
# misleading 0%. Genuine zero responses (after a billing reset) still include valid
# resets_at timestamps, so we trust those.
effective_builtin=false
if $use_builtin; then
    # Trust builtin if any percentage is non-zero (floored, matching PowerShell's Floor)
    if { [ -n "$builtin_five_hour_pct" ] && [ "$(floor_pct "$builtin_five_hour_pct")" != "0" ]; } || \
       { [ -n "$builtin_seven_day_pct" ] && [ "$(floor_pct "$builtin_seven_day_pct")" != "0" ]; }; then
        effective_builtin=true
    fi
    # Also trust if reset timestamps are present — genuine zero responses include valid reset times
    if ! $effective_builtin; then
        if { [ -n "$builtin_five_hour_reset" ] && [ "$builtin_five_hour_reset" != "null" ] && [ "$builtin_five_hour_reset" != "0" ]; } || \
           { [ -n "$builtin_seven_day_reset" ] && [ "$builtin_seven_day_reset" != "null" ] && [ "$builtin_seven_day_reset" != "0" ]; }; then
            effective_builtin=true
        fi
    fi
fi

# Refresh API cache when stale — runs regardless of builtin rate_limits because
# extra_usage is only exposed through the OAuth usage endpoint (not stdin JSON).
# Throttled to cache_max_age and stampede-locked via the fetch stamp for shared panes.
if $needs_refresh; then
    # Touch the stamp up front: it is BOTH the throttle (gates the next fetch for
    # cache_max_age) and the stampede lock (parallel panes see a fresh stamp and skip
    # their own fetch). The cache file is never touched here, so builtin-path cache
    # rewrites can't reset the throttle.
    touch "$fetch_stamp"
    token=$(get_oauth_token)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        # Present the real running client version so the usage endpoint applies its normal
        # rate-limit bucket, not the aggressive one it reserves for atypical User-Agents.
        # A hardcoded version silently rots (it had drifted 160+ releases); source it live
        # instead — stdin .version is the exact client invoking us, then the cached CLI
        # version. The literal is only a last resort for the (production-impossible) case
        # where both live sources are empty; bump it if you ever see it in the wild.
        client_version=$(echo "$input" | jq -r '.version // empty')
        [ -z "$client_version" ] && client_version="$cli_version"
        [ -z "$client_version" ] && client_version="2.1.197"
        # Pass the OAuth token via a curl config read from stdin, NOT as a '-H' argv element.
        # A command-line "-H Authorization: Bearer <token>" is world-readable in /proc/<pid>/cmdline
        # and `ps` for the request's lifetime. `printf` is a bash builtin (no fork), so the token
        # never lands in any process's argv; curl reads the header from the piped --config -.
        response=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -s --max-time 10 \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/${client_version}" \
            --config - \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        # Only cache valid usage responses (not error/rate-limit JSON)
        if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
            usage_data="$response"
            echo "$response" > "$cache_file"
        fi
    fi
fi

# Cross-platform ISO to epoch conversion
# Converts ISO 8601 timestamp (e.g. "2025-06-15T12:30:00Z" or "2025-06-15T12:30:00.123+00:00") to epoch seconds.
# Properly handles UTC timestamps and converts to local time.
iso_to_epoch() {
    local iso_str="$1"

    # Try GNU date first (Linux) — handles ISO 8601 format automatically
    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    # BSD date (macOS) - handle various ISO 8601 formats
    local stripped="${iso_str%%.*}"          # Remove fractional seconds (.123456)
    stripped="${stripped%%Z}"                 # Remove trailing Z
    stripped="${stripped%%+*}"               # Remove timezone offset (+00:00)
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"  # Remove negative timezone offset

    # Check if timestamp is UTC (has Z or +00:00 or -00:00)
    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        # For UTC timestamps, parse with timezone set to UTC
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

# Format ISO reset time to compact local time
# Usage: format_reset_time <iso_string> <style: time|datetime|date>
format_reset_time() {
    local iso_str="$1"
    local style="$2"
    { [ -z "$iso_str" ] || [ "$iso_str" = "null" ]; } && return

    # Parse ISO datetime and convert to local time (cross-platform)
    local epoch
    epoch=$(iso_to_epoch "$iso_str")
    [ -z "$epoch" ] && return

    # Format based on style
    # Try GNU date first (Linux), then BSD date (macOS)
    # Previous implementation piped BSD date through sed/tr, which always returned
    # exit code 0 from the last pipe stage, preventing the GNU date fallback from
    # ever executing on Linux.
    local formatted=""
    case "$style" in
        time)
            formatted=$(date -d "@$epoch" +"%H:%M" 2>/dev/null) || \
            formatted=$(date -j -r "$epoch" +"%H:%M" 2>/dev/null)
            ;;
        datetime)
            # LC_ALL=C pins the weekday abbreviation (%a) to English/capitalized so it matches
            # PowerShell's InvariantCulture; without it a non-English LC_TIME renders e.g. "mer.@10:52".
            formatted=$(LC_ALL=C date -d "@$epoch" +"%a@%H:%M" 2>/dev/null) || \
            formatted=$(LC_ALL=C date -j -r "$epoch" +"%a@%H:%M" 2>/dev/null)
            ;;
        *)
            formatted=$(LC_ALL=C date -d "@$epoch" +"%b %-d" 2>/dev/null) || \
            formatted=$(LC_ALL=C date -j -r "$epoch" +"%b %-d" 2>/dev/null)
            ;;
    esac
    [ -n "$formatted" ] && echo "$formatted"
}

sep=" ${dim}|${reset} "

# Compute the extra_usage cell (row 2, column 2) from API usage data — extra_usage
# is not available via stdin rate_limits. Sets the global extra_cell. Positional:
# defaults to a dim '-' (disabled / no data); shows dollar figures whenever
# is_enabled, INCLUDING a $0 month — the old hide-at-$0.00 rule is gone because a
# grid cell cannot vanish. The grid assembler owns separators; no leading ' | '.
render_extra_usage() {
    local data="$1"
    extra_cell="${dim}-${reset}"
    [ -z "$data" ] && return
    local enabled
    enabled=$(echo "$data" | jq -r '.extra_usage.is_enabled // false' 2>/dev/null)
    [ "$enabled" != "true" ] && return

    local pct raw_used raw_limit used limit color
    raw_used=$(echo "$data" | jq -r '.extra_usage.used_credits // empty')
    raw_limit=$(echo "$data" | jq -r '.extra_usage.monthly_limit // empty')

    # Show dollar figures only when both credit values are numeric. When they are
    # absent or malformed, fall back to a plain "enabled" marker rather than the
    # '-' placeholder — awk would otherwise coerce garbage to 0.
    if [[ "$raw_used" =~ ^[0-9]+([.][0-9]+)?$ ]] && [[ "$raw_limit" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        used=$(fmt_credits "$raw_used")
        limit=$(fmt_credits "$raw_limit")
        pct=$(echo "$data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%d", $1}')
        color=$(usage_color "$pct")
        extra_cell="${white}extra${reset} ${color}\$${used}/\$${limit}${reset}"
    else
        extra_cell="${white}extra${reset} ${green}enabled${reset}"
    fi
}

# 5h/7d cell pieces + the extra cell. Defaults are the no-data placeholders;
# branches overwrite. fh_time/sd_time include their leading '@'; sd_prefix is the
# weekday ('' for 5h).
fh_pct_txt="-"; fh_color="$dim"; fh_time=""
sd_pct_txt="-"; sd_color="$dim"; sd_prefix=""; sd_time=""
extra_cell="${dim}-${reset}"

if $effective_builtin; then
    # ---- Use rate_limits data provided directly by Claude Code in JSON input ----
    # resets_at values are Unix epoch integers in this source
    if [ -n "$builtin_five_hour_pct" ]; then
        five_hour_pct=$(floor_pct "$builtin_five_hour_pct")
        fh_pct_txt="${five_hour_pct}%"
        fh_color=$(usage_color "$five_hour_pct")
        if [ -n "$builtin_five_hour_reset" ] && [ "$builtin_five_hour_reset" != "null" ]; then
            five_hour_reset=$(date -d "@$builtin_five_hour_reset" +"%H:%M" 2>/dev/null || date -j -r "$builtin_five_hour_reset" +"%H:%M" 2>/dev/null)
            [ -n "$five_hour_reset" ] && fh_time="@${five_hour_reset}"
        fi
    fi

    if [ -n "$builtin_seven_day_pct" ]; then
        seven_day_pct=$(floor_pct "$builtin_seven_day_pct")
        sd_pct_txt="${seven_day_pct}%"
        sd_color=$(usage_color "$seven_day_pct")
        if [ -n "$builtin_seven_day_reset" ] && [ "$builtin_seven_day_reset" != "null" ]; then
            seven_day_reset=$(LC_ALL=C date -j -r "$builtin_seven_day_reset" +"%a@%H:%M" 2>/dev/null || LC_ALL=C date -d "@$builtin_seven_day_reset" +"%a@%H:%M" 2>/dev/null)
            if [ -n "$seven_day_reset" ]; then
                sd_prefix="${seven_day_reset%%@*}"
                sd_time="@${seven_day_reset#*@}"
            fi
        fi
    fi

    # Compute the extra cell from the API cache (stdin rate_limits doesn't expose it)
    render_extra_usage "$usage_data"

    # Cache builtin values so they're available as fallback when API is unavailable.
    # Convert epoch resets_at to ISO 8601 for compatibility with the API-format cache parser.
    # Preserve extra_usage from prior API response so we don't clobber it.
    _fh_reset_json="null"
    if [ -n "$builtin_five_hour_reset" ] && [ "$builtin_five_hour_reset" != "null" ] && [ "$builtin_five_hour_reset" != "0" ]; then
        _fh_iso=$(date -u -r "$builtin_five_hour_reset" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                  date -u -d "@$builtin_five_hour_reset" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
        [ -n "$_fh_iso" ] && _fh_reset_json="\"$_fh_iso\""
    fi
    _sd_reset_json="null"
    if [ -n "$builtin_seven_day_reset" ] && [ "$builtin_seven_day_reset" != "null" ] && [ "$builtin_seven_day_reset" != "0" ]; then
        _sd_iso=$(date -u -r "$builtin_seven_day_reset" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                  date -u -d "@$builtin_seven_day_reset" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
        [ -n "$_sd_iso" ] && _sd_reset_json="\"$_sd_iso\""
    fi
    _extra_json=$(echo "$usage_data" | jq -c '.extra_usage // null' 2>/dev/null)
    [ -z "$_extra_json" ] && _extra_json="null"
    printf '{"five_hour":{"utilization":%s,"resets_at":%s},"seven_day":{"utilization":%s,"resets_at":%s},"extra_usage":%s}' \
        "${builtin_five_hour_pct:-0}" "$_fh_reset_json" \
        "${builtin_seven_day_pct:-0}" "$_sd_reset_json" \
        "$_extra_json" > "$cache_file" 2>/dev/null
elif [ -n "$usage_data" ] && echo "$usage_data" | jq -e '.five_hour' >/dev/null 2>&1; then
    # ---- Fall back: API-fetched usage data ----
    # ---- 5-hour (current) ----
    five_hour_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%d", $1}')
    five_hour_reset_iso=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')
    five_hour_reset=$(format_reset_time "$five_hour_reset_iso" "time")
    fh_pct_txt="${five_hour_pct}%"
    fh_color=$(usage_color "$five_hour_pct")
    [ -n "$five_hour_reset" ] && fh_time="@${five_hour_reset}"

    # ---- 7-day (weekly) ----
    seven_day_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%d", $1}')
    seven_day_reset_iso=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')
    seven_day_reset=$(format_reset_time "$seven_day_reset_iso" "datetime")
    sd_pct_txt="${seven_day_pct}%"
    sd_color=$(usage_color "$seven_day_pct")
    if [ -n "$seven_day_reset" ]; then
        sd_prefix="${seven_day_reset%%@*}"
        sd_time="@${seven_day_reset#*@}"
    fi

    render_extra_usage "$usage_data"
else
    : # No valid usage data — the '-' placeholder defaults above stand.
fi

# ---- Compose the 5h/7d cells with internal %/@ alignment ----
# Right-align the percent strings to a shared width, and pad-left the pre-'@'
# fragment (always empty for 5h, the weekday for 7d) so the two '@'s stack. Widths
# derive from the actual values — a 3-digit 100% or a '-' placeholder self-adjusts.
pct_w=${#fh_pct_txt}
[ ${#sd_pct_txt} -gt "$pct_w" ] && pct_w=${#sd_pct_txt}
pre_w=${#sd_prefix}

five_cell="${white}5h${reset} $(printf '%*s' $(( pct_w - ${#fh_pct_txt} )) '')${fh_color}${fh_pct_txt}${reset}"
[ -n "$fh_time" ] && five_cell+=" $(printf '%*s' "$pre_w" '')${dim}${fh_time}${reset}"
seven_cell="${white}7d${reset} $(printf '%*s' $(( pct_w - ${#sd_pct_txt} )) '')${sd_color}${sd_pct_txt}${reset}"
[ -n "$sd_time" ] && seven_cell+=" ${dim}${sd_prefix}${sd_time}${reset}"

# ===== Update check (cached, 24h TTL) =====
# Set STATUSLINE_CHECK_UPDATES=false to disable the update check (no network calls).
update_line=""
if [ "${STATUSLINE_CHECK_UPDATES:-true}" != "false" ]; then
    version_cache_file="$cache_dir/statusline-version-cache.json"
    version_cache_max_age=86400  # 24 hours

    version_needs_refresh=true
    version_data=""

    if [ -f "$version_cache_file" ]; then
        vc_mtime=$(stat -c %Y "$version_cache_file" 2>/dev/null || stat -f %m "$version_cache_file" 2>/dev/null)
        vc_now=$(date +%s)
        vc_age=$(( vc_now - vc_mtime ))
        if [ "$vc_age" -lt "$version_cache_max_age" ]; then
            version_needs_refresh=false
        fi
        version_data=$(cat "$version_cache_file" 2>/dev/null)
    fi

    if $version_needs_refresh; then
        touch "$version_cache_file" 2>/dev/null
        vc_response=$(curl -s --max-time 5 \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/chrisdpurcell/ClaudeCodeStatusLine/releases/latest" 2>/dev/null)
        if [ -n "$vc_response" ] && echo "$vc_response" | jq -e '.tag_name' >/dev/null 2>&1; then
            version_data="$vc_response"
            echo "$vc_response" > "$version_cache_file"
        elif [ ! -s "$version_cache_file" ]; then
            rm -f "$version_cache_file" 2>/dev/null
        fi
    fi

    if [ -n "$version_data" ]; then
        latest_tag=$(echo "$version_data" | jq -r '.tag_name // empty')
        # The version cache is untrusted (poisonable on shared-/tmp systems) and the tag is
        # rendered raw into the terminal — restrict it to version characters so a crafted
        # tag_name can't inject ANSI/OSC escape sequences.
        latest_tag=$(printf '%s' "$latest_tag" | tr -cd 'v0-9.')
        if [ -n "$latest_tag" ] && version_gt "$latest_tag" "$VERSION"; then
            update_line=$'\n'"${dim}Update available: ${latest_tag} → Tell Claude: \"Find my installed status bar and update it\"${reset}"
        fi
    fi
fi

# ===== Assemble the two-line grid =====
# Column width = max visible width of the column's two cells; every cell except the
# last of its row pads right with PLAIN spaces to that width, so the ' | ' separators
# stack vertically. Row 2 always has four cells; row 1 may stop after the 5h cell.
r1=( "$model_cell" "$tokens_cell" "$five_cell" )
r2=( "$version_cell" "$extra_cell" "$seven_cell" )
# The +added/-removed pair is inserted into BOTH rows together (never one alone),
# so cwd@branch and worktree stay column partners whether or not it appears.
if [ -n "$diff_added_cell" ]; then
    r1+=( "$diff_added_cell" )
    r2+=( "$diff_removed_cell" )
fi
[ -n "$cwd_cell" ] && r1+=( "$cwd_cell" )
r2+=( "$worktree_cell" )

line1=""
line2=""
i=0
while [ "$i" -lt "${#r1[@]}" ] || [ "$i" -lt "${#r2[@]}" ]; do
    c1=""; c2=""; w1=0; w2=0
    if [ "$i" -lt "${#r1[@]}" ]; then c1="${r1[$i]}"; w1=$(visible_len "$c1"); fi
    if [ "$i" -lt "${#r2[@]}" ]; then c2="${r2[$i]}"; w2=$(visible_len "$c2"); fi
    w=$(( w1 > w2 ? w1 : w2 ))
    if [ "$i" -lt "${#r1[@]}" ]; then
        if [ "$i" -lt $(( ${#r1[@]} - 1 )) ]; then
            line1+="$c1$(printf '%*s' $(( w - w1 )) '')${sep}"
        else
            line1+="$c1"
        fi
    fi
    if [ "$i" -lt "${#r2[@]}" ]; then
        if [ "$i" -lt $(( ${#r2[@]} - 1 )) ]; then
            line2+="$c2$(printf '%*s' $(( w - w2 )) '')${sep}"
        else
            line2+="$c2"
        fi
    fi
    i=$(( i + 1 ))
done

# Output. '%s' (not '%b') so backslash escapes in JSON-derived fields are printed
# literally and can't split cells; colors and the real newlines (grid + update line)
# are already real bytes above.
printf '%s' "$line1"$'\n'"$line2$update_line"

exit 0
