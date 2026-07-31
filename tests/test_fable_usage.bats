#!/usr/bin/env bats
# Concern: Fable-scoped weekly usage cell (row 2, col 2) + limits[] cache retention.
# Fable data comes ONLY from the /api/oauth/usage response's limits[] array, so these
# tests pre-seed the on-disk API cache exactly as test_extra_usage.bats does, adding a
# limits[] array. statusline.ps1 is intentionally UNTESTED here (no pwsh on this host).
load test_helper

# Fable weekly limits[] fixture: one weekly_scoped Fable entry at 79%. Tests use bespoke
# inline sandboxes (below) rather than a shared helper because each needs different
# post-render inspection (the rewritten cache file vs. the rendered line).
FABLE_LIMITS='[{"kind":"weekly_scoped","group":"weekly","percent":79,"severity":"warning","resets_at":null,"scope":{"model":{"id":null,"display_name":"Fable"}},"is_active":true}]'

@test "cache: builtin render retains limits[] for the next render" {
    # Bespoke sandbox (not torn down until after we grep the rewritten cache).
    local sandbox home cfg stubbin runtime s hash cache stamp
    sandbox="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/statusline.XXXXXX")"
    home="$sandbox/home"; cfg="$sandbox/config"; stubbin="$sandbox/bin"; runtime="$sandbox/run"
    mkdir -p "$home" "$cfg" "$stubbin" "$runtime/claude"
    for s in curl secret-tool security claude; do
        printf '#!/bin/sh\nexit 1\n' > "$stubbin/$s"; chmod +x "$stubbin/$s"
    done
    hash="$(printf '%s' "$cfg" | sha256sum | cut -c1-8)"
    cache="$runtime/claude/statusline-usage-cache-${hash}.json"
    stamp="$runtime/claude/statusline-usage-fetched-${hash}"
    printf '{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":66,"resets_at":null},"limits":%s,"extra_usage":{"is_enabled":false}}' \
        "$FABLE_LIMITS" > "$cache"
    touch "$cache" "$stamp"
    # A builtin render (rate_limits in stdin) triggers the cache-rewrite branch.
    printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":26,"resets_at":1751763000}}}' | env \
        -u CLAUDE_CODE_OAUTH_TOKEN HOME="$home" CLAUDE_CONFIG_DIR="$cfg" \
        XDG_RUNTIME_DIR="$runtime" STATUSLINE_CHECK_UPDATES=false PATH="$stubbin:$PATH" \
        bash "$STATUSLINE_SH" >/dev/null 2>&1
    run cat "$cache"
    rm -rf "$sandbox"
    assert_contains "$output" '"Fable"'
    assert_contains "$output" '"limits"'
}

# --- Unit stubs: render_fable sets $extra_cell; reads white/dim/reset + usage_color/floor_pct.
seed_fable_plain() { extra_cell=""; white=""; dim=""; reset=""; usage_color() { echo ""; }; }
seed_fable_colors() { extra_cell=""; white=""; dim=""; reset=""; red="R"; orange="O"; yellow="Y"; green="G"; }

@test "unit: Fable entry -> 'Fable 79%'" {
    load_fn render_fable floor_pct visible_len
    seed_fable_plain
    render_fable "{\"limits\":$FABLE_LIMITS}"
    [ "$extra_cell" = 'Fable 79%' ]
}

@test "unit: no Fable entry -> 'Fable 😢' (label stays, percent -> 😢)" {
    # A non-Fable limits entry (or none) means the Fable weekly limit is unavailable: the cell
    # keeps its 'Fable' label and shows a 😢 where the percent would be — never a dim '-'.
    load_fn render_fable floor_pct visible_len
    seed_fable_plain
    extra_cell="STALE"
    render_fable '{"limits":[{"kind":"weekly_all","group":"weekly","percent":66,"scope":null}]}'
    [ "$extra_cell" = 'Fable 😢' ]
}

@test "unit: empty data -> 'Fable 😢' (label stays, percent -> 😢)" {
    load_fn render_fable floor_pct visible_len
    seed_fable_plain
    extra_cell="STALE"
    render_fable ""
    [ "$extra_cell" = 'Fable 😢' ]
}

@test "unit: percent floors (79.9 -> 79) and colors by usage_color" {
    load_fn render_fable floor_pct visible_len usage_color
    seed_fable_colors
    render_fable '{"limits":[{"kind":"weekly_scoped","group":"weekly","percent":79.9,"scope":{"model":{"display_name":"Fable"}}}]}'
    [ "$extra_cell" = 'Fable O79%' ]   # 79 -> orange ("O")
}

@test "unit: 92% -> red" {
    load_fn render_fable floor_pct visible_len usage_color
    seed_fable_colors
    render_fable '{"limits":[{"kind":"weekly_scoped","group":"weekly","percent":92,"scope":{"model":{"display_name":"Fable"}}}]}'
    [ "$extra_cell" = 'Fable R92%' ]
}

@test "unit: percent right-aligns to a wide tokens_cell (gap grows, 'Fable' stays left)" {
    load_fn render_fable floor_pct visible_len
    seed_fable_plain
    tokens_cell="435k/1M 44%"   # 11 visible -> 'Fable'(5) + gap + '79%'(3) must total 11
    render_fable "{\"limits\":$FABLE_LIMITS}"
    [ "$extra_cell" = 'Fable   79%' ]   # 3-space gap
}

@test "integration: Fable 79% renders in col 2, extra \$ rides with version" {
    local sandbox home cfg stubbin runtime s hash cache stamp out
    sandbox="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/statusline.XXXXXX")"
    home="$sandbox/home"; cfg="$sandbox/config"; stubbin="$sandbox/bin"; runtime="$sandbox/run"
    mkdir -p "$home" "$cfg" "$stubbin" "$runtime/claude"
    for s in curl secret-tool security claude; do
        printf '#!/bin/sh\nexit 1\n' > "$stubbin/$s"; chmod +x "$stubbin/$s"
    done
    hash="$(printf '%s' "$cfg" | sha256sum | cut -c1-8)"
    cache="$runtime/claude/statusline-usage-cache-${hash}.json"
    stamp="$runtime/claude/statusline-usage-fetched-${hash}"
    printf '{"five_hour":{"utilization":26,"resets_at":null},"seven_day":{"utilization":66,"resets_at":null},"limits":%s,"extra_usage":{"is_enabled":true,"utilization":0,"used_credits":0,"monthly_limit":2500}}' \
        "$FABLE_LIMITS" > "$cache"
    touch "$cache" "$stamp"
    out="$(printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":26,"resets_at":1751763000}}}' | env \
        -u CLAUDE_CODE_OAUTH_TOKEN HOME="$home" CLAUDE_CONFIG_DIR="$cfg" \
        XDG_RUNTIME_DIR="$runtime" STATUSLINE_CHECK_UPDATES=false PATH="$stubbin:$PATH" \
        bash "$STATUSLINE_SH" 2>/dev/null | strip_ansi)"
    rm -rf "$sandbox"
    assert_contains "$out" 'Fable 79%'
    assert_contains "$out" '$0/$25'
    assert_pipes_aligned "$(line_n "$out" 1)" "$(line_n "$out" 2)"
}

@test "integration: no Fable in limits -> col 2 shows 'Fable 😢' (holds the column)" {
    local sandbox home cfg stubbin runtime s hash cache stamp out
    sandbox="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/statusline.XXXXXX")"
    home="$sandbox/home"; cfg="$sandbox/config"; stubbin="$sandbox/bin"; runtime="$sandbox/run"
    mkdir -p "$home" "$cfg" "$stubbin" "$runtime/claude"
    for s in curl secret-tool security claude; do
        printf '#!/bin/sh\nexit 1\n' > "$stubbin/$s"; chmod +x "$stubbin/$s"
    done
    hash="$(printf '%s' "$cfg" | sha256sum | cut -c1-8)"
    cache="$runtime/claude/statusline-usage-cache-${hash}.json"
    stamp="$runtime/claude/statusline-usage-fetched-${hash}"
    printf '{"five_hour":{"utilization":26,"resets_at":null},"seven_day":{"utilization":66,"resets_at":null},"limits":[],"extra_usage":{"is_enabled":false}}' > "$cache"
    touch "$cache" "$stamp"
    out="$(printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":26,"resets_at":1751763000}}}' | env \
        -u CLAUDE_CODE_OAUTH_TOKEN HOME="$home" CLAUDE_CONFIG_DIR="$cfg" \
        XDG_RUNTIME_DIR="$runtime" STATUSLINE_CHECK_UPDATES=false PATH="$stubbin:$PATH" \
        bash "$STATUSLINE_SH" 2>/dev/null | strip_ansi)"
    rm -rf "$sandbox"
    # The cell does NOT vanish or dim to '-': 'Fable' label stays and the percent is a 😢.
    # tokens render '0/200k 0%' (9 wide), so 'Fable  😢' (5 + 2-gap + 2) is also 9 and aligns.
    assert_contains "$(line_n "$out" 2)" 'Fable  😢'
    refute_contains "$out" '| - |'
    # Prove the column did NOT slide (an empty/mis-sized cell would misalign row-2's pipes).
    assert_pipes_aligned "$(line_n "$out" 1)" "$(line_n "$out" 2)"
}

@test "integration: Fable percent right-aligns flush to the column pipe" {
    # A wide token cell (row 1, col 2) makes column 2 wider than 'Fable 79%', so the percent
    # is pushed to the column's right edge — flush against the ' | ' with no trailing pad.
    # Old left-packed behavior would leave spaces: '79%   |'.
    local sandbox home cfg stubbin runtime s hash cache stamp out
    sandbox="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/statusline.XXXXXX")"
    home="$sandbox/home"; cfg="$sandbox/config"; stubbin="$sandbox/bin"; runtime="$sandbox/run"
    mkdir -p "$home" "$cfg" "$stubbin" "$runtime/claude"
    for s in curl secret-tool security claude; do
        printf '#!/bin/sh\nexit 1\n' > "$stubbin/$s"; chmod +x "$stubbin/$s"
    done
    hash="$(printf '%s' "$cfg" | sha256sum | cut -c1-8)"
    cache="$runtime/claude/statusline-usage-cache-${hash}.json"
    stamp="$runtime/claude/statusline-usage-fetched-${hash}"
    printf '{"five_hour":{"utilization":26,"resets_at":null},"seven_day":{"utilization":66,"resets_at":null},"limits":%s,"extra_usage":{"is_enabled":false}}' \
        "$FABLE_LIMITS" > "$cache"
    touch "$cache" "$stamp"
    # context_window makes tokens render '435k/1M 44%' (11 wide) > 'Fable 79%' (9).
    out="$(printf '%s' '{"context_window":{"used_percentage":44,"context_window_size":1000000,"current_usage":{"input_tokens":435000}},"rate_limits":{"five_hour":{"used_percentage":26,"resets_at":1751763000}}}' | env \
        -u CLAUDE_CODE_OAUTH_TOKEN HOME="$home" CLAUDE_CONFIG_DIR="$cfg" \
        XDG_RUNTIME_DIR="$runtime" STATUSLINE_CHECK_UPDATES=false PATH="$stubbin:$PATH" \
        bash "$STATUSLINE_SH" 2>/dev/null | strip_ansi)"
    rm -rf "$sandbox"
    assert_contains "$out" 'Fable   79%'   # 3-space gap (5 + 3 + 3 = 11)
    assert_contains "$out" '79% |'         # percent flush to the pipe
    refute_contains "$out" '79%  |'        # not left-packed with trailing pad
    assert_pipes_aligned "$(line_n "$out" 1)" "$(line_n "$out" 2)"
}

@test "integration: token percent right-aligns flush when Fable is the wider cell" {
    # The mirror of the test above: a narrow token cell '0/1M 0%' (7 wide) is narrower than
    # 'Fable 79%' (9), so column 2's width comes from the Fable row. The token percent must be
    # pushed to the column's right edge so it stacks under Fable's — '0/1M   0%', flush to the
    # ' | '. Old left-packed behavior padded AFTER the percent: '0/1M 0%  |'.
    local sandbox home cfg stubbin runtime s hash cache stamp out
    sandbox="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/statusline.XXXXXX")"
    home="$sandbox/home"; cfg="$sandbox/config"; stubbin="$sandbox/bin"; runtime="$sandbox/run"
    mkdir -p "$home" "$cfg" "$stubbin" "$runtime/claude"
    for s in curl secret-tool security claude; do
        printf '#!/bin/sh\nexit 1\n' > "$stubbin/$s"; chmod +x "$stubbin/$s"
    done
    hash="$(printf '%s' "$cfg" | sha256sum | cut -c1-8)"
    cache="$runtime/claude/statusline-usage-cache-${hash}.json"
    stamp="$runtime/claude/statusline-usage-fetched-${hash}"
    printf '{"five_hour":{"utilization":26,"resets_at":null},"seven_day":{"utilization":66,"resets_at":null},"limits":%s,"extra_usage":{"is_enabled":false}}' \
        "$FABLE_LIMITS" > "$cache"
    touch "$cache" "$stamp"
    # context_window makes tokens render '0/1M 0%' (7 wide) < 'Fable 79%' (9).
    out="$(printf '%s' '{"context_window":{"used_percentage":0,"context_window_size":1000000,"current_usage":{"input_tokens":0}},"rate_limits":{"five_hour":{"used_percentage":26,"resets_at":1751763000}}}' | env \
        -u CLAUDE_CODE_OAUTH_TOKEN HOME="$home" CLAUDE_CONFIG_DIR="$cfg" \
        XDG_RUNTIME_DIR="$runtime" STATUSLINE_CHECK_UPDATES=false PATH="$stubbin:$PATH" \
        bash "$STATUSLINE_SH" 2>/dev/null | strip_ansi)"
    rm -rf "$sandbox"
    assert_contains "$out" '0/1M   0%'   # 3-space gap (4 + 3 + 2 = 9), percent pushed right
    assert_contains "$out" '0% |'        # token percent flush to the pipe
    refute_contains "$out" '0%  |'       # not left-packed with trailing pad (the old bug)
    assert_pipes_aligned "$(line_n "$out" 1)" "$(line_n "$out" 2)"
}

@test "integration: 😢 counts as width 2 when it is col 2's wider cell (pipes align)" {
    # The strongest guard on the emoji width accounting: NO Fable data (-> 😢) with a NARROW
    # token cell '0/1M 0%' (7). 'Fable 😢' is 8 display-wide (5 + 1 + 2), wider than the tokens,
    # so column 2 sizes to the Fable row and the token percent is pushed right to stack under
    # the 😢. If visible_len miscounted 😢 as width 1, 'Fable 😢' would size to 7, the row-2 pipe
    # after it would sit one column left of row 1's, and assert_pipes_aligned (which measures
    # display columns) would catch it.
    local sandbox home cfg stubbin runtime s hash cache stamp out
    sandbox="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/statusline.XXXXXX")"
    home="$sandbox/home"; cfg="$sandbox/config"; stubbin="$sandbox/bin"; runtime="$sandbox/run"
    mkdir -p "$home" "$cfg" "$stubbin" "$runtime/claude"
    for s in curl secret-tool security claude; do
        printf '#!/bin/sh\nexit 1\n' > "$stubbin/$s"; chmod +x "$stubbin/$s"
    done
    hash="$(printf '%s' "$cfg" | sha256sum | cut -c1-8)"
    cache="$runtime/claude/statusline-usage-cache-${hash}.json"
    stamp="$runtime/claude/statusline-usage-fetched-${hash}"
    # limits[] present but with NO Fable entry -> the 😢 unavailable path.
    printf '{"five_hour":{"utilization":26,"resets_at":null},"seven_day":{"utilization":66,"resets_at":null},"limits":[],"extra_usage":{"is_enabled":false}}' > "$cache"
    touch "$cache" "$stamp"
    out="$(printf '%s' '{"context_window":{"used_percentage":0,"context_window_size":1000000,"current_usage":{"input_tokens":0}},"rate_limits":{"five_hour":{"used_percentage":26,"resets_at":1751763000}}}' | env \
        -u CLAUDE_CODE_OAUTH_TOKEN HOME="$home" CLAUDE_CONFIG_DIR="$cfg" \
        XDG_RUNTIME_DIR="$runtime" STATUSLINE_CHECK_UPDATES=false PATH="$stubbin:$PATH" \
        bash "$STATUSLINE_SH" 2>/dev/null | strip_ansi)"
    rm -rf "$sandbox"
    assert_contains "$(line_n "$out" 2)" 'Fable 😢'   # 1-space gap (col 2 sized to Fable's 8)
    assert_contains "$out" '0/1M  0%'                 # token % pushed right to stack under 😢
    assert_pipes_aligned "$(line_n "$out" 1)" "$(line_n "$out" 2)"
}
