#!/usr/bin/env bats
# Concern: regression guards for the parity/robustness fixes from the 2026-07-01 code
# review (see CHANGELOG.md). Only the Bash-observable fixes are covered here — the
# PowerShell mirror is untested on this host (no pwsh), so its matching changes are
# verified by structural review, not execution.
load test_helper

# --- #2 rate-limit percentages floor (was: Bash rounded, PS floored) --------------

@test "fix: builtin rate-limit % floors 89.6 -> 89 (matches PowerShell)" {
    out="$(render '{"model":{"display_name":"X"},"rate_limits":{"five_hour":{"used_percentage":89.6,"resets_at":1893456000},"seven_day":{"used_percentage":10,"resets_at":1893456000}}}')"
    assert_contains "$out" "5h 89%"
    refute_contains "$out" "5h 90%"
}

@test "fix: fractional % below 1 floors to 0 and is NOT trusted (matches PowerShell)" {
    # 0.7% with no reset timestamps: floor -> 0, effective_builtin stays false, so we fall
    # through to the placeholder. (Previously Bash rounded 0.7 -> 1, trusted it, and showed
    # '5h 1%' where PowerShell showed the '-' placeholder.)
    out="$(render '{"model":{"display_name":"X"},"rate_limits":{"five_hour":{"used_percentage":0.7},"seven_day":{"used_percentage":0.3}}}')"
    assert_contains "$out" "5h -"
    refute_contains "$out" "5h 1%"
}

# --- #6 effort level is lowercased before matching (was: Bash case-sensitive) ------

@test "fix: effort 'Max' is lowercased to 'max' (matches PowerShell switch)" {
    out="$(render '{"model":{"display_name":"X"},"effort":{"level":"Max"}}')"
    # Effort right-aligns to the col-1 edge, so assert the word flush at the ' | ' rather
    # than adjacent to 'X'. The point here is the lowercasing: 'max' present, 'Max' absent.
    assert_contains "$(line_n "$out" 1)" "max |"
    refute_contains "$out" "Max"
}

@test "fix: effort 'MEDIUM' lowercases then maps to 'med'" {
    out="$(render '{"model":{"display_name":"X"},"effort":{"level":"MEDIUM"}}')"
    assert_contains "$(line_n "$out" 1)" "med |"
    refute_contains "$out" "MEDIUM"
}

# --- #7 final output uses printf %s, so JSON-derived escapes are literal -----------

@test "fix: literal backslash-n in display_name is NOT expanded to a newline" {
    # JSON '\\n' -> jq yields the two chars backslash+n -> must print literally (printf %s),
    # not as a real newline (printf %b would have split the single-line output).
    out="$(render '{"model":{"display_name":"Claude\\nPro"}}')"
    assert_contains "$out" "Claude\\nPro"
}

# --- fetch stamp decouples the OAuth-fetch throttle from cache writes ---------------
# The refresh gate keys off a dedicated fetch stamp, NOT the usage cache's mtime, so a
# fresh cache alone must NOT suppress a fetch — only a fresh stamp does. Probe by stubbing
# curl to record its invocation, then run with a fresh cache and either no stamp or a
# fresh stamp.
probe_fetch() {
    local mode="$1"   # "nostamp" | "stamp"
    local sandbox home cfg stubbin runtime cachedir hash cache stamp marker s
    sandbox="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/statusline.XXXXXX")"
    home="$sandbox/home"; cfg="$sandbox/config"; stubbin="$sandbox/bin"; runtime="$sandbox/run"
    cachedir="$runtime/claude"; marker="$sandbox/curl-called"
    mkdir -p "$home" "$cfg" "$stubbin" "$cachedir"
    # curl stub records each call to the marker; emits no valid body so the cache is untouched.
    printf '#!/bin/sh\necho called >> "%s"\nexit 0\n' "$marker" > "$stubbin/curl"
    chmod +x "$stubbin/curl"
    for s in secret-tool security claude; do
        printf '#!/bin/sh\nexit 1\n' > "$stubbin/$s"; chmod +x "$stubbin/$s"
    done
    hash="$(printf '%s' "$cfg" | sha256sum | cut -c1-8)"
    cache="$cachedir/statusline-usage-cache-${hash}.json"
    stamp="$cachedir/statusline-usage-fetched-${hash}"
    # Fresh, valid usage cache (has .five_hour) — loaded regardless of the stamp.
    printf '{"five_hour":{"utilization":5,"resets_at":null},"seven_day":{"utilization":0,"resets_at":null}}' > "$cache"
    touch "$cache"
    [ "$mode" = "stamp" ] && touch "$stamp"
    # A token is required for the refresh path to reach curl; update check disabled so the
    # ONLY possible curl is the usage fetch.
    printf '%s' '{"model":{"display_name":"X"}}' | env \
        -u CLAUDE_CODE_EFFORT_LEVEL \
        HOME="$home" CLAUDE_CONFIG_DIR="$cfg" XDG_RUNTIME_DIR="$runtime" \
        CLAUDE_CODE_OAUTH_TOKEN="test-token" \
        STATUSLINE_CHECK_UPDATES=false \
        PATH="$stubbin:$PATH" \
        bash "$STATUSLINE_SH" >/dev/null 2>&1
    if [ -f "$marker" ]; then echo CALLED; else echo SKIPPED; fi
    rm -rf "$sandbox"
}

@test "fix: absent fetch stamp triggers a fetch even with a fresh cache" {
    [ "$(probe_fetch nostamp)" = "CALLED" ]
}

@test "fix: fresh fetch stamp suppresses the fetch" {
    [ "$(probe_fetch stamp)" = "SKIPPED" ]
}

# --- update-tag sanitization: cached tag_name is rendered raw, so restrict its charset ---
# Seed a fresh version cache whose tag_name carries an OSC escape sequence + junk. The tag
# must reach the terminal stripped to version chars only (no escape bytes, no injected text).
probe_update() {
    local tag="$1"   # literal JSON string content (\uXXXX escapes allowed)
    local sandbox home cfg stubbin runtime cachedir vcache outp s
    sandbox="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/statusline.XXXXXX")"
    home="$sandbox/home"; cfg="$sandbox/config"; stubbin="$sandbox/bin"; runtime="$sandbox/run"
    cachedir="$runtime/claude"
    mkdir -p "$home" "$cfg" "$stubbin" "$cachedir"
    for s in curl secret-tool security claude; do
        printf '#!/bin/sh\nexit 1\n' > "$stubbin/$s"; chmod +x "$stubbin/$s"
    done
    vcache="$cachedir/statusline-version-cache.json"
    # jq -R encodes any raw control bytes in $tag into valid JSON (\uXXXX), which the
    # script's own `jq -r` then decodes back to the real bytes — exercising the escape path.
    printf '%s' "$tag" | jq -R '{tag_name: .}' > "$vcache"
    touch "$vcache"   # fresh -> update check reads cache, no refresh curl
    # Update check ENABLED (not "false"); strip_ansi removes CSI SGR but NOT the OSC escape,
    # so a surviving injection would be detectable in $outp.
    outp="$(printf '%s' '{"model":{"display_name":"X"}}' | env \
        -u CLAUDE_CODE_EFFORT_LEVEL -u CLAUDE_CODE_OAUTH_TOKEN \
        HOME="$home" CLAUDE_CONFIG_DIR="$cfg" XDG_RUNTIME_DIR="$runtime" \
        STATUSLINE_CHECK_UPDATES=true \
        PATH="$stubbin:$PATH" \
        bash "$STATUSLINE_SH" 2>/dev/null | strip_ansi)"
    rm -rf "$sandbox"
    printf '%s' "$outp"
}

@test "fix: escape-laden update tag is stripped to version chars before render" {
    # tag_name = v9.9.9 + ESC]HACKED BEL (an OSC title-injection payload). Sanitized to
    # "v9.9.9"; the escape byte and the injected word must never reach the terminal.
    out="$(probe_update "v9.9.9$(printf '\033')]HACKED$(printf '\007')")"
    assert_contains "$out" "Update available: v9.9.9"
    refute_contains "$out" "HACKED"
    refute_contains "$out" "$(printf '\033')"
}
