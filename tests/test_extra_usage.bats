#!/usr/bin/env bats
# Concern: extra-usage — the render_extra_usage() cell of statusline.sh (row 2,
# column 2 of the grid). Covers is_enabled gating (disabled/no data -> '-'
# placeholder), credits/100 dollar formatting with whole-dollar trimming
# ($0, $25, $3.50), always-visible-when-enabled (including $0), usage_color
# wrapping, and the "enabled" fallback branch (numeric-guard driven).
#
# The statusline.ps1 mirror is intentionally UNTESTED here — pwsh is not
# installed on this host, so only statusline.sh is exercised.
load test_helper

# --- Unit-level stub seeding -------------------------------------------------
# render_extra_usage() sets the global $extra_cell and reads several globals that
# are normally set at script top level (white, dim, reset, green, and color vars),
# plus it calls usage_color() and fmt_credits(). Each test seeds exactly the
# globals it needs.

# Seed the minimal stub environment used by the "no color" formatting cases:
# empty color/style vars and a usage_color stub that returns no color code (so
# $color expands to ""). With dim="" the '-' placeholder is a literal "-".
seed_plain_stubs() {
    extra_dollars=""
    white=""
    dim=""
    reset=""
    green=""
    usage_color() { echo ""; }
}

# Seed real-color sentinels so we can prove which color wraps the segment and
# that the color arg is the rounded utilization (not used_credits). Used with
# the REAL usage_color loaded via load_fn.
seed_color_sentinels() {
    extra_dollars=""
    white=""
    dim=""
    reset=""
    red="R"
    orange="O"
    yellow="Y"
    green="G"
}

# --- Integration harness -----------------------------------------------------
# The shared render() helper spins up a FRESH CLAUDE_CONFIG_DIR with no usage
# cache, so it cannot exercise the extra_usage path (usage_data stays empty).
# extra_usage is only ever read from the on-disk API cache, so these tests
# pre-seed that cache directly. The cache path is keyed by an 8-char sha256 of
# CLAUDE_CONFIG_DIR — computed here exactly as statusline.sh does (shasum -a 256
# and sha256sum produce identical digests) — and lives under the per-test
# XDG_RUNTIME_DIR/claude sandbox, so each run's cache is fully isolated and torn
# down with the sandbox (no shared /tmp/claude leakage).
#
# Freshness: a fetch stamp is seeded fresh (mtime age < 60s) => needs_refresh=false,
# so statusline.sh skips the (stubbed anyway) curl refresh entirely. The refresh gate
# now keys off this stamp, NOT the cache file's mtime.
render_seeded() {
    local extra_usage_json="$1" stdin_json="$2"
    local sandbox home cfg stubbin runtime s hash cachedir cache stamp outp
    sandbox="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/statusline.XXXXXX")"
    home="$sandbox/home"; cfg="$sandbox/config"; stubbin="$sandbox/bin"; runtime="$sandbox/run"
    cachedir="$runtime/claude"
    mkdir -p "$home" "$cfg" "$stubbin" "$cachedir"

    # Belt-and-suspenders: shadow network/credential binaries even though the
    # fresh-cache path should never reach them.
    for s in curl secret-tool security claude; do
        printf '#!/bin/sh\nexit 1\n' > "$stubbin/$s"
        chmod +x "$stubbin/$s"
    done

    hash="$(printf '%s' "$cfg" | sha256sum | cut -c1-8)"
    cache="$cachedir/statusline-usage-cache-${hash}.json"
    stamp="$cachedir/statusline-usage-fetched-${hash}"
    printf '{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":0,"resets_at":null},"extra_usage":%s}' \
        "$extra_usage_json" > "$cache"
    touch "$cache" "$stamp"

    outp="$(printf '%s' "$stdin_json" | env \
        -u CLAUDE_CODE_OAUTH_TOKEN \
        -u CLAUDE_CODE_EFFORT_LEVEL \
        HOME="$home" \
        CLAUDE_CONFIG_DIR="$cfg" \
        XDG_RUNTIME_DIR="$runtime" \
        STATUSLINE_CHECK_UPDATES=false \
        PATH="$stubbin:$PATH" \
        bash "$STATUSLINE_SH" 2>/dev/null | strip_ansi)"

    rm -rf "$sandbox"
    printf '%s' "$outp"
}

# ============================ UNIT TESTS ====================================

@test "unit: is_enabled=true, used_credits=1 -> \$0.01/\$50 (no 'extra' word)" {
    load_fn render_extra_usage fmt_credits
    seed_plain_stubs
    render_extra_usage '{"extra_usage":{"is_enabled":true,"utilization":2,"used_credits":1,"monthly_limit":5000}}'
    # used=1/100=0.01 (fractional -> 2dp); limit=5000/100=50 (whole -> integer).
    [ "$extra_dollars" = '$0.01/$50' ]
}

@test "unit: used_credits=0 stays visible as \$0/\$50" {
    load_fn render_extra_usage fmt_credits
    seed_plain_stubs
    render_extra_usage '{"extra_usage":{"is_enabled":true,"utilization":0,"used_credits":0,"monthly_limit":5000}}'
    [ "$extra_dollars" = '$0/$50' ]
}

@test "unit: large amounts -> \$1234.56/\$5000" {
    load_fn render_extra_usage fmt_credits
    seed_plain_stubs
    render_extra_usage '{"extra_usage":{"is_enabled":true,"utilization":75,"used_credits":123456,"monthly_limit":500000}}'
    [ "$extra_dollars" = '$1234.56/$5000' ]
}

@test "unit: is_enabled=false -> empty fragment (nothing appended to version)" {
    load_fn render_extra_usage fmt_credits
    seed_plain_stubs
    extra_dollars="STALE"
    render_extra_usage '{"extra_usage":{"is_enabled":false,"used_credits":9999,"monthly_limit":5000}}'
    [ -z "$extra_dollars" ]
}

@test "unit: is_enabled missing -> empty fragment" {
    load_fn render_extra_usage fmt_credits
    seed_plain_stubs
    extra_dollars="STALE"
    render_extra_usage '{"extra_usage":{"used_credits":9999,"monthly_limit":5000}}'
    [ -z "$extra_dollars" ]
}

@test "unit: empty data arg -> empty fragment" {
    load_fn render_extra_usage fmt_credits
    seed_plain_stubs
    extra_dollars="STALE"
    render_extra_usage ""
    [ -z "$extra_dollars" ]
}

@test "unit: color reflects usage_color(utilization): red at 95" {
    load_fn render_extra_usage fmt_credits usage_color
    seed_color_sentinels
    render_extra_usage '{"extra_usage":{"is_enabled":true,"utilization":95,"used_credits":1,"monthly_limit":5000}}'
    [ "$extra_dollars" = 'R$0.01/$50' ]
}

@test "unit: color green below 50 threshold" {
    load_fn render_extra_usage fmt_credits usage_color
    seed_color_sentinels
    render_extra_usage '{"extra_usage":{"is_enabled":true,"utilization":49,"used_credits":1,"monthly_limit":5000}}'
    [ "$extra_dollars" = 'G$0.01/$50' ]
}

@test "unit: usage_color exact boundaries (49,50,69,70,89,90,0)" {
    load_fn usage_color
    red="R"; orange="O"; yellow="Y"; green="G"
    [ "$(usage_color 49)" = "G" ]
    [ "$(usage_color 50)" = "Y" ]
    [ "$(usage_color 69)" = "Y" ]
    [ "$(usage_color 70)" = "O" ]
    [ "$(usage_color 89)" = "O" ]
    [ "$(usage_color 90)" = "R" ]
    [ "$(usage_color 0)"  = "G" ]
}

@test "unit: fmt_credits trims whole dollars, keeps cents" {
    load_fn fmt_credits
    [ "$(fmt_credits 0)" = "0" ]
    [ "$(fmt_credits 2500)" = "25" ]
    [ "$(fmt_credits 350)" = "3.50" ]
    [ "$(fmt_credits 123456)" = "1234.56" ]
}

@test "unit: enabled but unparseable credits -> 'enabled' marker fragment" {
    load_fn render_extra_usage fmt_credits
    seed_plain_stubs
    render_extra_usage '{"extra_usage":{"is_enabled":true,"utilization":5,"used_credits":"abc","monthly_limit":"xyz"}}'
    [ "$extra_dollars" = "enabled" ]   # green seeded empty -> bare word
}

@test "unit: enabled with missing amounts -> 'enabled' marker fragment" {
    load_fn render_extra_usage fmt_credits
    seed_plain_stubs
    render_extra_usage '{"extra_usage":{"is_enabled":true,"utilization":5}}'
    [ "$extra_dollars" = "enabled" ]
}

# ========================= INTEGRATION TESTS =================================

@test "integration: VISIBLE at \$0 (was hidden pre-grid), 5h block still shows" {
    out="$(render_seeded \
        '{"is_enabled":true,"utilization":0,"used_credits":0,"monthly_limit":5000}' \
        "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":10,\"resets_at\":$(mk_epoch '2026-07-01 11:30')}}}")"
    assert_contains "$out" '$0/$50'
    assert_contains "$out" "5h 10%"
    assert_pipes_aligned "$(line_n "$out" 1)" "$(line_n "$out" 2)"
}

@test "integration: VISIBLE at used_credits=1 -> \$0.01/\$50" {
    out="$(render_seeded \
        '{"is_enabled":true,"utilization":2,"used_credits":1,"monthly_limit":5000}' \
        "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":10,\"resets_at\":$(mk_epoch '2026-07-01 11:30')}}}")"
    assert_contains "$out" '$0.01/$50'
}

@test "integration: VISIBLE large value -> \$1234.56/\$5000" {
    out="$(render_seeded \
        '{"is_enabled":true,"utilization":75,"used_credits":123456,"monthly_limit":500000}' \
        "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":10,\"resets_at\":$(mk_epoch '2026-07-01 11:30')}}}")"
    assert_contains "$out" '$1234.56/$5000'
}

@test "integration: is_enabled=false -> no dollar fragment beside version" {
    out="$(render_seeded \
        '{"is_enabled":false,"used_credits":9999,"monthly_limit":5000}' \
        "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":10,\"resets_at\":$(mk_epoch '2026-07-01 11:30')}}}")"
    # Disabled -> render_extra_usage appends nothing, so the '$used/$limit' fragment (limit
    # 5000c = $50) never renders. refute the limit portion that would otherwise appear.
    refute_contains "$out" '/$50'
}

@test "integration: extra dollars right-align flush to the column pipe" {
    # A WIDE model makes column 1 wider than the version cell, so the dollars must be pushed
    # to the column's right edge — flush against the ' | ' separator with NO trailing pad
    # between them. The old left-packed behavior would leave spaces: '$0/$25   |'.
    out="$(render_seeded \
        '{"is_enabled":true,"utilization":0,"used_credits":0,"monthly_limit":2500}' \
        "{\"model\":{\"display_name\":\"Opus 4.8 (1M context)\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":10,\"resets_at\":$(mk_epoch '2026-07-01 11:30')}}}")"
    assert_contains "$out" '$0/$25 |'
    refute_contains "$out" '$0/$25  |'   # no double space before the pipe (not left-packed)
    assert_pipes_aligned "$(line_n "$out" 1)" "$(line_n "$out" 2)"
}
