#!/bin/bash
# Source: https://github.com/chrisdpurcell/ClaudeCodeStatusLine
# Originally created by Daniel Oliveira (https://github.com/daniel3303/ClaudeCodeStatusLine); maintained by Chris Purcell.
# Two lines, pipe-aligned grid (column width = max visible width of its two cells):
#   Model [✦] effort  | tokens %used | 5h N%    @reset | [+added]   | cwd@branch[:worktree]
#   vVERSION [$x/$y]  | Fable N%     | 7d N% Day@reset | [-removed] | ~/path/to/cwd
# Cells are positional: row 2 always renders version/Fable/7d (dim '-' placeholders for
# unknown version / absent Fable weekly); the extra-usage '$used/$limit' rides in the
# version cell when enabled; Fable is the Fable-scoped weekly usage % (col 2), or a 😢 in
# place of the percent when the Fable weekly limit is unavailable (the label always stays);
# the +added/-removed pair is inserted into BOTH rows together, only while the tree is dirty.
# The trailing column is cwd-derived and shared: row 1 shows basename@branch[:worktree],
# row 2 the full path with $HOME collapsed to '~'; both cells appear or omit together, so
# when there is no cwd both rows simply end after their usage cells. The worktree name
# (--worktree sessions only) rides on the end of row 1's branch as ':name', hidden with its
# colon otherwise. The 5h/7d cells right-align their percents and stack their '@'s; the
# effort word (col 1), token % and Fable % (col 2) and the extra-usage dollars (col 1)
# likewise right-align to their column's edge so they stack vertically. The ✦ between model
# and effort appears only when thinking.enabled is true.

set -f  # disable globbing
shopt -s extglob  # extended globs in ${var//pat/} — visible_len strips SGR escapes with *([0-9;])
VERSION="1.8.2"

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

# Collapse a leading $HOME in a path to '~' for the compact row-2 cwd cell (e.g.
# /home/me/projects/x -> ~/projects/x). A function (not an inline case) so the suite can
# exercise it via load_fn. The `case` glob matches even under `set -f` (globbing off
# affects pathname expansion, not case patterns). No-op when HOME is unset.
collapse_home() {
    local p="$1"
    if [ -n "$HOME" ]; then
        case "$p" in
            "$HOME")   p="~" ;;
            "$HOME"/*) p="~${p#"$HOME"}" ;;
        esac
    fi
    printf '%s' "$p"
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
    # 😢 (Fable-unavailable marker) is an emoji: one code point but TWO terminal columns
    # (and 4 UTF-8 bytes under a C locale). ${#} would count 1 (UTF-8) or 4 (C), both wrong
    # for alignment — swap it for two ASCII chars so the width is its display width (2) in
    # any locale, so the pipe after the Fable cell stays aligned. (PowerShell needs no
    # equivalent — .Length counts its surrogate pair as 2, already the display width.)
    s="${s//😢/..}"
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

used_tokens=$(format_tokens "$current")
total_tokens=$(format_tokens "$size")

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
# Split the fused cell into a prefix (bare model name) and the effort group so the effort can
# be right-aligned to column 1's edge after the version cell is finalized (see the effort
# right-align pass below render_extra_usage). The ✦ thinking marker joins the effort GROUP (not
# the prefix) so the right-align pad lands between the model name and '✦ effort', keeping the ✦
# flush against the effort word at the pipe. Built here in natural (1-space) form, which is also
# the width render_extra_usage measures to size column 1.
[ "$thinking_enabled" = "true" ] && effort_part="${purple}✦${reset} ${effort_part}"
model_prefix="${blue}${model_name}${reset}"
model_cell="${model_prefix} ${effort_part}"

# Worktree name — read before the cwd block so it can ride on row 1's branch. stdin
# .worktree.name exists only in --worktree isolation sessions.
worktree_name=$(echo "$input" | jq -r '.worktree.name // empty')

# Current working directory drives BOTH trailing cells: row 1's basename@branch[:worktree]
# (cwd_cell) and row 2's full path with $HOME collapsed to '~' (path_cell). Both are
# cwd-derived, so they appear or omit together as column partners. Prefer
# workspace.current_dir (the documented-preferred alias); fall back to .cwd for older CLIs.
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
cwd_cell=""
path_cell=""
diff_added_cell=""
diff_removed_cell=""
if [ -n "$cwd" ]; then
    display_dir="${cwd##*/}"
    git_branch=$(git -C "${cwd}" rev-parse --abbrev-ref HEAD 2>/dev/null)
    cwd_cell="${green}${display_dir}${reset}"
    if [ -n "$git_branch" ]; then
        cwd_cell+="${dim}@${reset}${blue}${git_branch}${reset}"
        # Worktree rides on the end of the branch as ':name' (dim ':' + cyan name), only in
        # --worktree sessions; the colon and name hide together otherwise.
        [ -n "$worktree_name" ] && cwd_cell+="${dim}:${reset}${cyan}${worktree_name}${reset}"
        # Unstaged line changes, tracked files only — rendered as a stacked column
        # pair (+added over -removed) that exists only while the tree is dirty.
        git_stat=$(git -C "${cwd}" diff --numstat 2>/dev/null | awk '{a+=$1; d+=$2} END {if (a+d>0) printf "%d %d", a, d}')
        if [ -n "$git_stat" ]; then
            diff_added_cell="${green}+${git_stat%% *}${reset}"
            diff_removed_cell="${red}-${git_stat##* }${reset}"
        fi
    fi
    path_cell="${cyan}$(collapse_home "$cwd")${reset}"
fi

# Token cell (row 1, col 2). Split into prefix (used/total) and percent so the percent can be
# right-aligned to column 2's edge once the Fable cell (row 2) is sized — see the token
# right-align pass just below render_fable. Built here in natural (1-space) form, which is
# also what render_fable measures to size column 2.
tokens_prefix="${orange}${used_tokens}/${total_tokens}${reset}"
tokens_pct="${green}${pct_used}%${reset}"
tokens_cell="${tokens_prefix} ${tokens_pct}"

# CLI version — row 2, column 1. Positional, so unknown renders '-' rather than
# vanishing (vanishing would slide the whole second row left).
if [ -n "$cli_version" ]; then
    version_cell="${orange}v${cli_version}${reset}"
else
    version_cell="${dim}-${reset}"
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

# Compute the extra-usage dollars FRAGMENT (row 2, col 1 — appended to version_cell).
# extra_usage is only in the API response, not stdin rate_limits. Sets the global
# extra_dollars: a colored "$used/$limit" when enabled + numeric; an "enabled" marker
# when enabled but unparseable; empty otherwise (nothing gets appended to the version).
render_extra_usage() {
    local data="$1"
    extra_dollars=""
    [ -z "$data" ] && return
    local enabled
    enabled=$(echo "$data" | jq -r '.extra_usage.is_enabled // false' 2>/dev/null)
    [ "$enabled" != "true" ] && return

    local pct raw_used raw_limit used limit color
    raw_used=$(echo "$data" | jq -r '.extra_usage.used_credits // empty')
    raw_limit=$(echo "$data" | jq -r '.extra_usage.monthly_limit // empty')

    if [[ "$raw_used" =~ ^[0-9]+([.][0-9]+)?$ ]] && [[ "$raw_limit" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        used=$(fmt_credits "$raw_used")
        limit=$(fmt_credits "$raw_limit")
        pct=$(echo "$data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%d", $1}')
        color=$(usage_color "$pct")
        extra_dollars="${color}\$${used}/\$${limit}${reset}"
    else
        # Enabled but credit values unparseable: keep the spec's "enabled" marker
        # (awk would coerce garbage to a fake $0), rendered as "v…  enabled".
        extra_dollars="${green}enabled${reset}"
    fi
}

# Fable weekly usage cell (row 2, col 2) — the Fable-scoped weekly limit from the API
# response's limits[] array (never stdin). Hardcoded to display_name=="Fable"; a future
# scoped model won't hijack this cell. Percent floored + colored like the 5h/7d cells; no
# reset time (it shares the 7d window, already shown in col 3). When the Fable weekly limit
# is ABSENT (Fable left subscription plans 2026-07-07, non-Fable accounts, or no API data)
# the cell does NOT vanish or dim to '-': the 'Fable' label stays and the percent becomes a
# 😢, holding the column until Fable returns to subscription plans. The 😢 is display-width 2
# (see visible_len), so it right-aligns to the column edge exactly like a percent would.
render_fable() {
    local data="$1"
    # Default = Fable unavailable. Overwritten below only when a numeric Fable percent exists.
    local pct_txt="😢" color="$reset"
    if [ -n "$data" ]; then
        local pct
        pct=$(echo "$data" | jq -r '.limits[]? | select((.scope.model.display_name // "")=="Fable") | .percent' 2>/dev/null | head -n1)
        if [ -n "$pct" ] && [[ "$pct" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            pct=$(floor_pct "$pct")
            color=$(usage_color "$pct")
            pct_txt="${pct}%"
        fi
    fi
    # Right-align the value ('NN%' or 😢) to column 2's RIGHT edge, 'Fable' stays left —
    # padding goes BETWEEN the label and the value. Column 2's width is max(tokens row 1,
    # Fable row 2) and tokens_cell is the only row-1 cell there, so size it now and pre-expand
    # (1-space minimum gap). 'Fable' is a fixed 5 visible chars; the value's width comes from
    # visible_len (so the double-width 😢 counts as 2).
    local lab_len=5 pl tok gap target natural
    pl=$(visible_len "$pct_txt")
    tok=$(visible_len "${tokens_cell:-}")
    natural=$(( lab_len + 1 + pl ))
    target=$(( tok > natural ? tok : natural ))
    gap=$(( target - lab_len - pl ))
    extra_cell="${white}Fable${reset}$(printf '%*s' "$gap" '')${color}${pct_txt}${reset}"
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
    # Preserve the model-scoped limits[] array (Fable weekly lives here) across the
    # builtin-path rewrite; without it the Fable cell flickers to '-' on cached renders.
    _limits_json=$(echo "$usage_data" | jq -c '.limits // null' 2>/dev/null)
    [ -z "$_limits_json" ] && _limits_json="null"
    printf '{"five_hour":{"utilization":%s,"resets_at":%s},"seven_day":{"utilization":%s,"resets_at":%s},"limits":%s,"extra_usage":%s}' \
        "${builtin_five_hour_pct:-0}" "$_fh_reset_json" \
        "${builtin_seven_day_pct:-0}" "$_sd_reset_json" \
        "$_limits_json" "$_extra_json" > "$cache_file" 2>/dev/null
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
else
    : # No valid usage data — the '-' placeholder defaults above stand.
fi

# extra-usage dollars ride along in the version cell (row 2, col 1); Fable weekly takes
# the freed col-2 slot. Both read the API response only, so compute them once here — after
# every branch has populated usage_data — regardless of which usage source rendered 5h/7d.
render_extra_usage "$usage_data"
# Right-align the extra-usage dollars to column 1's RIGHT edge (flush with the ' | '),
# putting the pad BETWEEN the version and the dollars instead of after the cell. Column 1's
# width is max(model row 1, version row 2) and model_cell is the only row-1 cell here, so we
# can size it now and pre-expand — the generic pad pass then adds zero trailing pad. Keeps a
# 2-space minimum gap for the (rare) case where the version cell is the wider of the two.
if [ -n "$extra_dollars" ]; then
    ed_vlen=$(visible_len "$version_cell")
    ed_dlen=$(visible_len "$extra_dollars")
    ed_mlen=$(visible_len "$model_cell")
    ed_natural=$(( ed_vlen + 2 + ed_dlen ))
    ed_target=$(( ed_mlen > ed_natural ? ed_mlen : ed_natural ))
    ed_gap=$(( ed_target - ed_vlen - ed_dlen ))
    version_cell="${version_cell}$(printf '%*s' "$ed_gap" '')${extra_dollars}"
fi

# Right-align the effort word to column 1's RIGHT edge so it stays flush with the ' | ' and
# doesn't drift when the version+dollars cell is the wider of the two — otherwise the generic
# pad pass would add the slack AFTER the effort word (that trailing pad was the bug: high
# dollars widened col 1, pushing 'effort' off the pipe). Col 1's width is max(model natural,
# finalized version cell); pad BETWEEN the model name and the '✦ effort' group (1-space min). Same
# sub-align idiom as the extra dollars / token % / Fable %; run unconditionally (not just when
# dollars exist) so col 1 stays right-aligned whichever cell is wider.
m_col=$(visible_len "$version_cell")
m_natural=$(visible_len "$model_cell")
[ "$m_col" -lt "$m_natural" ] && m_col=$m_natural
m_pfx_w=$(visible_len "$model_prefix")
m_eff_w=$(visible_len "$effort_part")
m_gap=$(( m_col - m_pfx_w - m_eff_w ))
[ "$m_gap" -lt 1 ] && m_gap=1
model_cell="${model_prefix}$(printf '%*s' "$m_gap" '')${effort_part}"

render_fable "$usage_data"

# Right-align the token percent to column 2's RIGHT edge so it stacks under the Fable
# percent (row 2). render_fable has already sized extra_cell to column 2's width
# (max of the token natural width and the Fable cell), so pad BETWEEN used/total and the
# percent up to that width — a 1-space minimum matches the natural form when the token cell
# is the wider of the two.
tk_col=$(visible_len "$extra_cell")
tk_natural=$(visible_len "$tokens_cell")
[ "$tk_col" -lt "$tk_natural" ] && tk_col=$tk_natural
tk_pfx_w=$(visible_len "$tokens_prefix")
tk_pct_w=$(visible_len "$tokens_pct")
tk_gap=$(( tk_col - tk_pfx_w - tk_pct_w ))
[ "$tk_gap" -lt 1 ] && tk_gap=1
tokens_cell="${tokens_prefix}$(printf '%*s' "$tk_gap" '')${tokens_pct}"

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
# stack vertically. Both rows share the same three leading cells (version/Fable/7d in
# row 2); the trailing cwd column is optional and appears in both rows or neither.
r1=( "$model_cell" "$tokens_cell" "$five_cell" )
r2=( "$version_cell" "$extra_cell" "$seven_cell" )
# The +added/-removed pair is inserted into BOTH rows together (never one alone), so the
# cwd cell (row 1) and path cell (row 2) stay column partners whether or not it appears.
if [ -n "$diff_added_cell" ]; then
    r1+=( "$diff_added_cell" )
    r2+=( "$diff_removed_cell" )
fi
# cwd_cell and path_cell are both set iff cwd is present, so they are appended together
# (same trailing column) or omitted together — no positional '-' placeholder needed.
[ -n "$cwd_cell" ] && r1+=( "$cwd_cell" )
[ -n "$path_cell" ] && r2+=( "$path_cell" )

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
